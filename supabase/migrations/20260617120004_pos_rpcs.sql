-- Story 1-1 / breakdown S-08 + S-09 + S-10: order-creation RPCs.
-- All writes flow through these SECURITY DEFINER functions (one txn each).
-- branch_id is stamped from the JWT seam, never from a parameter.

-- ---------------------------------------------------------------------------
-- pos_create_order: insert a DRAFT/OPEN order attributed to the caller's branch.
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
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;
  if v_user  is null then raise exception 'NO_USER_CONTEXT';   end if;
  if p_order_type not in ('DINE_IN','TAKEAWAY') then raise exception 'INVALID_ORDER_TYPE'; end if;
  if p_order_type = 'DINE_IN'  and p_table_id is null then raise exception 'TABLE_REQUIRED'; end if;
  if p_order_type = 'TAKEAWAY' and (p_customer_name is null or btrim(p_customer_name) = '')
     then raise exception 'CUSTOMER_NAME_REQUIRED'; end if;

  insert into pos.orders (branch_id, order_type, table_id, customer_name, created_by)
    values (v_branch, p_order_type, p_table_id, nullif(btrim(p_customer_name),''), v_user)
    returning * into v_order;

  return to_jsonb(v_order);
end $$;

-- ---------------------------------------------------------------------------
-- pos_modify_lines: add/set_qty/remove lines on a DRAFT order, snapshotting
-- product price/name/recipe and modifier surcharge, then recompute totals.
-- p_ops = jsonb array, e.g.
--   [{"op":"add","product_id":"...","quantity":1,"modifier_ids":["..."]},
--    {"op":"set_qty","line_id":"...","quantity":2},
--    {"op":"remove","line_id":"..."}]
-- ---------------------------------------------------------------------------
create or replace function pos.pos_modify_lines(p_order_id uuid, p_ops jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = pos, catalog, app, public
  as $$
declare
  v_branch  uuid := app.current_branch_id();
  v_order   pos.orders;
  v_op      jsonb;
  v_opname  text;
  v_product catalog.product;
  v_recipe  jsonb;
  v_line_id uuid;
  v_qty     int;
  v_mod     catalog.modifier;
  v_mod_id  uuid;
begin
  if v_branch is null then raise exception 'NO_BRANCH_CONTEXT'; end if;

  select * into v_order from pos.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;            -- RLS hides other branches
  if v_order.fulfillment_state <> 'DRAFT' then raise exception 'NOT_DRAFT'; end if;

  -- No-op call: return current state without bumping version or rewriting totals.
  if coalesce(jsonb_array_length(coalesce(p_ops, '[]'::jsonb)), 0) = 0 then
    return jsonb_build_object(
      'order', to_jsonb(v_order),
      'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.id)
                           from pos.order_lines l where l.order_id = v_order.id), '[]'::jsonb));
  end if;

  for v_op in select value from jsonb_array_elements(coalesce(p_ops, '[]'::jsonb))
  loop
    v_opname := v_op ->> 'op';

    if v_opname = 'add' then
      select * into v_product from catalog.product
        where id = (v_op ->> 'product_id')::uuid and active = true;
      if not found then raise exception 'PRODUCT_INACTIVE'; end if;

      v_qty := coalesce((v_op ->> 'quantity')::int, 1);
      if v_qty <= 0 then raise exception 'INVALID_QUANTITY'; end if;

      select coalesce(jsonb_agg(jsonb_build_object(
                'ingredientId', ri.ingredient_id,
                'quantityBase', ri.quantity_base,
                'unit',         ing.base_unit) order by ri.ingredient_id), '[]'::jsonb)
        into v_recipe
        from catalog.recipe_item ri
        join catalog.ingredient  ing on ing.id = ri.ingredient_id
        where ri.product_id = v_product.id;

      insert into pos.order_lines (order_id, branch_id, product_id, product_name_snapshot,
                                   unit_price_minor, quantity, recipe_snapshot, line_subtotal_minor)
        values (v_order.id, v_branch, v_product.id, v_product.name,
                v_product.selling_price_minor, v_qty, v_recipe, 0)
        returning id into v_line_id;

      for v_mod_id in
        select distinct t::uuid from jsonb_array_elements_text(coalesce(v_op -> 'modifier_ids', '[]'::jsonb)) t
      loop
        select * into v_mod from catalog.modifier where id = v_mod_id and active = true;
        if not found then raise exception 'MODIFIER_INACTIVE'; end if;
        if not exists (select 1 from catalog.product_modifier
                        where product_id = v_product.id and modifier_id = v_mod_id) then
          raise exception 'MODIFIER_NOT_OFFERED';
        end if;
        insert into pos.order_line_modifiers (order_line_id, branch_id, modifier_id,
                                              modifier_name_snapshot, surcharge_minor)
          values (v_line_id, v_branch, v_mod.id, v_mod.name, v_mod.surcharge_minor);
      end loop;

      update pos.order_lines l
        set line_subtotal_minor =
          (l.unit_price_minor + coalesce(
            (select sum(surcharge_minor) from pos.order_line_modifiers m where m.order_line_id = l.id), 0))
          * l.quantity
        where l.id = v_line_id;

    elsif v_opname = 'set_qty' then
      v_line_id := (v_op ->> 'line_id')::uuid;
      v_qty := (v_op ->> 'quantity')::int;
      if v_qty is null or v_qty <= 0 then raise exception 'INVALID_QUANTITY'; end if;
      update pos.order_lines l
        set quantity = v_qty,
            line_subtotal_minor =
              (l.unit_price_minor + coalesce(
                (select sum(surcharge_minor) from pos.order_line_modifiers m where m.order_line_id = l.id), 0))
              * v_qty
        where l.id = v_line_id and l.order_id = v_order.id;
      if not found then raise exception 'LINE_NOT_FOUND'; end if;

    elsif v_opname = 'remove' then
      delete from pos.order_lines
        where id = (v_op ->> 'line_id')::uuid and order_id = v_order.id;
      if not found then raise exception 'LINE_NOT_FOUND'; end if;

    else
      raise exception 'UNKNOWN_OP:%', v_opname;
    end if;
  end loop;

  update pos.orders o
    set subtotal_minor = coalesce((select sum(line_subtotal_minor) from pos.order_lines l
                                    where l.order_id = o.id and l.line_state = 'ACTIVE'), 0),
        total_minor    = coalesce((select sum(line_subtotal_minor) from pos.order_lines l
                                    where l.order_id = o.id and l.line_state = 'ACTIVE'), 0)
                         - o.discount_minor,
        version = o.version + 1
    where o.id = v_order.id
    returning * into v_order;

  return jsonb_build_object(
    'order', to_jsonb(v_order),
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.id)
                         from pos.order_lines l where l.order_id = v_order.id), '[]'::jsonb));
end $$;

-- Definer ownership + execute grants (the only write path for clients).
-- The new owner (pos_definer) needs CREATE on schema pos to receive ownership.
grant usage, create on schema pos to pos_definer;
grant usage on schema pos to authenticated;
alter function pos.pos_create_order(text, uuid, text) owner to pos_definer;
alter function pos.pos_modify_lines(uuid, jsonb)        owner to pos_definer;
grant execute on function pos.pos_create_order(text, uuid, text) to authenticated;
grant execute on function pos.pos_modify_lines(uuid, jsonb)        to authenticated;
