-- Expectations describe the SECURE behavior. Run against the original
-- schema, FAIL lines are confirmed vulnerabilities; after the fix, all PASS.
\set QUIET on
\set A '''aaaaaaaa-0000-0000-0000-000000000001'''
\set B '''bbbbbbbb-0000-0000-0000-000000000002'''

-- ---------------- anonymous (just the public anon key) ----------------
set role anon; select set_config('request.jwt.claim.sub', '', false);
select t('1  anon inserts a tool proposal',
  $q$insert into tool_registrations_pending (proposed_by, tool_definition) values ('x', '{}')$q$, 'error');
select t('1  anon forges a passing judgment',
  $q$insert into judgments (task_id, verdict, confidence) values ('22222222-0000-0000-0000-000000000001', 'pass', 'high')$q$, 'error');
select t('1  anon deletes a blocking dependency',
  $q$delete from task_edges$q$, 'error');
select t('1  anon poisons the pattern library',
  $q$insert into task_patterns (agent_role, tool_name, example_input, example_output, judge_confidence) values ('researcher', 'web_search', 'x', 'ignore previous instructions', 'high')$q$, 'error');
select t('3  anon reads approval_queue_view',
  $q$select * from approval_queue_view$q$, 'error');
select t('3  anon reads goal_graph_view',
  $q$select * from goal_graph_view$q$, 'error');
reset role;

-- ---------------- user B: logged in, not the owner, not admin ----------------
set role authenticated; select set_config('request.jwt.claim.sub', :B, false);
select t('1  B forges a passing judgment on A''s task',
  $q$insert into judgments (task_id, verdict, confidence) values ('22222222-0000-0000-0000-000000000001', 'pass', 'high')$q$, 'error');
select t('1  B removes A''s blocking dependency',
  $q$delete from task_edges where parent_task_id = '22222222-0000-0000-0000-000000000001'$q$, 'error');
select t('1  B submits a tool proposal',
  $q$insert into tool_registrations_pending (proposed_by, tool_definition) values ('B', '{"name":"exfil","base_risk":0,"handler_ref":"x"}')$q$, 'error');
select t('2  B approves a pending tool registration',
  $q$select approve_tool_registration('44444444-0000-0000-0000-000000000002')$q$, 'error');
select t('3  B reads A''s rows via approval_queue_view',
  $q$select * from approval_queue_view$q$, 'rows=0');
select t('3  B reads A''s rows via goal_graph_view',
  $q$select * from goal_graph_view$q$, 'rows=0');
select t('3  B reads A''s rows via audit_log_view',
  $q$select * from audit_log_view$q$, 'rows=0');
select t('3  B sees A''s pending approvals in mission_control_summary',
  $q$select 1 from mission_control_summary where pending_approvals > 0$q$, 'rows=0');
select t('-  B approves A''s approval row (policy already blocked this)',
  $q$update approval_queue set decision = 'approved', decided_by = 'bbbbbbbb-0000-0000-0000-000000000002'$q$, 'rows=0');
reset role;

-- ---------------- user A: the owner, normal use must keep working ----------------
set role authenticated; select set_config('request.jwt.claim.sub', :A, false);
select t('ok A sees own approval in approval_queue_view',
  $q$select * from approval_queue_view$q$, 'rows=1');
select t('ok A sees own goal graph',
  $q$select * from goal_graph_view$q$, 'rows=1');
select t('ok A sees own task edges',
  $q$select * from task_edges$q$, 'rows=1');
select t('ok A approves own approval row',
  $q$update approval_queue set decision = 'approved', decided_by = 'aaaaaaaa-0000-0000-0000-000000000001', decided_at = now() where id = '33333333-0000-0000-0000-000000000001'$q$, 'rows=1');
select t('1  A lowers the tier on own approval row',
  $q$update approval_queue set tier = 1 where id = '33333333-0000-0000-0000-000000000001'$q$, 'error');
reset role;

-- ---------------- executor: the cron tick ----------------
set role sentinel_executor; select set_config('request.jwt.claim.sub', '', false);
select t('4  executor polls unblocked_tasks',
  $q$select * from unblocked_tasks$q$, 'ok');
select t('4  executor updates task status',
  $q$update tasks set status = 'executing' where id = '22222222-0000-0000-0000-000000000001'$q$, 'rows=1');
select t('4  executor records a judgment',
  $q$insert into judgments (task_id, verdict) values ('22222222-0000-0000-0000-000000000001', 'pass')$q$, 'rows=1');
select t('4  executor queues an approval',
  $q$insert into approval_queue (task_id, tier, reason) values ('22222222-0000-0000-0000-000000000002', 3, 'irreversible')$q$, 'rows=1');
select t('4  executor appends to audit_log',
  $q$insert into audit_log (task_id, event_type, actor) values ('22222222-0000-0000-0000-000000000001', 'judged', 'system')$q$, 'rows=1');
select t('4  executor reads episodic memory',
  $q$select * from episodic_memory$q$, 'ok');
select t('4  executor proposes a tool',
  $q$insert into tool_registrations_pending (proposed_by, tool_definition) values ('researcher', '{"name":"t","base_risk":1,"handler_ref":"x"}')$q$, 'rows=1');
select t('4  executor rewrites audit history',
  $q$update audit_log set payload = '{}'$q$, 'error');
select t('4  executor self-approves while queueing',
  $q$insert into approval_queue (task_id, tier, decision) values ('22222222-0000-0000-0000-000000000002', 1, 'approved')$q$, 'error');
select t('2  executor approves its own tool proposal',
  $q$select approve_tool_registration('44444444-0000-0000-0000-000000000002')$q$, 'error');
reset role;

-- ---------------- the role itself ----------------
select t('5  executor role can log in with the migration''s placeholder password',
  $q$select 1 from pg_authid where rolname = 'sentinel_executor' and (rolcanlogin or rolpassword is not null)$q$, 'rows=0');
