-- Story 1-1 / breakdown S-03 (catalog subset): products, modifiers, recipes, tables.
-- POS reads & snapshots from these; it never mutates them. Money = BIGINT minor units.

create schema if not exists catalog;

create table if not exists catalog.category (
    id     uuid primary key default gen_random_uuid(),
    name   text not null,
    active boolean not null default true
);

create table if not exists catalog.product (
    id                  uuid primary key default gen_random_uuid(),
    category_id         uuid not null references catalog.category(id),
    name                text not null,
    selling_price_minor bigint not null check (selling_price_minor >= 0),
    active              boolean not null default true,
    created_at          timestamptz not null default now()
);

create table if not exists catalog.modifier (
    id              uuid primary key default gen_random_uuid(),
    name            text not null,
    surcharge_minor bigint not null default 0 check (surcharge_minor >= 0),
    active          boolean not null default true
);

create table if not exists catalog.product_modifier (
    product_id  uuid not null references catalog.product(id) on delete cascade,
    modifier_id uuid not null references catalog.modifier(id) on delete cascade,
    primary key (product_id, modifier_id)
);

create table if not exists catalog.ingredient (
    id        uuid primary key default gen_random_uuid(),
    name      text not null,
    base_unit text not null,          -- 'mg','ml','unit'
    active    boolean not null default true
);

create table if not exists catalog.recipe_item (
    product_id    uuid not null references catalog.product(id) on delete cascade,
    ingredient_id uuid not null references catalog.ingredient(id),
    quantity_base bigint not null check (quantity_base > 0),
    primary key (product_id, ingredient_id)
);

create table if not exists catalog.table_seat (
    id           uuid primary key default gen_random_uuid(),
    branch_id    uuid not null references app.branch(id),
    table_number text not null,
    capacity     int  not null check (capacity > 0),
    status       text not null default 'AVAILABLE'
                 check (status in ('AVAILABLE','OCCUPIED','RESERVED','DIRTY')),
    constraint uq_table_number unique (branch_id, table_number)
);

-- Catalog is readable by signed-in users (PostgREST reads); no RLS (shared catalog).
grant usage on schema catalog to authenticated, pos_definer;
grant select on all tables in schema catalog to authenticated, pos_definer;
alter default privileges in schema catalog grant select on tables to authenticated, pos_definer;
