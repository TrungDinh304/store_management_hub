-- Story 1-1 / breakdown S-01: tenant-context seam, minimal identity tables, definer role.
-- Supabase-native: tenant identity is read from the Supabase Auth JWT via a single seam
-- (architecture.md §4.1). The §9 Spring migration swaps the body of these helpers only.
--
-- RECONCILIATION NOTE: database-design.md §3.1 places branch/user_account in the `auth`
-- schema, but Supabase reserves `auth` for GoTrue (DDL there is denied to migrations).
-- We therefore host app identity tables in the `app` schema. The seam reads the claims
-- GUC directly (`request.jwt.claims`) — identical to what `auth.jwt()` does internally —
-- so it needs no privileges on the reserved `auth` schema. §9 target may rename to `auth`.

create schema if not exists app;

-- ---------------------------------------------------------------------------
-- Tenant-context seam (the ONLY place coupled to how identity arrives)
-- ---------------------------------------------------------------------------
create or replace function app.current_claims() returns jsonb
  language sql stable
  as $$ select nullif(current_setting('request.jwt.claims', true), '')::jsonb $$;

create or replace function app.current_branch_id() returns uuid
  language sql stable
  as $$ select nullif(app.current_claims() ->> 'branch_id', '')::uuid $$;

create or replace function app.is_admin() returns boolean
  language sql stable
  as $$ select coalesce(app.current_claims() ->> 'role', '') = 'ADMIN' $$;

create or replace function app.current_user_id() returns uuid
  language sql stable
  as $$ select nullif(app.current_claims() ->> 'sub', '')::uuid $$;

-- ---------------------------------------------------------------------------
-- Minimal identity tables (subset of database-design.md §3.1 needed for 1-1)
-- ---------------------------------------------------------------------------
create table if not exists app.branch (
    id                  uuid primary key default gen_random_uuid(),
    name                text not null,
    business_day_cutoff time not null default '04:00',
    active              boolean not null default true,
    created_at          timestamptz not null default now()
);

create table if not exists app.user_account (
    id          uuid primary key default gen_random_uuid(),
    branch_id   uuid not null references app.branch(id),
    username    text not null,
    pin_hash    text not null,
    role        text not null check (role in ('ADMIN','MANAGER','BARISTA')),
    active      boolean not null default true,
    created_at  timestamptz not null default now(),
    constraint uq_user_username unique (username)
);

-- ---------------------------------------------------------------------------
-- Definer role: owns the SECURITY DEFINER POS RPCs. NON-superuser so it is
-- subject to RLS (defense in depth). `authenticated` keeps SELECT but has all
-- direct DML revoked in the RLS migration, so the only write path is an RPC.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pos_definer') then
    create role pos_definer nologin noinherit;
  end if;
end $$;

-- The migration role must be a member of pos_definer to transfer function
-- ownership to it (ALTER FUNCTION ... OWNER TO requires SET ROLE capability).
grant pos_definer to postgres;

grant usage on schema app to pos_definer, authenticated;
grant execute on function app.current_claims(), app.current_branch_id(),
  app.is_admin(), app.current_user_id() to pos_definer, authenticated;
grant select on app.branch, app.user_account to authenticated, pos_definer;

-- ---------------------------------------------------------------------------
-- Custom Access Token Hook: injects branch_id/role into the JWT at sign-in.
-- Registered with Auth via config.toml [auth.hook.custom_access_token].
-- (Not exercised by pgTAP; the seam above is what RLS/RPCs read.)
-- ---------------------------------------------------------------------------
create or replace function public.custom_access_token_hook(event jsonb)
  returns jsonb
  language plpgsql stable
  set search_path = app, public
  as $$
declare
  v_claims jsonb := event -> 'claims';
  v_user   app.user_account;
begin
  select * into v_user from app.user_account
   where id = (event ->> 'user_id')::uuid and active = true;
  if found then
    v_claims := jsonb_set(v_claims, '{branch_id}', to_jsonb(v_user.branch_id::text));
    v_claims := jsonb_set(v_claims, '{role}', to_jsonb(v_user.role));
  end if;
  return jsonb_set(event, '{claims}', v_claims);
end $$;

-- Lock the hook down: ONLY GoTrue (supabase_auth_admin) may run it. Without this,
-- the function is exposed as a PostgREST RPC any client could call to enumerate
-- another user's branch_id/role.
revoke execute on function public.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant  execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
grant  usage  on schema app to supabase_auth_admin;
grant  select on app.user_account to supabase_auth_admin;
