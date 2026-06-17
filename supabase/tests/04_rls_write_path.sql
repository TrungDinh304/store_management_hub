-- Story 1-1 tests (added in code review): exercise the production write path through
-- the `authenticated` role, verify modifier dedup + no-op guard, and prove the
-- cross-branch WITH CHECK rejection that the SELECT-only RLS test couldn't.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pos, catalog, app;

select plan(7);

-- Fixtures (as postgres)
insert into app.branch (id, name) values
  ('11111111-1111-1111-1111-111111111111','Branch A');
insert into app.user_account (id, branch_id, username, pin_hash, role) values
  ('a1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','baristaA','x','BARISTA');
insert into catalog.category (id, name) values ('c1111111-1111-1111-1111-111111111111','Drinks');
insert into catalog.product (id, category_id, name, selling_price_minor, active) values
  ('50000000-0000-0000-0000-000000000001','c1111111-1111-1111-1111-111111111111','Latte',40000,true);
insert into catalog.modifier (id, name, surcharge_minor, active) values
  ('60000000-0000-0000-0000-000000000001','Oat Milk',5000,true);
insert into catalog.product_modifier (product_id, modifier_id) values
  ('50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001');

-- ===== Production path: act as a real authenticated client (RLS-subject) =====
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';

select lives_ok(
  $$ select pos.pos_create_order('TAKEAWAY', null, 'Mary') $$,
  'authenticated client can create an order via the RPC (end-to-end definer path)');

-- Add Latte with a DUPLICATE modifier id -> must be charged once (dedup + unique guard)
select lives_ok(
  $$ select pos.pos_modify_lines((select id from pos.orders limit 1),
       jsonb_build_array(jsonb_build_object(
         'op','add','product_id','50000000-0000-0000-0000-000000000001','quantity',1,
         'modifier_ids', jsonb_build_array(
           '60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001')))) $$,
  'authenticated client can add a line via the RPC');
select is((select line_subtotal_minor from pos.order_lines limit 1), 45000::bigint,
          'duplicate modifier is charged once (no double-charge)');
select is((select count(*)::int from pos.order_line_modifiers), 1,
          'duplicate modifier produced exactly one modifier row');
select is((select total_minor from pos.orders limit 1), 45000::bigint,
          'order total reflects single surcharge');

-- No-op modify must not bump version
select pos.pos_modify_lines((select id from pos.orders limit 1), '[]'::jsonb);
select is((select version from pos.orders limit 1), 1,
          'empty p_ops is a no-op: version not bumped (0->1 from the add, stays 1)');

-- ===== Cross-branch WITH CHECK rejection =====
-- Asserted from the postgres context (so pgTAP is visible); the role switch to the
-- definer happens inside the DO block. pos_definer HAS INSERT privilege, so a 42501
-- here is specifically the RLS WITH CHECK rejecting a foreign-branch row.
reset role;
set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111","branch_id":"11111111-1111-1111-1111-111111111111","role":"BARISTA"}';
select lives_ok($outer$
  do $inner$
  begin
    set local role pos_definer;
    begin
      insert into pos.orders (branch_id, order_type, customer_name, created_by)
        values ('22222222-2222-2222-2222-222222222222','TAKEAWAY','x',
                'a1111111-1111-1111-1111-111111111111');
      reset role;
      raise exception 'WITH_CHECK_DID_NOT_BLOCK';   -- insert should NOT have succeeded
    exception
      when insufficient_privilege then reset role;   -- expected: RLS blocked it
    end;
  end
  $inner$;
$outer$, 'WITH CHECK blocks the definer from writing another branch row');
reset role;

select * from finish();
rollback;
