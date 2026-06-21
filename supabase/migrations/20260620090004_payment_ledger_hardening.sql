-- Story 1-4 code-review patches (2026-06-21). Forward-only.
--   P1 — Extend the append-only guarantee to TRUNCATE. The row-level trigger from
--        20260620090001 covers UPDATE/DELETE only; TRUNCATE is statement-level and
--        was only revoked (the table owner could still truncate). A BEFORE TRUNCATE
--        statement trigger makes the "no mutation, even for the owner" claim true.
--   P2 — A recorded change cannot exist without a tender behind it. Closes a table
--        hole where a CASH row could carry change_minor with a NULL tendered_minor
--        (the RPC never does this, but the ledger should forbid it).

create trigger trg_payment_no_truncate
  before truncate on pos.payment_transactions
  for each statement execute function pos.forbid_mutation();

alter table pos.payment_transactions
  add constraint ck_change_requires_tender
  check (change_minor is null or tendered_minor is not null);
