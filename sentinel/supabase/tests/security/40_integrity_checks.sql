-- Integrity checks for 20260726000002_sentinel_v2_integrity.sql.
\set QUIET on
\set A '''aaaaaaaa-0000-0000-0000-000000000001'''

set role sentinel_executor; select set_config('request.jwt.claim.sub', '', false);

-- least privilege
select t('I  task gives send_email to a role not allowed to use it',
  $q$insert into tasks (goal_id, description, tool_name, agent_role) values ('11111111-0000-0000-0000-000000000001', 'x', 'send_email', 'researcher')$q$, 'error');

-- risk floor: base 0 + financial 2 + external 1 = 3 -> tier 2, despite claiming 0 / tier 1
select t('I  risk floor raises an under-scored task (financial, external)',
  $q$with ins as (insert into tasks (goal_id, description, tool_name, agent_role, data_sensitivity, scope, intrinsic_risk, approval_tier) values ('11111111-0000-0000-0000-000000000001', 'x', 'web_search', 'researcher', '{financial}', 'external', 0, 1) returning intrinsic_risk, approval_tier) select 1 from ins where intrinsic_risk = 3 and approval_tier = 2$q$, 'rows=1');

-- base 2 + irreversible 2 + external 1 = 5 -> tier 3
select t('I  risk floor puts an external irreversible send at Level 3',
  $q$with ins as (insert into tasks (goal_id, description, tool_name, agent_role, scope, intrinsic_risk, approval_tier) values ('11111111-0000-0000-0000-000000000001', 'x', 'send_email', 'communicator', 'external', 0, 1) returning approval_tier) select 1 from ins where approval_tier = 3$q$, 'rows=1');

-- risk frozen for the executor
select t('I  executor lowers a task''s risk',
  $q$update tasks set intrinsic_risk = 0 where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
select t('I  executor lowers a task''s approval tier',
  $q$update tasks set approval_tier = 1 where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
select t('I  executor swaps a task''s tool',
  $q$update tasks set tool_name = 'web_search' where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');

-- approval integrity
select t('I  executor queues a Level 3 task at tier 1',
  $q$insert into approval_queue (task_id, tier, reason) values ('22222222-0000-0000-0000-000000000002', 1, 'x')$q$, 'error');
select t('I  second pending approval for the same task',
  $q$insert into approval_queue (task_id, tier, reason) values ('22222222-0000-0000-0000-000000000001', 2, 'dup')$q$, 'error');

-- value checks
select t('I  status typo strands a task',
  $q$update tasks set status = 'complete' where id = '22222222-0000-0000-0000-000000000001'$q$, 'error');
select t('I  task depends on itself',
  $q$insert into task_edges values ('22222222-0000-0000-0000-000000000001', '22222222-0000-0000-0000-000000000001', 'blocks')$q$, 'error');
select t('I  judgment with an invalid verdict',
  $q$insert into judgments (task_id, verdict) values ('22222222-0000-0000-0000-000000000001', 'looks fine')$q$, 'error');

-- updated_at
select t('ok updated_at moves on update',
  $q$with u as (update tasks set status = 'executing' where id = '22222222-0000-0000-0000-000000000001' returning updated_at, created_at) select 1 from u where updated_at > created_at$q$, 'rows=1');

-- "unsupported" decompositions can be stored but are never polled
insert into tasks (goal_id, description, tool_name, agent_role)
values ('11111111-0000-0000-0000-000000000001', 'Needs a capability we lack', 'unsupported', 'researcher');
select t('ok unsupported task is stored',
  $q$select 1 from tasks where tool_name = 'unsupported'$q$, 'rows=1');
select t('I  executor polls an unsupported task',
  $q$select 1 from unblocked_tasks where tool_name = 'unsupported'$q$, 'rows=0');
reset role;

-- decided_at is server-stamped
set role authenticated; select set_config('request.jwt.claim.sub', :A, false);
select t('I  owner backdates decided_at',
  $q$update approval_queue set decided_at = '2000-01-01' where id = '33333333-0000-0000-0000-000000000001'$q$, 'error');
select t('ok decision gets a server timestamp',
  $q$with u as (update approval_queue set decision = 'approved', decided_by = 'aaaaaaaa-0000-0000-0000-000000000001' where id = '33333333-0000-0000-0000-000000000001' returning decided_at) select 1 from u where decided_at is not null$q$, 'rows=1');
select t('I  decision without a decider',
  $q$update approval_queue set decision = 'approved', decided_by = null where id = '33333333-0000-0000-0000-000000000001'$q$, 'error');
reset role;
