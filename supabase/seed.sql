-- Local dev seed (Story 1-1). Idempotent; uses demo UUIDs distinct from the
-- pgTAP test fixtures (tests run in rolled-back transactions with their own ids).
-- Named fixture from the story: Latte 40,000 + Oat Milk +5,000 + recipe 18g beans / 150ml milk.

insert into app.branch (id, name) values
  ('dddddddd-0000-0000-0000-000000000001','Demo Branch')
  on conflict (id) do nothing;

insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('dddddddd-0000-0000-0000-000000000010','dddddddd-0000-0000-0000-000000000001','demo_barista','x','BARISTA')
  on conflict (id) do nothing;

insert into catalog.category (id, name) values
  ('dddddddd-0000-0000-0000-000000000100','Drinks')
  on conflict (id) do nothing;

insert into catalog.product (id, category_id, name, selling_price_minor, active) values
  ('dddddddd-0000-0000-0000-000000000200','dddddddd-0000-0000-0000-000000000100','Latte',40000,true)
  on conflict (id) do nothing;

insert into catalog.modifier (id, name, surcharge_minor, active) values
  ('dddddddd-0000-0000-0000-000000000300','Oat Milk',5000,true)
  on conflict (id) do nothing;

insert into catalog.product_modifier (product_id, modifier_id) values
  ('dddddddd-0000-0000-0000-000000000200','dddddddd-0000-0000-0000-000000000300')
  on conflict do nothing;

insert into catalog.ingredient (id, name, base_unit) values
  ('dddddddd-0000-0000-0000-000000000400','Beans','mg'),
  ('dddddddd-0000-0000-0000-000000000401','Milk','ml')
  on conflict (id) do nothing;

insert into catalog.recipe_item (product_id, ingredient_id, quantity_base) values
  ('dddddddd-0000-0000-0000-000000000200','dddddddd-0000-0000-0000-000000000400',18000),
  ('dddddddd-0000-0000-0000-000000000200','dddddddd-0000-0000-0000-000000000401',150)
  on conflict do nothing;
