---
baseline_commit: 8112bba0e19f9c8253c362b4463929b89e5a08a0
---

# Story 1.1: Order Creation with Products and Modifiers

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **Barista**,
I want to **build an order from active products and their modifiers, with add/change/remove before firing**,
so that **I can capture exactly what the customer wants, with prices locked at the moment of sale**.

> **Scope note (read first).** This is the **first story in a greenfield repo**, so it bootstraps the minimal foundation needed for a runnable vertical slice: Supabase project init, the order-table migration, the auth/tenant seam, RLS on these tables, and the `pos_create_order` RPC (so there is an order to add lines to). It then delivers the story's real subject — **lines + modifiers + price snapshot + live totals** on a DRAFT order. **Out of scope:** payment, fire/inventory consumption, the polished Angular UI (S-29, blocked by the UX gap), and the payment/drawer/audit tables. This story is the **data + RPC vertical slice**, fully testable via pgTAP without UI.
>
> Maps to breakdown slices **S-09 + S-10** (subject) bootstrapped by **S-00, S-01, S-03, S-08, S-28 (partial)**. See [story-breakdown-epic-1.md](story-breakdown-epic-1.md).

## Acceptance Criteria

1. **Add product + modifier with snapshot.** Given an active product (e.g. "Latte" 40,000) with an active modifier (e.g. "Oat Milk" +5,000), when the barista adds it to a DRAFT order, then a line is created with `product_name_snapshot`, `unit_price_minor`, and `recipe_snapshot` copied from catalog, the modifier's `surcharge_minor` snapshotted, and the line subtotal = (unit price + Σ surcharges) × quantity. *(UC-01 main flow; Gherkin "Create a dine-in order with modifiers")*
2. **Live totals.** Order `subtotal_minor` = Σ of ACTIVE line subtotals; `discount_minor` = 0 (no discounts in this story); `total_minor` = subtotal − discount. Totals recompute on every add/change/remove. *(epics 1-1 AC1)*
3. **Inactive product rejected.** Adding a product whose `catalog.product.active = false` (or a modifier with `active = false`) raises a typed error and creates no line. *(UC-01 E1; Gherkin)*
4. **Edit only while DRAFT.** Add/change/remove and quantity changes are allowed only when `fulfillment_state = 'DRAFT'`; any modify attempt on a non-DRAFT order raises a typed error. Removing a line recomputes totals. *(epics 1-1 AC3; Gherkin "Edit an order before it is fired")*
5. **Snapshot immutability.** After a line exists, changing the catalog product price, name, modifier surcharge, or recipe **does not** alter the existing line's snapshot, its subtotal, or the order total. *(database-design §5; locked decision)*
6. **No inventory consumed.** Building/editing a DRAFT order writes **zero** `inventory.inventory_transactions` rows (consumption happens only at fire, a later story). *(Gherkin "no inventory has been consumed yet")*
7. **Branch isolation (RLS).** The order and its children are stamped with `branch_id` from the caller's JWT (never a parameter); a caller in branch A cannot read/modify an order in branch B (returns nothing / typed error). *(US-20; architecture §4)*

## Tasks / Subtasks

- [x] **Task 1 — Project & migration foundation** (AC: 1,2,3,4,5,6,7) — *bootstrap, breakdown S-00/S-03*
  - [x] `supabase init`; link project; establish `supabase/migrations/` + local `supabase db reset` flow; CI runs `supabase db push`.
  - [x] Migration `<ts>_catalog.sql`: `catalog.category`, `catalog.product`, `catalog.modifier`, `catalog.product_modifier`, `catalog.ingredient`, `catalog.recipe_item`, `catalog.table_seat` per [database-design.md §3.2](../planning-artifacts/database-design.md). Seed a small fixture (Latte 40,000 + Oat Milk +5,000 + recipe 18g beans/150ml milk) for tests.
  - [x] Migration `<ts>_pos_orders.sql`: `pos.orders`, `pos.order_lines`, `pos.order_line_modifiers` per [database-design.md §3.4](../planning-artifacts/database-design.md) — all CHECKs (`ck_dinein_requires_table`, money ≥ 0, qty > 0, enum checks), `version int`, indexes `(branch_id,business_day)` + partial active-state + `uq_table_active_order`, `recipe_snapshot jsonb`, **denormalized `branch_id` on both child tables**.
  - [x] Verify `supabase db reset` applies clean; a `DINE_IN` insert without `table_id` is rejected by CHECK.
- [x] **Task 2 — Auth & tenant seam (minimal)** (AC: 7) — *breakdown S-01*
  - [x] `auth.branch`, `auth.user_account` tables (subset needed: branch + user with `branch_id`, `role`) per [database-design.md §3.1](../planning-artifacts/database-design.md).
  - [x] `app.current_branch_id()` and `app.is_admin()` reading `auth.jwt()` (the single coupling seam; see [architecture.md §4.1](../planning-artifacts/architecture.md)).
  - [x] Custom Access Token Hook injecting `branch_id`/`role` into the JWT.
  - [x] DB roles: `authenticated` (RLS-subject; **REVOKE INSERT/UPDATE/DELETE** on `pos.*`; EXECUTE on the two RPCs); `pos_definer` (owns the SECURITY DEFINER RPCs, INSERT/SELECT on `pos.*`).
  - [x] Boot/integration assertion: `authenticated` cannot directly `INSERT` into `pos.orders`.
- [x] **Task 3 — `pos_create_order` RPC** (AC: 4,7) — *breakdown S-08*
  - [x] `pos_create_order(p_order_type text, p_table_id uuid default null, p_customer_name text default null)` SECURITY DEFINER: validate (DINE_IN⇒table, TAKEAWAY⇒name); insert order `(DRAFT, OPEN)`; **stamp `branch_id` from `app.current_branch_id()`**; return the order row as JSON.
  - [x] Reject DINE_IN without table / TAKEAWAY without name with typed errors.
- [x] **Task 4 — `pos_modify_lines` RPC (snapshot + totals + modifiers)** (AC: 1,2,3,4,5,6) — *breakdown S-09 + S-10*
  - [x] `pos_modify_lines(p_order_id uuid, p_ops jsonb)` SECURITY DEFINER, one transaction, `SELECT … FOR UPDATE` on the order.
  - [x] Guard: order must belong to caller branch and be `DRAFT` (else typed error).
  - [x] For add/change ops: read the **active** product + requested modifiers from `catalog`; reject if inactive (AC3). Snapshot `product_name_snapshot`, `unit_price_minor`, `recipe_snapshot` (jsonb `[{ingredientId,quantityBase,unit}]`), and per-modifier `modifier_name_snapshot` + `surcharge_minor`. Stamp child `branch_id`.
  - [x] Compute `line_subtotal_minor = (unit_price_minor + Σ surcharge_minor) × quantity`; recompute order `subtotal_minor`/`total_minor` (discount = 0).
  - [x] For remove ops: delete the line (DRAFT) and recompute totals.
  - [x] Return updated order + lines as JSON.
- [x] **Task 5 — RLS policies (these tables)** (AC: 7) — *breakdown S-28 (partial)*
  - [x] `ENABLE` + `FORCE` RLS on `pos.orders`, `pos.order_lines`, `pos.order_line_modifiers`.
  - [x] SELECT policy: `app.is_admin() OR branch_id = app.current_branch_id()`; `WITH CHECK (branch_id = app.current_branch_id())`. No direct INSERT/UPDATE/DELETE policy (writes only via RPC). Identity via `auth.jwt()` seam — **not** `SET LOCAL` (that is the §9 migration target; see [database-design.md §8.5 reconciliation note](story-breakdown-epic-1.md)).
- [x] **Task 6 — Tests (pgTAP)** (AC: all)
  - [x] Snapshot immutability: create line → update `catalog.product.selling_price_minor` and `modifier.surcharge_minor` → assert line snapshot + order total unchanged (AC5).
  - [x] Totals: add Latte+Oat → assert subtotal/total = 45,000; change qty to 2 → 90,000; remove → 0 (AC1,AC2,AC4).
  - [x] Inactive product/modifier → modify raises typed error, no line written (AC3).
  - [x] Non-DRAFT modify → typed error (AC4).
  - [x] No `inventory_transactions` rows written by any modify (AC6).
  - [x] RLS: branch-A JWT cannot SELECT a branch-B order; cross-branch `WITH CHECK` blocks write (AC7).
  - [x] Constraints: DINE_IN without table rejected; qty ≤ 0 rejected; negative money rejected.

> **Frontend (S-29) deferred:** the Angular order-entry + modifier-picker page is **not** in this story — it is blocked by the missing UX spec (readiness finding UX-1). Track it as a follow-on dev pass under epic story 1-1 once wireframes exist.

### Review Findings (code review 2026-06-17)

**Patch (unresolved, fix candidates):**
- [x] [Review][Patch] Duplicate `modifier_ids` double-charge — loop has no dedup and `order_line_modifiers` lacks a unique `(order_line_id, modifier_id)` constraint; `["X","X"]` adds the surcharge twice, inflating `line_subtotal_minor` [supabase/migrations/20260617120004_pos_rpcs.sql:95-107] (High)
- [x] [Review][Patch] Access-token hook is world-executable and unregistered — `public.custom_access_token_hook` defaults to PUBLIC EXECUTE (callable as a PostgREST RPC → enumerate any user's branch/role), `[auth.hook.custom_access_token]` is commented out in `config.toml` (claims never injected for real sign-ins), and it has no pinned `search_path` [supabase/migrations/20260617120001_app_auth_seam.sql:80] (Med-High)
- [x] [Review][Patch] `set_qty` null quantity bypasses the `<= 0` guard — no `coalesce`/null-check (unlike `add`); `NULL <= 0` is NULL→false, so it hits the NOT NULL CHECK with an opaque error instead of `INVALID_QUANTITY` [supabase/migrations/20260617120004_pos_rpcs.sql:117-119] (Med)
- [x] [Review][Patch] Test completeness — exercise the RPC through the `authenticated` role and assert a cross-branch `WITH CHECK` rejection; current tests prove definer-branch writes (SECURITY DEFINER runs as `pos_definer`, so RLS does apply) but never call the RPC as `authenticated` nor prove cross-branch write is blocked [supabase/tests/] (Med)
- [x] [Review][Patch] Empty/null `p_ops` still bumps `version` and rewrites totals — guard to a no-op when no ops are processed [supabase/migrations/20260617120004_pos_rpcs.sql:139] (Low)
- [x] [Review][Patch] `recipe_snapshot` `jsonb_agg` has no `ORDER BY` → nondeterministic snapshot ordering [supabase/migrations/20260617120004_pos_rpcs.sql:80-87] (Low)
- [x] [Review][Patch] `setup-env.js` lacks template/dir existence guard → ENOENT crash on partial clone [frontend/scripts/setup-env.js] (Low)
- [x] [Review][Patch] Story accuracy — Task 1 "seed a shared catalog fixture" is checked, but fixtures live inline per test; add `supabase/seed.sql` or correct the claim [this story] (Low)

**Deferred (real, belong to a later story / cross-cutting):**
- [x] [Review][Defer] `table_id` not validated to caller branch; TAKEAWAY can hold a table; `uq_table_active_order` is global not branch-scoped; raw `23505` instead of a `TABLE_OCCUPIED` domain error — belongs to Story 1-2 (table assignment + occupancy, S-11) [supabase/migrations/20260617120003_pos_orders.sql:32, 20260617120004:24-31]
- [x] [Review][Defer] `discount_minor` > subtotal → `23514` CHECK violation wedges the order — belongs to the comp/discount story (S-23); discount is always 0 here [supabase/migrations/20260617120004_pos_rpcs.sql:142-144]
- [x] [Review][Defer] No idempotency on create/modify (retry duplicates lines) — belongs to S-05 idempotency infrastructure
- [x] [Review][Defer] Opaque SQLSTATEs (22P02/22023/23502) for malformed input instead of named domain errors — cross-cutting input-validation hardening
- [x] [Review][Defer] Defense-in-depth: `is_admin()`/`created_by` trust JWT claims without validating against `app.user_account`; malformed claims JSON not fail-closed — auth hardening

## Dev Notes

### Architecture patterns & constraints (MUST follow)
- **Topology is Supabase-native (LOCKED).** No REST, no ORM. All POS **writes go through PL/pgSQL `SECURITY DEFINER` RPCs**; reads use `supabase-js` `.from().select()` under RLS. Edge Functions are not needed for this story. [architecture.md §5](../planning-artifacts/architecture.md), [story-breakdown-epic-1.md](story-breakdown-epic-1.md).
- **One RPC = one transaction.** `pos_modify_lines` does `SELECT … FOR UPDATE` on the order, all writes commit/rollback together. [architecture.md §5.2].
- **Money = `BIGINT` minor units, never float/numeric.** Column suffix `_minor`, `CHECK (… >= 0)`. [database-design.md §0].
- **Snapshot at sale time.** `product_name`, `unit_price`, `recipe` (jsonb), modifier name + surcharge are copied onto the line; `product_id`/`modifier_id` are soft references for analytics only — the **snapshot columns are authoritative**. Later catalog edits never mutate history. [database-design.md §5].
- **`branch_id` is stamped by the RPC from `auth.jwt()`**, never accepted from the client; denormalized onto child tables (set at insert, immutable). [architecture.md §8 / database-design.md §8.5].
- **Enums are `text + CHECK`** (not native PG enums). Order: `fulfillment_state DRAFT|IN_PREP|READY|SERVED|CANCELLED`, `financial_state OPEN|…`, `line_state ACTIVE|VOIDED|COMPED`, `order_type DINE_IN|TAKEAWAY`. [database-design.md §2].
- **Totals are a persisted cache** for list queries; financial transitions (later stories) always recompute from `payment_transactions` — but for this story, `subtotal/total` are computed from lines on each modify.

### Source tree components to touch
```
supabase/
  migrations/
    <ts>_auth_seam.sql        # branch/user subset, app.current_branch_id(), is_admin(), hook, roles
    <ts>_catalog.sql          # catalog tables + test seed fixture
    <ts>_pos_orders.sql       # pos.orders, order_lines, order_line_modifiers (+ indexes, CHECKs)
    <ts>_pos_rpcs.sql         # pos_create_order, pos_modify_lines
    <ts>_rls_policies.sql     # ENABLE+FORCE RLS + policies on the 3 pos tables
  tests/                      # pgTAP test files (one per AC cluster)
frontend/                     # NOT touched in this story (S-29 deferred — UX-blocked)
```
All migrations are **plain Postgres SQL** (Supabase CLI), portable to self-hosted PG.

### Testing standards
- **pgTAP** for all DB logic (schema constraints, RPC behavior, snapshot immutability, RLS). Run via `supabase db reset` + the pgTAP runner in CI.
- Each AC cluster gets explicit assertions (see Task 6). Property-style coverage for the totals math.
- Tests must prove the **negative** cases (inactive product, non-DRAFT edit, cross-branch) — these are the high-value guardrails.

### Project Structure Notes
- Greenfield: `frontend/` and `supabase/` directories exist (untracked scaffolding) but no migrations/code yet. This story creates the first real migrations under `supabase/migrations/`.
- **Variance flagged:** `database-design.md §8.5` expresses tenant context as `SET LOCAL app.current_branch` — that is the **§9 Spring migration target**, NOT this build. Supabase-native uses the `auth.jwt()` seam (architecture.md §4). The reconciliation note lives in [story-breakdown-epic-1.md](story-breakdown-epic-1.md) §28. **Follow architecture.md §4.**
- **Dependency inversion handled:** breakdown tags `pos_create_order` (S-08) under epic story 1-2, but story 1-1 (lines) needs an order to exist, so create-order is included here. Story 1-2 then adds type/table assignment + table-occupancy transitions on top.

### Resolved architecture decisions relevant later (not this story)
- M2-a blocked-attempt audit = Edge Fn wrapper two-call; M2-b comp-to-zero = reuse `COMP_DISCOUNT`; M2-c consume = in-transaction (§F2). [architecture.md Appendix → Resolved]. None affect story 1-1 (no grants/audit/fire here).

### References
- [Source: docs/planning-artifacts/epics.md#1-1 — Order creation with products and modifiers]
- [Source: docs/planning-artifacts/pos-order-management-use-cases.md#UC-01] and §3 Gherkin ("Create a dine-in order with modifiers", "Edit an order before it is fired")
- [Source: docs/planning-artifacts/architecture.md#5 — RPC vs Edge Function] , [#4 — RLS Strategy], [#2 — Domain Model / snapshot]
- [Source: docs/planning-artifacts/database-design.md#3 — Table Definitions], [#5 — Snapshot Strategy], [#8.5 — RLS]
- [Source: docs/implementation-artifacts/story-breakdown-epic-1.md — S-00/S-01/S-03/S-08/S-09/S-10/S-28]

### Latest tech notes (confirm exact versions at build)
- **Supabase CLI** (latest stable) for local dev + migrations; **PostgreSQL 15+** (Supabase managed); **pgTAP** for DB tests.
- **`supabase-js` v2** for reads (frontend, deferred); **Ionic + Angular** latest LTS (frontend, deferred).
- Ship the SPA with the **anon** key only; `service_role` lives in CI/secrets, never the browser.

## Dev Agent Record

### Agent Model Used

{{agent_model_name_version}}

### Debug Log References

- `supabase start` → applied all 5 migrations clean (after fixes below).
- `supabase test db` → **40/40 pgTAP assertions PASS** across 3 test files.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- **Implemented the full backend vertical slice for order creation with modifiers.** All 7 ACs verified by pgTAP (40 assertions): snapshot-at-sale, live totals, inactive-product/modifier rejection, DRAFT-only edits, snapshot immutability after catalog reprice, no inventory consumption, and branch RLS isolation.
- **Deviation 1 (auth schema):** database-design §3.1 places identity tables in the `auth` schema, but Supabase reserves `auth` for GoTrue (DDL denied to migrations). Identity tables (`branch`, `user_account`) live in the `app` schema instead; the tenant seam reads `request.jwt.claims` directly (identical to `auth.jwt()` internals) so it needs no `auth`-schema privileges. Documented inline in migration 1 and as a reconciliation note in the story.
- **Deviation 2 (RLS + definer):** architecture §4.2 implies "no INSERT policy". Because RLS is FORCEd and the RPC owner `pos_definer` is a non-superuser (≠ table owner), the definer is subject to RLS and therefore needs branch-scoped INSERT/UPDATE/DELETE policies. Direct client writes remain blocked via REVOKE of table DML from `authenticated` (proven by RLS test #5: direct INSERT → 42501). Net security property (no cross-branch, no direct client write) is preserved.
- **Migration fixes during build:** (a) `grant <role> to current_user` broke the Supabase CLI statement splitter → used explicit `postgres`; (b) ownership transfer required `pos_definer` to hold CREATE on schema `pos` → granted before `ALTER FUNCTION ... OWNER`.
- **Frontend:** wired the hosted Supabase URL + publishable (anon) key into `environment.ts`/`environment.prod.ts` (S-00 config). The `@supabase/supabase-js` client install + order-entry UI (S-29) remain deferred (new dependency + UX gap) per story scope.
- **AC6** is asserted as "no `inventory` schema exists yet" — consumption is introduced at fire in a later story; this proves order-building writes no consumption.

### Change Log

- 2026-06-17: Implemented Story 1-1 (order creation with products & modifiers) — 5 SQL migrations (app/auth seam, catalog, pos order tables, RPCs, RLS), 3 pgTAP test files (40 assertions, all passing), frontend Supabase env config. Status → review.
- 2026-06-17: Code review — applied 8 patch findings (modifier dedup + unique constraint, auth-hook lockdown + registration, set_qty null guard, no-op p_ops guard, deterministic recipe order, setup-env guard, seed.sql, +RLS write-path test); 5 findings deferred to later stories (logged in deferred-work.md). Test suite now 47/47 passing. Status → done.

### File List

- `supabase/migrations/20260617120001_app_auth_seam.sql` (new)
- `supabase/migrations/20260617120002_catalog.sql` (new)
- `supabase/migrations/20260617120003_pos_orders.sql` (new)
- `supabase/migrations/20260617120004_pos_rpcs.sql` (new)
- `supabase/migrations/20260617120005_rls_policies.sql` (new)
- `supabase/tests/01_orders_create.sql` (new)
- `supabase/tests/02_modify_lines.sql` (new)
- `supabase/tests/03_rls_isolation.sql` (new)
- `frontend/src/environments/environment.ts` (local only — now **gitignored**; holds the publishable anon key)
- `frontend/src/environments/environment.prod.ts` (local only — now **gitignored**; holds the publishable anon key)
- `frontend/src/environments/environment.example.ts` (new — committed template, placeholders)
- `frontend/src/environments/environment.prod.example.ts` (new — committed template, placeholders)
- `frontend/scripts/setup-env.js` (new — generates env files from templates when missing)
- `frontend/package.json` (modified — `setup:env` + `prestart`/`prebuild` hooks)
- `frontend/.gitignore` (modified — fixed broken env-file ignore entries; env files + `.env` now ignored, `.env.example` tracked)
- `supabase/tests/04_rls_write_path.sql` (new — review: authenticated→definer path, modifier dedup, no-op guard, cross-branch WITH CHECK)
- `supabase/seed.sql` (new — review: shared catalog/branch demo fixture)
- `supabase/config.toml` (modified — review: registered the custom access token hook)
- `docs/implementation-artifacts/deferred-work.md` (new — review: deferred findings log)

### Review Finding Resolved (pre-review fix)
- **[Security/config hygiene] Supabase config was hardcoded in tracked source.** `.gitignore` had typo'd entries (`.enviroments/enviroment...`) that failed to ignore the real env files. Fixed: real `environment.ts`/`environment.prod.ts` are now gitignored; committed `*.example.ts` templates + a `setup:env` generator (run via `prestart`/`prebuild`) keep fresh clones/CI building cleanly. Note: the key in question is the **publishable/anon** key (safe to ship; RLS protects data) — the `service_role` key is never present in frontend code.
