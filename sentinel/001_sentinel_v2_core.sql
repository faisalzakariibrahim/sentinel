-- ============================================================
-- Sentinel v2 — Personal AI OS core schema
-- ============================================================

create extension if not exists vector;
create extension if not exists pgcrypto;

-- ============ GOALS & DECOMPOSITION ============

create table goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users not null,
  raw_input text not null,
  status text not null default 'decomposing',
    -- decomposing | active | clarification_needed | completed | abandoned
  created_at timestamptz default now()
);

create table tool_registry (
  name text primary key,
  description text,
  base_risk int not null,
  irreversible boolean not null default false,
  requires_scope text,
  handler_ref text not null,
  active boolean not null default true,
  created_at timestamptz default now()
);

create table agent_roles (
  name text primary key,
  system_prompt text not null,
  allowed_tools text[] not null default '{}',
  model_default text not null default 'claude-sonnet-4-6',
  trust_score numeric not null default 0.5,
  updated_at timestamptz default now()
);

create table tasks (
  id uuid primary key default gen_random_uuid(),
  goal_id uuid references goals not null,
  description text not null,
  tool_name text references tool_registry(name) not null,
  agent_role text not null,

  -- from decomposition
  data_sensitivity text[] default '{}',   -- pii, financial, credentials, external_comms
  scope text not null default 'internal', -- internal | external
  reversible boolean not null default true,
  flagged_sensitive boolean not null default false,

  -- risk engine output (computed, never LLM-set)
  intrinsic_risk int not null default 0,
  inherited_risk int not null default 0,
  effective_risk int generated always as (greatest(intrinsic_risk, inherited_risk)) stored,
  approval_tier int not null default 1,  -- 1 | 2 | 3

  -- lifecycle (LoopOS state machine)
  status text not null default 'pending',
    -- pending | executing | judging | repair | awaiting_approval
    -- | approved | rejected | completed | failed | blocked
  result jsonb,
  attempt_count int not null default 0,

  -- cost tracking
  tokens_in int,
  tokens_out int,
  cost_usd numeric(10,6),
  model_used text,

  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table task_edges (
  parent_task_id uuid references tasks not null,
  child_task_id uuid references tasks not null,
  edge_type text not null default 'blocks', -- blocks | informs
  primary key (parent_task_id, child_task_id)
);

-- ============ VERIFICATION ============

create table judgments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references tasks not null,
  verdict text not null,          -- pass | fail | repair
  reason text,
  scope_violation boolean default false,
  escalate boolean default false,
  repair_instructions text,
  confidence text default 'medium',
  model_used text,
  tokens_in int,
  tokens_out int,
  cost_usd numeric(10,6),
  created_at timestamptz default now()
);

-- ============ APPROVAL ============

create table approval_queue (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references tasks not null,
  tier int not null,
  reason text,
  decided_by uuid references auth.users,
  decision text,           -- approved | rejected | null (pending)
  decided_at timestamptz,
  created_at timestamptz default now()
);

-- controlled tool-registration path (new tools always gated)
create table tool_registrations_pending (
  id uuid primary key default gen_random_uuid(),
  proposed_by text not null,
  tool_definition jsonb not null,
  status text not null default 'pending', -- pending | approved | rejected
  reviewed_by uuid references auth.users,
  created_at timestamptz default now()
);

create or replace function approve_tool_registration(reg_id uuid)
returns void
language plpgsql security definer
as $$
begin
  update tool_registrations_pending set status = 'approved', reviewed_by = auth.uid()
  where id = reg_id;

  insert into tool_registry (name, description, base_risk, irreversible, handler_ref)
  select (tool_definition->>'name'), (tool_definition->>'description'),
         (tool_definition->>'base_risk')::int, (tool_definition->>'irreversible')::boolean,
         (tool_definition->>'handler_ref')
  from tool_registrations_pending where id = reg_id;
end;
$$;

-- ============ MEMORY ============

create table episodic_memory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users not null,
  goal_id uuid references goals,
  task_id uuid references tasks,
  content text not null,
  embedding vector(1536),
  created_at timestamptz default now()
);
create index on episodic_memory using hnsw (embedding vector_cosine_ops);

create table identity_memory (
  user_id uuid references auth.users not null,
  key text not null,
  value jsonb not null,
  updated_at timestamptz default now(),
  primary key (user_id, key)
);

create table project_memory (
  goal_id uuid references goals not null,
  key text not null,
  value jsonb not null,
  updated_at timestamptz default now(),
  primary key (goal_id, key)
);

-- ============ LEARNING (pattern library) ============

create table task_patterns (
  id uuid primary key default gen_random_uuid(),
  agent_role text references agent_roles not null,
  tool_name text references tool_registry not null,
  example_input text not null,
  example_output text not null,
  judge_confidence text not null,
  active boolean default true,
  created_at timestamptz default now()
);

-- ============ AUDIT ============

create table audit_log (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references tasks,
  event_type text not null,  -- decomposed | executed | judged | escalated | approved | rejected | repaired
  actor text not null,       -- 'system' | agent_role | user_id
  payload jsonb,
  created_at timestamptz default now()
);
create index on audit_log using gin (payload jsonb_path_ops);

-- ============================================================
-- ROLES & GRANTS
-- ============================================================

create role sentinel_executor login password 'CHANGE_ME' noinherit;

grant select, insert, update on tasks, task_edges, judgments, audit_log to sentinel_executor;
grant select, insert on episodic_memory, task_patterns to sentinel_executor;
grant select, update on project_memory, identity_memory to sentinel_executor;
grant select, insert (task_id, tier, reason) on approval_queue to sentinel_executor;
grant select on tool_registry, agent_roles to sentinel_executor;
-- deliberately no grants on goals or tool_registry writes for sentinel_executor

-- ============================================================
-- RLS
-- ============================================================

alter table goals enable row level security;
alter table tasks enable row level security;
alter table approval_queue enable row level security;
alter table tool_registry enable row level security;
alter table agent_roles enable row level security;
alter table identity_memory enable row level security;
alter table episodic_memory enable row level security;
alter table project_memory enable row level security;
alter table audit_log enable row level security;

create policy goals_owner on goals
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy tasks_via_goal on tasks
  for select using (goal_id in (select id from goals where user_id = auth.uid()));
  -- no insert/update policy for authenticated users — default deny;
  -- only sentinel_executor writes tasks

create policy approval_view on approval_queue
  for select using (
    task_id in (
      select t.id from tasks t join goals g on g.id = t.goal_id
      where g.user_id = auth.uid()
    )
  );

create policy approval_decide on approval_queue
  for update using (
    decision is null
    and task_id in (
      select t.id from tasks t join goals g on g.id = t.goal_id
      where g.user_id = auth.uid()
    )
  )
  with check (decided_by = auth.uid() and decision in ('approved','rejected'));

create policy tool_registry_read on tool_registry for select using (true);
create policy agent_roles_read on agent_roles for select using (true);

create policy identity_memory_owner on identity_memory
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy episodic_memory_owner on episodic_memory
  for select using (auth.uid() = user_id);

create policy project_memory_via_goal on project_memory
  for select using (goal_id in (select id from goals where user_id = auth.uid()));

create policy audit_log_view on audit_log
  for select using (
    task_id in (
      select t.id from tasks t join goals g on g.id = t.goal_id
      where g.user_id = auth.uid()
    )
  );

-- ============================================================
-- DASHBOARD VIEWS (Mission Control)
-- ============================================================

create or replace view unblocked_tasks as
select t.*
from tasks t
where t.status = 'pending'
and not exists (
  select 1 from task_edges te
  join tasks parent on parent.id = te.parent_task_id
  where te.child_task_id = t.id
  and te.edge_type = 'blocks'
  and parent.status not in ('completed', 'approved')
);

create or replace view goal_graph_view as
select
  g.id as goal_id,
  g.raw_input as goal_text,
  g.status as goal_status,
  jsonb_agg(distinct jsonb_build_object(
    'id', t.id, 'description', t.description, 'agent_role', t.agent_role,
    'status', t.status, 'effective_risk', t.effective_risk,
    'approval_tier', t.approval_tier, 'attempt_count', t.attempt_count
  )) filter (where t.id is not null) as nodes,
  jsonb_agg(distinct jsonb_build_object(
    'from', te.parent_task_id, 'to', te.child_task_id, 'type', te.edge_type
  )) filter (where te.parent_task_id is not null) as edges
from goals g
left join tasks t on t.goal_id = g.id
left join task_edges te on te.parent_task_id = t.id or te.child_task_id = t.id
group by g.id;

create or replace view approval_queue_view as
select
  aq.id as approval_id, aq.tier, aq.reason, aq.created_at as queued_at,
  t.description as task_description, t.tool_name, t.agent_role,
  t.intrinsic_risk, t.inherited_risk, t.result as task_output,
  j.reason as judge_reason, j.scope_violation, j.confidence as judge_confidence,
  g.raw_input as goal_text,
  case
    when j.scope_violation then 'scope_violation'
    when t.inherited_risk > t.intrinsic_risk then 'inherited_from_ancestor'
    else 'intrinsic'
  end as escalation_source
from approval_queue aq
join tasks t on t.id = aq.task_id
join goals g on g.id = t.goal_id
left join lateral (
  select * from judgments j2 where j2.task_id = t.id
  order by created_at desc limit 1
) j on true
where aq.decision is null
order by aq.tier desc, aq.created_at asc;

create or replace view cost_by_tool as
select
  t.tool_name, t.agent_role, count(*) as task_count,
  sum(coalesce(t.cost_usd,0)) as exec_cost,
  sum(coalesce(j.cost_usd,0)) as judge_cost,
  sum(coalesce(t.cost_usd,0) + coalesce(j.cost_usd,0)) as total_cost,
  avg(coalesce(t.cost_usd,0) + coalesce(j.cost_usd,0)) as avg_cost_per_task
from tasks t
left join judgments j on j.task_id = t.id
group by t.tool_name, t.agent_role
order by total_cost desc;

create or replace view cost_by_goal as
select
  g.id as goal_id, g.raw_input, count(t.id) as task_count,
  sum(coalesce(t.cost_usd,0) + coalesce(j.cost_usd,0)) as total_cost
from goals g
join tasks t on t.goal_id = g.id
left join judgments j on j.task_id = t.id
group by g.id
order by total_cost desc;

create or replace view judge_stats_by_task_type as
select
  t.tool_name, t.agent_role, count(*) as total_judged,
  count(*) filter (where j.verdict = 'pass') as passed,
  count(*) filter (where j.verdict = 'fail') as failed,
  count(*) filter (where j.verdict = 'repair') as repaired,
  count(*) filter (where j.escalate) as escalated,
  round(count(*) filter (where j.verdict = 'pass')::numeric
    / nullif(count(*),0) * 100, 1) as pass_rate_pct
from tasks t
join judgments j on j.task_id = t.id
group by t.tool_name, t.agent_role
order by pass_rate_pct asc;

create or replace view judge_stats_last_7d as
select
  t.tool_name, t.agent_role,
  count(*) filter (where j.verdict = 'pass') as passed_7d,
  count(*) as total_7d,
  round(count(*) filter (where j.verdict='pass')::numeric
    / nullif(count(*),0) * 100, 1) as pass_rate_7d
from tasks t
join judgments j on j.task_id = t.id
where j.created_at > now() - interval '7 days'
group by t.tool_name, t.agent_role;

create or replace view audit_log_view as
select
  al.id, al.event_type, al.actor, al.payload, al.created_at,
  t.description as task_description, t.tool_name, g.raw_input as goal_text
from audit_log al
left join tasks t on t.id = al.task_id
left join goals g on g.id = t.goal_id
order by al.created_at desc;

create or replace view mission_control_summary as
select
  (select count(*) from tasks where status not in ('completed','rejected','failed')) as active_tasks,
  (select count(*) from approval_queue where decision is null) as pending_approvals,
  (select count(*) from approval_queue where decision is null and tier = 3) as pending_level3,
  (select sum(cost_usd) from tasks where created_at > now() - interval '24h') as spend_24h,
  (select round(avg(pass_rate_pct),1) from judge_stats_last_7d) as avg_pass_rate_7d;
