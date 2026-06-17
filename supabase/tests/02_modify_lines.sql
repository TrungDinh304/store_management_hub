-- Story 1-1 tests: pos_modify_lines — snapshot, totals, edits, guards, immutability.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(19);

-- Fixtures -----------------------------------------------------------------
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA');
insert into catalog.category (id, name) values ('c1111111-1111-1111-1111-111111111111','Drinks');
insert into catalog.product (id, category_id, name, selling_price_minor, active) values
  ('50000000-0000-0000-0000-000000000001','c1111111-1111-1111-1111-111111111111','Latte',40000,true),
  ('50000000-0000-0000-0000-000000000002','c1111111-1111-1111-1111-111111111111','Cake', 30000,true),
  ('50000000-0000-0000-0000-0000000000ff','c1111111-1111-1111-1111-111111111111','Retired',25000,false);
insert into catalog.modifier (id, name, surcharge_minor, active) values
  ('60000000-0000-0000-0000-000000000001','Oat Milk',5000,true),
  ('60000000-0000-0000-0000-0000000000ff','Discontinued',1000,false);
insert into catalog.product_modifier (product_id, modifier_id) values
  ('50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001'),
  ('50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-0000000000ff');
insert into catalog.ingredient (id, name, base_unit) values
  ('70000000-0000-0000-0000-000000000001','Beans','mg'),
  ('70000000-0000-0000-0000-000000000002','Milk','ml');
insert into catalog.recipe_item (product_id, ingredient_id, quantity_base) values
  ('50000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',18000),
  ('50000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000002',150);

set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';

create temp table _ord as
  select (pos.pos_create_order('TAKEAWAY', null, 'Mary') ->> 'id')::uuid as id;

-- Add Latte + Oat Milk (AC1)
select lives_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object(
         'op','add','product_id','50000000-0000-0000-0000-000000000001','quantity',1,
         'modifier_ids', jsonb_build_array('60000000-0000-0000-0000-000000000001')))) $$,
  'add Latte + Oat Milk');
select is((select total_minor from pos.orders where id=(select id from _ord)), 45000::bigint,
          'total = base 40000 + surcharge 5000');
select is((select count(*)::int from pos.order_lines where order_id=(select id from _ord) and line_state='ACTIVE'),
          1, 'one active line');
select is((select unit_price_minor from pos.order_lines
            where order_id=(select id from _ord) and product_id='50000000-0000-0000-0000-000000000001'),
          40000::bigint, 'unit price snapshotted');
select is((select line_subtotal_minor from pos.order_lines
            where order_id=(select id from _ord) and product_id='50000000-0000-0000-0000-000000000001'),
          45000::bigint, 'line subtotal = (price+surcharge)*qty');
select is((select m.surcharge_minor from pos.order_line_modifiers m
             join pos.order_lines l on l.id=m.order_line_id where l.order_id=(select id from _ord)),
          5000::bigint, 'modifier surcharge snapshotted');
select is((select jsonb_array_length(recipe_snapshot) from pos.order_lines
            where order_id=(select id from _ord) and product_id='50000000-0000-0000-0000-000000000001'),
          2, 'recipe snapshot has 2 ingredients');

-- Change quantity (AC2/AC4)
select lives_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object('op','set_qty',
         'line_id',(select id from pos.order_lines where order_id=(select id from _ord)
                     and product_id='50000000-0000-0000-0000-000000000001'),
         'quantity',2))) $$,
  'set quantity to 2');
select is((select total_minor from pos.orders where id=(select id from _ord)), 90000::bigint,
          'total recomputed for qty 2');

-- Add a second product then remove it (AC4)
select lives_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object('op','add',
         'product_id','50000000-0000-0000-0000-000000000002','quantity',1))) $$,
  'add Cake');
select is((select total_minor from pos.orders where id=(select id from _ord)), 120000::bigint,
          'total includes Cake');
select lives_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object('op','remove',
         'line_id',(select id from pos.order_lines where order_id=(select id from _ord)
                     and product_id='50000000-0000-0000-0000-000000000002')))) $$,
  'remove Cake');
select is((select total_minor from pos.orders where id=(select id from _ord)), 90000::bigint,
          'total recomputed after remove');

-- Snapshot immutability (AC5): later catalog edits must not change the order
update catalog.product  set selling_price_minor = 99999 where id='50000000-0000-0000-0000-000000000001';
update catalog.modifier set surcharge_minor     = 99999 where id='60000000-0000-0000-0000-000000000001';
select is((select unit_price_minor from pos.order_lines
            where order_id=(select id from _ord) and product_id='50000000-0000-0000-0000-000000000001'),
          40000::bigint, 'line price unchanged after catalog reprice');
select is((select total_minor from pos.orders where id=(select id from _ord)), 90000::bigint,
          'order total unchanged after catalog reprice');

-- Inactive product / modifier rejected (AC3)
select throws_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object('op','add',
         'product_id','50000000-0000-0000-0000-0000000000ff','quantity',1))) $$,
  'PRODUCT_INACTIVE', 'inactive product rejected');
select throws_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object('op','add',
         'product_id','50000000-0000-0000-0000-000000000001','quantity',1,
         'modifier_ids', jsonb_build_array('60000000-0000-0000-0000-0000000000ff')))) $$,
  'MODIFIER_INACTIVE', 'inactive modifier rejected');

-- Edit only while DRAFT (AC4)
update pos.orders set fulfillment_state='IN_PREP' where id=(select id from _ord);
select throws_ok(
  $$ select pos.pos_modify_lines((select id from _ord),
       jsonb_build_array(jsonb_build_object('op','add',
         'product_id','50000000-0000-0000-0000-000000000002','quantity',1))) $$,
  'NOT_DRAFT', 'cannot modify a non-DRAFT order');

-- No inventory consumption in this story (AC6) — consumption arrives at fire (later)
select is((select count(*)::int from information_schema.schemata where schema_name='inventory'),
          0, 'no inventory consumption introduced by order building');

select * from finish();
rollback;
