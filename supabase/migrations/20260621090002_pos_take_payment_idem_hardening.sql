-- Story 1-5 code-review patches (2026-06-21). Forward-only CREATE OR REPLACE.
--   P1 (HIGH) — Cross-branch / uncommitted-concurrent key collision was a FALSE
--      idempotent success: the replay SELECTs are RLS branch-scoped, but the
--      idempotency_key UNIQUE index is global, so a key owned by another branch
--      made the conflict invisible (v_existing NULL → the `<>` guard is NULL →
--      skipped) and the RPC returned idempotent_replay=true with NO payment recorded.
--      Now: if the ON CONFLICT backstop fires but no visible row is found, raise
--      IDEMPOTENCY_KEY_CONFLICT (the colliding row is in another branch or an
--      uncommitted concurrent txn — never report success).
--   P2 — Scope both replay SELECTs to kind='CHARGE' so a charge can never "replay"
--      a future REFUND row (Story 1-10). Zero behavior change today.
--   P3 — Strict idempotency: a key replayed with a different amount/method is a
--      stale-key reuse (a real new payment would be silently dropped) — raise
--      IDEMPOTENCY_KEY_MISMATCH instead of a false success.
--
-- Return contract (documented): on replay, `change_minor` is THAT charge's original
-- change; `balance_minor` is the order's CURRENT balance. They describe different
-- facts and are both correct.

create or replace function pos.pos_take_payment(
    p_order_id        uuid,
    p_method          text,
    p_amount_minor    bigint,
    p_tendered_minor  bigint default null,
    p_idempotency_key text   default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = pos, catalog, app, public
  as $$
declare
  v_branch   uuid := app.current_branch_id();
  v_user     uuid := app.current_user_id();
  v_order    pos.orders;
  v_existing pos.payment_transactions;
  v_inserted uuid;
  v_paid     bigint;
  v_balance  bigint;
  v_change   bigint;
  v_new      text;
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;
  if v_user   is null then raise exception 'NO_USER_CONTEXT';   end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = ''
     then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_method not in ('CASH','CARD','QR')      then raise exception 'INVALID_METHOD'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  select * into v_order from pos.orders
    where id = p_order_id and branch_id = v_branch
    for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  -- Replay fast-path: a prior CHARGE under this key returns the original effect,
  -- no writes, before any balance/state validation.
  select * into v_existing from pos.payment_transactions
    where idempotency_key = p_idempotency_key and kind = 'CHARGE';   -- P2
  if found then
    if v_existing.order_id <> v_order.id then raise exception 'IDEMPOTENCY_KEY_CONFLICT'; end if;
    if v_existing.method <> p_method or v_existing.amount_minor <> p_amount_minor       -- P3
       then raise exception 'IDEMPOTENCY_KEY_MISMATCH'; end if;
    select coalesce(sum(case when kind = 'CHARGE' then amount_minor else -amount_minor end), 0)
      into v_paid from pos.payment_transactions where order_id = v_order.id;
    return jsonb_build_object(
      'order',            to_jsonb(v_order),
      'change_minor',     v_existing.change_minor,
      'balance_minor',    v_order.total_minor - v_paid,
      'idempotent_replay', true);
  end if;

  -- Normal path: balance derived from the ledger.
  select coalesce(sum(case when kind = 'CHARGE' then amount_minor else -amount_minor end), 0)
    into v_paid from pos.payment_transactions where order_id = v_order.id;
  v_balance := v_order.total_minor - v_paid;

  if v_balance <= 0           then raise exception 'ALREADY_PAID';            end if;
  if p_amount_minor > v_balance then raise exception 'AMOUNT_EXCEEDS_BALANCE'; end if;

  if p_method = 'CASH' then
    if p_tendered_minor is null or p_tendered_minor < p_amount_minor
       then raise exception 'INSUFFICIENT_TENDER'; end if;
    v_change := p_tendered_minor - p_amount_minor;
  else
    if p_tendered_minor is not null then raise exception 'TENDER_ON_NON_CASH'; end if;
    v_change := null;
  end if;

  insert into pos.payment_transactions
    (order_id, branch_id, kind, method, amount_minor, tendered_minor, change_minor,
     idempotency_key, actor)
  values
    (v_order.id, v_branch, 'CHARGE', p_method, p_amount_minor,
     case when p_method = 'CASH' then p_tendered_minor else null end,
     v_change, p_idempotency_key, v_user)
  on conflict (idempotency_key) do nothing
  returning id into v_inserted;

  -- Concurrency backstop: a same-key insert won the unique slot between our SELECT
  -- and INSERT. Resolve to the replay (or typed conflict) — never a duplicate or a
  -- false success.
  if v_inserted is null then
    select * into v_existing from pos.payment_transactions
      where idempotency_key = p_idempotency_key and kind = 'CHARGE';   -- P2
    -- P1: the conflict is real (insert was skipped) but the colliding row isn't
    -- visible here → it belongs to another branch (RLS) or an uncommitted concurrent
    -- txn. Either way this caller must NOT report success.
    if not found then raise exception 'IDEMPOTENCY_KEY_CONFLICT'; end if;
    if v_existing.order_id <> v_order.id then raise exception 'IDEMPOTENCY_KEY_CONFLICT'; end if;
    if v_existing.method <> p_method or v_existing.amount_minor <> p_amount_minor       -- P3
       then raise exception 'IDEMPOTENCY_KEY_MISMATCH'; end if;
    select coalesce(sum(case when kind = 'CHARGE' then amount_minor else -amount_minor end), 0)
      into v_paid from pos.payment_transactions where order_id = v_order.id;
    return jsonb_build_object(
      'order',            to_jsonb(v_order),
      'change_minor',     v_existing.change_minor,
      'balance_minor',    v_order.total_minor - v_paid,
      'idempotent_replay', true);
  end if;

  -- New payment applied: recompute, guard, advance state.
  v_paid    := v_paid + p_amount_minor;
  v_balance := v_order.total_minor - v_paid;
  v_new     := case when v_balance = 0 then 'PAID' else 'PARTIALLY_PAID' end;

  perform pos.assert_financial_transition(v_order.financial_state, v_new);

  update pos.orders
    set financial_state = v_new, version = version + 1
    where id = v_order.id
    returning * into v_order;

  return jsonb_build_object(
    'order',            to_jsonb(v_order),
    'change_minor',     v_change,
    'balance_minor',    v_balance,
    'idempotent_replay', false);
end $$;
