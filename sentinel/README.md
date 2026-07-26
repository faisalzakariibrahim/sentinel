# Sentinel v2 — Personal AI OS layer

This bundle extends the existing Sentinel control plane (approval queue,
audit log, agent loop on Vercel cron, tool registry, budget guards, kill
switch) with: risk-scored approval tiers, a Judge verification step,
structured intent decomposition, memory tables, and Mission Control
dashboard views.

## Contents

- `migrations/001_sentinel_v2_core.sql` — full schema: goals, tasks,
  task_edges, tool_registry, agent_roles, judgments, approval_queue,
  tool_registrations_pending, episodic/identity/project memory,
  task_patterns, audit_log, RLS policies, sentinel_executor role +
  grants, and Mission Control views.
- `prompts/judge_prompt.md` — verification step system prompt + wiring
  notes (model routing, escalation rules, repair cap).
- `prompts/decomposer_prompt.md` — goal → task graph system prompt +
  the deterministic risk-scoring formula it feeds.

## Loop wiring (inside your existing Vercel cron tick — no new cron job)

```
tick →
  check kill switch (global + per-agent-role)
  check budget guard (global + per-agent-role, driven by cost_by_tool /
    sum(cost_usd) over a rolling window, not raw call count)
  ↓
  pull from `unblocked_tasks` view (bounded batch, e.g. limit 10)
  ↓
  for each task:
    status → executing → run agent_roles[task.agent_role] executor
    status → judging → run Judge (model tier by effective_risk)
    insert into judgments
    ↓
    pass + confidence != low + !escalate:
      effective_risk <= 1 → status = completed
      else → status = awaiting_approval, insert approval_queue row
    repair: attempt_count += 1, status = repair (cap at 3 before
      forcing Level 2 escalation regardless of score)
    fail / escalate: status = awaiting_approval,
      tier = max(effective_risk, 2)
  ↓
  separately: watch approval_queue.decision != null
    approved → status = approved → next tick executes child tasks
    rejected → status = rejected → dependent tasks marked blocked
      (not silently dropped)
```

Intent decomposition is a separate on-demand endpoint (fires once per
goal submission), not part of the tick — it populates `tasks` /
`task_edges` with `status='pending'` and the next tick picks them up
via `unblocked_tasks` naturally.

## Before running the migration

- Replace `'CHANGE_ME'` in the `sentinel_executor` role creation with a
  real secret, stored in Vercel env / Supabase Vault — never in the repo.
- Confirm the `vector` extension is enabled on your Supabase project
  (Flicktek org) before this runs — it's in the migration but Supabase
  sometimes needs it toggled in the dashboard first on fresh projects.
- Point your cron executor's DB client at the `sentinel_executor` role,
  not `service_role` — this is what makes the RLS/grants boundary real.
  `service_role` bypasses RLS entirely and defeats the whole point of
  scoping the executor's writes.

## Git

```bash
# from inside your existing Sentinel repo root
mkdir -p supabase/migrations agents/prompts
cp migrations/001_sentinel_v2_core.sql supabase/migrations/$(date +%Y%m%d%H%M%S)_sentinel_v2_core.sql
cp prompts/*.md agents/prompts/

git checkout -b sentinel-v2-core
git add supabase/migrations agents/prompts
git commit -m "Add Sentinel v2 core: risk-scored approval tiers, Judge step, intent decomposition, memory + Mission Control views"
git push -u origin sentinel-v2-core
```

If you hit the same stalled-push issue as before (git init pointed at
the home directory instead of the repo root), confirm first:

```bash
git rev-parse --show-toplevel   # should print your Sentinel repo path, not /home/...
git remote -v                   # should show your Sentinel GitHub remote
```

If `--show-toplevel` prints anything outside your project folder, `rm
-rf .git` from that wrong location is NOT safe to run blindly — cd into
the actual Sentinel project directory first, confirm you're there with
`pwd`, then re-run `git init` scoped to that directory before retrying
the push above.
