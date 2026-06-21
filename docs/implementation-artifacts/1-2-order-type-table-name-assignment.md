---
baseline_commit: 42ad03b3096d068b6b0b22ddb7da53b3e1f89bb2
---

# Story 1.2: Order Type & Table/Name Assignment (+ Table Occupancy)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **Barista**,
I want to **mark an order Dine-In (assigned to a table) or Takeaway (with a name), with the table's occupancy kept in sync**,
so that **each order is served to the right place/person and a table is never double-booked**.

> **Scope note (read first).** Story 1-1 already created the order with `order_type`/`table_id`/`customer_name` and the `catalog.table_seat` table — but `pos_create_order` does **not** yet touch table occupancy or validate the table. This story adds the **table-occupancy lifecycle** (AVAILABLE↔OCCUPIED) driven by order actions, **re-assignment/abandon** on a DRAFT order, and the **table-integrity validations deferred from the 1-1 code review**. **Out of scope:** fire/inventory (1-3/1-7), close→DIRTY (1-8), the Angular UI (S-29, UX-blocked).
>
> Maps to breakdown slice **S-11** (+ modifies S-08's `pos_create_order`). Resolves deferred-work items: table branch-validation, TAKEAWAY-holds-table, `TABLE_OCCUPIED` domain error, branch-scoped active-table uniqueness. See [story-breakdown-epic-1.md](story-breakdown-epic-1.md) and [deferred-work.md](deferred-work.md).

## Acceptance Criteria

1. **Dine-In requires a table; assigning occupies it.** Creating (or assigning) a DINE_IN order to an AVAILABLE table sets that table `OCCUPIED` in the **same transaction**. *(UC-01; epics 1-2 AC1)*
2. **Table must belong to the caller's branch and be free.** `table_id` is validated to exist in `catalog.table_seat` within the caller's `branch_id`; assigning a table that is already `OCCUPIED` (by another active order) raises a typed `TABLE_OCCUPIED` error; a table from another branch raises `TABLE_NOT_FOUND`. *(resolves deferred 1-1 finding)*
3. **Takeaway captures a name and holds no table.** A TAKEAWAY order requires a non-empty `customer_name` and must **not** carry a `table_id`; passing one raises `TAKEAWAY_HAS_TABLE`. *(epics 1-2 AC2; resolves deferred finding)*
4. **Re-assign on a DRAFT order.** A DRAFT dine-in order's table can be changed (old table → AVAILABLE, new table → OCCUPIED, atomically); only allowed while DRAFT. **Clearing to no-table is rejected with `TABLE_REQUIRED`** — the dine-in invariant `ck_dinein_requires_table` forbids a table-less dine-in order, so a held table is released by **abandoning the draft** (`pos_abandon_order`, AC5), not by clearing. *(US-03; amended 2026-06-21 per code review to match the locked invariant)*
5. **Abandoned draft releases the table.** Abandoning a DRAFT order sets fulfillment `CANCELLED`, returns any held table to `AVAILABLE`, and records **no revenue and no inventory consumption**. *(epics 1-2 AC3; UC-01 E2; Gherkin "Abandoned draft does not hold resources")*
6. **One active order per table.** A table cannot be held by two active (non-SERVED/CANCELLED) orders simultaneously — enforced by the partial unique index **and** the in-RPC `TABLE_OCCUPIED` guard. *(architecture §3.3)*
7. **Branch isolation (RLS).** `catalog.table_seat` is RLS-scoped by `branch_id` (read by branch; admin cross-branch read); occupancy writes happen only via RPC and only within the caller's branch. *(architecture §4)*

## Tasks / Subtasks

- [x] **Task 1 — Migration V3: table occupancy + RLS** (AC: 1,2,6,7) — *breakdown S-11, §3.3*
  - [x] New migration `20260618090001_table_occupancy.sql`. Enable + FORCE RLS on `catalog.table_seat`; SELECT policy (`app.is_admin() OR branch_id = app.current_branch_id()`) + branch-scoped INSERT/UPDATE/DELETE policies; REVOKE direct DML from `authenticated`, grant DML to `pos_definer` (mirrors the story-1-1 RLS pattern).
  - [x] Confirmed `uq_table_active_order` on `pos.orders` covers one-active-order-per-table (already present from 1-1; kept). Table `status` transitions are guarded in the RPCs below.
  - [x] Used inline checks in the RPCs (`SELECT … FOR UPDATE` + status assertion) instead of a separate helper — keeps the lock and the guard in one place.
- [x] **Task 2 — Modify `pos_create_order` for occupancy + validation** (AC: 1,2,3,6) — *modifies S-08 RPC*
  - [x] DINE_IN: validate `table_id` exists in `catalog.table_seat` AND `branch_id = app.current_branch_id()` (else `TABLE_NOT_FOUND`); assert status `AVAILABLE` (else `TABLE_OCCUPIED`); set it `OCCUPIED` in the same txn.
  - [x] TAKEAWAY: reject a non-null `table_id` with `TAKEAWAY_HAS_TABLE`.
  - [x] Preserved existing behavior: branch/user stamping, DRAFT/OPEN, name validation, returned JSON shape. 1-1 pgTAP suite still green (`create or replace` keeps the pos_definer owner + execute grants).
- [x] **Task 3 — `pos_assign_table` RPC (re-assign on DRAFT)** (AC: 4,2,6) — *breakdown S-11*
  - [x] `pos_assign_table(p_order_id uuid, p_table_id uuid)` SECURITY DEFINER, one txn, `SELECT … FOR UPDATE` on the order; DRAFT + DINE_IN only.
  - [x] Releases the previously held table (→ AVAILABLE), validates + occupies the new one (branch + AVAILABLE checks). **Decision (see Completion Notes):** `p_table_id = NULL` is *rejected* (`TABLE_REQUIRED`) rather than clearing — a null clear would violate the locked `ck_dinein_requires_table` invariant and break the 1-1 regression test. Release is done via `pos_abandon_order`.
- [x] **Task 4 — `pos_abandon_order` RPC** (AC: 5) — *breakdown S-11, UC-01 E2*
  - [x] `pos_abandon_order(p_order_id uuid)` SECURITY DEFINER, one txn: DRAFT-only → fulfillment `CANCELLED`; if a table is held, release it (→ AVAILABLE); writes nothing to inventory and no revenue (financial_state stays OPEN, total 0). No payment rows possible on a DRAFT (and no payments schema exists yet).
  - [x] Abandoning an already-CANCELLED (non-DRAFT) order raises `INVALID_STATE`.
- [x] **Task 5 — Tests (pgTAP)** (AC: all)
  - [x] DINE_IN create occupies the table; second active order on the same table → `TABLE_OCCUPIED`.
  - [x] Cross-branch `table_id` → `TABLE_NOT_FOUND`; TAKEAWAY with `table_id` → `TAKEAWAY_HAS_TABLE`.
  - [x] Re-assign: old table → AVAILABLE, new table → OCCUPIED; null clear rejected; re-assign on non-DRAFT → `NOT_DRAFT`; assign on TAKEAWAY → `NOT_DINE_IN`; assign onto occupied table → `TABLE_OCCUPIED`.
  - [x] Abandon: order → CANCELLED, table → AVAILABLE, financial_state OPEN + total 0 (no revenue); re-abandon → `INVALID_STATE`.
  - [x] RLS: branch B cannot SELECT branch A's `table_seat` rows; authenticated cannot UPDATE `table_seat` directly (42501); occupancy via RPC succeeds within branch.
  - [x] Regression: full suite re-run — all 5 files, 71 assertions pass (47 from 1-1 + 24 new).
- [ ] **Frontend (S-29) deferred** — order-type toggle + table picker + name field, UX-blocked (readiness UX-1). Track as a follow-on pass.

### Review Findings (2026-06-21)

_Adversarial review: Blind Hunter + Edge Case Hunter + Acceptance Auditor. 1 decision, 3 patches, 7 deferred, 4 dismissed._

- [x] [Review][Decision] AC4 "or cleared" deviation — RESOLVED 2026-06-21: accepted the intentional deviation; AC4 wording amended to state clearing is rejected with `TABLE_REQUIRED` and release is via `pos_abandon_order`. No code change.
- [x] [Review][Patch] Idempotent table release — FIXED in `20260618090004`: release UPDATEs now require `status = 'OCCUPIED'`.
- [x] [Review][Patch] Defense-in-depth branch scoping — FIXED in `20260618090004`: explicit `branch_id = v_branch` on the order lookups + occupancy UPDATEs; new `06_cross_branch_rpc.sql` regression test (6 assertions) proves cross-branch abandon/assign → `ORDER_NOT_FOUND`.
- [x] [Review][Patch] Story File List incomplete — FIXED: `20260618090003`, `20260618090004`, and `06_cross_branch_rpc.sql` added to File List + Change Log.
- [x] [Review][Defer] SERVED/close does not release the seat — `OCCUPIED→AVAILABLE/DIRTY` on close is Story 1-8; status-guard vs `uq_table_active_order` can diverge until then [deferred] — by-design, out of scope
- [x] [Review][Defer] Table-swap deadlock window — two concurrent `pos_assign_table` swapping the same two tables can ABBA-deadlock on seat rows; old seat not locked `FOR UPDATE` before release [20260618090002_pos_table_rpcs.sql:48] [deferred] — low-probability, Postgres aborts+retryable
- [x] [Review][Defer] No-op reassign self-heal — early-return when `table_id = p_table_id` doesn't reconcile a desynced seat status [20260618090002_pos_table_rpcs.sql:35] [deferred] — largely moot once release is idempotent
- [x] [Review][Defer] `public` in SECURITY DEFINER `search_path` — cross-cutting; all RPCs share the pattern, builtins resolve via `pg_catalog` anyway [deferred] — fold into RPC hardening pass
- [x] [Review][Defer] No composite FK `(table_id, branch_id)` on `pos.orders` — branch-consistency of the soft table ref is enforced only by RPC construction [deferred] — schema hardening
- [x] [Review][Defer] AC6 partial-unique-index backstop never independently tested — status guard always fires first [deferred] — low value
- [x] [Review][Defer] AC3 `CUSTOMER_NAME_REQUIRED` not re-asserted in `05` — covered by `01_orders_create.sql` against the redefined function [deferred] — coverage exists
- Dismissed (4): `search_path=''` breaks seam fns — false (bodies use only `pg_catalog` + qualified `app.*`; suite 71/71 green); admin write-policy asymmetry — by design (writes via RPC only); `version` int overflow — unreachable; missing optimistic-concurrency check — by design (pessimistic `FOR UPDATE`).

## Dev Notes

### Files this story MODIFIES (read before editing — preserve existing behavior)
- **`supabase/migrations/20260617120004_pos_rpcs.sql` → `pos_create_order`** *(current state):* inserts order `(DRAFT, OPEN)`, stamps `branch_id`/`created_by` from claims, validates DINE_IN⇒table / TAKEAWAY⇒name, returns `to_jsonb(order)`. It does **NOT** validate the table against the branch, does not check availability, and does not touch `catalog.table_seat`. *This story adds those.* **Add a NEW migration** for the changes (don't edit the shipped 1-1 migration — it's committed and applied); use `create or replace function pos.pos_create_order(...)` in the new migration to redefine it.
- **`supabase/migrations/20260617120003_pos_orders.sql` → `uq_table_active_order`** *(current):* `unique (table_id) where table_id is not null and fulfillment_state not in ('SERVED','CANCELLED')`. `table_id` is a global PK in `table_seat`, so this is already effectively branch-safe; keep it. The real fix is the in-RPC branch validation (Task 2).
- **`catalog.table_seat`** *(current):* exists with `branch_id`, `status` CHECK (AVAILABLE/OCCUPIED/RESERVED/DIRTY), `uq_table_number`. Currently catalog has **no RLS** and `grant select to authenticated`. This story adds RLS to `table_seat` specifically (it's tenant data, unlike the shared product catalog).

### Architecture patterns & constraints (carry forward from 1-1)
- **All writes via SECURITY DEFINER RPCs owned by `pos_definer`**; one RPC = one transaction with `SELECT … FOR UPDATE` on the order. `authenticated` has table DML revoked. [architecture.md §5, §4].
- **Table occupancy FSM** (architecture §3.3): `AVAILABLE→OCCUPIED` on dine-in assign; `OCCUPIED→AVAILABLE` on draft abandon (release held table); `OCCUPIED→DIRTY` on close (Story 1-8, NOT here); `RESERVED` modeled but unused (Epic 2). Drive transitions **inside the same RPC txn** as the order action.
- **`branch_id` from `app.current_branch_id()`**, never a parameter; RLS WITH CHECK enforces branch on writes.
- **Money/snapshot/no-inventory** unchanged — this story records no revenue and no consumption (asserted in tests).

### Previous Story Intelligence (1-1 — apply these, they bit us)
- **Supabase CLI statement splitter chokes on `current_user`** in `GRANT ... TO current_user` → use an explicit role (`postgres`). [1-1 migration 1]
- **`ALTER FUNCTION ... OWNER TO pos_definer`** requires (a) the migration role be a member of `pos_definer` (`grant pos_definer to postgres;`) and (b) `pos_definer` hold `CREATE` on the schema. Grant both **before** the ALTER.
- **`SECURITY DEFINER` runs as the owner (`pos_definer`), not the caller** — so RLS DOES apply to RPC writes even in superuser-invoked tests. Good for coverage; remember when reasoning about policies.
- **pgTAP `throws_ok` with a 5-char SQLSTATE** must use the 4-arg form `throws_ok(sql, '23514', NULL, 'desc')` — the 3-arg form treats arg 3 as an expected message.
- **pgTAP isn't visible under `set local role pos_definer`** (no USAGE on `extensions`) — do role-switch writes inside a `DO` block and assert with `lives_ok` from the postgres context (see `tests/04_rls_write_path.sql`).
- **`supabase db reset` fails on a Realtime container seed** in this CLI (v2.101) — use **`supabase stop && supabase start`** to re-apply migrations. (Consider upgrading the CLI.)
- **Identity tables live in `app`, not `auth`** (Supabase reserves `auth`); seam reads `request.jwt.claims` via `app.current_branch_id()`/`is_admin()`.
- Test claims pattern: `set local request.jwt.claims = '{"sub":"…","branch_id":"…","role":"BARISTA"}'`; use fixed UUIDs distinct from `seed.sql`'s `dddddddd-…` demo ids.

### Source tree
```
supabase/
  migrations/
    <ts>_table_occupancy.sql   # table_seat RLS + (re)defined pos_create_order
    <ts>_pos_table_rpcs.sql    # pos_assign_table, pos_abandon_order
  tests/
    05_table_occupancy.sql     # new pgTAP file for this story
frontend/                      # NOT touched (S-29 deferred, UX-blocked)
```

### Testing standards
- pgTAP, run via `supabase test db` after `supabase stop && supabase start`. Each AC cluster gets explicit assertions including the negative cases (`TABLE_OCCUPIED`, `TABLE_NOT_FOUND`, `TAKEAWAY_HAS_TABLE`, non-DRAFT re-assign). Re-run the whole suite to prove no 1-1 regression.

### References
- [Source: docs/planning-artifacts/epics.md#1-2 — Order type and table/name assignment]
- [Source: docs/planning-artifacts/pos-order-management-use-cases.md#UC-01] + Gherkin "Abandoned draft does not hold resources"
- [Source: docs/planning-artifacts/architecture.md#3.3 — Table occupancy], [#5 — RPCs], [#4 — RLS]
- [Source: docs/planning-artifacts/database-design.md#3.2 — catalog.table_seat]
- [Source: docs/implementation-artifacts/deferred-work.md — table integrity items from 1-1 review]
- [Source: docs/implementation-artifacts/1-1-order-creation-with-modifiers.md — patterns, File List, Dev Agent Record]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Claude Code dev-story)

### Debug Log References

- `supabase start` after `stop` restores the docker volume but does **not** run pending migrations — the new `20260618090001/02` migrations stayed unapplied and the first `supabase test db` reproduced 1-1 behavior (no table_seat RLS, old `pos_create_order`). Fixed by running `supabase migration up --local`, which applied both cleanly. (Update to the 1-1 intelligence: prefer `supabase migration up --local` to apply new migrations to a running stack; `db reset` still trips the Realtime seed bug on CLI v2.101.)

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- **Implemented Supabase-native, all writes via SECURITY DEFINER RPCs owned by `pos_definer`.** Two new migrations + one new pgTAP file; no edits to shipped 1-1 migrations (`pos_create_order` redefined via `create or replace`, preserving owner + execute grants).
- **AC1/2/3/6 (create):** `pos_create_order` now validates the table against the caller's branch (`TABLE_NOT_FOUND`), asserts `AVAILABLE` (`TABLE_OCCUPIED`), occupies it in the same txn, and rejects a TAKEAWAY carrying a table (`TAKEAWAY_HAS_TABLE`). RLS scoping means a foreign-branch table is simply invisible → `TABLE_NOT_FOUND`.
- **AC4 (re-assign) — design decision:** `pos_assign_table` covers table→table re-assignment (release old, occupy new, atomic). **Null-clear is intentionally rejected** with `TABLE_REQUIRED`. Reason: the dine-in invariant `ck_dinein_requires_table` (locked in 1-1) forbids a DINE_IN order with `table_id IS NULL`, and the 1-1 regression test asserts that CHECK at the DB level. Honoring a true "clear to null" would require weakening that invariant **and** changing a committed 1-1 test — out of this story's scope. Releasing a table is done by abandoning the draft (AC5). **Flag for the user:** if a genuine "detach table but keep the order" is desired, it's a follow-up that must also decide what such an order *is* (likely a conversion to TAKEAWAY) and relax the invariant accordingly.
- **AC5 (abandon):** `pos_abandon_order` is DRAFT-only, sets `CANCELLED`, releases any held table, and provably records no revenue (test asserts `financial_state = OPEN`, `total_minor = 0`). No inventory writes (no consumption happens until fire/confirm, Story 1-7). Re-abandon → `INVALID_STATE`.
- **AC7 (RLS):** `catalog.table_seat` now has ENABLE + FORCE RLS with branch-scoped SELECT/INSERT/UPDATE/DELETE policies; `authenticated` lost direct DML (verified: direct UPDATE → `42501`), `pos_definer` granted DML. Cross-branch read isolation verified (branch B sees 0 of branch A's tables).
- **Concurrency:** every RPC takes `SELECT … FOR UPDATE` on the order, and table reads in create/assign lock the `table_seat` row `FOR UPDATE`, so the occupy/release pair is race-safe; the partial unique index `uq_table_active_order` is the backstop (one active order per table).
- **No regressions:** full suite = 71 assertions across 5 files, all green.

### File List

- `supabase/migrations/20260618090001_table_occupancy.sql` (new) — table_seat ENABLE+FORCE RLS + branch policies, DML grants, and `create or replace pos.pos_create_order` (table validation + occupancy + TAKEAWAY_HAS_TABLE).
- `supabase/migrations/20260618090002_pos_table_rpcs.sql` (new) — `pos.pos_assign_table`, `pos.pos_abandon_order` (SECURITY DEFINER, owned by pos_definer, execute granted to authenticated).
- `supabase/migrations/20260618090003_harden_function_search_path.sql` (new) — pins `search_path=''` on the four `app.*` auth-seam functions (Supabase linter 0011 fix; deployed during the cloud-push hardening pass).
- `supabase/migrations/20260618090004_table_rpc_hardening.sql` (new) — code-review patches P1/P2: idempotent seat release (`status='OCCUPIED'` guard) + explicit `branch_id` scoping on the order lookups; redefines all three occupancy RPCs via `create or replace`.
- `supabase/tests/05_table_occupancy.sql` (new) — 24 pgTAP assertions covering AC1–AC7 incl. negative cases.
- `supabase/tests/06_cross_branch_rpc.sql` (new) — 6 pgTAP assertions: cross-branch abandon/assign blocked (`ORDER_NOT_FOUND`); same-branch access intact (code-review patch P2).
- `docs/implementation-artifacts/1-2-order-type-table-name-assignment.md` (this story; status/checkboxes/records).
- `docs/implementation-artifacts/sprint-status.yaml` (1-2 → in-progress → review).
- `docs/implementation-artifacts/deferred-work.md` (code-review deferrals logged 2026-06-21).

### Change Log

- 2026-06-18 — Implemented Story 1-2 (table occupancy + order type/table assignment). Added 2 migrations + 1 pgTAP file (24 assertions). Redefined `pos_create_order`; added `pos_assign_table` and `pos_abandon_order`; added `catalog.table_seat` RLS. Full suite 71/71 green. Status → review.
- 2026-06-21 — Cloud deploy + code review. Deployed all migrations to cloud project. Added `20260618090003` (seam `search_path=''` hardening, Supabase linter fix). Adversarial code review (3 layers): AC4 wording amended (clear-to-null rejected by design); patches P1 (idempotent seat release) + P2 (explicit branch scoping) applied in `20260618090004` with new `06_cross_branch_rpc.sql`; 7 items deferred to deferred-work.md. Full suite 77/77 green.
