import type { VercelRequest, VercelResponse } from "@vercel/node";
import { decomposeGoal } from "../../lib/decomposer";
import { env } from "../../lib/env";

// Fired once per goal submission (not part of the cron tick). The client
// inserts the goal row through Supabase RLS, then calls this with its id;
// resulting tasks land as status='pending' and the next tick picks them up
// via unblocked_tasks.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.headers.authorization !== `Bearer ${env("SENTINEL_API_SECRET")}`) {
    return res.status(401).json({ error: "unauthorized" });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method not allowed" });
  }
  const goalId = req.body?.goal_id;
  if (typeof goalId !== "string" || goalId.length === 0) {
    return res.status(400).json({ error: "goal_id (uuid) is required" });
  }
  try {
    const result = await decomposeGoal(goalId);
    return res.status(200).json(result);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("decompose failed:", err);
    return res.status(500).json({ error: message });
  }
}
