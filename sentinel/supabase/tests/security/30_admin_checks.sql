-- Only meaningful after the fix (sentinel_admins is new).
\set QUIET on
\set B '''bbbbbbbb-0000-0000-0000-000000000002'''
\set ADM '''dddddddd-0000-0000-0000-000000000004'''

insert into sentinel_admins (user_id) values ('dddddddd-0000-0000-0000-000000000004');

set role authenticated; select set_config('request.jwt.claim.sub', :B, false);
select t('2  B makes themselves admin',
  $q$insert into sentinel_admins (user_id) values ('bbbbbbbb-0000-0000-0000-000000000002')$q$, 'error');
select t('2  B reads the tool registration queue',
  $q$select * from tool_registrations_pending$q$, 'rows=0');
reset role;

set role authenticated; select set_config('request.jwt.claim.sub', :ADM, false);
select t('2  admin re-approves a REJECTED tool',
  $q$select approve_tool_registration('44444444-0000-0000-0000-000000000001')$q$, 'error');
select t('ok admin reads the tool registration queue',
  $q$select * from tool_registrations_pending$q$, 'rows=2');
select t('ok admin approves a pending tool',
  $q$select approve_tool_registration('44444444-0000-0000-0000-000000000002')$q$, 'ok');
reset role;

-- the approval above was rolled back by t(); run it for real to test double-approval
set role authenticated; select set_config('request.jwt.claim.sub', :ADM, false);
select approve_tool_registration('44444444-0000-0000-0000-000000000002');
select t('2  admin approves the same tool twice',
  $q$select approve_tool_registration('44444444-0000-0000-0000-000000000002')$q$, 'error');
select t('ok admin rejects a pending tool (none left -> error)',
  $q$select reject_tool_registration('44444444-0000-0000-0000-000000000002')$q$, 'error');
reset role;
select t('ok approved tool landed in tool_registry',
  $q$select 1 from tool_registry where name = 'read_calendar' and irreversible = false$q$, 'rows=1');
