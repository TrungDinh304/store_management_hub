-- Story 1-2 / breakdown S-11: table-occupancy lifecycle (part 2).
-- Two SECURITY DEFINER RPCs (one txn each), owned by pos_definer:
--   pos_assign_table  - re-assign a DRAFT dine-in order's table (release old, occupy new)
--   pos_abandon_order - cancel a DRAFT order and release any held table (no revenue)
-- Both lock the order FOR UPDATE; RLS hides other branches' orders (-> ORDER_NOT_FOUND).

-- ---------------------------------------------------------------------------
-- pos_assign_table: change the table of a DRAFT dine-in order, atomically.
--   Release the previously held table (-> AVAILABLE), validate + occupy the new
--   one (must exist in the caller's branch and be AVAILABLE). No-op if unchanged.
--   Clearing to NULL is NOT supported: the dine-in invariant (ck_dinein_requires_
--   table) forbids a dine-in order without a table — release via pos_abandon_order.
--   Typed errors: NOT_DINE_IN, NOT_DRAFT, TABLE_REQUIRED, TABLE_NOT_FOUND, TABLE_OCCUPIED.
-- ---------------------------------------------------------------------------
create or replace function pos.pos_assign_table(p_order_id uuid, p_table_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = pos, catalog, app, public
  as $$
declare
  v_branch uuid := app.current_branch_id();
  v_order  pos.orders;
  v_table  catalog.table_seat;
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;
  if p_table_id is null then raise exception 'TABLE_REQUIRED'; end if;

  select * into v_order from pos.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;            -- RLS hides other branches
  if v_order.order_type <> 'DINE_IN'       then raise exception 'NOT_DINE_IN'; end if;
  if v_order.fulfillment_state <> 'DRAFT'  then raise exception 'NOT_DRAFT';   end if;

  -- No-op: re-assigning to the table it already holds.
  if v_order.table_id = p_table_id then
    return to_jsonb(v_order);
  end if;

  -- Validate + lock the target table within the caller's branch.
  select * into v_table from catalog.table_seat
    where id = p_table_id and branch_id = v_branch
    for update;
  if not found then raise exception 'TABLE_NOT_FOUND'; end if;
  if v_table.status <> 'AVAILABLE' then raise exception 'TABLE_OCCUPIED'; end if;

  -- Release the old table (if any), occupy the new one, move the order.
  if v_order.table_id is not null then
    update catalog.table_seat set status = 'AVAILABLE'
      where id = v_order.table_id and branch_id = v_branch;
  end if;
  update catalog.table_seat set status = 'OCCUPIED' where id = p_table_id;

  update pos.orders set table_id = p_table_id, version = version + 1
    where id = v_order.id
    returning * into v_order;

  return to_jsonb(v_order);
end $$;

-- ---------------------------------------------------------------------------
-- pos_abandon_order: cancel a DRAFT order and free its table.
--   DRAFT-only (else INVALID_STATE). Sets fulfillment CANCELLED, releases any
--   held table (-> AVAILABLE). Records NO revenue and NO inventory consumption:
--   a DRAFT has never been fired, so there is nothing to reverse.
-- ---------------------------------------------------------------------------
create or replace function pos.pos_abandon_order(p_order_id uuid)
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

  select * into v_order from pos.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;            -- RLS hides other branches
  if v_order.fulfillment_state <> 'DRAFT' then raise exception 'INVALID_STATE'; end if;

  -- Release any held table back to the pool.
  if v_order.table_id is not null then
    update catalog.table_seat set status = 'AVAILABLE'
      where id = v_order.table_id and branch_id = v_branch;
  end if;

  update pos.orders
    set fulfillment_state = 'CANCELLED', version = version + 1
    where id = v_order.id
    returning * into v_order;

  return to_jsonb(v_order);
end $$;

-- Definer ownership + execute grants (the only write path for clients).
-- pos_definer already holds usage+create on schema pos and DML on pos.orders
-- (story 1-1) plus DML on catalog.table_seat (previous migration in this story).
alter function pos.pos_assign_table(uuid, uuid) owner to pos_definer;
alter function pos.pos_abandon_order(uuid)      owner to pos_definer;
grant execute on function pos.pos_assign_table(uuid, uuid) to authenticated;
grant execute on function pos.pos_abandon_order(uuid)      to authenticated;
