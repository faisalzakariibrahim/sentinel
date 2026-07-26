import type { VercelRequest, VercelResponse } from "@vercel/node";
import { db } from "../lib/db";
import { env } from "../lib/env";

// Mission Control snapshot: the dashboard views in one JSON payload.
// Admin-only. SENTINEL_ADMIN_SECRET is a distinct secret from anything a
// browser client calls (see api/goals/decompose.ts) — it must never be
// shipped to end-user clients, since this endpoint returns global
// operational data (all goals' costs, the approval queue, kill switch and
// budget controls) with no per-user scoping.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.headers.authorization !== `Bearer ${env("SENTINEL_ADMIN_SECRET")}`) {
    return res.status(401).json({ error: "unauthorized" });
  }
  try {
    const [summary, approvals, costByTool, judgeStats, controls] = await Promise.all([
      db().query(`select * from mission_control_summary`),
      db().query(`select * from approval_queue_view limit 50`),
      db().query(`select * from cost_by_tool limit 25`),
      db().query(`select * from judge_stats_last_7d`),
      db().query(`select scope, kill_switch, budget_limit_usd, budget_window_hours from system_controls`),
    ]);
    return res.status(200).json({
      summary: summary.rows[0] ?? null,
      pending_approvals: approvals.rows,
      cost_by_tool: costByTool.rows,
      judge_stats_7d: judgeStats.rows,
      controls: controls.rows,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("mission-control failed:", err);
    return res.status(500).json({ error: message });
  }
}
