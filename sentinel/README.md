# Sentinel v2 — Personal AI OS layer

Extends the Sentinel control plane (approval queue, audit log, agent loop
on Vercel cron, tool registry, budget guards, kill switch) with:
risk-scored approval tiers, a Judge verification step, structured intent
decomposition, memory tables, and Mission Control dashboard views.

## Contents

- `supabase/migrations/` — apply in filename order:
  - `20260726000000_sentinel_v2_core.sql` — full schema: goals, tasks,
    task_edges, tool_registry, agent_roles, judgments, approval_queue,
    tool_registrations_pending, episodic/identity/project memory,
    task_patterns, audit_log, RLS policies, sentinel_executor role +
    grants, and Mission Control views.
  - `20260726000001_sentinel_v2_security_fixes.sql` — closes RLS gaps,
    gates tool approval behind `sentinel_admins`, makes the dashboard
    views respect RLS, gives `sentinel_executor` working policies, and
    disables the role until a real password is set.
  - `20260726000002_sentinel_v2_integrity.sql` — enforces the risk floor
    and each role's `allowed_tools` in the database, freezes risk fields
    for the executor, adds status/tier checks, one pending approval per
    task, server-stamped `decided_at`/`updated_at`, and indexes.
  - `20260726000003_sentinel_v2_preexecution_approval.sql` — irreversible
    or external Level 2+ tasks (and all Level 3) are approved *before*
    they run, against the exact `planned_call`; status guards; decisions
    apply themselves and rejections block everything downstream.
- `supabase/tests/security/run.sh` — local Postgres test suite for all
  of the above.
- `agents/prompts/judge_prompt.md` — verification step system prompt +
  wiring notes (model routing, escalation rules, repair cap).
- `agents/prompts/decomposer_prompt.md` — goal → task graph system prompt
  + the deterministic risk-scoring formula it feeds.
- `scripts/set_sentinel_secret.sh` — sets the executor password.

## Loop wiring (inside your existing Vercel cron tick — no new cron job)

```
tick →
  check kill switch (global + per-agent-role)
  check budget guard (global + per-agent-role, driven by cost_by_tool /
    sum(cost_usd) over a rolling window, not raw call count)
  ↓
  1. gate before execution — pull from `tasks_needing_preapproval`
     (Level 3, or Level 2+ irreversible/external; deps already done):
     for each task:
       build the exact tool call (recipients, body, amount, ...) without
         running it, and in ONE update set planned_call = <call>,
         status = awaiting_preapproval
       insert approval_queue row (stage = 'pre_execution',
         tier = task.approval_tier)
  ↓
  2. run — pull from `unblocked_tasks` (bounded batch, e.g. limit 10).
     Pre-approved tasks reappear here once you approve them.
     for each task:
       status → executing → run agent_roles[task.agent_role] executor
         (pre-approved tasks: execute planned_call exactly as stored)
       status → judging → run Judge (model tier by effective_risk)
       insert into judgments
       ↓
       pass + confidence != low + !escalate:
         approval_tier = 1, or already pre-approved → status = completed
         else → status = awaiting_approval, insert approval_queue row
           (stage = 'post_execution', tier = task.approval_tier)
       repair: attempt_count += 1, status = repair (cap at 3 before
         forcing Level 2 escalation regardless of score)
       fail / escalate: status = awaiting_approval, post_execution row,
         tier = max(task.approval_tier, 2)
```

Decisions apply themselves (database trigger, no polling needed):
pre-execution approved → task back to `pending`, now runnable; post-
execution approved → `approved`, children unblock; rejected → task
`rejected` and every downstream task `blocked` (not silently dropped).

The database refuses `executing` without a required pre-approval,
`approved` without a human decision, `completed` for a Level 2+ task
with no human approval, and any change to `planned_call` once it is
under review or approved. `tier` is the 1–3 approval level, not the risk
score, and can't be queued below the task's own `approval_tier`.

Intent decomposition is a separate on-demand endpoint (fires once per
goal submission), not part of the tick — it populates `tasks` /
`task_edges` with `status='pending'` and the next tick picks them up
via `unblocked_tasks` naturally. The database raises each task's
`intrinsic_risk` and `approval_tier` to at least the deterministic floor
from the decomposer formula, and rejects a task whose tool isn't in its
role's `allowed_tools`. Tasks with `tool: "unsupported"` are stored but
never polled.

## Setup

1. Confirm the `vector` extension is enabled on your Supabase project
   (Flicktek org) — it's in the migration, but fresh projects sometimes
   need it toggled in the dashboard first.
2. Apply the four migrations in filename order (`supabase db push`).
3. Set the executor password and turn login on — the password never goes
   in the repo:
   `DATABASE_URL=postgres://... PRINT_PASSWORD=1 ./scripts/set_sentinel_secret.sh`
   then put the printed value in your Vercel env.
4. Point the cron executor's DB client at `sentinel_executor`, not
   `service_role`. `service_role` bypasses RLS entirely and defeats the
   point of scoping the executor's writes.
5. Make yourself an admin so you can review tool registrations:
   `insert into public.sentinel_admins (user_id) values ('<your auth.users id>');`
6. Seed `agent_roles` with each role's `allowed_tools` — a task can only
   use a tool its role lists.

## Tests

```bash
./supabase/tests/security/run.sh
```

Needs a local Postgres 15+ (`pg_config` on PATH, or set `PG_BIN`). It
runs the checks against the original v2 schema first — those FAIL lines
are the issues the later migrations fix — then applies every migration
and requires every check to PASS.
