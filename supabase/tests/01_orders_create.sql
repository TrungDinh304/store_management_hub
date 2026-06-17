-- Story 1-1 tests: schema shape, constraints, and pos_create_order behavior.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(15);

-- Fixtures (as postgres; superuser bypasses RLS) ---------------------------
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA');

-- Caller identity (branch A barista)
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';

-- Schema shape
select has_table('app','branch','app.branch exists');
select has_table('app','user_account','app.user_account exists');
select has_table('pos','orders','pos.orders exists');
select has_table('pos','order_lines','pos.order_lines exists');
select has_table('pos','order_line_modifiers','pos.order_line_modifiers exists');
select has_function('app','current_branch_id','tenant seam function exists');

-- pos_create_order happy path (TAKEAWAY)
select lives_ok(
  $$ select pos.pos_create_order('TAKEAWAY', null, 'Mary') $$,
  'create TAKEAWAY order succeeds');
select is((select fulfillment_state from pos.orders limit 1), 'DRAFT', 'new order is DRAFT');
select is((select financial_state   from pos.orders limit 1), 'OPEN',  'new order is OPEN');
select is((select branch_id from pos.orders limit 1),
          '11111111-1111-1111-1111-111111111111'::uuid,
          'branch_id stamped from JWT, not a parameter');

-- Validation errors
select throws_ok(
  $$ select pos.pos_create_order('DINE_IN', null, null) $$,
  'TABLE_REQUIRED', 'DINE_IN without table is rejected');
select throws_ok(
  $$ select pos.pos_create_order('TAKEAWAY', null, '   ') $$,
  'CUSTOMER_NAME_REQUIRED', 'TAKEAWAY without name is rejected');
select throws_ok(
  $$ select pos.pos_create_order('DELIVERY', null, 'x') $$,
  'INVALID_ORDER_TYPE', 'unknown order type is rejected');

-- DB-level CHECK: dine-in requires a table (direct insert)
select throws_ok(
  $$ insert into pos.orders (branch_id, order_type, created_by)
     values ('11111111-1111-1111-1111-111111111111','DINE_IN',
             'a1111111-1111-1111-1111-111111111111') $$,
  '23514', NULL, 'ck_dinein_requires_table enforced at DB level');

-- Fail-closed: no branch context -> rejected
set local request.jwt.claims = '{}';
select throws_ok(
  $$ select pos.pos_create_order('TAKEAWAY', null, 'Mary') $$,
  'NO_BRANCH_CONTEXT', 'missing branch claim fails closed');

select * from finish();
rollback;
