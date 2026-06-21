-- Story 1-2 / breakdown S-11: table_seat RLS + table-occupancy lifecycle (part 1).
-- table_seat is TENANT data (unlike the shared product catalog), so it gets
-- branch-scoped RLS here. Occupancy (AVAILABLE<->OCCUPIED) is driven only by the
-- POS RPCs; pos_create_order is redefined below to validate + occupy the table in
-- the SAME transaction as the order insert. (pos_assign_table / pos_abandon_order
-- live in the next migration.)

-- ---- privileges ----------------------------------------------------------
-- `authenticated` keeps SELECT (granted in the catalog migration) but gets no
-- direct DML; the only write path is a definer RPC running as pos_definer.
revoke insert, update, delete on catalog.table_seat from authenticated;
grant  select, insert, update, delete on catalog.table_seat to pos_definer;

-- ---- enable + force RLS --------------------------------------------------
-- FORCE so pos_definer (a non-superuser, ≠ table owner) is ALSO subject to the
-- policies — branch isolation holds even on the RPC write path.
alter table catalog.table_seat enable row level security;
alter table catalog.table_seat force  row level security;

create policy table_seat_sel on catalog.table_seat for select
  using (app.is_admin() or branch_id = app.current_branch_id());
create policy table_seat_ins on catalog.table_seat for insert
  with check (branch_id = app.current_branch_id());
create policy table_seat_upd on catalog.table_seat for update
  using (branch_id = app.current_branch_id())
  with check (branch_id = app.current_branch_id());
create policy table_seat_del on catalog.table_seat for delete
  using (branch_id = app.current_branch_id());

-- ---------------------------------------------------------------------------
-- Redefine pos_create_order (S-08): add table branch-validation, availability
-- check, occupancy, and the TAKEAWAY-holds-no-table rejection. CREATE OR REPLACE
-- preserves the existing owner (pos_definer) and EXECUTE grants from story 1-1.
--   New typed errors: TABLE_NOT_FOUND, TABLE_OCCUPIED, TAKEAWAY_HAS_TABLE.
-- Preserves 1-1 behavior: branch/user stamping, DRAFT/OPEN, TABLE_REQUIRED,
-- CUSTOMER_NAME_REQUIRED, INVALID_ORDER_TYPE, returned to_jsonb(order) shape.
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
    -- Table must exist within the caller's branch. RLS also scopes this read,
    -- so a foreign-branch table simply isn't visible -> TABLE_NOT_FOUND.
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
    update catalog.table_seat set status = 'OCCUPIED' where id = p_table_id;
  end if;

  return to_jsonb(v_order);
end $$;
