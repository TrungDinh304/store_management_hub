-- Story 1-3 tests: fulfillment FSM guard (S-12) + pos_fire_order (S-13).
-- TAKEAWAY orders are used throughout so no table_seat fixtures are needed
-- (fire does not touch occupancy; the table was occupied at create in 1-2).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(28);

-- ===== Fixtures (as postgres; superuser bypasses RLS) =====
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A'),
  ('22222222-2222-2222-2222-222222222222','Branch B');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA'),
  ('b2222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','baristaB','x','BARISTA');

-- Orders (all branch A, TAKEAWAY so table_id is null and unconstrained).
insert into pos.orders (id, branch_id, order_type, customer_name, created_by, fulfillment_state) values
  ('0f111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','FIRE','a1111111-1111-1111-1111-111111111111','DRAFT'),
  ('0e111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','EMPTY','a1111111-1111-1111-1111-111111111111','DRAFT'),
  ('0d111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','HOLD','a1111111-1111-1111-1111-111111111111','DRAFT'),
  ('05111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','SRVD','a1111111-1111-1111-1111-111111111111','SERVED'),
  ('0c111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','CANC','a1111111-1111-1111-1111-111111111111','CANCELLED'),
  ('0a111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','RDY','a1111111-1111-1111-1111-111111111111','READY'),
  ('0b111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','XBR','a1111111-1111-1111-1111-111111111111','DRAFT');

-- ACTIVE lines for orders that need to be fireable; a VOIDED line for EMPTY.
insert into pos.order_lines
  (order_id, branch_id, product_id, product_name_snapshot, unit_price_minor, quantity, recipe_snapshot, line_state, line_subtotal_minor)
values
  ('0f111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','90000000-0000-0000-0000-000000000001','Latte',50000,1,'[]'::jsonb,'ACTIVE',50000),
  ('0d111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','90000000-0000-0000-0000-000000000001','Latte',50000,1,'[]'::jsonb,'ACTIVE',50000),
  ('05111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','90000000-0000-0000-0000-000000000001','Latte',50000,1,'[]'::jsonb,'ACTIVE',50000),
  ('0a111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','90000000-0000-0000-0000-000000000001','Latte',50000,1,'[]'::jsonb,'ACTIVE',50000),
  ('0b111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','90000000-0000-0000-0000-000000000001','Latte',50000,1,'[]'::jsonb,'ACTIVE',50000),
  ('0e111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','90000000-0000-0000-0000-000000000001','Latte',50000,1,'[]'::jsonb,'VOIDED',0);

-- ===== Section A: FSM guard matrix (AC5) — run as postgres (internal helper) =====
select lives_ok($$ select pos.assert_fulfillment_transition('DRAFT','IN_PREP') $$,   'guard: DRAFT→IN_PREP legal');
select lives_ok($$ select pos.assert_fulfillment_transition('DRAFT','CANCELLED') $$, 'guard: DRAFT→CANCELLED legal');
select lives_ok($$ select pos.assert_fulfillment_transition('IN_PREP','READY') $$,   'guard: IN_PREP→READY legal');
select lives_ok($$ select pos.assert_fulfillment_transition('IN_PREP','IN_PREP') $$, 'guard: IN_PREP→IN_PREP (re-fire) legal');
select lives_ok($$ select pos.assert_fulfillment_transition('READY','SERVED') $$,    'guard: READY→SERVED legal');
select throws_ok($$ select pos.assert_fulfillment_transition('DRAFT','READY') $$,    'INVALID_STATE', 'guard: DRAFT→READY skip rejected');
select throws_ok($$ select pos.assert_fulfillment_transition('READY','IN_PREP') $$,  'INVALID_STATE', 'guard: READY→IN_PREP backward rejected');
select throws_ok($$ select pos.assert_fulfillment_transition('SERVED','READY') $$,   'INVALID_STATE', 'guard: SERVED→* rejected');
select throws_ok($$ select pos.assert_fulfillment_transition('CANCELLED','IN_PREP') $$,'INVALID_STATE','guard: CANCELLED→* rejected');

-- ===== Become a real RLS-subject branch-A barista for the RPC tests =====
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';

-- ----- Section B: fire happy path (AC1) -----
select lives_ok($$ select pos.pos_fire_order('0f111111-1111-1111-1111-111111111111') $$,
                'fire a DRAFT order with an ACTIVE line succeeds');
select is((select fulfillment_state from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          'IN_PREP', 'fired order is IN_PREP');
select ok((select fired_at from pos.orders where id='0f111111-1111-1111-1111-111111111111') is not null,
          'fired order has fired_at stamped');
select is((select version from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          1, 'fire bumps version to 1');

-- ----- Section C: empty order (AC2) -----
select throws_ok($$ select pos.pos_fire_order('0e111111-1111-1111-1111-111111111111') $$,
                 'EMPTY_ORDER', 'firing an order with no ACTIVE line is rejected');
select is((select fulfillment_state from pos.orders where id='0e111111-1111-1111-1111-111111111111'),
          'DRAFT', 'rejected empty order stays DRAFT');

-- ----- Section D: hold (AC3) -----
select is((select fulfillment_state from pos.orders where id='0d111111-1111-1111-1111-111111111111'),
          'DRAFT', 'a never-fired (held) order stays DRAFT');

-- ----- Section E: re-fire is idempotent (AC4) -----
select lives_ok($$ select pos.pos_fire_order('0f111111-1111-1111-1111-111111111111') $$,
                're-firing an IN_PREP order succeeds (idempotent)');
select is((select fulfillment_state from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          'IN_PREP', 're-fire leaves the order IN_PREP');
select is((select version from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          1, 're-fire does NOT bump version (no second fire)');
select is((select count(*)::int from pos.order_lines where order_id='0f111111-1111-1111-1111-111111111111'),
          1, 're-fire creates no duplicate lines (no second sale)');

-- ----- Section E2: re-firing an all-VOIDED IN_PREP order is rejected (review patch P1) -----
-- Void the only line of the already-fired order (direct fixture edit as postgres,
-- standing in for the future Story 1-9 void RPC), then attempt to re-fire.
reset role;
update pos.order_lines set line_state='VOIDED'
  where order_id='0f111111-1111-1111-1111-111111111111';
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select throws_ok($$ select pos.pos_fire_order('0f111111-1111-1111-1111-111111111111') $$,
                 'EMPTY_ORDER', 're-firing an IN_PREP order with no ACTIVE line is rejected');
select is((select fulfillment_state from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          'IN_PREP', 'rejected empty re-fire leaves the order unchanged (IN_PREP)');

-- ----- Section F: illegal fire rejected by the guard (AC5) -----
select throws_ok($$ select pos.pos_fire_order('05111111-1111-1111-1111-111111111111') $$,
                 'INVALID_STATE', 'firing a SERVED order is rejected');
select throws_ok($$ select pos.pos_fire_order('0c111111-1111-1111-1111-111111111111') $$,
                 'INVALID_STATE', 'firing a CANCELLED order is rejected');
select throws_ok($$ select pos.pos_fire_order('0a111111-1111-1111-1111-111111111111') $$,
                 'INVALID_STATE', 'firing a READY order is rejected');

-- ----- Section G: branch isolation (AC6) -----
-- Branch B cannot fire branch A's order.
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';
select throws_ok($$ select pos.pos_fire_order('0b111111-1111-1111-1111-111111111111') $$,
                 'ORDER_NOT_FOUND', 'branch B cannot fire a branch A order (cross-tenant blocked)');
-- Branch A still can (same-branch access intact).
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select lives_ok($$ select pos.pos_fire_order('0b111111-1111-1111-1111-111111111111') $$,
                'branch A fires its own order');
select is((select fulfillment_state from pos.orders where id='0b111111-1111-1111-1111-111111111111'),
          'IN_PREP', 'branch A order is now IN_PREP');

select * from finish();
rollback;
