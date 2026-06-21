-- Story 1-2 tests: table_seat RLS + occupancy lifecycle across
-- pos_create_order / pos_assign_table / pos_abandon_order.
-- Orders are tagged via customer_name so they can be re-found after their
-- table_id changes (the RPCs accept a name on dine-in orders too).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(24);

-- ===== Fixtures (as postgres; superuser bypasses RLS) =====
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A'),
  ('22222222-2222-2222-2222-222222222222','Branch B');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA'),
  ('b2222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','baristaB','x','BARISTA');
insert into catalog.table_seat (id, branch_id, table_number, capacity, status) values
  ('71111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','A1',4,'AVAILABLE'),
  ('72222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','A2',2,'AVAILABLE'),
  ('73333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222','B1',4,'AVAILABLE');

-- ===== Section A: table_seat RLS (AC7) =====
set local role authenticated;
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';
select is((select count(*)::int from catalog.table_seat
            where branch_id = '11111111-1111-1111-1111-111111111111'), 0,
          'RLS: branch B cannot read branch A table_seat rows');
select is((select count(*)::int from catalog.table_seat), 1,
          'RLS: branch B sees only its own table');

set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select is((select count(*)::int from catalog.table_seat), 2,
          'RLS: branch A sees its own two tables');
select throws_ok(
  $$ update catalog.table_seat set status='OCCUPIED'
       where id='71111111-1111-1111-1111-111111111111' $$,
  '42501', NULL, 'RLS: authenticated cannot UPDATE table_seat directly');

-- ===== Section B: pos_create_order occupancy + validation (branch A; AC1,2,3,6) =====
select lives_ok(
  $$ select pos.pos_create_order('DINE_IN','71111111-1111-1111-1111-111111111111','ORD1') $$,
  'create DINE_IN on an available table succeeds');
select is((select status from catalog.table_seat
            where id='71111111-1111-1111-1111-111111111111'), 'OCCUPIED',
          'creating a DINE_IN order occupies the table (same txn)');
select throws_ok(
  $$ select pos.pos_create_order('DINE_IN','71111111-1111-1111-1111-111111111111','ORD2') $$,
  'TABLE_OCCUPIED', 'second active order on the same table is rejected');
select throws_ok(
  $$ select pos.pos_create_order('DINE_IN','73333333-3333-3333-3333-333333333333','ORDX') $$,
  'TABLE_NOT_FOUND', 'a table from another branch is rejected (TABLE_NOT_FOUND)');
select throws_ok(
  $$ select pos.pos_create_order('TAKEAWAY','72222222-2222-2222-2222-222222222222','Mary') $$,
  'TAKEAWAY_HAS_TABLE', 'TAKEAWAY carrying a table_id is rejected');
select throws_ok(
  $$ select pos.pos_create_order('DINE_IN', null, null) $$,
  'TABLE_REQUIRED', 'DINE_IN without a table is still rejected (1-1 regression)');

-- ===== Section C: pos_assign_table re-assign / guards (AC4,2,6) =====
-- ORD1 currently holds A1. Re-assign it to A2.
select lives_ok(
  $$ select pos.pos_assign_table(
       (select id from pos.orders where customer_name='ORD1'),
       '72222222-2222-2222-2222-222222222222') $$,
  'reassign a DRAFT dine-in order to a new table succeeds');
select is((select status from catalog.table_seat where id='71111111-1111-1111-1111-111111111111'),
          'AVAILABLE', 'reassign releases the old table');
select is((select status from catalog.table_seat where id='72222222-2222-2222-2222-222222222222'),
          'OCCUPIED', 'reassign occupies the new table');
select throws_ok(
  $$ select pos.pos_assign_table((select id from pos.orders where customer_name='ORD1'), null) $$,
  'TABLE_REQUIRED', 'clearing a dine-in table via assign is rejected (release via abandon)');

-- ORD3 on A1 (now free); reassign it onto A2 (occupied by ORD1) -> TABLE_OCCUPIED.
select pos.pos_create_order('DINE_IN','71111111-1111-1111-1111-111111111111','ORD3');
select throws_ok(
  $$ select pos.pos_assign_table((select id from pos.orders where customer_name='ORD3'),
       '72222222-2222-2222-2222-222222222222') $$,
  'TABLE_OCCUPIED', 'reassign to an occupied table is rejected');

-- Non-DRAFT order cannot be re-assigned.
reset role;
update pos.orders set fulfillment_state='IN_PREP' where customer_name='ORD3';
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select throws_ok(
  $$ select pos.pos_assign_table((select id from pos.orders where customer_name='ORD3'),
       '71111111-1111-1111-1111-111111111111') $$,
  'NOT_DRAFT', 'reassign on a non-DRAFT order is rejected');

-- A TAKEAWAY order cannot be given a table.
select pos.pos_create_order('TAKEAWAY', null, 'TKW1');
select throws_ok(
  $$ select pos.pos_assign_table((select id from pos.orders where customer_name='TKW1'),
       '71111111-1111-1111-1111-111111111111') $$,
  'NOT_DINE_IN', 'assigning a table to a TAKEAWAY order is rejected');

-- ===== Section D: pos_abandon_order (AC5) =====
-- ORD1 is a DRAFT dine-in holding A2.
select lives_ok(
  $$ select pos.pos_abandon_order((select id from pos.orders where customer_name='ORD1')) $$,
  'abandon a DRAFT dine-in order succeeds');
select is((select fulfillment_state from pos.orders where customer_name='ORD1'),
          'CANCELLED', 'abandoned order is CANCELLED');
select is((select status from catalog.table_seat where id='72222222-2222-2222-2222-222222222222'),
          'AVAILABLE', 'abandon releases the held table');
select is((select financial_state from pos.orders where customer_name='ORD1'),
          'OPEN', 'abandoned draft records no revenue (financial_state stays OPEN)');
select is((select total_minor from pos.orders where customer_name='ORD1'),
          0::bigint, 'abandoned draft has zero total (no revenue)');
select throws_ok(
  $$ select pos.pos_abandon_order((select id from pos.orders where customer_name='ORD1')) $$,
  'INVALID_STATE', 'abandoning an already-cancelled order is rejected');

-- ===== Section E: TAKEAWAY happy path still works (1-1 regression) =====
select is((select fulfillment_state from pos.orders where customer_name='TKW1'),
          'DRAFT', 'TAKEAWAY happy path still works (1-1 regression)');

select * from finish();
rollback;
