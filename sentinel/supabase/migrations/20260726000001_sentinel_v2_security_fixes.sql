-- ============================================================
-- Sentinel v2 — security fixes
-- Timestamped migration: 20260726000001
-- Runs after 20260726000000_sentinel_v2_core.sql.
--
-- Fixes:
--   1. Tables with RLS off (task_edges, judgments,
--      tool_registrations_pending, task_patterns) were writable by
--      anyone holding the anon key via Supabase's default grants.
--   2. approve_tool_registration() had no caller check and no status
--      check, so any user could approve their own tool (Level 2 bypass)
--      and rejected tools could be re-approved.
--   3. Mission Control views ran as their owner, bypassing RLS and
--      exposing every user's goals, tasks and outputs.
--   4. sentinel_executor had grants but no RLS policies, so every read
--      and write it made was silently denied. It also had no access to
--      the unblocked_tasks view it polls.
--   5. sentinel_executor was created with a placeholder password. It is
--      disabled here until scripts/set_sentinel_secret.sh sets a real one.
--
-- Hardening while in here:
--   - audit_log is append-only for the executor (no update/delete).
--   - Users can only change the decision columns on approval_queue,
--     not tier, task_id or reason.
--   - New sentinel_admins table gates tool-registration review.
-- ============================================================


-- ============ ADMINS (gate for tool registration review) ============

create table public.sentinel_admins (
  user_id uuid primary key references auth.users on delete cascade,
  created_at timestamptz default now()
);
alter table public.sentinel_admins enable row level security;

create policy sentinel_admins_self on public.sentinel_admins
  for select to authenticated using (user_id = auth.uid());

-- Admins are added by hand (SQL editor / service_role), never via the API:
--   insert into public.sentinel_admins (user_id) values ('<your auth.users id>');

create or replace function public.is_sentinel_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.sentinel_admins where user_id = auth.uid()
  );
$$;


-- ============ FIX 1: lock down table privileges + enable RLS ============

-- Supabase grants ALL on new public tables to anon and authenticated by
-- default. Start from nothing and grant back only what each role needs.
revoke all on
  public.goals, public.tasks, public.task_edges, public.judgments,
  public.approval_queue, public.tool_registry, public.agent_roles,
  public.tool_registrations_pending, public.episodic_memory,
  public.identity_memory, public.project_memory, public.task_patterns,
  public.audit_log, public.sentinel_admins
from anon, authenticated;

-- Dashboard users (RLS policies below decide which rows)
grant select, insert, update, delete on public.goals to authenticated;
grant select, insert, update, delete on public.identity_memory to authenticated;
grant select on
  public.tasks, public.task_edges, public.judgments, public.approval_queue,
  public.tool_registry, public.agent_roles, public.tool_registrations_pending,
  public.episodic_memory, public.project_memory, public.task_patterns,
  public.audit_log, public.sentinel_admins
to authenticated;
-- approval decisions only: tier, task_id and reason stay executor-owned
grant update (decision, decided_by, decided_at) on public.approval_queue to authenticated;

alter table public.task_edges enable row level security;
alter table public.judgments enable row level security;
alter table public.tool_registrations_pending enable row level security;
alter table public.task_patterns enable row level security;

create policy task_edges_via_goal on public.task_edges
  for select to authenticated using (
    exists (
      select 1 from public.tasks t
      join public.goals g on g.id = t.goal_id
      where t.id = task_edges.child_task_id and g.user_id = auth.uid()
    )
  );

create policy judgments_via_goal on public.judgments
  for select to authenticated using (
    exists (
      select 1 from public.tasks t
      join public.goals g on g.id = t.goal_id
      where t.id = judgments.task_id and g.user_id = auth.uid()
    )
  );

-- pattern library is shared, read-only for users
create policy task_patterns_read on public.task_patterns
  for select to authenticated using (true);

-- only admins see the tool registration queue
create policy tool_registrations_admin_read on public.tool_registrations_pending
  for select to authenticated using (public.is_sentinel_admin());


-- ============ FIX 2: tool registration approval gate ============

create or replace function public.approve_tool_registration(reg_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  reg public.tool_registrations_pending%rowtype;
  def jsonb;
begin
  if auth.uid() is null or not public.is_sentinel_admin() then
    raise exception 'not authorized to approve tool registrations'
      using errcode = '42501';
  end if;

  select * into reg
  from public.tool_registrations_pending
  where id = reg_id and status = 'pending'
  for update;

  if not found then
    raise exception 'registration % not found or no longer pending', reg_id
      using errcode = 'P0002';
  end if;

  def := reg.tool_definition;

  if coalesce(def->>'name', '') = ''
     or coalesce(def->>'handler_ref', '') = ''
     or def->>'base_risk' is null then
    raise exception 'tool_definition needs name, handler_ref and base_risk'
      using errcode = '22023';
  end if;

  if (def->>'base_risk')::int < 0 then
    raise exception 'base_risk cannot be negative' using errcode = '22023';
  end if;

  -- Plain insert: an existing tool name raises a unique violation instead
  -- of being silently overwritten. Missing "irreversible" fails safe (true).
  insert into public.tool_registry
    (name, description, base_risk, irreversible, requires_scope, handler_ref)
  values (
    def->>'name',
    def->>'description',
    (def->>'base_risk')::int,
    coalesce((def->>'irreversible')::boolean, true),
    def->>'requires_scope',
    def->>'handler_ref'
  );

  update public.tool_registrations_pending
  set status = 'approved', reviewed_by = auth.uid()
  where id = reg_id;
end;
$$;

create or replace function public.reject_tool_registration(reg_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not public.is_sentinel_admin() then
    raise exception 'not authorized to reject tool registrations'
      using errcode = '42501';
  end if;

  update public.tool_registrations_pending
  set status = 'rejected', reviewed_by = auth.uid()
  where id = reg_id and status = 'pending';

  if not found then
    raise exception 'registration % not found or no longer pending', reg_id
      using errcode = 'P0002';
  end if;
end;
$$;

-- Functions are executable by PUBLIC by default; the API exposes them.
revoke execute on function
  public.approve_tool_registration(uuid),
  public.reject_tool_registration(uuid),
  public.is_sentinel_admin()
from public, anon;
grant execute on function
  public.approve_tool_registration(uuid),
  public.reject_tool_registration(uuid),
  public.is_sentinel_admin()
to authenticated;


-- ============ FIX 3: views respect the caller's RLS ============

alter view public.unblocked_tasks set (security_invoker = true);
alter view public.goal_graph_view set (security_invoker = true);
alter view public.approval_queue_view set (security_invoker = true);
alter view public.cost_by_tool set (security_invoker = true);
alter view public.cost_by_goal set (security_invoker = true);
alter view public.judge_stats_by_task_type set (security_invoker = true);
alter view public.judge_stats_last_7d set (security_invoker = true);
alter view public.audit_log_view set (security_invoker = true);
alter view public.mission_control_summary set (security_invoker = true);

revoke all on
  public.unblocked_tasks, public.goal_graph_view, public.approval_queue_view,
  public.cost_by_tool, public.cost_by_goal, public.judge_stats_by_task_type,
  public.judge_stats_last_7d, public.audit_log_view,
  public.mission_control_summary
from anon, authenticated;

grant select on
  public.goal_graph_view, public.approval_queue_view, public.cost_by_tool,
  public.cost_by_goal, public.judge_stats_by_task_type,
  public.judge_stats_last_7d, public.audit_log_view,
  public.mission_control_summary
to authenticated;


-- ============ FIX 4: executor policies ============
-- Each policy is "for all"; the table grants decide which operations the
-- executor actually has. The executor has no JWT, so the auth.uid()-based
-- user policies never match it.

-- The v2 user policies had no TO clause, so they also applied to the
-- executor and queried goals, which it has no grant on ("permission denied
-- for table goals"). Scope them to dashboard users only.
alter policy goals_owner on public.goals to authenticated;
alter policy tasks_via_goal on public.tasks to authenticated;
alter policy approval_view on public.approval_queue to authenticated;
alter policy approval_decide on public.approval_queue to authenticated;
alter policy identity_memory_owner on public.identity_memory to authenticated;
alter policy episodic_memory_owner on public.episodic_memory to authenticated;
alter policy project_memory_via_goal on public.project_memory to authenticated;
alter policy audit_log_view on public.audit_log to authenticated;
alter policy tool_registry_read on public.tool_registry to authenticated, sentinel_executor;
alter policy agent_roles_read on public.agent_roles to authenticated, sentinel_executor;

-- audit trail is append-only for the executor
revoke update, delete on public.audit_log from sentinel_executor;

-- the cron tick polls this view
grant select on public.unblocked_tasks to sentinel_executor;

-- agents can propose tools; only an admin can approve them (fix 2)
grant select, insert (proposed_by, tool_definition)
  on public.tool_registrations_pending to sentinel_executor;

create policy executor_tasks on public.tasks
  for all to sentinel_executor using (true) with check (true);
create policy executor_task_edges on public.task_edges
  for all to sentinel_executor using (true) with check (true);
create policy executor_judgments on public.judgments
  for all to sentinel_executor using (true) with check (true);
create policy executor_audit_log on public.audit_log
  for all to sentinel_executor using (true) with check (true);
create policy executor_episodic_memory on public.episodic_memory
  for all to sentinel_executor using (true) with check (true);
create policy executor_identity_memory on public.identity_memory
  for all to sentinel_executor using (true) with check (true);
create policy executor_project_memory on public.project_memory
  for all to sentinel_executor using (true) with check (true);
create policy executor_task_patterns on public.task_patterns
  for all to sentinel_executor using (true) with check (true);

-- the executor queues approvals but can never record a decision
create policy executor_approval_queue_read on public.approval_queue
  for select to sentinel_executor using (true);
create policy executor_approval_queue_insert on public.approval_queue
  for insert to sentinel_executor
  with check (decision is null and decided_by is null and decided_at is null);

create policy executor_tool_registrations on public.tool_registrations_pending
  for all to sentinel_executor
  using (true)
  with check (status = 'pending' and reviewed_by is null);


-- ============ FIX 5: no login with the placeholder password ============
-- Run scripts/set_sentinel_secret.sh after this migration. It sets a real
-- password and turns LOGIN back on.
alter role sentinel_executor with nologin password null;
