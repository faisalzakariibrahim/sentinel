-- Pre-execution approval checks for 20260726000003.
-- Unlike earlier files, some steps here are real (not rolled back) so the
-- whole flow can be walked: plan -> review -> approve -> execute, and
-- plan -> review -> reject -> downstream blocked.
\set QUIET on
\set ON_ERROR_STOP on
\set A '''aaaaaaaa-0000-0000-0000-000000000001'''
\set B '''bbbbbbbb-0000-0000-0000-000000000002'''

-- seed: t1 (web_search, reversible, awaiting post-review) blocks t2
--       (send_email, irreversible, Level 3)
select t('P  irreversible Level 3 send requires pre-approval',
  $q$select 1 from tasks where id = '22222222-0000-0000-0000-000000000002' and requires_preapproval$q$, 'rows=1');
select t('ok reversible internal research does not',
  $q$select 1 from tasks where id = '22222222-0000-0000-0000-000000000001' and not requires_preapproval$q$, 'rows=1');

-- ---------------- executor tries to skip the gates ----------------
set role sentinel_executor; select set_config('request.jwt.claim.sub', '', false);
select t('P  executor runs the send before approval',
  $q$update tasks set status = 'executing' where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
select t('P  executor marks its own work approved',
  $q$update tasks set status = 'approved' where id = '22222222-0000-0000-0000-000000000001'$q$, 'error');
select t('P  executor completes a Level 2 task with no human decision',
  $q$update tasks set status = 'completed' where id = '22222222-0000-0000-0000-000000000001'$q$, 'error');
select t('P  executor asks for approval without saying what it will do',
  $q$update tasks set status = 'awaiting_preapproval' where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
reset role;

-- ---------------- A approves t1's output (real) -> t1 approved -> t2 ready ----------------
set role authenticated; select set_config('request.jwt.claim.sub', :A, false);
update approval_queue set decision = 'approved', decided_by = 'aaaaaaaa-0000-0000-0000-000000000001'
where id = '33333333-0000-0000-0000-000000000001';
reset role;
select t('ok human post-approval marks t1 approved',
  $q$select 1 from tasks where id = '22222222-0000-0000-0000-000000000001' and status = 'approved'$q$, 'rows=1');

set role sentinel_executor; select set_config('request.jwt.claim.sub', '', false);
select t('P  t2 is ready but NOT runnable',
  $q$select 1 from unblocked_tasks where id = '22222222-0000-0000-0000-000000000002'$q$, 'rows=0');
select t('ok t2 shows up as needing pre-approval',
  $q$select 1 from tasks_needing_preapproval where id = '22222222-0000-0000-0000-000000000002'$q$, 'rows=1');

-- executor plans the exact call and asks (real)
update tasks set status = 'awaiting_preapproval',
  planned_call = '{"to": ["board@acme.test"], "subject": "Q3", "body": "Approved draft v1"}'
where id = '22222222-0000-0000-0000-000000000002';
insert into approval_queue (task_id, tier, stage, reason)
values ('22222222-0000-0000-0000-000000000002', 3, 'pre_execution', 'irreversible external send');

select t('P  executor swaps the email body while it is under review',
  $q$update tasks set planned_call = '{"to": ["attacker@evil.test"]}' where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
select t('P  executor runs the send while it is under review',
  $q$update tasks set status = 'executing' where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
select t('ok no longer listed as needing pre-approval',
  $q$select 1 from tasks_needing_preapproval where id = '22222222-0000-0000-0000-000000000002'$q$, 'rows=0');
reset role;

set role authenticated; select set_config('request.jwt.claim.sub', :A, false);
select t('ok reviewer sees the exact planned call',
  $q$select 1 from approval_queue_view where stage = 'pre_execution' and planned_call->>'body' = 'Approved draft v1'$q$, 'rows=1');
reset role;

set role authenticated; select set_config('request.jwt.claim.sub', :B, false);
select t('P  another user approves A''s send',
  $q$update approval_queue set decision = 'approved', decided_by = 'bbbbbbbb-0000-0000-0000-000000000002' where task_id = '22222222-0000-0000-0000-000000000002' and stage = 'pre_execution'$q$, 'rows=0');
reset role;

-- A approves the send (real)
set role authenticated; select set_config('request.jwt.claim.sub', :A, false);
update approval_queue set decision = 'approved', decided_by = 'aaaaaaaa-0000-0000-0000-000000000001'
where task_id = '22222222-0000-0000-0000-000000000002' and stage = 'pre_execution';
reset role;

set role sentinel_executor; select set_config('request.jwt.claim.sub', '', false);
select t('ok pre-approval returns t2 to the runnable queue',
  $q$select 1 from unblocked_tasks where id = '22222222-0000-0000-0000-000000000002'$q$, 'rows=1');
select t('P  executor edits the approved call before sending',
  $q$update tasks set planned_call = '{"to": ["attacker@evil.test"]}' where id = '22222222-0000-0000-0000-000000000002'$q$, 'error');
select t('ok executor runs the approved send',
  $q$update tasks set status = 'executing' where id = '22222222-0000-0000-0000-000000000002'$q$, 'rows=1');
select t('ok approved send can complete after a passing Judge',
  $q$update tasks set status = 'completed' where id = '22222222-0000-0000-0000-000000000002'$q$, 'rows=1');

-- ---------------- reject path: t3 (send) blocks t4, t4 blocks t5 ----------------
insert into tasks (id, goal_id, description, tool_name, agent_role, scope) values
 ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001', 'Email the press', 'send_email', 'communicator', 'external'),
 ('22222222-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000001', 'Track coverage', 'web_search', 'researcher', 'internal'),
 ('22222222-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000001', 'Summarise coverage', 'web_search', 'researcher', 'internal');
insert into task_edges values
 ('22222222-0000-0000-0000-000000000003', '22222222-0000-0000-0000-000000000004', 'blocks'),
 ('22222222-0000-0000-0000-000000000004', '22222222-0000-0000-0000-000000000005', 'blocks');
update tasks set status = 'awaiting_preapproval', planned_call = '{"to": ["press@news.test"]}'
where id = '22222222-0000-0000-0000-000000000003';
insert into approval_queue (task_id, tier, stage, reason)
values ('22222222-0000-0000-0000-000000000003', 3, 'pre_execution', 'press release');
reset role;

set role authenticated; select set_config('request.jwt.claim.sub', :A, false);
update approval_queue set decision = 'rejected', decided_by = 'aaaaaaaa-0000-0000-0000-000000000001'
where task_id = '22222222-0000-0000-0000-000000000003';
reset role;

select t('ok rejection marks the send rejected',
  $q$select 1 from tasks where id = '22222222-0000-0000-0000-000000000003' and status = 'rejected'$q$, 'rows=1');
select t('ok rejection blocks the direct dependent',
  $q$select 1 from tasks where id = '22222222-0000-0000-0000-000000000004' and status = 'blocked'$q$, 'rows=1');
select t('ok rejection blocks the dependent''s dependent',
  $q$select 1 from tasks where id = '22222222-0000-0000-0000-000000000005' and status = 'blocked'$q$, 'rows=1');

set role sentinel_executor; select set_config('request.jwt.claim.sub', '', false);
select t('P  rejected send can still be executed',
  $q$update tasks set status = 'executing' where id = '22222222-0000-0000-0000-000000000003'$q$, 'error');
reset role;
