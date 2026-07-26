import { callClaude, extractJson, MODELS } from "./anthropic";
import { logAudit } from "./audit";
import { db, withTx } from "./db";
import { decomposerSystemPrompt } from "./prompts";
import { INHERITED_LEVEL2_FLOOR, intrinsicRisk, tierForScore } from "./risk";
import { AgentRoleRow, ToolRow } from "./types";

interface DecomposedTask {
  id: string;
  description: string;
  tool: string;
  agent_role: string;
  data_sensitivity?: string[];
  flagged_sensitive?: boolean;
  scope?: string;
  reversible?: boolean;
}

interface DecomposerOutput {
  goal?: string;
  clarification_needed?: string | null;
  tasks?: DecomposedTask[];
  edges?: { from: string; to: string; edge_type?: string }[];
}

export interface DecomposeResult {
  status: "active" | "clarification_needed";
  clarification?: string;
  taskCount?: number;
  edgeCount?: number;
  costUsd: number;
}

// Kahn topological sort; throws on cycles. Returns task ids in dependency order.
function topoSort(taskIds: string[], edges: { from: string; to: string }[]): string[] {
  const indegree = new Map(taskIds.map((id) => [id, 0]));
  const children = new Map<string, string[]>(taskIds.map((id) => [id, []]));
  for (const edge of edges) {
    indegree.set(edge.to, (indegree.get(edge.to) ?? 0) + 1);
    children.get(edge.from)!.push(edge.to);
  }
  const queue = taskIds.filter((id) => indegree.get(id) === 0);
  const order: string[] = [];
  while (queue.length) {
    const id = queue.shift()!;
    order.push(id);
    for (const child of children.get(id) ?? []) {
      const remaining = indegree.get(child)! - 1;
      indegree.set(child, remaining);
      if (remaining === 0) queue.push(child);
    }
  }
  if (order.length !== taskIds.length) throw new Error("Task graph contains a cycle");
  return order;
}

export async function decomposeGoal(goalId: string): Promise<DecomposeResult> {
  const goal = (
    await db().query<{ id: string; raw_input: string; status: string }>(
      `select id, raw_input, status from goals where id = $1`,
      [goalId],
    )
  ).rows[0];
  if (!goal) throw new Error(`Goal ${goalId} not found`);
  if (goal.status !== "decomposing") {
    throw new Error(`Goal ${goalId} is in status '${goal.status}', expected 'decomposing'`);
  }

  const tools = (
    await db().query<ToolRow>(`select * from tool_registry where active`)
  ).rows;
  const roles = (await db().query<AgentRoleRow>(`select * from agent_roles`)).rows;
  const toolByName = new Map(tools.map((t) => [t.name, t]));
  const roleByName = new Map(roles.map((r) => [r.name, r]));

  const registryBlock = tools
    .map((t) => `- ${t.name}: ${t.description ?? "(no description)"}`)
    .join("\n");
  const rolesBlock = roles.map((r) => `- ${r.name}`).join("\n");

  const out = await callClaude({
    model: MODELS.sonnet,
    system: decomposerSystemPrompt(),
    user: [
      `## Tool registry`,
      registryBlock,
      ``,
      `## Available agent roles`,
      rolesBlock,
      ``,
      `## User goal`,
      goal.raw_input,
    ].join("\n"),
    maxTokens: 8192,
  });

  const parsed = extractJson<DecomposerOutput>(out.text);

  if (parsed.clarification_needed) {
    await db().query(`update goals set status = 'clarification_needed' where id = $1`, [goalId]);
    return {
      status: "clarification_needed",
      clarification: parsed.clarification_needed,
      costUsd: out.costUsd,
    };
  }

  const tasks = parsed.tasks ?? [];
  const edges = (parsed.edges ?? []).map((e) => ({
    from: e.from,
    to: e.to,
    edge_type: e.edge_type === "informs" ? "informs" : "blocks",
  }));
  if (tasks.length === 0) throw new Error("Decomposer returned no tasks and no clarification");

  // Validate against the registry — never trust invented tool or role names.
  const localIds = new Set(tasks.map((t) => t.id));
  for (const task of tasks) {
    if (!toolByName.has(task.tool)) throw new Error(`Decomposer used unknown tool '${task.tool}'`);
    if (!roleByName.has(task.agent_role)) {
      throw new Error(`Decomposer used unknown agent role '${task.agent_role}'`);
    }
  }
  for (const edge of edges) {
    if (!localIds.has(edge.from) || !localIds.has(edge.to)) {
      throw new Error(`Edge references unknown task id: ${edge.from} -> ${edge.to}`);
    }
  }
  const order = topoSort([...localIds], edges.filter((e) => e.edge_type === "blocks"));

  // Deterministic risk scoring (never LLM-judged).
  const scores = new Map<string, { intrinsic: number; inherited: number }>();
  const taskById = new Map(tasks.map((t) => [t.id, t]));
  const blockingParents = new Map<string, string[]>();
  for (const edge of edges) {
    if (edge.edge_type !== "blocks") continue;
    const list = blockingParents.get(edge.to) ?? [];
    list.push(edge.from);
    blockingParents.set(edge.to, list);
  }

  for (const id of order) {
    const task = taskById.get(id)!;
    const tool = toolByName.get(task.tool)!;
    const role = roleByName.get(task.agent_role)!;
    const intrinsic = intrinsicRisk({
      toolBaseRisk: tool.base_risk,
      toolIrreversible: tool.irreversible,
      taskReversible: task.reversible !== false,
      dataSensitivity: task.data_sensitivity ?? [],
      scope: task.scope === "external" ? "external" : "internal",
      flaggedSensitive: Boolean(task.flagged_sensitive),
      agentTrustScore: Number(role.trust_score),
    });

    // Level 3 anywhere upstream forces every downstream consumer to >= Level 2.
    let inherited = 0;
    for (const parentId of blockingParents.get(id) ?? []) {
      const parent = scores.get(parentId)!;
      const parentEffective = Math.max(parent.intrinsic, parent.inherited);
      if (tierForScore(parentEffective) === 3 || parent.inherited >= INHERITED_LEVEL2_FLOOR) {
        inherited = Math.max(inherited, INHERITED_LEVEL2_FLOOR);
      }
    }
    scores.set(id, { intrinsic, inherited });
  }

  const inserted = await withTx(async (client) => {
    const dbIds = new Map<string, string>();
    for (const id of order) {
      const task = taskById.get(id)!;
      const score = scores.get(id)!;
      const effective = Math.max(score.intrinsic, score.inherited);
      const row = await client.query<{ id: string }>(
        `insert into tasks (goal_id, description, tool_name, agent_role,
                            data_sensitivity, scope, reversible, flagged_sensitive,
                            intrinsic_risk, inherited_risk, approval_tier, status)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'pending')
         returning id`,
        [
          goalId,
          task.description,
          task.tool,
          task.agent_role,
          task.data_sensitivity ?? [],
          task.scope === "external" ? "external" : "internal",
          task.reversible !== false,
          Boolean(task.flagged_sensitive),
          score.intrinsic,
          score.inherited,
          tierForScore(effective),
        ],
      );
      dbIds.set(id, row.rows[0].id);
    }
    for (const edge of edges) {
      await client.query(
        `insert into task_edges (parent_task_id, child_task_id, edge_type) values ($1, $2, $3)`,
        [dbIds.get(edge.from), dbIds.get(edge.to), edge.edge_type],
      );
    }
    await client.query(`update goals set status = 'active' where id = $1`, [goalId]);
    await logAudit(client, {
      eventType: "decomposed",
      actor: "system",
      payload: {
        goal_id: goalId,
        task_count: tasks.length,
        edge_count: edges.length,
        model: out.model,
        cost_usd: out.costUsd,
      },
    });
    return { taskCount: tasks.length, edgeCount: edges.length };
  });

  return { status: "active", ...inserted, costUsd: out.costUsd };
}
