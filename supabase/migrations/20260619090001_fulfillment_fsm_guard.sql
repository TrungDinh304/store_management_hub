-- Story 1-3 / breakdown S-12: centralized fulfillment-state transition guard.
-- The SINGLE source of truth for fulfillment edge legality (architecture §3.1/§3.5).
-- Every fulfillment-mutating RPC calls this so the matrix lives in exactly one place;
-- later stories reuse it unchanged (1-6 READY/SERVED, 1-8 close).
--
-- Legal edges:  DRAFT→IN_PREP (fire), DRAFT→CANCELLED (abandon),
--               IN_PREP→READY, IN_PREP→IN_PREP (re-fire), READY→SERVED.
-- Everything else (backward moves, SERVED→*, CANCELLED→*, skips like DRAFT→READY)
-- raises INVALID_STATE. Pure logic, no table access -> SECURITY INVOKER + empty
-- search_path (avoids Supabase linter 0011 mutable-search_path).

create or replace function pos.assert_fulfillment_transition(p_from text, p_to text)
  returns void
  language plpgsql
  immutable
  set search_path = ''
  as $$
begin
  if (p_from, p_to) in (
       ('DRAFT','IN_PREP'),
       ('DRAFT','CANCELLED'),
       ('IN_PREP','READY'),
       ('IN_PREP','IN_PREP'),
       ('READY','SERVED')
     ) then
    return;
  end if;
  raise exception 'INVALID_STATE';
end $$;

-- Internal helper, not an API surface: only the definer RPCs need it.
revoke all     on function pos.assert_fulfillment_transition(text, text) from public;
grant  execute on function pos.assert_fulfillment_transition(text, text) to pos_definer;
