import type { VercelRequest, VercelResponse } from "@vercel/node";
import { AuthError, verifySupabaseAccessToken } from "../../lib/auth";
import { decomposeGoal, GoalNotFoundError } from "../../lib/decomposer";

// Fired once per goal submission (not part of the cron tick). The client
// inserts the goal row through Supabase RLS as itself, then calls this
// endpoint with its own Supabase access token — never a shared secret.
// The token is verified here and the resulting user id is enforced against
// goals.user_id inside decomposeGoal() before anything is read or written.
// Resulting tasks land as status='pending' and the next tick picks them up
// via unblocked_tasks.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method not allowed" });
  }

  let userId: string;
  try {
    userId = verifySupabaseAccessToken(req.headers.authorization).userId;
  } catch (err) {
    if (err instanceof AuthError) return res.status(401).json({ error: err.message });
    throw err;
  }

  const goalId = req.body?.goal_id;
  if (typeof goalId !== "string" || goalId.length === 0) {
    return res.status(400).json({ error: "goal_id (uuid) is required" });
  }
  try {
    const result = await decomposeGoal(goalId, userId);
    return res.status(200).json(result);
  } catch (err) {
    if (err instanceof GoalNotFoundError) {
      return res.status(404).json({ error: err.message });
    }
    const message = err instanceof Error ? err.message : String(err);
    console.error("decompose failed:", err);
    return res.status(500).json({ error: message });
  }
}
