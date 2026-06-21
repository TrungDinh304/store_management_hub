-- Story 1-2 code-review patch P2: cross-branch isolation on the table RPCs.
-- A barista in branch B must not be able to abandon or re-assign a branch-A order
-- (explicit branch_id scope + FORCE RLS both hide it -> ORDER_NOT_FOUND), while a
-- branch-A barista still operates on it normally (P2 didn't break same-branch access).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(6);

-- ===== Fixtures (as postgres; superuser bypasses RLS) =====
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A'),
  ('22222222-2222-2222-2222-222222222222','Branch B');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA'),
  ('b2222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','baristaB','x','BARISTA');
insert into catalog.table_seat (id, branch_id, table_number, capacity, status) values
  ('71111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','A1',4,'OCCUPIED'),
  ('73333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222','B1',4,'AVAILABLE');
-- A branch-A DRAFT dine-in order holding table A1, with a known id.
insert into pos.orders (id, branch_id, order_type, table_id, customer_name, created_by) values
  ('0a111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111',
   'DINE_IN','71111111-1111-1111-1111-111111111111','XBR1',
   'a1111111-1111-1111-1111-111111111111');

-- ===== Branch B cannot touch branch A's order =====
set local role authenticated;
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';

select throws_ok(
  $$ select pos.pos_abandon_order('0a111111-1111-1111-1111-111111111111') $$,
  'ORDER_NOT_FOUND', 'branch B cannot abandon a branch A order (cross-tenant blocked)');

select throws_ok(
  $$ select pos.pos_assign_table('0a111111-1111-1111-1111-111111111111',
       '73333333-3333-3333-3333-333333333333') $$,
  'ORDER_NOT_FOUND', 'branch B cannot re-assign a branch A order (cross-tenant blocked)');

-- The blocked attempts changed nothing.
reset role;
select is((select fulfillment_state from pos.orders where id='0a111111-1111-1111-1111-111111111111'),
          'DRAFT', 'branch A order untouched by the blocked cross-branch calls');

-- ===== Branch A still operates on its own order (P2 didn't break same-branch) =====
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select lives_ok(
  $$ select pos.pos_abandon_order('0a111111-1111-1111-1111-111111111111') $$,
  'branch A barista abandons its own order (same-branch access intact)');

reset role;
select is((select fulfillment_state from pos.orders where id='0a111111-1111-1111-1111-111111111111'),
          'CANCELLED', 'same-branch abandon cancels the order');
select is((select status from catalog.table_seat where id='71111111-1111-1111-1111-111111111111'),
          'AVAILABLE', 'same-branch abandon releases the held table (idempotent release P1)');

select * from finish();
rollback;
