-- Story 1-1 / breakdown S-03: pos.orders, order_lines, order_line_modifiers.
-- Snapshot columns are authoritative; product_id/modifier_id are soft refs.
-- branch_id denormalized onto child tables (set by the RPC) for flat RLS predicates.

create schema if not exists pos;

create table if not exists pos.orders (
    id                uuid primary key default gen_random_uuid(),
    branch_id         uuid not null,                       -- logical ref auth.branch
    business_day      date,                                -- set at close (later story)
    order_type        text not null check (order_type in ('DINE_IN','TAKEAWAY')),
    table_id          uuid,                                -- logical ref catalog.table_seat
    customer_name     text,
    fulfillment_state text not null default 'DRAFT'
                      check (fulfillment_state in ('DRAFT','IN_PREP','READY','SERVED','CANCELLED')),
    financial_state   text not null default 'OPEN'
                      check (financial_state in
                        ('OPEN','PARTIALLY_PAID','PAID','CLOSED','PARTIALLY_REFUNDED','REFUNDED')),
    subtotal_minor    bigint not null default 0 check (subtotal_minor >= 0),
    discount_minor    bigint not null default 0 check (discount_minor >= 0),
    total_minor       bigint not null default 0 check (total_minor >= 0),
    version           int    not null default 0,
    created_by        uuid not null,
    created_at        timestamptz not null default now(),
    fired_at          timestamptz,
    closed_at         timestamptz,
    constraint ck_dinein_requires_table check (order_type <> 'DINE_IN' or table_id is not null)
);
create index if not exists ix_orders_branch_day on pos.orders (branch_id, business_day);
create index if not exists ix_orders_active_tickets on pos.orders (branch_id, fulfillment_state)
    where fulfillment_state in ('IN_PREP','READY');
create unique index if not exists uq_table_active_order on pos.orders (table_id)
    where table_id is not null and fulfillment_state not in ('SERVED','CANCELLED');

create table if not exists pos.order_lines (
    id                    uuid primary key default gen_random_uuid(),
    order_id              uuid not null references pos.orders(id) on delete cascade,
    branch_id             uuid not null,                   -- denormalized for RLS
    product_id            uuid not null,                   -- soft ref
    product_name_snapshot text   not null,
    unit_price_minor      bigint not null check (unit_price_minor >= 0),
    quantity              int    not null check (quantity > 0),
    recipe_snapshot       jsonb  not null,                 -- [{ingredientId,quantityBase,unit}]
    line_state            text   not null default 'ACTIVE'
                          check (line_state in ('ACTIVE','VOIDED','COMPED')),
    line_subtotal_minor   bigint not null check (line_subtotal_minor >= 0)
);
create index if not exists ix_lines_order on pos.order_lines (order_id);
create index if not exists ix_lines_branch on pos.order_lines (branch_id);

create table if not exists pos.order_line_modifiers (
    id                     uuid primary key default gen_random_uuid(),
    order_line_id          uuid not null references pos.order_lines(id) on delete cascade,
    branch_id              uuid not null,                  -- denormalized for RLS
    modifier_id            uuid not null,                  -- soft ref
    modifier_name_snapshot text   not null,
    surcharge_minor        bigint not null check (surcharge_minor >= 0),
    constraint uq_line_modifier unique (order_line_id, modifier_id)
);
create index if not exists ix_linemods_line on pos.order_line_modifiers (order_line_id);
create index if not exists ix_linemods_branch on pos.order_line_modifiers (branch_id);
