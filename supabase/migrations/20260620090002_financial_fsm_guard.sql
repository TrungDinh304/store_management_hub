-- Story 1-4 / breakdown S-15: centralized financial-state transition guard.
-- The money-side twin of pos.assert_fulfillment_transition (Story 1-3) and the
-- SINGLE source of truth for financial edge legality (architecture §3.2/§3.5).
-- Balance itself is derived from pos.payment_transactions inside each RPC; this
-- guard only validates that a (from -> to) state edge is legal.
--
-- Legal edges (complete matrix; 1-8 close and 1-10 refund reuse it):
--   OPEN→PARTIALLY_PAID, OPEN→PAID,
--   PARTIALLY_PAID→PARTIALLY_PAID (further partial), PARTIALLY_PAID→PAID,
--   PAID→CLOSED, PAID→PARTIALLY_REFUNDED, PAID→REFUNDED,
--   CLOSED→PARTIALLY_REFUNDED, CLOSED→REFUNDED,
--   PARTIALLY_REFUNDED→PARTIALLY_REFUNDED, PARTIALLY_REFUNDED→REFUNDED.
-- Story 1-4 exercises only the four payment edges; refund/close edges are
-- validated by their own stories (which MUST call this guard).

create or replace function pos.assert_financial_transition(p_from text, p_to text)
  returns void
  language plpgsql
  immutable
  set search_path = ''
  as $$
begin
  if (p_from, p_to) in (
       ('OPEN','PARTIALLY_PAID'),
       ('OPEN','PAID'),
       ('PARTIALLY_PAID','PARTIALLY_PAID'),
       ('PARTIALLY_PAID','PAID'),
       ('PAID','CLOSED'),
       ('PAID','PARTIALLY_REFUNDED'),
       ('PAID','REFUNDED'),
       ('CLOSED','PARTIALLY_REFUNDED'),
       ('CLOSED','REFUNDED'),
       ('PARTIALLY_REFUNDED','PARTIALLY_REFUNDED'),
       ('PARTIALLY_REFUNDED','REFUNDED')
     ) then
    return;
  end if;
  raise exception 'INVALID_STATE';
end $$;

revoke all     on function pos.assert_financial_transition(text, text) from public;
grant  execute on function pos.assert_financial_transition(text, text) to pos_definer;
