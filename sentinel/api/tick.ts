import type { VercelRequest, VercelResponse } from "@vercel/node";
import { env } from "../lib/env";
import { runTick } from "../lib/tick";

// Vercel cron invokes this with `Authorization: Bearer ${CRON_SECRET}`.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.headers.authorization !== `Bearer ${env("CRON_SECRET")}`) {
    return res.status(401).json({ error: "unauthorized" });
  }
  try {
    const summary = await runTick();
    return res.status(200).json(summary);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("tick failed:", err);
    return res.status(500).json({ error: message });
  }
}
