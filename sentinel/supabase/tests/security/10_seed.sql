-- Users: A (owner of the goal), B (other user, attacker), ADM (admin)
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000002'),
  ('dddddddd-0000-0000-0000-000000000004');

insert into tool_registry (name, description, base_risk, irreversible, handler_ref)
values ('web_search', 'search', 0, false, 'tools/web_search'),
       ('send_email', 'email', 2, true, 'tools/send_email');
insert into agent_roles (name, system_prompt, allowed_tools)
values ('researcher', 'You research.', '{web_search}');

insert into goals (id, user_id, raw_input, status)
values ('11111111-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001', 'A secret goal: plan acquisition', 'active');

insert into tasks (id, goal_id, description, tool_name, agent_role, status, approval_tier, result)
values
 ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
  'Research target', 'web_search', 'researcher', 'awaiting_approval', 2, '{"summary":"confidential"}'),
 ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
  'Email the board', 'send_email', 'researcher', 'pending', 3, null);

-- t2 is blocked until t1 is approved
insert into task_edges values
 ('22222222-0000-0000-0000-000000000001', '22222222-0000-0000-0000-000000000002', 'blocks');

insert into approval_queue (id, task_id, tier, reason)
values ('33333333-0000-0000-0000-000000000001', '22222222-0000-0000-0000-000000000001', 2, 'needs review');

insert into audit_log (task_id, event_type, actor, payload)
values ('22222222-0000-0000-0000-000000000001', 'executed', 'researcher', '{"x":1}');

-- a tool proposal that was already rejected, and one still pending
insert into tool_registrations_pending (id, proposed_by, tool_definition, status)
values
 ('44444444-0000-0000-0000-000000000001', 'researcher',
  '{"name":"wire_money","base_risk":0,"irreversible":false,"handler_ref":"tools/wire"}', 'rejected'),
 ('44444444-0000-0000-0000-000000000002', 'researcher',
  '{"name":"read_calendar","base_risk":1,"irreversible":false,"handler_ref":"tools/cal"}', 'pending');
