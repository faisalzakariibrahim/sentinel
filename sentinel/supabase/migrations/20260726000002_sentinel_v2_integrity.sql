-- ============================================================
-- Sentinel v2 — integrity fixes
-- Timestamped migration: 20260726000002
-- Runs after 20260726000001_sentinel_v2_security_fixes.sql.
--
-- 1. Risk floor enforced in the database. The decomposer prompt says risk
--    is "computed, never LLM-set", but nothing stopped a task row being
--    written with risk 0 / tier 1. A trigger now applies the deterministic
--    part of the formula and raises intrinsic_risk and approval_tier to at
--    least that floor (the agent trust penalty stays app-side).
-- 2. Risk fields frozen for the executor: it can update a task's
--    lifecycle columns, not its risk, tier, tool, role or goal.
-- 3. Least privilege: a task's tool must be in its agent role's
--    allowed_tools, so a manipulated decomposition can't hand an
--    irreversible tool to a low-trust role.
-- 4. "unsupported" tasks from the decomposer violated the tool_registry
--    foreign key. Seeded as an inactive placeholder tool; unblocked_tasks
--    now skips inactive tools (also a per-tool kill switch).
-- 5. Approval integrity: tier must be 1–3 and never below the task's own
--    approval_tier; one pending approval per task; decided_at is stamped
--    by the server, not the client.
-- 6. Value checks on every status / enum-like column, no self-loop edges,
--    tasks.agent_role must exist.
-- 7. updated_at maintained by triggers; indexes behind the RLS subqueries.
-- ============================================================


-- ============ 4. placeholder tool for "unsupported" decompositions ============

insert into public.tool_registry (name, description, base_risk, irreversible, handler_ref, active)
values ('unsupported',
        'Placeholder for goals that need a capability not in the registry. Never executed.',
        0, false, 'none', false)
on conflict (name) do nothing;


-- ============ 6. value checks ============

alter table public.goals add constraint goals_status_check
  check (status in ('decomposing','active','clarification_needed','completed','abandoned'));

alter table public.tasks add constraint tasks_status_check
  check (status in ('pending','executing','judging','repair','awaiting_approval',
                    'approved','rejected','completed','failed','blocked'));
alter table public.tasks add constraint tasks_scope_check
  check (scope in ('internal','external'));
alter table public.tasks add constraint tasks_approval_tier_check
  check (approval_tier between 1 and 3);
alter table public.tasks add constraint tasks_risk_nonnegative_check
  check (intrinsic_risk >= 0 and inherited_risk >= 0);
alter table public.tasks add constraint tasks_attempt_count_check
  check (attempt_count >= 0);
alter table public.tasks add constraint tasks_data_sensitivity_check
  check (data_sensitivity <@ array['pii','financial','credentials','external_comms']::text[]);
alter table public.tasks add constraint tasks_agent_role_fkey
  foreign key (agent_role) references public.agent_roles (name);

alter table public.task_edges add constraint task_edges_type_check
  check (edge_type in ('blocks','informs'));
alter table public.task_edges add constraint task_edges_no_self_loop
  check (parent_task_id <> child_task_id);

alter table public.judgments add constraint judgments_verdict_check
  check (verdict in ('pass','fail','repair'));
alter table public.judgments add constraint judgments_confidence_check
  check (confidence in ('high','medium','low'));

alter table public.approval_queue add constraint approval_queue_tier_check
  check (tier between 1 and 3);
alter table public.approval_queue add constraint approval_queue_decision_check
  check (decision is null or decision in ('approved','rejected'));
alter table public.approval_queue add constraint approval_queue_decided_by_check
  check ((decision is null) = (decided_by is null));

alter table public.tool_registry add constraint tool_registry_base_risk_check
  check (base_risk >= 0);
alter table public.tool_registrations_pending add constraint tool_registrations_status_check
  check (status in ('pending','approved','rejected'));
alter table public.agent_roles add constraint agent_roles_trust_score_check
  check (trust_score between 0 and 1);
alter table public.task_patterns add constraint task_patterns_confidence_check
  check (judge_confidence in ('high','medium','low'));


-- ============ 1 + 3. risk floor and tool allow-list ============

create or replace function public.tasks_enforce_policy()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  tool public.tool_registry%rowtype;
  floor_risk int;
  floor_tier int;
begin
  select * into tool from public.tool_registry where name = new.tool_name;
  -- (missing tool is caught by the tasks.tool_name foreign key)

  -- least privilege: the role must be allowed to use this tool
  if new.tool_name <> 'unsupported' and not exists (
    select 1 from public.agent_roles r
    where r.name = new.agent_role and new.tool_name = any (r.allowed_tools)
  ) then
    raise exception 'agent role % is not allowed to use tool %',
      new.agent_role, new.tool_name using errcode = '42501';
  end if;

  -- deterministic part of the decomposer's risk formula
  floor_risk := coalesce(tool.base_risk, 0)
    + case when coalesce(tool.irreversible, false) or not new.reversible then 2 else 0 end
    + case when new.data_sensitivity && array['financial','credentials'] then 2 else 0 end
    + case when 'pii' = any (new.data_sensitivity) then 1 else 0 end
    + case when new.scope = 'external' then 1 else 0 end
    + case when new.flagged_sensitive then 1 else 0 end;

  new.intrinsic_risk := greatest(new.intrinsic_risk, floor_risk);

  -- tier mapping: 0-1 -> 1, 2-4 -> 2, 5+ -> 3
  floor_tier := case
    when greatest(new.intrinsic_risk, new.inherited_risk) >= 5 then 3
    when greatest(new.intrinsic_risk, new.inherited_risk) >= 2 then 2
    else 1 end;
  new.approval_tier := greatest(new.approval_tier, floor_tier);

  return new;
end;
$$;

create trigger tasks_enforce_policy
  before insert or update of tool_name, agent_role, reversible, scope,
    data_sensitivity, flagged_sensitive, intrinsic_risk, inherited_risk, approval_tier
  on public.tasks
  for each row execute function public.tasks_enforce_policy();


-- ============ 2. executor can't rewrite risk ============

revoke update on public.tasks from sentinel_executor;
grant update (status, result, attempt_count, tokens_in, tokens_out, cost_usd, model_used)
  on public.tasks to sentinel_executor;


-- ============ 4. unblocked_tasks skips inactive tools ============

create or replace view public.unblocked_tasks
with (security_invoker = true)
as
select t.*
from public.tasks t
join public.tool_registry tr on tr.name = t.tool_name and tr.active
where t.status = 'pending'
and not exists (
  select 1 from public.task_edges te
  join public.tasks parent on parent.id = te.parent_task_id
  where te.child_task_id = t.id
  and te.edge_type = 'blocks'
  and parent.status not in ('completed', 'approved')
);


-- ============ 5. approval integrity ============

-- never queue an approval below the tier the task itself requires
drop policy executor_approval_queue_insert on public.approval_queue;
create policy executor_approval_queue_insert on public.approval_queue
  for insert to sentinel_executor
  with check (
    decision is null and decided_by is null and decided_at is null
    and tier >= (select t.approval_tier from public.tasks t where t.id = task_id)
  );

create unique index approval_queue_one_pending_per_task
  on public.approval_queue (task_id) where decision is null;

-- server-side timestamp; clients can no longer set it
revoke update (decided_at) on public.approval_queue from authenticated;

create or replace function public.approval_queue_stamp_decision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.decision is distinct from old.decision then
    new.decided_at := now();
  end if;
  return new;
end;
$$;

create trigger approval_queue_stamp_decision
  before update on public.approval_queue
  for each row execute function public.approval_queue_stamp_decision();


-- ============ 7. updated_at + indexes ============

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger tasks_set_updated_at before update on public.tasks
  for each row execute function public.set_updated_at();
create trigger agent_roles_set_updated_at before update on public.agent_roles
  for each row execute function public.set_updated_at();
create trigger identity_memory_set_updated_at before update on public.identity_memory
  for each row execute function public.set_updated_at();
create trigger project_memory_set_updated_at before update on public.project_memory
  for each row execute function public.set_updated_at();

create index goals_user_id_idx on public.goals (user_id);
create index tasks_goal_id_idx on public.tasks (goal_id);
create index tasks_status_idx on public.tasks (status);
create index task_edges_child_task_id_idx on public.task_edges (child_task_id);
create index judgments_task_id_created_at_idx on public.judgments (task_id, created_at desc);
create index approval_queue_task_id_idx on public.approval_queue (task_id);
create index audit_log_task_id_idx on public.audit_log (task_id);
create index audit_log_created_at_idx on public.audit_log (created_at desc);
create index episodic_memory_user_id_idx on public.episodic_memory (user_id);

-- trigger helpers are not API functions
revoke execute on function
  public.tasks_enforce_policy(),
  public.approval_queue_stamp_decision(),
  public.set_updated_at()
from public, anon, authenticated;
