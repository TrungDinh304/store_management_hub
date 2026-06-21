-- Story 1-5 / breakdown S-05 + S-17: graceful idempotency for pos_take_payment.
-- Forward-only CREATE OR REPLACE (preserves the pos_definer owner + execute grant
-- from 1-4). Split already works via the ledger sum; this adds duplicate-safe replay.
--
-- The critical rule (1-4 review deferral): a replay must short-circuit BEFORE the
-- balance/ALREADY_PAID checks and BEFORE the version bump + FSM re-assert — otherwise
-- a replay of a now-PAID order would raise ALREADY_PAID or fail the PAID->PAID guard.
-- Two layers: a replay fast-path SELECT (common sequential retry) + an ON CONFLICT
-- backstop (true concurrent same-key race). Cross-order key reuse -> typed error.

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

  -- Replay fast-path: a key already used returns the original effect, no writes,
  -- BEFORE any balance/state validation. Cross-order reuse is a typed error.
  select * into v_existing from pos.payment_transactions
    where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.order_id <> v_order.id then raise exception 'IDEMPOTENCY_KEY_CONFLICT'; end if;
    select coalesce(sum(case when kind = 'CHARGE' then amount_minor else -amount_minor end), 0)
      into v_paid from pos.payment_transactions where order_id = v_order.id;
    return jsonb_build_object(
      'order',            to_jsonb(v_order),
      'change_minor',     v_existing.change_minor,
      'balance_minor',    v_order.total_minor - v_paid,
      'idempotent_replay', true);
  end if;

  -- Normal path (unchanged from 1-4): balance derived from the ledger.
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
  -- and INSERT. Resolve to the replay (or typed conflict), never a duplicate row.
  if v_inserted is null then
    select * into v_existing from pos.payment_transactions
      where idempotency_key = p_idempotency_key;
    if v_existing.order_id <> v_order.id then raise exception 'IDEMPOTENCY_KEY_CONFLICT'; end if;
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
