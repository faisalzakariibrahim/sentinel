import Anthropic from "@anthropic-ai/sdk";

let client: Anthropic | undefined;

export function anthropic(): Anthropic {
  if (!client) client = new Anthropic();
  return client;
}

// Model tiers per the prompt wiring notes: Haiku judges Level 1 work,
// Sonnet judges Level 2+ / sensitive work and runs decomposition.
export const MODELS = {
  haiku: "claude-haiku-4-5",
  sonnet: "claude-sonnet-4-6",
} as const;

// USD per million tokens [input, output].
const PRICING: Record<string, [number, number]> = {
  "claude-haiku-4-5": [1, 5],
  "claude-sonnet-4-6": [3, 15],
  "claude-sonnet-5": [3, 15],
  "claude-opus-4-8": [5, 25],
  "claude-opus-5": [5, 25],
};

export function costUsd(model: string, tokensIn: number, tokensOut: number): number {
  const [inRate, outRate] = PRICING[model] ?? PRICING["claude-sonnet-4-6"];
  return (tokensIn * inRate + tokensOut * outRate) / 1_000_000;
}

// Capability ranking so the Judge is never run on a cheaper model than the
// model that produced the work it is judging.
export function modelRank(model: string): number {
  if (model.includes("fable") || model.includes("mythos")) return 3;
  if (model.includes("opus")) return 2;
  if (model.includes("sonnet")) return 1;
  return 0;
}

export interface ClaudeResult {
  text: string;
  model: string;
  tokensIn: number;
  tokensOut: number;
  costUsd: number;
}

export async function callClaude(opts: {
  model: string;
  system: string;
  user: string;
  maxTokens?: number;
}): Promise<ClaudeResult> {
  const response = await anthropic().messages.create({
    model: opts.model,
    max_tokens: opts.maxTokens ?? 4096,
    system: opts.system,
    messages: [{ role: "user", content: opts.user }],
  });

  if (response.stop_reason === "refusal") {
    throw new Error(`Model ${opts.model} refused the request`);
  }

  const text = response.content
    .filter((block): block is Anthropic.TextBlock => block.type === "text")
    .map((block) => block.text)
    .join("");

  const tokensIn = response.usage.input_tokens;
  const tokensOut = response.usage.output_tokens;
  return {
    text,
    model: response.model,
    tokensIn,
    tokensOut,
    costUsd: costUsd(opts.model, tokensIn, tokensOut),
  };
}

// Model output is instructed to be JSON-only, but tolerate stray prose or
// code fences around the object.
export function extractJson<T>(text: string): T {
  try {
    return JSON.parse(text) as T;
  } catch {
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start === -1 || end <= start) {
      throw new Error(`No JSON object found in model output: ${text.slice(0, 200)}`);
    }
    return JSON.parse(text.slice(start, end + 1)) as T;
  }
}
