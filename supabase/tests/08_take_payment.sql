-- Story 1-4 tests: payment ledger (append-only) + financial FSM guard + pos_take_payment.
-- TAKEAWAY orders with an explicit total_minor are used (no lines/table_seat needed).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(34);

-- ===== Fixtures (as postgres; superuser bypasses RLS) =====
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A'),
  ('22222222-2222-2222-2222-222222222222','Branch B');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA'),
  ('b2222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','baristaB','x','BARISTA');

-- Orders: all branch A, TAKEAWAY, OPEN, with explicit totals.
insert into pos.orders (id, branch_id, order_type, customer_name, created_by, total_minor) values
  ('01111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','SEED','a1111111-1111-1111-1111-111111111111',10000),
  ('0c111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','CASH','a1111111-1111-1111-1111-111111111111',50000),
  ('0d111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','CARD','a1111111-1111-1111-1111-111111111111',50000),
  ('0e111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','NONCASH','a1111111-1111-1111-1111-111111111111',50000),
  ('0f111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','PARTIAL','a1111111-1111-1111-1111-111111111111',50000),
  ('0a111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','REJECT','a1111111-1111-1111-1111-111111111111',50000),
  ('0b111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','TAKEAWAY','XBR','a1111111-1111-1111-1111-111111111111',50000);

-- ===== Section A: append-only ledger (AC1, AC6) — as postgres =====
select lives_ok(
  $$ insert into pos.payment_transactions
       (order_id, branch_id, kind, method, amount_minor, idempotency_key, actor)
     values ('01111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111',
             'CHARGE','CARD',10000,'seed-pay-1','a1111111-1111-1111-1111-111111111111') $$,
  'seed: a payment row can be inserted');
select throws_ok(
  $$ update pos.payment_transactions set amount_minor = 999 where idempotency_key = 'seed-pay-1' $$,
  'APPEND_ONLY', 'UPDATE on a payment row is rejected (append-only, even for owner)');
select throws_ok(
  $$ delete from pos.payment_transactions where idempotency_key = 'seed-pay-1' $$,
  'APPEND_ONLY', 'DELETE on a payment row is rejected (append-only)');
select throws_ok(
  $$ insert into pos.payment_transactions
       (order_id, branch_id, kind, method, amount_minor, idempotency_key, actor)
     values ('01111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111',
             'CHARGE','CARD',10000,'seed-pay-1','a1111111-1111-1111-1111-111111111111') $$,
  '23505', NULL, 'duplicate idempotency_key is rejected (UNIQUE)');
-- TRUNCATE is also blocked (review patch P1: append-only covers truncate too).
select throws_ok(
  $$ truncate pos.payment_transactions $$,
  'APPEND_ONLY', 'TRUNCATE on the ledger is rejected (append-only, even for owner)');
-- A change without a tender is forbidden at the table level (review patch P2).
select throws_ok(
  $$ insert into pos.payment_transactions
       (order_id, branch_id, kind, method, amount_minor, change_minor, idempotency_key, actor)
     values ('01111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111',
             'CHARGE','CASH',1000,500,'bad-change','a1111111-1111-1111-1111-111111111111') $$,
  '23514', NULL, 'a change_minor with no tendered_minor is rejected (CHECK)');

-- ===== Section B: financial FSM guard matrix (AC5) — as postgres (internal helper) =====
select lives_ok($$ select pos.assert_financial_transition('OPEN','PARTIALLY_PAID') $$,        'guard: OPEN→PARTIALLY_PAID legal');
select lives_ok($$ select pos.assert_financial_transition('OPEN','PAID') $$,                   'guard: OPEN→PAID legal');
select lives_ok($$ select pos.assert_financial_transition('PARTIALLY_PAID','PAID') $$,         'guard: PARTIALLY_PAID→PAID legal');
select lives_ok($$ select pos.assert_financial_transition('PAID','REFUNDED') $$,               'guard: PAID→REFUNDED legal');
select throws_ok($$ select pos.assert_financial_transition('PAID','PARTIALLY_PAID') $$,        'INVALID_STATE', 'guard: PAID→PARTIALLY_PAID backward rejected');
select throws_ok($$ select pos.assert_financial_transition('OPEN','CLOSED') $$,                'INVALID_STATE', 'guard: OPEN→CLOSED skip rejected');
select throws_ok($$ select pos.assert_financial_transition('REFUNDED','PAID') $$,              'INVALID_STATE', 'guard: REFUNDED→* rejected');

-- ===== Become a real RLS-subject branch-A barista for the RPC tests =====
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';

-- authenticated has no direct INSERT on the ledger (writes only via the RPC).
select throws_ok(
  $$ insert into pos.payment_transactions
       (order_id, branch_id, kind, method, amount_minor, idempotency_key, actor)
     values ('0c111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111',
             'CHARGE','CARD',50000,'direct-1','a1111111-1111-1111-1111-111111111111') $$,
  '42501', NULL, 'authenticated cannot INSERT a payment directly (RPC-only write path)');

-- ----- Section C: cash full payment → change + PAID (AC2) -----
select is((pos.pos_take_payment('0c111111-1111-1111-1111-111111111111','CASH',50000,100000,'k-cash')->>'change_minor')::bigint,
          50000::bigint, 'cash: change = tendered - amount = 50000');
select is((select financial_state from pos.orders where id='0c111111-1111-1111-1111-111111111111'),
          'PAID', 'cash full payment sets order PAID');
select is((select change_minor from pos.payment_transactions
            where order_id='0c111111-1111-1111-1111-111111111111' and method='CASH'),
          50000::bigint, 'cash payment row records server-computed change');

-- ----- Section D: card payment → PAID; non-cash tender rejected (AC3) -----
select is((pos.pos_take_payment('0d111111-1111-1111-1111-111111111111','CARD',50000,null,'k-card')->>'balance_minor')::bigint,
          0::bigint, 'card payment drives balance to 0');
select is((select financial_state from pos.orders where id='0d111111-1111-1111-1111-111111111111'),
          'PAID', 'card full payment sets order PAID');
select throws_ok(
  $$ select pos.pos_take_payment('0e111111-1111-1111-1111-111111111111','CARD',50000,100000,'k-nc') $$,
  'TENDER_ON_NON_CASH', 'a non-cash payment carrying a tender is rejected');

-- ----- Section E: partial then close; balance derived from the ledger (AC4) -----
select is((pos.pos_take_payment('0f111111-1111-1111-1111-111111111111','CARD',20000,null,'k-p1')->>'balance_minor')::bigint,
          30000::bigint, 'partial payment leaves balance 30000');
select is((select financial_state from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          'PARTIALLY_PAID', 'partial payment sets PARTIALLY_PAID');
select is((pos.pos_take_payment('0f111111-1111-1111-1111-111111111111','CASH',30000,30000,'k-p2')->>'change_minor')::bigint,
          0::bigint, 'closing payment exact cash → change 0');
select is((select financial_state from pos.orders where id='0f111111-1111-1111-1111-111111111111'),
          'PAID', 'second payment closes the balance → PAID');
select is((select count(*)::int from pos.payment_transactions where order_id='0f111111-1111-1111-1111-111111111111'),
          2, 'balance was derived from two ledger rows');

-- ----- Section F: rejections (AC5, AC6) -----
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CARD',60000,null,'k-x1') $$,
  'AMOUNT_EXCEEDS_BALANCE', 'paying more than the balance is rejected (card)');
-- Model A: cash overpay must be expressed via tendered, never a larger amount.
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CASH',60000,70000,'k-x1b') $$,
  'AMOUNT_EXCEEDS_BALANCE', 'cash amount over balance is rejected (overpay goes via tendered)');
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CASH',50000,40000,'k-x2') $$,
  'INSUFFICIENT_TENDER', 'cash tendered below the amount is rejected');
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CARD',0,null,'k-x3') $$,
  'INVALID_AMOUNT', 'a non-positive amount is rejected');
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','BTC',50000,null,'k-x4') $$,
  'INVALID_METHOD', 'an unknown method is rejected');
select throws_ok(
  $$ select pos.pos_take_payment('0a111111-1111-1111-1111-111111111111','CARD',50000,null,null) $$,
  'IDEMPOTENCY_KEY_REQUIRED', 'a missing idempotency key is rejected');
select throws_ok(
  $$ select pos.pos_take_payment('0c111111-1111-1111-1111-111111111111','CARD',10000,null,'k-x5') $$,
  'ALREADY_PAID', 'charging an already-PAID order is rejected');

-- ----- Section G: branch isolation (AC7) -----
set local request.jwt.claims = '{"sub":"b2222222-2222-2222-2222-222222222222","branch_id":"22222222-2222-2222-2222-222222222222","role":"BARISTA"}';
select throws_ok(
  $$ select pos.pos_take_payment('0b111111-1111-1111-1111-111111111111','CARD',50000,null,'k-bx') $$,
  'ORDER_NOT_FOUND', 'branch B cannot pay a branch A order (cross-tenant blocked)');
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select is((pos.pos_take_payment('0b111111-1111-1111-1111-111111111111','CARD',50000,null,'k-ba')->>'balance_minor')::bigint,
          0::bigint, 'branch A pays its own order to zero');

select * from finish();
rollback;
