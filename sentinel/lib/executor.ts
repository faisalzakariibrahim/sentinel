import { callClaude } from "./anthropic";
import { AgentRoleRow, TaskRow, ToolRow } from "./types";

export interface ExecutionResult {
  result: unknown;
  model: string | null;
  tokensIn: number;
  tokensOut: number;
  costUsd: number;
}

export class UnsupportedToolError extends Error {}

type ToolHandler = (task: TaskRow, role: AgentRoleRow) => Promise<ExecutionResult>;

// Tool handlers are registered here and referenced by tool_registry.handler_ref.
// New tools go through tool_registrations_pending + approve_tool_registration(),
// never a direct insert — the handler must exist here before approval.
const HANDLERS: Record<string, ToolHandler> = {
  "builtin.echo": async (task) => ({
    result: { echo: task.description },
    model: null,
    tokensIn: 0,
    tokensOut: 0,
    costUsd: 0,
  }),

  "builtin.llm_generate": async (task, role) => {
    const repair =
      task.attempt_count > 0 && task.result
        ? `\n\nPrevious attempt was rejected by the verification step. Prior output:\n${JSON.stringify(task.result).slice(0, 4000)}`
        : "";
    const out = await callClaude({
      model: role.model_default,
      system: role.system_prompt,
      user: `${task.description}${repair}`,
      maxTokens: 4096,
    });
    return {
      result: { text: out.text },
      model: out.model,
      tokensIn: out.tokensIn,
      tokensOut: out.tokensOut,
      costUsd: out.costUsd,
    };
  },

  "builtin.unsupported": async (task) => {
    throw new UnsupportedToolError(
      `Task requires a capability not in the tool registry: ${task.description}`,
    );
  },
};

export async function executeTask(
  task: TaskRow,
  tool: ToolRow,
  role: AgentRoleRow,
): Promise<ExecutionResult> {
  if (!tool.active) throw new Error(`Tool ${tool.name} is inactive`);
  if (!role.allowed_tools.includes(tool.name)) {
    throw new Error(`Agent role ${role.name} is not allowed to use tool ${tool.name}`);
  }
  const handler = HANDLERS[tool.handler_ref];
  if (!handler) throw new Error(`No handler registered for ${tool.handler_ref}`);
  return handler(task, role);
}
