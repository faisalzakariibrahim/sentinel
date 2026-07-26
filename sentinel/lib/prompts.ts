import { readFileSync } from "fs";
import { join } from "path";

// The prompt markdown files in agents/prompts are the source of truth; the
// system prompt is the first fenced code block after the "## System Prompt"
// heading. vercel.json includeFiles ships them with the serverless bundle.

const cache = new Map<string, string>();

function loadSystemPrompt(filename: string): string {
  const cached = cache.get(filename);
  if (cached) return cached;

  const raw = readFileSync(join(process.cwd(), "agents", "prompts", filename), "utf8");
  const afterHeading = raw.split(/^## System Prompt\s*$/m)[1];
  const match = afterHeading?.match(/```\n([\s\S]*?)```/);
  if (!match) throw new Error(`No fenced system prompt found in ${filename}`);

  const prompt = match[1].trim();
  cache.set(filename, prompt);
  return prompt;
}

export const judgeSystemPrompt = () => loadSystemPrompt("judge_prompt.md");
export const decomposerSystemPrompt = () => loadSystemPrompt("decomposer_prompt.md");
