-- ============================================================
-- Sentinel v2 — approval before execution
-- Timestamped migration: 20260726000003
-- Runs after 20260726000002_sentinel_v2_integrity.sql.
--
-- Problem: the loop ran Level 2/3 tasks first and asked for approval
-- afterwards, so an irreversible action (send_email, a payment) had
-- already happened by the time the approval card appeared.
--
-- Now:
--   - A task requires pre-approval when it is Level 3, or Level 2+ and
--     irreversible or external. Computed by the database, never lowered.
--   - Once its dependencies are done it appears in
--     tasks_needing_preapproval. The executor writes the exact call it
--     intends to make into planned_call, sets status
--     awaiting_preapproval and queues a 'pre_execution' approval.
--   - planned_call is frozen while under review and after approval, so
--     what you approve is what runs.
--   - The database refuses:
--       executing  without an approved pre-execution approval (when required)
--       approved   without a human post-execution approval
--       completed  for a Level 2+ task without any human approval
--   - A decision applies itself: pre-approval returns the task to the
--     queue; post-approval marks it approved; a rejection marks it
--     rejected and blocks every downstream task (not silently dropped).
--
-- Reversible internal Level 2 tasks keep the original flow: they run,
-- the Judge checks them, and you review the output before children run.
-- ============================================================


-- ============ columns + statuses ============

alter table public.tasks
  add column requires_preapproval boolean not null default false,
  add column planned_call jsonb;

alter table public.approval_queue
  add column stage text not null default 'post_execution';
alter table public.approval_queue add constraint approval_queue_stage_check
  check (stage in ('pre_execution', 'post_execution'));

alter table public.tasks drop constraint tasks_status_check;
alter table public.tasks add constraint tasks_status_check
  check (status in ('pending','awaiting_preapproval','executing','judging','repair',
                    'awaiting_approval','approved','rejected','completed','failed','blocked'));


-- ============ requires_preapproval (extends the risk-floor trigger) ============

create or replace function public.tasks_enforce_policy()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  tool public.tool_registry%rowtype;
  floor_risk int;
  floor_tier int;
  irreversible boolean;
begin
  select * into tool from public.tool_registry where name = new.tool_name;

  -- least privilege: the role must be allowed to use this tool
  if new.tool_name <> 'unsupported' and not exists (
    select 1 from public.agent_roles r
    where r.name = new.agent_role and new.tool_name = any (r.allowed_tools)
  ) then
    raise exception 'agent role % is not allowed to use tool %',
      new.agent_role, new.tool_name using errcode = '42501';
  end if;

  irreversible := coalesce(tool.irreversible, false) or not new.reversible;

  -- deterministic part of the decomposer's risk formula
  floor_risk := coalesce(tool.base_risk, 0)
    + case when irreversible then 2 else 0 end
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

  -- approve before running anything you can't take back
  new.requires_preapproval := new.requires_preapproval
    or new.approval_tier = 3
    or (new.approval_tier >= 2 and (irreversible or new.scope = 'external'));

  return new;
end;
$$;

drop trigger tasks_enforce_policy on public.tasks;
create trigger tasks_enforce_policy
  before insert or update of tool_name, agent_role, reversible, scope,
    data_sensitivity, flagged_sensitive, intrinsic_risk, inherited_risk,
    approval_tier, requires_preapproval
  on public.tasks
  for each row execute function public.tasks_enforce_policy();

-- backfill rows that existed before this migration (fires the trigger)
update public.tasks set requires_preapproval = requires_preapproval;


-- ============ status guards ============

create or replace function public.tasks_guard_transitions()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  pre_ok boolean;
  post_ok boolean;
begin
  select
    coalesce(bool_or(stage = 'pre_execution'  and decision = 'approved'), false),
    coalesce(bool_or(stage = 'post_execution' and decision = 'approved'), false)
  into pre_ok, post_ok
  from public.approval_queue
  where task_id = new.id;

  -- what you approved is what runs
  if new.planned_call is distinct from old.planned_call
     and (old.status = 'awaiting_preapproval' or pre_ok) then
    raise exception 'planned_call for task % is locked: it is under review or already approved', new.id
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if new.status = 'executing' and new.requires_preapproval and not pre_ok then
      raise exception 'task % requires approval before execution', new.id
        using errcode = '42501';
    end if;

    if new.status = 'awaiting_preapproval' and new.planned_call is null then
      raise exception 'task % needs a planned_call before requesting approval', new.id
        using errcode = '23514';
    end if;

    if new.status = 'approved' and not post_ok then
      raise exception 'task % can only be marked approved by a human decision', new.id
        using errcode = '42501';
    end if;

    if new.status = 'completed' and new.approval_tier >= 2 and not (pre_ok or post_ok) then
      raise exception 'Level % task % cannot complete without a human approval',
        new.approval_tier, new.id using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger tasks_guard_transitions
  before update of status, planned_call on public.tasks
  for each row execute function public.tasks_guard_transitions();

-- the executor writes the call it intends to make
grant update (planned_call) on public.tasks to sentinel_executor;


-- ============ decisions apply themselves ============

create or replace function public.approval_queue_apply_decision()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.decision = 'approved' then
    if new.stage = 'pre_execution' then
      -- back into the queue; unblocked_tasks now lets it through
      update public.tasks set status = 'pending'
      where id = new.task_id and status = 'awaiting_preapproval';
    else
      update public.tasks set status = 'approved'
      where id = new.task_id and status = 'awaiting_approval';
    end if;

  elsif new.decision = 'rejected' then
    update public.tasks set status = 'rejected'
    where id = new.task_id;

    -- block everything that depends on it, transitively
    with recursive downstream (id) as (
      select te.child_task_id from public.task_edges te
      where te.parent_task_id = new.task_id and te.edge_type = 'blocks'
      union
      select te.child_task_id from public.task_edges te
      join downstream d on te.parent_task_id = d.id
      where te.edge_type = 'blocks'
    )
    update public.tasks set status = 'blocked'
    where id in (select id from downstream)
      and status in ('pending', 'awaiting_preapproval');
  end if;

  return null;
end;
$$;

create trigger approval_queue_apply_decision
  after update of decision on public.approval_queue
  for each row
  when (old.decision is null and new.decision is not null)
  execute function public.approval_queue_apply_decision();

-- the executor sets the stage when it queues an approval
grant insert (stage) on public.approval_queue to sentinel_executor;


-- ============ views ============

-- dependencies satisfied (shared by both views below)
create or replace view public.ready_tasks
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

-- ready AND cleared to run
create or replace view public.unblocked_tasks
with (security_invoker = true)
as
select t.*
from public.ready_tasks t
where not t.requires_preapproval
   or exists (
     select 1 from public.approval_queue aq
     where aq.task_id = t.id and aq.stage = 'pre_execution' and aq.decision = 'approved'
   );

-- ready but waiting for the executor to plan the call and ask
create or replace view public.tasks_needing_preapproval
with (security_invoker = true)
as
select t.*
from public.ready_tasks t
where t.requires_preapproval
and not exists (
  select 1 from public.approval_queue aq
  where aq.task_id = t.id and aq.stage = 'pre_execution'
    and (aq.decision is null or aq.decision = 'approved')
);

revoke all on public.ready_tasks, public.tasks_needing_preapproval from anon, authenticated;
grant select on public.ready_tasks, public.unblocked_tasks, public.tasks_needing_preapproval
  to sentinel_executor;

-- reviewers see the stage and, for pre-execution, the exact planned call
create or replace view public.approval_queue_view
with (security_invoker = true)
as
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
  end as escalation_source,
  aq.stage,
  t.planned_call
from public.approval_queue aq
join public.tasks t on t.id = aq.task_id
join public.goals g on g.id = t.goal_id
left join lateral (
  select * from public.judgments j2 where j2.task_id = t.id
  order by created_at desc limit 1
) j on true
where aq.decision is null
order by aq.tier desc, aq.created_at asc;


-- trigger helpers are not API functions
revoke execute on function
  public.tasks_enforce_policy(),
  public.tasks_guard_transitions(),
  public.approval_queue_apply_decision()
from public, anon, authenticated;
