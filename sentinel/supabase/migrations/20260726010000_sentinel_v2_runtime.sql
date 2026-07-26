-- ============================================================
-- Sentinel v2 — runtime support (migration 2)
-- Adds what the executor loop needs beyond the core schema:
--   * system_controls: kill switch + budget guard, global and per-agent-role
--   * grants the core migration deliberately deferred but the app layer
--     requires: view reads, goals status transitions, trust_score updates
--   * seed tool_registry / agent_roles so decomposition has a vocabulary
-- ============================================================

-- ============ KILL SWITCH & BUDGET GUARD ============

create table system_controls (
  scope text primary key,            -- 'global' | agent_roles.name
  kill_switch boolean not null default false,
  budget_limit_usd numeric(10,2),    -- null = no budget cap for this scope
  budget_window_hours int not null default 24,
  updated_at timestamptz default now()
);

insert into system_controls (scope, kill_switch, budget_limit_usd)
values ('global', false, 25.00);

alter table system_controls enable row level security;
create policy system_controls_read on system_controls for select using (true);
-- no insert/update policies: controls are flipped by the owner via the
-- Supabase dashboard / service role, never by the executor or end users

grant select on system_controls to sentinel_executor;

-- ============ GRANTS THE LOOP NEEDS ============

-- Views execute with owner privileges, but selecting FROM a view still
-- requires a grant on the view itself.
grant select on unblocked_tasks, approval_queue_view, cost_by_tool, cost_by_goal,
  judge_stats_by_task_type, judge_stats_last_7d, audit_log_view,
  mission_control_summary, goal_graph_view
  to sentinel_executor;

-- The decompose endpoint reads goals.raw_input and moves goals through
-- decomposing -> active/clarification_needed; the tick sweep marks goals
-- completed. Reads + status writes only — the executor still cannot create
-- or delete goals, which stays a user-side (RLS) operation.
grant select, update (status) on goals to sentinel_executor;

-- Trust decay: the tick recomputes trust_score from the rolling judge pass
-- rate, which feeds the deterministic risk formula's agent_trust_penalty.
grant update (trust_score, updated_at) on agent_roles to sentinel_executor;

-- ============ SEED TOOLS ============

insert into tool_registry (name, description, base_risk, irreversible, handler_ref) values
  ('echo',        'Diagnostic no-op: returns the task description as its result. Safe for smoke-testing the loop.', 0, false, 'builtin.echo'),
  ('llm_generate','Generate text with the agent role''s model (drafts, summaries, analysis). Output is internal until a downstream tool sends it anywhere.', 0, false, 'builtin.llm_generate'),
  ('unsupported', 'Sentinel placeholder emitted by the Decomposer when a goal needs a capability not in this registry. Always fails with an explanation instead of substituting a different tool.', 0, false, 'builtin.unsupported');

-- ============ SEED AGENT ROLE ============

insert into agent_roles (name, system_prompt, allowed_tools, model_default, trust_score) values
  ('generalist',
   'You are a Sentinel executor agent. Complete exactly the task you are given — nothing more. Stay within the declared scope and data-sensitivity flags. Produce your result as plain text unless the task specifies a format.',
   array['echo','llm_generate','unsupported'],
   'claude-sonnet-4-6',
   0.5);
