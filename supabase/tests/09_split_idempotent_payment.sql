-- Story 1-5 tests: split payments (S-17) + graceful idempotency replay (S-05).
-- TAKEAWAY orders with explicit totals; assertions run as a branch-A barista.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(22);

-- ===== Fixtures (as postgres) =====
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A'),
  ('22222222-2222-2222-2222-222222222222','Branch B');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA'),
  ('b2222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','baristaB','x','BARISTA');
insert into pos.orders (id, branch_id, order_type, customer_name, created_by, total_minor) values
  ('0a111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','SPLIT','a1111111-1111-1111-1111-111111111111',100000),
  ('0b111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','REPLAY','a1111111-1111-1111-1111-111111111111',50000),
  ('0c111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','MID','a1111111-1111-1111-1111-111111111111',100000),
  ('0d111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','OTHER','a1111111-1111-1111-1111-111111111111',50000),
  ('0e111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','REG','a1111111-1111-1111-1111-111111111111',30000),
  ('0fa11111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','XBRA','a1111111-1111-1111-1111-111111111111',50000),
  ('0fb22222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','TAKEAWAY','XBRB','b2222222-2222-2222-2222-222222222222',50000);
-- A branch-B payment already used key 'xbr-key' (seeded directly as postgres).
insert into pos.payment_transactions
  (order_id, branch_id, kind, method, amount_minor, idempotency_key, actor)
values
  ('0fb22222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222',
   'CHARGE','CARD',50000,'xbr-key','b2222222-2222-2222-2222-222222222222');

set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';

-- ===== Section A: split across methods → PAID (AC1) =====
select is((pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CARD',60000,null,'sk-A')->>'balance_minor')::bigint,
          40000::bigint, 'split: first CARD 60000 leaves balance 40000');
select is((select financial_state from pos.orders where id='0a111111-1111-1111-1111-111111111111'),
          'PARTIALLY_PAID', 'split: order is PARTIALLY_PAID after first payment');
select is((pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CASH',40000,40000,'sk-B')->>'balance_minor')::bigint,
          0::bigint, 'split: second CASH 40000 closes the balance');
select is((select financial_state from pos.orders where id='0a111111-1111-1111-1111-111111111111'),
          'PAID', 'split: order is PAID once balance hits 0');
select is((select count(*)::int from pos.payment_transactions where order_id='0a111111-1111-1111-1111-111111111111'),
          2, 'split: exactly two ledger rows');

-- ===== Section B: idempotent replay of a PAID order (AC2/AC3) =====
select is((pos.pos_take_payment('0b111111-1111-1111-1111-111111111111','CARD',50000,null,'rk-K')->>'balance_minor')::bigint,
          0::bigint, 'replay: first payment drives balance to 0');
select is((select version from pos.orders where id='0b111111-1111-1111-1111-111111111111')::int,
          1, 'replay: first payment bumps version to 1');
-- The replay must succeed (NOT raise ALREADY_PAID) and report itself as a replay.
select is((pos.pos_take_payment('0b111111-1111-1111-1111-111111111111','CARD',50000,null,'rk-K')->>'idempotent_replay'),
          'true', 'replay: same key returns idempotent_replay=true (no ALREADY_PAID)');
select is((select version from pos.orders where id='0b111111-1111-1111-1111-111111111111')::int,
          1, 'replay: version is NOT bumped a second time');
select is((select count(*)::int from pos.payment_transactions where order_id='0b111111-1111-1111-1111-111111111111'),
          1, 'replay: no second ledger row created');
select is((select financial_state from pos.orders where id='0b111111-1111-1111-1111-111111111111'),
          'PAID', 'replay: order remains PAID');

-- ===== Section C: mid-split replay (AC2) =====
select is((pos.pos_take_payment('0c111111-1111-1111-1111-111111111111','CARD',60000,null,'mk-A')->>'balance_minor')::bigint,
          40000::bigint, 'mid: partial leaves balance 40000');
select is((pos.pos_take_payment('0c111111-1111-1111-1111-111111111111','CARD',60000,null,'mk-A')->>'idempotent_replay'),
          'true', 'mid: replay of the partial returns the original');
select is((select financial_state from pos.orders where id='0c111111-1111-1111-1111-111111111111'),
          'PARTIALLY_PAID', 'mid: replay leaves PARTIALLY_PAID');
select is((select version from pos.orders where id='0c111111-1111-1111-1111-111111111111')::int,
          1, 'mid: replay does not bump version');
select is((select count(*)::int from pos.payment_transactions where order_id='0c111111-1111-1111-1111-111111111111'),
          1, 'mid: replay creates no second row');

-- ===== Section D: cross-order key reuse → typed error (AC4) =====
select throws_ok(
  $$ select pos.pos_take_payment('0d111111-1111-1111-1111-111111111111','CARD',50000,null,'sk-A') $$,
  'IDEMPOTENCY_KEY_CONFLICT', 'reusing a key from another order is rejected');

-- ===== Section E: regression — ALREADY_PAID still fires for a NEW key on a paid order (AC6) =====
select is((pos.pos_take_payment('0e111111-1111-1111-1111-111111111111','CARD',30000,null,'reg-1')->>'balance_minor')::bigint,
          0::bigint, 'regression: single card payment → balance 0');
select throws_ok(
  $$ select pos.pos_take_payment('0e111111-1111-1111-1111-111111111111','CARD',10000,null,'reg-2') $$,
  'ALREADY_PAID', 'regression: a NEW key on a PAID order still raises ALREADY_PAID');

-- ===== Section E2: review patches P3 (param mismatch) + P1 (cross-branch conflict) =====
-- P3: replaying key 'rk-K' (originally CARD 50000) with a different amount is rejected,
-- not silently reported as a success.
select throws_ok(
  $$ select pos.pos_take_payment('0b111111-1111-1111-1111-111111111111','CARD',40000,null,'rk-K') $$,
  'IDEMPOTENCY_KEY_MISMATCH', 'replaying a key with a different amount is rejected');
-- P1: key 'xbr-key' belongs to a branch-B order; a branch-A caller must hit a typed
-- conflict (the row is RLS-invisible here), NOT a false idempotent success.
select throws_ok(
  $$ select pos.pos_take_payment('0fa11111-1111-1111-1111-111111111111','CARD',50000,null,'xbr-key') $$,
  'IDEMPOTENCY_KEY_CONFLICT', 'a key owned by another branch is a typed conflict, not a false success');

-- ===== Section F: branch isolation regression (AC6) =====
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CARD',10000,null,'bx-1') $$,
  'ORDER_NOT_FOUND', 'branch B cannot pay a branch A order');

select * from finish();
rollback;
