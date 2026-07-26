import { db } from "./db";

export interface GuardResult {
  ok: boolean;
  reason?: string;
  scope?: string;
}

// Kill switch: global plus per-agent-role rows in system_controls.
export async function checkKillSwitch(scopes: string[]): Promise<GuardResult> {
  const { rows } = await db().query<{ scope: string }>(
    `select scope from system_controls where kill_switch and scope = any($1) limit 1`,
    [scopes],
  );
  if (rows.length > 0) {
    return { ok: false, reason: "kill_switch", scope: rows[0].scope };
  }
  return { ok: true };
}

// Budget guard: rolling-window spend (executor + judge cost) against
// system_controls.budget_limit_usd — driven by cost_usd sums, not call count.
export async function checkBudget(scope: string): Promise<GuardResult> {
  const { rows } = await db().query<{ scope: string; spend: string; limit: string }>(
    `select sc.scope,
            coalesce((
              select sum(coalesce(t.cost_usd, 0) + coalesce(j.cost_usd, 0))
              from tasks t
              left join judgments j on j.task_id = t.id
              where t.updated_at > now() - make_interval(hours => sc.budget_window_hours)
                and (sc.scope = 'global' or t.agent_role = sc.scope)
            ), 0) as spend,
            sc.budget_limit_usd as limit
     from system_controls sc
     where sc.scope = $1 and sc.budget_limit_usd is not null`,
    [scope],
  );
  const row = rows[0];
  if (row && Number(row.spend) >= Number(row.limit)) {
    return { ok: false, reason: "budget_exceeded", scope: row.scope };
  }
  return { ok: true };
}
