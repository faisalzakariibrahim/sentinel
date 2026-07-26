// Deterministic risk engine — computed after decomposition, never LLM-set.
// Formula and tier mapping from agents/prompts/decomposer_prompt.md.

export interface RiskInputs {
  toolBaseRisk: number;
  toolIrreversible: boolean;
  taskReversible: boolean;
  dataSensitivity: string[];
  scope: string; // 'internal' | 'external'
  flaggedSensitive: boolean;
  agentTrustScore: number; // 0..1, decays penalty as pass-rate improves
}

export function trustPenalty(trustScore: number): number {
  const clamped = Math.min(1, Math.max(0, trustScore));
  return Math.round((1 - clamped) * 2); // 0-2
}

export function intrinsicRisk(input: RiskInputs): number {
  const sensitivity = new Set(input.dataSensitivity);
  let score = input.toolBaseRisk;
  if (input.toolIrreversible || !input.taskReversible) score += 2;
  if (sensitivity.has("financial") || sensitivity.has("credentials")) score += 2;
  if (sensitivity.has("pii")) score += 1;
  if (input.scope === "external") score += 1;
  score += trustPenalty(input.agentTrustScore);
  if (input.flaggedSensitive) score += 1;
  return score;
}

// 0–1 → Level 1 (autonomous) · 2–4 → Level 2 (approval) · 5+ → Level 3.
export function tierForScore(score: number): 1 | 2 | 3 {
  if (score <= 1) return 1;
  if (score <= 4) return 2;
  return 3;
}

// Any task landing at Level 3 forces every downstream consumer of its output
// to at least Level 2, even if its own intrinsic score would be Level 1.
// `inherited_risk` of 2 maps to tier 2 via effective_risk = max(intrinsic, inherited).
export const INHERITED_LEVEL2_FLOOR = 2;
