import { callClaude, extractJson, modelRank, MODELS } from "./anthropic";
import { db } from "./db";
import { judgeSystemPrompt } from "./prompts";
import { TaskRow, ToolRow } from "./types";

export interface Judgment {
  verdict: "pass" | "fail" | "repair";
  reason: string;
  scope_violation: boolean;
  escalate: boolean;
  repair_instructions: string | null;
  confidence: "high" | "medium" | "low";
  model: string;
  tokensIn: number;
  tokensOut: number;
  costUsd: number;
}

// Haiku for Level 1 tasks; Sonnet mandatory for Level 2+ or any task with a
// non-empty data_sensitivity array. Never judge on a cheaper model than the
// one that produced the work.
function judgeModel(task: TaskRow, executorModel: string | null): string {
  let model: string =
    task.effective_risk <= 1 && task.data_sensitivity.length === 0
      ? MODELS.haiku
      : MODELS.sonnet;
  if (executorModel && modelRank(executorModel) > modelRank(model)) {
    model = executorModel;
  }
  return model;
}

export async function judgeTask(
  task: TaskRow,
  tool: ToolRow,
  execution: { result: unknown; model: string | null },
): Promise<Judgment> {
  // Memory context: recent failures for this tool + role combination.
  const { rows: failures } = await db().query<{ reason: string }>(
    `select j.reason from judgments j
     join tasks t on t.id = j.task_id
     where t.tool_name = $1 and t.agent_role = $2 and j.verdict <> 'pass'
     order by j.created_at desc limit 3`,
    [task.tool_name, task.agent_role],
  );

  const user = [
    `## Task`,
    `id: ${task.id}`,
    `description: ${task.description}`,
    `data_sensitivity: ${JSON.stringify(task.data_sensitivity)}`,
    `scope: ${task.scope}`,
    `reversible: ${task.reversible}`,
    `risk_level (tier): ${task.approval_tier}`,
    ``,
    `## Tool called`,
    `name: ${tool.name}`,
    `description: ${tool.description ?? ""}`,
    `parameters: ${JSON.stringify({ description: task.description })}`,
    ``,
    `## Raw output`,
    JSON.stringify(execution.result).slice(0, 20_000),
    ``,
    `## Memory context (recent failures for this task type)`,
    failures.length ? failures.map((f) => `- ${f.reason}`).join("\n") : "(none)",
  ].join("\n");

  // Always a fresh context — never the executor's conversation.
  const out = await callClaude({
    model: judgeModel(task, execution.model),
    system: judgeSystemPrompt(),
    user,
    maxTokens: 2048,
  });

  const parsed = extractJson<{
    verdict?: string;
    reason?: string;
    scope_violation?: boolean;
    escalate?: boolean;
    repair_instructions?: string | null;
    confidence?: string;
  }>(out.text);

  const verdict =
    parsed.verdict === "pass" || parsed.verdict === "repair" ? parsed.verdict : "fail";
  const confidence =
    parsed.confidence === "high" || parsed.confidence === "low" ? parsed.confidence : "medium";

  return {
    verdict,
    reason: parsed.reason ?? "No reason provided",
    scope_violation: Boolean(parsed.scope_violation),
    escalate: Boolean(parsed.escalate) || Boolean(parsed.scope_violation),
    repair_instructions: parsed.repair_instructions ?? null,
    confidence,
    model: out.model,
    tokensIn: out.tokensIn,
    tokensOut: out.tokensOut,
    costUsd: out.costUsd,
  };
}
