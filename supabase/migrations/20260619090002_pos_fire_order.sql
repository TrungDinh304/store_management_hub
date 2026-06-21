-- Story 1-3 / breakdown S-13: fire / hold / re-fire.
-- pos_fire_order: DRAFT→IN_PREP fire (requires ≥1 ACTIVE line), idempotent re-fire
-- of an already-IN_PREP order, and ORDER_NOT_FOUND for anything outside the branch.
-- "Hold" needs no RPC — an order simply stays DRAFT until fired.
-- One txn, SECURITY DEFINER owned by pos_definer, SELECT … FOR UPDATE on the order.
--
-- SCOPE SEAMS (intentionally NOT done here):
--   * Inventory consumption (inventory.SALE rows) is Story 1-7 / S-14; it will
--     CREATE OR REPLACE this function to insert those rows in THIS same txn.
--   * Table occupancy is untouched — the table was occupied at CREATE (Story 1-2).
--   * Dedicated idempotency-key dedupe is Story 1-5 / S-05; double-fire safety here
--     rests on SELECT … FOR UPDATE + the FSM guard + version (architecture §5).

create function pos.pos_fire_order(p_order_id uuid)
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

  -- Explicit branch scope (Story 1-2 code-review P2) on top of FORCE RLS:
  -- a foreign-branch order is ORDER_NOT_FOUND, never a silent no-op.
  select * into v_order from pos.orders
    where id = p_order_id and branch_id = v_branch
    for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  -- Re-fire: an order already IN_PREP re-surfaces its ticket. Idempotent — no second
  -- sale, no version bump, no inventory re-consume (when 1-7 lands). Only fired_at is
  -- refreshed so the ticket reads as freshly fired on the board.
  if v_order.fulfillment_state = 'IN_PREP' then
    update pos.orders set fired_at = now()
      where id = v_order.id
      returning * into v_order;
    return to_jsonb(v_order);
  end if;

  -- Fire: guard permits only DRAFT→IN_PREP here (rejects READY/SERVED/CANCELLED).
  perform pos.assert_fulfillment_transition(v_order.fulfillment_state, 'IN_PREP');

  -- An order with nothing to make cannot be fired (VOIDED/COMPED lines don't count).
  if not exists (select 1 from pos.order_lines
                 where order_id = v_order.id and line_state = 'ACTIVE') then
    raise exception 'EMPTY_ORDER';
  end if;

  -- [S-14 / Story 1-7] inventory.SALE rows from recipe_snapshot × qty go HERE.

  update pos.orders
    set fulfillment_state = 'IN_PREP', fired_at = now(), version = version + 1
    where id = v_order.id
    returning * into v_order;

  return to_jsonb(v_order);
end $$;

alter function pos.pos_fire_order(uuid) owner to pos_definer;
grant execute on function pos.pos_fire_order(uuid) to authenticated;
