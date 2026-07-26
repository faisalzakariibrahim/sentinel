export interface TaskRow {
  id: string;
  goal_id: string;
  description: string;
  tool_name: string;
  agent_role: string;
  data_sensitivity: string[];
  scope: string;
  reversible: boolean;
  flagged_sensitive: boolean;
  intrinsic_risk: number;
  inherited_risk: number;
  effective_risk: number;
  approval_tier: number;
  status: string;
  result: unknown;
  attempt_count: number;
}

export interface ToolRow {
  name: string;
  description: string | null;
  base_risk: number;
  irreversible: boolean;
  requires_scope: string | null;
  handler_ref: string;
  active: boolean;
}

export interface AgentRoleRow {
  name: string;
  system_prompt: string;
  allowed_tools: string[];
  model_default: string;
  trust_score: number;
}
