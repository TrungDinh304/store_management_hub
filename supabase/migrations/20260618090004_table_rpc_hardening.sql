-- Story 1-2 code-review patches (2026-06-21). Forward-only: redefines the three
-- occupancy RPCs via CREATE OR REPLACE (preserves pos_definer owner + execute grants).
--   P1 — Idempotent seat release: the table-release UPDATEs now require
--        status = 'OCCUPIED', so abandoning/reassigning can't clobber a future
--        DIRTY/RESERVED seat (Story 1-8 / Epic 2) back to AVAILABLE.
--   P2 — Defense-in-depth branch scoping: the order SELECT … FOR UPDATE in
--        pos_assign_table / pos_abandon_order now filters branch_id = v_branch
--        explicitly (isolation no longer rests solely on FORCE RLS; an admin's
--        cross-branch call becomes a clean ORDER_NOT_FOUND instead of a silent
--        no-op). The occupancy UPDATEs are branch-scoped for consistency too.
-- Behavior is otherwise identical to 20260618090001/02.

-- ---------------------------------------------------------------------------
-- pos_create_order — P2 only: branch-scope the occupancy UPDATE.
-- ---------------------------------------------------------------------------
create or replace function pos.pos_create_order(
    p_order_type    text,
    p_table_id      uuid default null,
    p_customer_name text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = pos, catalog, app, public
  as $$
declare
  v_branch uuid := app.current_branch_id();
  v_user   uuid := app.current_user_id();
  v_order  pos.orders;
  v_table  catalog.table_seat;
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;
  if v_user  is null then raise exception 'NO_USER_CONTEXT';   end if;
  if p_order_type not in ('DINE_IN','TAKEAWAY') then raise exception 'INVALID_ORDER_TYPE'; end if;

  if p_order_type = 'DINE_IN' then
    if p_table_id is null then raise exception 'TABLE_REQUIRED'; end if;
    select * into v_table from catalog.table_seat
      where id = p_table_id and branch_id = v_branch
      for update;
    if not found then raise exception 'TABLE_NOT_FOUND'; end if;
    if v_table.status <> 'AVAILABLE' then raise exception 'TABLE_OCCUPIED'; end if;
  end if;

  if p_order_type = 'TAKEAWAY' then
    if p_table_id is not null then raise exception 'TAKEAWAY_HAS_TABLE'; end if;
    if p_customer_name is null or btrim(p_customer_name) = ''
       then raise exception 'CUSTOMER_NAME_REQUIRED'; end if;
  end if;

  insert into pos.orders (branch_id, order_type, table_id, customer_name, created_by)
    values (v_branch, p_order_type, p_table_id, nullif(btrim(p_customer_name),''), v_user)
    returning * into v_order;

  if p_order_type = 'DINE_IN' then
    update catalog.table_seat set status = 'OCCUPIED'
      where id = p_table_id and branch_id = v_branch;          -- P2: branch-scoped
  end if;

  return to_jsonb(v_order);
end $$;

-- ---------------------------------------------------------------------------
-- pos_assign_table — P1 (idempotent release) + P2 (branch-scoped order lookup).
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

  select * into v_order from pos.orders
    where id = p_order_id and branch_id = v_branch              -- P2: explicit branch scope
    for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.order_type <> 'DINE_IN'       then raise exception 'NOT_DINE_IN'; end if;
  if v_order.fulfillment_state <> 'DRAFT'  then raise exception 'NOT_DRAFT';   end if;

  -- No-op: re-assigning to the table it already holds.
  if v_order.table_id = p_table_id then
    return to_jsonb(v_order);
  end if;

  select * into v_table from catalog.table_seat
    where id = p_table_id and branch_id = v_branch
    for update;
  if not found then raise exception 'TABLE_NOT_FOUND'; end if;
  if v_table.status <> 'AVAILABLE' then raise exception 'TABLE_OCCUPIED'; end if;

  -- Release the old table (only if actually OCCUPIED), occupy the new one.
  if v_order.table_id is not null then
    update catalog.table_seat set status = 'AVAILABLE'
      where id = v_order.table_id and branch_id = v_branch
        and status = 'OCCUPIED';                                -- P1: idempotent release
  end if;
  update catalog.table_seat set status = 'OCCUPIED'
    where id = p_table_id and branch_id = v_branch;             -- P2: branch-scoped

  update pos.orders set table_id = p_table_id, version = version + 1
    where id = v_order.id
    returning * into v_order;

  return to_jsonb(v_order);
end $$;

-- ---------------------------------------------------------------------------
-- pos_abandon_order — P1 (idempotent release) + P2 (branch-scoped order lookup).
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

  select * into v_order from pos.orders
    where id = p_order_id and branch_id = v_branch              -- P2: explicit branch scope
    for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.fulfillment_state <> 'DRAFT' then raise exception 'INVALID_STATE'; end if;

  if v_order.table_id is not null then
    update catalog.table_seat set status = 'AVAILABLE'
      where id = v_order.table_id and branch_id = v_branch
        and status = 'OCCUPIED';                                -- P1: idempotent release
  end if;

  update pos.orders
    set fulfillment_state = 'CANCELLED', version = version + 1
    where id = v_order.id
    returning * into v_order;

  return to_jsonb(v_order);
end $$;
