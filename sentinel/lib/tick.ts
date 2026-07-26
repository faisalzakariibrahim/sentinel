import { logAudit } from "./audit";
import { db } from "./db";
import { executeTask, UnsupportedToolError } from "./executor";
import { checkBudget, checkKillSwitch } from "./guards";
import { judgeTask } from "./judge";
import { AgentRoleRow, TaskRow, ToolRow } from "./types";

const BATCH_LIMIT = 10;
const REPAIR_CAP = 3; // repair attempts before forcing Level 2 escalation

export interface TickSummary {
  halted?: string;
  approvals: { approved: number; rejected: number; blockedDownstream: number };
  tasks: { id: string; outcome: string }[];
  goalsCompleted: number;
}

// Approved tasks unblock their children via the unblocked_tasks view
// (status 'approved' counts as a satisfied parent). Rejected tasks mark all
// transitive dependents blocked — not silently dropped.
async function processApprovalDecisions(): Promise<TickSummary["approvals"]> {
  const approved = await db().query(
    `update tasks set status = 'approved', updated_at = now()
     where status = 'awaiting_approval'
       and id in (select task_id from approval_queue where decision = 'approved')
     returning id`,
  );
  for (const row of approved.rows) {
    await logAudit(db(), { taskId: row.id, eventType: "approved", actor: "system" });
  }

  const rejected = await db().query(
    `update tasks set status = 'rejected', updated_at = now()
     where status = 'awaiting_approval'
       and id in (select task_id from approval_queue where decision = 'rejected')
     returning id`,
  );

  let blockedDownstream = 0;
  for (const row of rejected.rows) {
    await logAudit(db(), { taskId: row.id, eventType: "rejected", actor: "system" });
    const blocked = await db().query(
      `with recursive descendants as (
         select child_task_id as id from task_edges
         where parent_task_id = $1 and edge_type = 'blocks'
         union
         select te.child_task_id from task_edges te
         join descendants d on d.id = te.parent_task_id
         where te.edge_type = 'blocks'
       )
       update tasks set status = 'blocked', updated_at = now()
       where id in (select id from descendants)
         and status in ('pending', 'repair')
       returning id`,
      [row.id],
    );
    blockedDownstream += blocked.rowCount ?? 0;
    for (const b of blocked.rows) {
      await logAudit(db(), {
        taskId: b.id,
        eventType: "blocked",
        actor: "system",
        payload: { rejected_ancestor: row.id },
      });
    }
  }

  return {
    approved: approved.rowCount ?? 0,
    rejected: rejected.rowCount ?? 0,
    blockedDownstream,
  };
}

async function setStatus(taskId: string, status: string): Promise<void> {
  await db().query(`update tasks set status = $2, updated_at = now() where id = $1`, [
    taskId,
    status,
  ]);
}

async function enqueueApproval(task: TaskRow, tier: number, reason: string): Promise<void> {
  await setStatus(task.id, "awaiting_approval");
  await db().query(
    `insert into approval_queue (task_id, tier, reason) values ($1, $2, $3)`,
    [task.id, tier, reason],
  );
  await logAudit(db(), {
    taskId: task.id,
    eventType: "escalated",
    actor: "system",
    payload: { tier, reason },
  });
}

async function runTask(task: TaskRow): Promise<string> {
  const tool = (
    await db().query<ToolRow>(`select * from tool_registry where name = $1`, [task.tool_name])
  ).rows[0];
  const role = (
    await db().query<AgentRoleRow>(`select * from agent_roles where name = $1`, [task.agent_role])
  ).rows[0];
  if (!tool || !role) {
    await setStatus(task.id, "failed");
    await logAudit(db(), {
      taskId: task.id,
      eventType: "failed",
      actor: "system",
      payload: { error: `missing ${tool ? "agent_role" : "tool"} definition` },
    });
    return "failed";
  }

  const roleBudget = await checkBudget(task.agent_role);
  if (!roleBudget.ok) return `skipped:${roleBudget.reason}:${roleBudget.scope}`;
  const roleKill = await checkKillSwitch([task.agent_role]);
  if (!roleKill.ok) return `skipped:kill_switch:${roleKill.scope}`;

  await setStatus(task.id, "executing");
  let execution;
  try {
    execution = await executeTask(task, tool, role);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await db().query(
      `update tasks set status = 'failed', result = $2, updated_at = now() where id = $1`,
      [task.id, JSON.stringify({ error: message })],
    );
    await logAudit(db(), {
      taskId: task.id,
      eventType: "failed",
      actor: task.agent_role,
      payload: { error: message, unsupported: err instanceof UnsupportedToolError },
    });
    return "failed";
  }

  await db().query(
    `update tasks set status = 'judging', result = $2, tokens_in = $3, tokens_out = $4,
            cost_usd = $5, model_used = $6, updated_at = now()
     where id = $1`,
    [
      task.id,
      JSON.stringify(execution.result),
      execution.tokensIn,
      execution.tokensOut,
      execution.costUsd,
      execution.model,
    ],
  );
  await logAudit(db(), {
    taskId: task.id,
    eventType: "executed",
    actor: task.agent_role,
    payload: { tool: tool.name, model: execution.model, cost_usd: execution.costUsd },
  });

  const judgment = await judgeTask(task, tool, execution);
  await db().query(
    `insert into judgments (task_id, verdict, reason, scope_violation, escalate,
                            repair_instructions, confidence, model_used, tokens_in, tokens_out, cost_usd)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
    [
      task.id,
      judgment.verdict,
      judgment.reason,
      judgment.scope_violation,
      judgment.escalate,
      judgment.repair_instructions,
      judgment.confidence,
      judgment.model,
      judgment.tokensIn,
      judgment.tokensOut,
      judgment.costUsd,
    ],
  );
  await logAudit(db(), {
    taskId: task.id,
    eventType: "judged",
    actor: "system",
    payload: { verdict: judgment.verdict, confidence: judgment.confidence, escalate: judgment.escalate },
  });

  // Routing per README: pass + confidence != low + !escalate completes Level 1
  // work autonomously and queues everything else for approval; repair retries
  // up to the cap; fail/escalate/scope_violation goes to at least Level 2.
  if (judgment.verdict === "pass" && judgment.confidence !== "low" && !judgment.escalate) {
    if (task.effective_risk <= 1) {
      await setStatus(task.id, "completed");
      await logAudit(db(), { taskId: task.id, eventType: "completed", actor: "system" });
      return "completed";
    }
    await enqueueApproval(task, task.approval_tier, `Judge passed; tier ${task.approval_tier} requires approval`);
    return "awaiting_approval";
  }

  if (judgment.verdict === "repair") {
    const attempts = task.attempt_count + 1;
    if (attempts >= REPAIR_CAP) {
      await db().query(`update tasks set attempt_count = $2 where id = $1`, [task.id, attempts]);
      await enqueueApproval(task, Math.max(task.approval_tier, 2), `Repair cap (${REPAIR_CAP}) reached: ${judgment.reason}`);
      return "awaiting_approval";
    }
    await db().query(
      `update tasks set status = 'repair', attempt_count = $2, updated_at = now() where id = $1`,
      [task.id, attempts],
    );
    await logAudit(db(), {
      taskId: task.id,
      eventType: "repaired",
      actor: "system",
      payload: { attempt: attempts, instructions: judgment.repair_instructions },
    });
    return "repair";
  }

  await enqueueApproval(
    task,
    Math.max(task.approval_tier, 2),
    judgment.scope_violation ? `Scope violation: ${judgment.reason}` : `Judge ${judgment.verdict}: ${judgment.reason}`,
  );
  return "awaiting_approval";
}

// Trust decays toward the rolling 7-day judge pass rate, which feeds the
// deterministic risk formula's agent_trust_penalty on future decompositions.
async function updateTrustScores(): Promise<void> {
  await db().query(
    `update agent_roles r
     set trust_score = sub.pass_rate, updated_at = now()
     from (
       select t.agent_role,
              avg(case when j.verdict = 'pass' then 1.0 else 0.0 end) as pass_rate
       from judgments j join tasks t on t.id = j.task_id
       where j.created_at > now() - interval '7 days'
       group by t.agent_role
     ) sub
     where sub.agent_role = r.name`,
  );
}

async function completeFinishedGoals(): Promise<number> {
  const { rows } = await db().query<{ id: string }>(
    `update goals g set status = 'completed'
     where g.status = 'active'
       and exists (select 1 from tasks t where t.goal_id = g.id)
       and not exists (
         select 1 from tasks t
         where t.goal_id = g.id
           and t.status not in ('completed', 'approved', 'rejected', 'blocked', 'failed')
       )
       and not exists (
         select 1 from tasks t
         where t.goal_id = g.id and t.status in ('rejected', 'blocked', 'failed')
       )
     returning id`,
  );
  return rows.length;
}

export async function runTick(): Promise<TickSummary> {
  const globalKill = await checkKillSwitch(["global"]);
  if (!globalKill.ok) {
    return { halted: "kill_switch:global", approvals: { approved: 0, rejected: 0, blockedDownstream: 0 }, tasks: [], goalsCompleted: 0 };
  }
  const globalBudget = await checkBudget("global");
  if (!globalBudget.ok) {
    return { halted: "budget_exceeded:global", approvals: { approved: 0, rejected: 0, blockedDownstream: 0 }, tasks: [], goalsCompleted: 0 };
  }

  const approvals = await processApprovalDecisions();

  // Bounded batch: dependency-unblocked pending tasks plus repair retries.
  const { rows: batch } = await db().query<TaskRow>(
    `select * from unblocked_tasks
     union all
     select * from tasks where status = 'repair'
     order by effective_risk asc, created_at asc
     limit $1`,
    [BATCH_LIMIT],
  );

  const results: TickSummary["tasks"] = [];
  for (const task of batch) {
    try {
      results.push({ id: task.id, outcome: await runTask(task) });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await setStatus(task.id, "failed").catch(() => {});
      await logAudit(db(), {
        taskId: task.id,
        eventType: "failed",
        actor: "system",
        payload: { error: message },
      }).catch(() => {});
      results.push({ id: task.id, outcome: `error:${message}` });
    }
  }

  await updateTrustScores();
  const goalsCompleted = await completeFinishedGoals();

  return { approvals, tasks: results, goalsCompleted };
}
