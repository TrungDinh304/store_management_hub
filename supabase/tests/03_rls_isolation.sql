-- Story 1-1 tests: RLS branch isolation + write-surface lockdown (AC7).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(6);

-- Fixtures: two branches
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A'),
  ('22222222-2222-2222-2222-222222222222','Branch B');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA');

-- Create one order in Branch A (as postgres, branch-A claims)
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select lives_ok(
  $$ select pos.pos_create_order('TAKEAWAY', null, 'Mary') $$,
  'seed: order created in Branch A');

-- Now act as a real (RLS-subject) authenticated client
set local role authenticated;

-- Branch A sees its own order
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select is((select count(*)::int from pos.orders), 1, 'tenant A sees its own order');

-- Branch B cannot see Branch A's order
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';
select is((select count(*)::int from pos.orders), 0, 'tenant B cannot see Branch A order (RLS)');

-- Admin reads across branches
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"ADMIN"}';
select is((select count(*)::int from pos.orders), 1, 'admin reads across branches');

-- Authenticated cannot write directly (only the RPC may write)
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';
select throws_ok(
  $$ insert into pos.orders (branch_id, order_type, customer_name, created_by)
     values ('22222222-2222-2222-2222-222222222222','TAKEAWAY','x',
             'b2222222-2222-2222-2222-222222222222') $$,
  '42501', NULL, 'direct client INSERT denied (writes go through RPC only)');

-- Fail-closed: no claims -> no rows
set local request.jwt.claims = '{}';
select is((select count(*)::int from pos.orders), 0, 'no tenant context = no rows (fail closed)');

select * from finish();
rollback;
