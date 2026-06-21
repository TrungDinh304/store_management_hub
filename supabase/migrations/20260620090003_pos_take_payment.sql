-- Story 1-4 / breakdown S-16: take a cash/card/QR payment against an order.
-- One txn, SECURITY DEFINER owned by pos_definer, SELECT … FOR UPDATE on the order.
-- Balance is derived from the ledger (Σ CHARGE − Σ REFUND), never from the cached
-- total. Cash change is computed server-side (the client value is never trusted).
--
-- SCOPE SEAMS (intentionally NOT done here):
--   * Drawer linkage (cash ⇒ OPEN drawer_session) is Story 1-12 / S-24 — drawer_session_id
--     stays NULL and the drawer guard is deferred (drawer_sessions doesn't exist yet).
--   * Graceful idempotency replay (ON CONFLICT … DO NOTHING RETURNING the original) is
--     Story 1-5 / S-05. Here the key is required and UNIQUE; a duplicate hard-fails (23505).
--   * Split / multi-method until zero works naturally via the ledger sum; formally 1-5.

create function pos.pos_take_payment(
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
  v_branch  uuid := app.current_branch_id();
  v_user    uuid := app.current_user_id();
  v_order   pos.orders;
  v_paid    bigint;
  v_balance bigint;
  v_change  bigint;
  v_new     text;
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;
  if v_user   is null then raise exception 'NO_USER_CONTEXT';   end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = ''
     then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_method not in ('CASH','CARD','QR')      then raise exception 'INVALID_METHOD'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  -- Explicit branch scope (Story 1-2 P2) on top of FORCE RLS.
  select * into v_order from pos.orders
    where id = p_order_id and branch_id = v_branch
    for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  -- Balance owed, derived from the ledger (never the cached total_minor for "paid").
  select coalesce(sum(case when kind = 'CHARGE' then amount_minor else -amount_minor end), 0)
    into v_paid
    from pos.payment_transactions
    where order_id = v_order.id;
  v_balance := v_order.total_minor - v_paid;

  if v_balance <= 0           then raise exception 'ALREADY_PAID';            end if;
  if p_amount_minor > v_balance then raise exception 'AMOUNT_EXCEEDS_BALANCE'; end if;

  -- Cash computes change server-side; non-cash carries no tender.
  if p_method = 'CASH' then
    if p_tendered_minor is null or p_tendered_minor < p_amount_minor
       then raise exception 'INSUFFICIENT_TENDER'; end if;
    v_change := p_tendered_minor - p_amount_minor;
  else
    if p_tendered_minor is not null then raise exception 'TENDER_ON_NON_CASH'; end if;
    v_change := null;
  end if;

  -- Append the CHARGE (append-only ledger). drawer_session_id NULL until Story 1-12.
  -- Duplicate idempotency_key hard-fails on uq_payment_idem; graceful replay is Story 1-5.
  insert into pos.payment_transactions
    (order_id, branch_id, kind, method, amount_minor, tendered_minor, change_minor,
     idempotency_key, actor)
  values
    (v_order.id, v_branch, 'CHARGE', p_method, p_amount_minor,
     case when p_method = 'CASH' then p_tendered_minor else null end,
     v_change, p_idempotency_key, v_user);

  -- Recompute paid + decide the new financial state, then guard the edge.
  v_paid    := v_paid + p_amount_minor;
  v_balance := v_order.total_minor - v_paid;
  v_new     := case when v_balance = 0 then 'PAID' else 'PARTIALLY_PAID' end;

  perform pos.assert_financial_transition(v_order.financial_state, v_new);

  update pos.orders
    set financial_state = v_new, version = version + 1
    where id = v_order.id
    returning * into v_order;

  return jsonb_build_object(
    'order',         to_jsonb(v_order),
    'change_minor',  v_change,
    'balance_minor', v_balance);
end $$;

alter function pos.pos_take_payment(uuid, text, bigint, bigint, text) owner to pos_definer;
grant execute on function pos.pos_take_payment(uuid, text, bigint, bigint, text) to authenticated;
