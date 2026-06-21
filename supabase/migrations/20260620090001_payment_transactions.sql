-- Story 1-4 / breakdown S-04 (partial): the append-only payment ledger.
-- Only pos.payment_transactions is created here; drawer/adjustment/audit tables
-- come with their own stories (1-12 / 1-11 / 1-9..1-11). Money is BIGINT minor units.
--
-- Append-only: a payment row is immutable — corrections are NEW reversing rows
-- (a REFUND, Story 1-10), never an UPDATE. Enforced by a BEFORE UPDATE/DELETE
-- trigger that fires for EVERY role (incl. the table owner and pos_definer) plus
-- revoked UPDATE/DELETE/TRUNCATE privileges.

-- ---------------------------------------------------------------------------
-- Reusable append-only backstop (also used by the other ledgers in later stories).
-- ---------------------------------------------------------------------------
create or replace function pos.forbid_mutation()
  returns trigger
  language plpgsql
  set search_path = ''
  as $$
begin
  raise exception 'APPEND_ONLY'
    using detail = format('table %I.%I is append-only', tg_table_schema, tg_table_name);
end $$;

-- ---------------------------------------------------------------------------
-- pos.payment_transactions (architecture §2 data model)
-- ---------------------------------------------------------------------------
create table if not exists pos.payment_transactions (
    id                uuid primary key default gen_random_uuid(),
    order_id          uuid   not null references pos.orders(id),
    branch_id         uuid   not null,                       -- denormalized for RLS
    drawer_session_id uuid,                                  -- soft ref; cash linkage is Story 1-12
    kind              text   not null check (kind in ('CHARGE','REFUND')),
    method            text   not null check (method in ('CASH','CARD','QR')),
    amount_minor      bigint not null check (amount_minor > 0),
    tendered_minor    bigint,
    change_minor      bigint check (change_minor is null or change_minor >= 0),
    idempotency_key   text   not null,
    reason            text,
    actor             uuid   not null,
    created_at        timestamptz not null default now(),
    constraint uq_payment_idem unique (idempotency_key),
    -- tendered/change are meaningful only for CASH; non-cash carries neither
    constraint ck_tender_cash_only
      check (method = 'CASH' or (tendered_minor is null and change_minor is null)),
    -- when a cash tender is recorded, change must equal tendered - amount
    constraint ck_cash_change
      check (method <> 'CASH' or tendered_minor is null
             or change_minor = tendered_minor - amount_minor)
);
create index if not exists ix_payment_order  on pos.payment_transactions (order_id);
create index if not exists ix_payment_branch on pos.payment_transactions (branch_id, created_at);

create trigger trg_payment_no_mutation
  before update or delete on pos.payment_transactions
  for each row execute function pos.forbid_mutation();

-- ---- privileges: append-only, writes only via the definer RPC -------------
grant  select, insert on pos.payment_transactions to pos_definer;
grant  select         on pos.payment_transactions to authenticated;
revoke update, delete, truncate on pos.payment_transactions from pos_definer, authenticated;

-- ---- RLS: branch-scoped; admin cross-branch read -------------------------
alter table pos.payment_transactions enable row level security;
alter table pos.payment_transactions force  row level security;

create policy pt_sel on pos.payment_transactions for select
  using (app.is_admin() or branch_id = app.current_branch_id());
create policy pt_ins on pos.payment_transactions for insert
  with check (branch_id = app.current_branch_id());
-- No UPDATE/DELETE policies: the table is append-only.
