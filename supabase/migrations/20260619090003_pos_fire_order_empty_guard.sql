-- Story 1-3 code-review patch P1 (2026-06-21). Forward-only redefinition of
-- pos_fire_order (CREATE OR REPLACE preserves the pos_definer owner + execute grants).
--
-- Fix: the previous version short-circuited the re-fire (IN_PREP) path BEFORE the
-- EMPTY_ORDER check, so an IN_PREP order whose lines were later all voided (once the
-- Story 1-9 void RPC exists) could be re-fired as an empty ticket. Now BOTH the FSM
-- legality guard and the active-line check run before the fire/re-fire split:
--   * guard FIRST  -> READY/SERVED/CANCELLED rejected with INVALID_STATE (precedence
--     preserved; also exercises the guard's IN_PREP→IN_PREP edge for re-fire);
--   * EMPTY_ORDER  -> applies to fire AND re-fire;
--   * then split: IN_PREP -> idempotent re-fire (refresh fired_at, no version bump);
--                 DRAFT   -> fire (IN_PREP + fired_at + version+1).
-- Behavior is otherwise identical to 20260619090002.

create or replace function pos.pos_fire_order(p_order_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = pos, catalog, app, public
  as $$
declare
  v_branch uuid := app.current_branch_id();
  v_order  pos.orders;
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;

  -- Explicit branch scope (Story 1-2 P2) on top of FORCE RLS.
  select * into v_order from pos.orders
    where id = p_order_id and branch_id = v_branch
    for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  -- Legality first: only DRAFT (fire) and IN_PREP (re-fire) may reach/hold IN_PREP.
  -- Rejects READY/SERVED/CANCELLED with INVALID_STATE before anything else.
  perform pos.assert_fulfillment_transition(v_order.fulfillment_state, 'IN_PREP');

  -- An order with nothing to make cannot be (re-)fired (VOIDED/COMPED don't count).
  if not exists (select 1 from pos.order_lines
                 where order_id = v_order.id and line_state = 'ACTIVE') then
    raise exception 'EMPTY_ORDER';
  end if;

  -- Re-fire: already IN_PREP -> reproduce the ticket idempotently. No version bump,
  -- no second sale; only refresh fired_at so the board reads it as freshly fired.
  if v_order.fulfillment_state = 'IN_PREP' then
    update pos.orders set fired_at = now()
      where id = v_order.id
      returning * into v_order;
    return to_jsonb(v_order);
  end if;

  -- [S-14 / Story 1-7] inventory.SALE rows from recipe_snapshot × qty go HERE.
  -- Table occupancy is NOT touched (occupied at create, Story 1-2).

  update pos.orders
    set fulfillment_state = 'IN_PREP', fired_at = now(), version = version + 1
    where id = v_order.id
    returning * into v_order;

  return to_jsonb(v_order);
end $$;
