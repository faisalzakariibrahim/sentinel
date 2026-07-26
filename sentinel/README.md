# Sentinel v2 — Personal AI OS layer

Sentinel is a personal AI OS control plane: goals are decomposed into a
risk-scored task graph, an agent loop on Vercel cron executes unblocked
tasks, a Judge model verifies every result in a fresh context, and
anything above Level 1 risk waits in an approval queue. Budget guards,
per-role kill switches, and a full audit log wrap the whole loop.

## Contents

- `supabase/migrations/20260726000000_sentinel_v2_core.sql` — full
  schema: goals, tasks, task_edges, tool_registry, agent_roles,
  judgments, approval_queue, tool_registrations_pending,
  episodic/identity/project memory, task_patterns, audit_log, RLS
  policies, sentinel_executor role + grants, and Mission Control views.
- `supabase/migrations/20260726010000_sentinel_v2_runtime.sql` — runtime
  support: `system_controls` (kill switch + budget guard, global and
  per-agent-role), the grants the app layer needs (view reads, goal
  status transitions, trust_score updates), and seed tools/roles.
- `agents/prompts/judge_prompt.md` — verification step system prompt +
  wiring notes (model routing, escalation rules, repair cap). The app
  parses the fenced system prompt out of this file at runtime — it is
  the source of truth, not a copy.
- `agents/prompts/decomposer_prompt.md` — goal → task graph system
  prompt + the deterministic risk-scoring formula it feeds (implemented
  in `lib/risk.ts`).
- `api/` + `lib/` — the Vercel app implementing the loop (below).
- `scripts/set_sentinel_secret.sh` — generates and applies the
  sentinel_executor password.

## App layer (Vercel)

| Route | Method | Auth | Purpose |
|---|---|---|---|
| `/api/tick` | GET (cron, every 5 min) | `Bearer $CRON_SECRET` | The loop: guards → apply approval decisions → run a bounded batch of unblocked/repair tasks → execute → judge → route → trust decay → complete finished goals |
| `/api/goals/decompose` | POST `{"goal_id": "<uuid>"}` | `Bearer <caller's own Supabase access token>` | Fired once per goal submission: verify the JWT, enforce `goals.user_id = caller` → Decomposer (Sonnet) → validate graph against the registry → deterministic risk scoring + Level 3 propagation → insert tasks/edges as `pending` |
| `/api/mission-control` | GET | `Bearer $SENTINEL_ADMIN_SECRET` (admin only — never given to a browser client) | Dashboard snapshot: summary, pending approvals, cost by tool, 7-day judge stats, controls |

There is no shared secret for `/api/goals/decompose` — it authenticates
each request as the specific end user who owns the goal (`lib/auth.ts`
verifies the token against `SUPABASE_JWT_SECRET`; `lib/decomposer.ts`
rejects any `goal_id` the caller doesn't own with the same 404 whether
the goal is missing or belongs to someone else). `SENTINEL_ADMIN_SECRET`
is a completely separate secret scoped to `/api/mission-control` only,
since that endpoint returns global data with no per-user scoping — it
must never reach client code.

Key modules: `lib/tick.ts` (state machine), `lib/decomposer.ts`,
`lib/judge.ts` (Haiku for Level 1, Sonnet for Level 2+/sensitive, never
cheaper than the executor's model), `lib/risk.ts` (deterministic
formula), `lib/executor.ts` (handler registry keyed by
`tool_registry.handler_ref`), `lib/guards.ts` (kill switch + rolling
cost-window budget), `lib/auth.ts` (per-user Supabase JWT verification).

Environment variables: see `.env.example`. Deploy with the repo root set
to this directory; `vercel.json` registers the cron and ships
`agents/prompts/` with the serverless bundle.

Submitting a goal end to end:

1. Client inserts a row into `goals` via Supabase (RLS scopes it to the
   user) — status starts as `decomposing`.
2. Client calls `POST /api/goals/decompose` with the goal id, sending its
   own Supabase access token as the bearer (the same token the client
   already holds from its Supabase session — no separate secret to manage).
3. The next tick picks up unblocked tasks; Level 1 passes complete
   autonomously, everything else lands in `approval_queue`.
4. The user approves/rejects via Supabase (RLS `approval_decide`
   policy); the next tick applies decisions — approvals unblock
   children, rejections block all transitive dependents.

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

## Before running the migrations

- Generate a real `sentinel_executor` password with
  `scripts/set_sentinel_secret.sh` and substitute it for the
  `__SENTINEL_EXECUTOR_PASSWORD__` placeholder in
  `supabase/migrations/20260726000000_sentinel_v2_core.sql` before
  applying — never commit the real value.
- Confirm the `vector` extension is enabled on your Supabase project
  before this runs — it's in the migration but Supabase sometimes needs
  it toggled in the dashboard first on fresh projects.
- Point `SENTINEL_DB_URL` (used by every `lib/*` module via `lib/db.ts`)
  at the `sentinel_executor` role, not `service_role` — this is what
  makes the RLS/grants boundary real. `service_role` bypasses RLS
  entirely and defeats the whole point of scoping the executor's writes.
- Apply both migrations in order (`...000000_sentinel_v2_core.sql` then
  `...010000_sentinel_v2_runtime.sql`) via the Supabase CLI or dashboard
  SQL editor — the second depends on tables/views the first creates.

## Local development

```bash
cd sentinel
npm install
npm run typecheck
```

Copy `.env.example` to `.env` and fill in `SENTINEL_DB_URL`,
`ANTHROPIC_API_KEY`, `CRON_SECRET`, and `SENTINEL_API_SECRET` before
running anything against a real database. Deploy with this directory
(`sentinel/`) as the Vercel project root.
