-- Story 1-1 / breakdown S-28 (partial): RLS on the POS order tables.
-- branch_id is the tenant key; fail-closed; admin may READ across branches but not write.
--
-- Write surface: `authenticated` has ALL direct DML revoked, so the only write path is an
-- RPC running as pos_definer. RLS is FORCEd, and because pos_definer is a non-superuser
-- (≠ table owner), it is subject to the policies — hence branch-scoped INSERT/UPDATE/DELETE
-- policies are present so the definer can write within its own branch (and only there).

-- ---- privileges ----------------------------------------------------------
revoke all on pos.orders, pos.order_lines, pos.order_line_modifiers from authenticated;
grant  select on pos.orders, pos.order_lines, pos.order_line_modifiers to authenticated;
grant  select, insert, update, delete
       on pos.orders, pos.order_lines, pos.order_line_modifiers to pos_definer;

-- ---- enable + force ------------------------------------------------------
alter table pos.orders               enable row level security;
alter table pos.orders               force  row level security;
alter table pos.order_lines          enable row level security;
alter table pos.order_lines          force  row level security;
alter table pos.order_line_modifiers enable row level security;
alter table pos.order_line_modifiers force  row level security;

-- ---- policies (template applied to each tenant table) --------------------
create policy orders_sel on pos.orders for select
  using (app.is_admin() or branch_id = app.current_branch_id());
create policy orders_ins on pos.orders for insert
  with check (branch_id = app.current_branch_id());
create policy orders_upd on pos.orders for update
  using (branch_id = app.current_branch_id())
  with check (branch_id = app.current_branch_id());
create policy orders_del on pos.orders for delete
  using (branch_id = app.current_branch_id());

create policy lines_sel on pos.order_lines for select
  using (app.is_admin() or branch_id = app.current_branch_id());
create policy lines_ins on pos.order_lines for insert
  with check (branch_id = app.current_branch_id());
create policy lines_upd on pos.order_lines for update
  using (branch_id = app.current_branch_id())
  with check (branch_id = app.current_branch_id());
create policy lines_del on pos.order_lines for delete
  using (branch_id = app.current_branch_id());

create policy linemods_sel on pos.order_line_modifiers for select
  using (app.is_admin() or branch_id = app.current_branch_id());
create policy linemods_ins on pos.order_line_modifiers for insert
  with check (branch_id = app.current_branch_id());
create policy linemods_upd on pos.order_line_modifiers for update
  using (branch_id = app.current_branch_id())
  with check (branch_id = app.current_branch_id());
create policy linemods_del on pos.order_line_modifiers for delete
  using (branch_id = app.current_branch_id());
