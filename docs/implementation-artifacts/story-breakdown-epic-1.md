# Implementation Story Breakdown — Epic 1: POS Order Management

**Project:** store_management_hub · **Author:** TRUNG · **Date:** 2026-06-14
**Reconciled:** 2026-06-17 to the Supabase-native architecture (see `sprint-change-proposal-2026-06-17.md`)
**Sources:** `docs/planning-artifacts/pos-order-management-use-cases.md` (business baseline) · `docs/planning-artifacts/architecture.md` (Supabase-native technical design) · `docs/planning-artifacts/database-design.md` · `epics.md` (parent stories 1-1…1-13)

> **Platform (per architecture.md — LOCKED, Supabase-native):** Ionic Angular SPA on **Vercel** → **`supabase-js`** → **PostgREST/RPC** → **PL/pgSQL SECURITY DEFINER RPCs** → **Supabase PostgreSQL** with **RLS** as the tenant boundary. **No REST API. No ORM in Phase 1.** Direct `supabase-js` for **reads** (RLS-filtered); **all writes go through RPCs**; **Edge Functions for orchestration only** (gateway/webhook/cron/secrets/non-relational compute). Migrations via **Supabase CLI** (plain SQL under `supabase/migrations/`, portable to self-host). Tenant identity read from the **Supabase Auth JWT** via the `app.current_branch_id()` seam.

> **Decomposition rules applied:** each slice ≤ ~1 day · independently testable · clear acceptance criteria · minimal coupling (shared concerns pushed into foundation slices so feature slices stay thin and parallelizable).

> **ID scheme:** `S-NN` = build-ordered implementation slice. Each maps to a parent epic story (`1-x`) and an architecture section (`§`). The 13 epic stories remain the acceptance umbrella; these `S-NN` slices are how they get built.

> **Call-path legend (from the RPC-vs-Edge decision matrix):**
> **UI** = Angular only · **RD** = → Supabase Client (RLS-filtered read) · **RPC** = → PostgreSQL RPC · **EF** = → Edge Function → RPC

> **✅ Architecture decisions resolved (2026-06-17 — see `architecture.md` Appendix → Resolved):**
> - **M2-a** Blocked-attempt audit → **Edge Function wrapper, two-call** (`pos_log_blocked_attempt` in its own txn). Affects S-06/S-21/S-22/S-23.
> - **M2-b** Comp-to-zero close → **reuse the `COMP_DISCOUNT` grant** (no new grant). Affects S-20/S-23.
> - **M2-c** Inventory consume → **in-transaction (§F2)**, no outbox. Affects S-13/S-14.

---

## Build-order & dependency map

```
Track A — Foundations (must precede slices)
  S-00 project init (Ionic+Supabase+CI)
  S-01 auth & tenant seam ─┬─ S-02 Money convention
                           ├─ S-03 migration: order tables ─ S-04 migration: payment/drawer/audit/adjustment
                           ├─ S-05 idempotency (in-RPC) ─────────────┐
                           ├─ S-06 audit infra (+blocked-attempt EF) ┤
                           └─ S-07 grants/RBAC (live in-RPC) ────────┤
Track B — Order lifecycle                                            │
  S-08 create draft ─ S-09 lines+snapshot ─ S-10 modifiers           │
  S-11 type/table assign (+table state)                              │
  S-12 fulfillment FSM ─ S-13 fire/hold/refire ─ S-14 inventory consume/restore (in-txn)
Track C — Money                                                      │
  S-15 financial FSM ─ S-16 take payment ─ S-17 split+idempotent ────┘
                                         └ S-18 declined digital (Epic-2 dep)
Track D — Completion / corrections
  S-19 ready/served+waste · S-20 close+free table+revenue
  S-21 void(+restore) · S-22 refund(+restore) · S-23 comp/discount
Track E — Shift
  S-24 open drawer · S-25 cash attaches to session · S-26 close+reconcile
Track F — Multi-branch
  S-27 business-day bucketing · S-28 RLS isolation + admin cross-branch read
Track G — Frontend (each depends on its API slice + UX; parallelizable)   ⚠️ blocked by UX gap
  S-29 order-entry+modifiers · S-30 tender/payment · S-31 ticket board · S-32 drawer reconcile
```

---

## Track A — Foundations

### S-00 — Project initialization (greenfield) — *[added 2026-06-17, fixes readiness M1]*
- **Parent:** cross-cutting (enables all) · **Arch:** Platform · **Path:** UI/RD
- **Goal:** Stand up the runnable greenfield skeleton: the Ionic Angular app, the Supabase project, the `supabase-js` data layer, and CI/CD.
- **Tasks:**
  - `supabase init`; link a Supabase project; establish `supabase/migrations/` and local `supabase db reset` flow.
  - Scaffold the Ionic Angular app; install and configure `supabase-js` with the **anon** key only (never `service_role` in the SPA).
  - A thin data-access layer abstraction so components don't import `supabase-js` directly (eases the §9 migration).
  - CI: run `supabase db push` on migration changes; deploy frontend to Vercel.
- **Acceptance Criteria:** `supabase db reset` applies cleanly; the app boots and authenticates an anon session; CI runs migrations + a Vercel preview deploy; the bundle ships only the anon key.
- **Dependencies:** none.

### S-01 — Auth & tenant-context seam
- **Parent:** cross-cutting (enables all) · **Arch:** §4, §9 · **Path:** RPC infra
- **Goal:** Establish identity and the tenant boundary mechanism: Supabase Auth issues the JWT; a hook injects tenant claims; RLS reads them through a single swappable seam; DB roles enforce the write surface.
- **Tasks:**
  - Supabase Auth (PIN/password → JWT) login path.
  - **Custom Access Token Hook** (Postgres function registered with Auth) injecting `branch_id`, `role`, `grants[]` from `auth.user_account`/`auth.user_grant`.
  - Helper seam: `app.current_branch_id()` and `app.is_admin()` reading `auth.jwt()` (the only place coupled to Supabase Auth; §9 swaps the body).
  - DB roles: `authenticated` (non-bypass, RLS-subject, **REVOKE INSERT/UPDATE/DELETE** on `pos`/`inventory` tables, EXECUTE on RPCs); `pos_definer` (RPC owner, INSERT/SELECT, no UPDATE/DELETE on append-only); `service_role` confined to CI.
  - Boot/integration assertion: `authenticated` **cannot** directly `INSERT` into `pos.orders`.
- **Acceptance Criteria:** signed-in JWT carries `branch_id`/`role`/`grants`; a direct client `INSERT` into a `pos` table is denied; `app.current_branch_id()` returns the claim; missing claim → NULL → RLS denies (fail-closed).
- **Dependencies:** S-00.

### S-02 — Money convention (minor units)
- **Parent:** cross-cutting · **Arch:** §0, §2 · **Path:** UI
- **Goal:** One money discipline end to end; forbid float/negative.
- **Tasks:** `BIGINT` `_minor` columns with `CHECK (… >= 0)` in SQL (already in migrations); a small TS helper in Angular for formatting/parsing minor units (no float, no client-side money math that the server doesn't re-derive).
- **Acceptance Criteria:** money renders/parses correctly as integer minor units; negative/float input rejected client-side; server remains authoritative for all money arithmetic.
- **Dependencies:** none (pairs with S-03/S-04).

### S-03 — Migration V1: order tables
- **Parent:** 1-1/1-2 · **Arch:** §4 · **Path:** —
- **Goal:** Supabase CLI migration (plain Postgres SQL) for `pos.orders`, `pos.order_lines`, `pos.order_line_modifiers`.
- **Tasks:** DDL with CHECKs (dine_in ⇒ table_id, money ≥ 0, qty > 0, enum checks), `version int` optimistic-lock column, indexes `(branch_id,business_day)`, partial active-state + active-table unique indexes; `recipe_snapshot jsonb`; **denormalized `branch_id` on child tables** (RLS, DB §8.5).
- **Acceptance Criteria:** migration applies clean; `DINE_IN` without `table_id` rejected by CHECK; required indexes present (verified by test).
- **Dependencies:** S-01.

### S-04 — Migration V2: payment / drawer / adjustment / audit tables
- **Parent:** 1-4/1-10/1-11/1-12 · **Arch:** §4, §6 · **Path:** —
- **Goal:** Supabase CLI migration for `payment_transactions`, `order_adjustments`, `drawer_sessions`, `audit_entries`.
- **Tasks:** UNIQUE `idempotency_key`; partial UNIQUE `(register_id) WHERE state='OPEN'`; cash⇒drawer CHECK; **`REVOKE UPDATE,DELETE,TRUNCATE`** on append-only tables from **`pos_definer` and `authenticated`**; `BEFORE UPDATE OR DELETE` → `pos.forbid_mutation()` trigger backstop.
- **Acceptance Criteria:** duplicate `idempotency_key` fails; second OPEN drawer fails; any UPDATE on a payment row (even by definer) denied — all proven by tests.
- **Dependencies:** S-03.

### S-05 — Idempotency infrastructure (in-RPC)
- **Parent:** 1-5 · **Arch:** §5, §13 · **Path:** RPC
- **Goal:** Reusable idempotency for money/side-effecting RPCs — handled in the database, not an HTTP layer.
- **Tasks:** standard pattern `INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING …`; on conflict, SELECT and return the original transaction; client generates a key per intent and persists it for retries.
- **Acceptance Criteria:** same key replayed → exactly one persisted effect, original result returned; a key-required RPC called without a key → typed error.
- **Dependencies:** S-04.

### S-06 — Audit trail infrastructure (incl. blocked attempts)
- **Parent:** 1-9/1-10/1-11 (US-17) · **Arch:** §6 · **Path:** RPC/EF
- **Goal:** Append-only audit with an in-transaction success path and a **survivable blocked-attempt path**.
- **Tasks:** an audit-writing helper that joins the caller's RPC txn for success entries; for BLOCKED attempts, the sensitive RPC raises a typed error and a thin **Edge Function wrapper** catches it and calls `pos_log_blocked_attempt` in its own transaction so the audit row survives the rollback. ✅ **M2-a resolved (2026-06-17):** Edge Function wrapper, two-call pattern (chosen over `dblink`/`pg_background`).
- **Acceptance Criteria:** a rejected sensitive action (rolled back) still leaves a `BLOCKED` audit row; a successful sensitive action's audit commits atomically with it.
- **Dependencies:** S-04.

### S-07 — Per-action grants / RBAC enforcement (live, in-RPC)
- **Parent:** 1-9/1-10/1-11 · **Arch:** §4 (F5), §5 · **Path:** RPC
- **Goal:** Enforce 3 base roles **+ per-user grants** (`VOID_FIRED`, `COMP_DISCOUNT`, `REFUND`) with a **live** check, not a stale JWT claim.
- **Tasks:** in-RPC `EXISTS (SELECT 1 FROM auth.user_grant WHERE user_id = … AND grant_code = …)`; on failure, raise typed error → S-06 blocked-audit; reusable guard snippet across sensitive RPCs.
- **Acceptance Criteria:** barista refund attempt → typed permission error + audited BLOCKED; user with `REFUND` grant passes; a just-revoked grant is honored immediately (live re-check, not token TTL).
- **Dependencies:** S-01, S-06.

---

## Track B — Order lifecycle

### S-08 — Create draft order
- **Parent:** 1-2 · **Arch:** §5 · **Path:** RPC
- **Goal:** RPC `pos_create_order` creates `(DRAFT, OPEN)` attributed to the caller's branch.
- **Tasks:** params (type, table?/name?); validate (DINE_IN⇒table, TAKEAWAY⇒name); stamp `branch_id` from `auth.jwt()` claim (never a parameter).
- **Acceptance Criteria:** dine-in without table → typed validation error; created order's `branch_id` comes from the token; state DRAFT/OPEN.
- **Dependencies:** S-03, S-01.

### S-09 — Order lines with catalog price snapshot + totals
- **Parent:** 1-1 (UC-01) · **Arch:** §5, §2 · **Path:** RPC
- **Goal:** RPC `pos_modify_lines` add/change/remove on DRAFT, snapshotting product name/price/recipe; recompute totals in-txn.
- **Tasks:** read active product from `catalog`; snapshot price + recipe (jsonb); reject inactive product; recalc subtotal/total; DRAFT-only guard.
- **Acceptance Criteria:** adding an inactive product → rejected; removing a line recalculates total; no inventory consumed yet; edits blocked once not DRAFT.
- **Dependencies:** S-08, S-02.

### S-10 — Modifiers with surcharge snapshot
- **Parent:** 1-1 · **Arch:** §2 · **Path:** RPC
- **Goal:** Attach modifiers (folded into `pos_modify_lines`), snapshotting surcharge; totals include surcharges.
- **Acceptance Criteria:** "Latte + Oat Milk" total = base + oat surcharge captured at sale time; a later catalog surcharge change does not alter this order.
- **Dependencies:** S-09.

### S-11 — Order type & table/name assignment + table occupancy
- **Parent:** 1-2 · **Arch:** §3.3, §5 · **Path:** RPC
- **Goal:** Assign/clear table (DINE_IN) or name (TAKEAWAY); flip table `AVAILABLE→OCCUPIED` on assign within the same txn.
- **Tasks:** assignment inside create/modify RPC; table-state guard; reject assigning an OCCUPIED table to a 2nd active order (`uq_table_active_order`).
- **Acceptance Criteria:** assigning table 5 sets it OCCUPIED; assigning an already-occupied table → rejected; abandoned draft releases the table (AVAILABLE) with no revenue/consumption.
- **Dependencies:** S-08.

### S-12 — Fulfillment state machine (guards)
- **Parent:** 1-3/1-6 · **Arch:** §3.1, §3.5 · **Path:** RPC
- **Goal:** Centralized `pos.assert_fulfillment_transition(from,to)` PL/pgSQL guard (DRAFT→IN_PREP→READY→SERVED, +CANCELLED, +re-fire).
- **Acceptance Criteria:** every invalid transition (READY→DRAFT, SERVED→*) raises `INVALID_STATE`; pgTAP property-test over the transition table.
- **Dependencies:** S-08.

### S-13 — Fire / hold / re-fire
- **Parent:** 1-3 (UC-01/03) · **Arch:** §5, §6, §7.1 · **Path:** RPC
- **Goal:** RPC `pos_fire_order` (DRAFT→IN_PREP); hold = stay DRAFT (no call); re-fire = reproduce ticket, no duplicate sale.
- **Tasks:** require ≥1 ACTIVE line; idempotent fire (S-05 + `version`); `SELECT … FOR UPDATE`; optional Realtime/trigger notify for the ticket board (not a correctness dependency).
- **Acceptance Criteria:** firing empty order → typed error; re-fire produces a ticket without a second sale/consumption; double-fire race → one wins, loser gets a conflict.
- **Dependencies:** S-12, S-05.

### S-14 — Inventory consumption on fire + restoration (in-transaction)
- **Parent:** 1-7 (UC-05/06) · **Arch:** §5, §F2 · **Path:** RPC
- **Goal:** Inside `pos_fire_order`, `INSERT inventory.SALE` rows from `recipe_snapshot × qty`; never block on zero/negative; expose restore for void/refund. ✅ **M2-c resolved (2026-06-17):** in-transaction consume per §F2 (no outbox).
- **Tasks:** consume in the same txn as fire; restore rows on void/refund; flag (don't block) on depletion; idempotent by `(source_order_id, source_line_id, txn_type)`.
- **Acceptance Criteria:** confirming a Latte consumes 18g beans + 150ml milk at the branch; with 0 beans the sale still completes and stock is flagged negative; refund/void restores consumed ingredients; crash mid-fire leaves no orphan consume (single txn).
- **Dependencies:** S-13.

---

## Track C — Money

### S-15 — Financial state machine (guards)
- **Parent:** 1-4 · **Arch:** §3.2 · **Path:** RPC
- **Goal:** Centralized `pos.assert_financial_transition()` (OPEN→PARTIALLY_PAID→PAID→CLOSED; →PARTIALLY_REFUNDED→REFUNDED); balance derived from `payment_transactions`.
- **Acceptance Criteria:** balance recomputed from transactions (never trusts cached total); refund while OPEN rejected; pgTAP property-test.
- **Dependencies:** S-04.

### S-16 — Take payment (cash/card/QR) + change
- **Parent:** 1-4 (UC-02) · **Arch:** §5, §7.3 · **Path:** RPC
- **Goal:** RPC `pos_take_payment`; cash computes change server-side; balance→0 sets PAID. Card/QR recorded via RPC in Epic 1 (gateway integration is Epic 2 / S-18).
- **Tasks:** record `CHARGE`; server-computed change (never trust client); cash requires OPEN drawer; non-cash amount ≤ balance.
- **Acceptance Criteria:** pay 100k on 50k cash → change 50k, state PAID; non-cash overpay → typed error; charge after PAID → conflict.
- **Dependencies:** S-15, S-04, S-24 (for cash drawer linkage).

### S-17 — Split payments + idempotent charge
- **Parent:** 1-5 (UC-02 A1/E2) · **Arch:** §5, §13 · **Path:** RPC
- **Goal:** Multiple partial `pos_take_payment` calls until balance 0; duplicate intent never double-charges.
- **Acceptance Criteria:** 60k CARD + 40k CASH → PAID, balance 0; same idempotency key submitted twice → one payment recorded.
- **Dependencies:** S-16, S-05.

### S-18 — Declined / failed digital payment *(Epic-2 dependent)*
- **Parent:** 1-4 (UC-02 E1) · **Arch:** §5.3, §7.6 · **Path:** EF
- **Goal:** Via the gateway **Edge Function**, a declined CARD/QR returns 402 and leaves the order OPEN, retriable, with **no RPC write**.
- **Note:** requires the Epic-2 `payments-gateway` Edge Function. In Epic 1 (no gateway), digital is recorded manually via S-16; this slice is **blocked on Epic 2** — track but do not build in Epic 1.
- **Acceptance Criteria:** declined card → 402, order still OPEN; customer can pay by another method.
- **Dependencies:** S-16, Epic-2 `payments-gateway`.

---

## Track D — Completion & corrections

### S-19 — Fulfillment progression + waste on remake
- **Parent:** 1-6 (UC-03) · **Arch:** §3.1, §5 · **Path:** RPC
- **Goal:** RPC `pos_advance_fulfillment` (READY then SERVED); record a remake as an `inventory.WASTE` row (one sale, separate waste).
- **Acceptance Criteria:** READY→SERVED valid; remaking a spilled latte records exactly one sale + one WASTE; sale consumes once.
- **Dependencies:** S-13, S-14.

### S-20 — Close order + free table + recognize revenue
- **Parent:** 1-8 (UC-04) · **Arch:** §5, §7.1, §8 · **Path:** RPC
- **Goal:** RPC `pos_close_order` when PAID (or comped-to-zero) **and** SERVED → CLOSED; table→DIRTY; set `business_day`. ✅ **M2-b resolved (2026-06-17):** comp-to-zero close authorized by the `COMP_DISCOUNT` grant (no new grant).
- **Acceptance Criteria:** close while unpaid (not comped) → conflict; closing sets table DIRTY and buckets revenue into the branch business day.
- **Dependencies:** S-15, S-11, S-19.

### S-21 — Void unpaid item/order (+restore if consumed)
- **Parent:** 1-9 (UC-05) · **Arch:** §5, §6 · **Path:** RPC
- **Goal:** RPC `pos_void` for an unpaid item/order with reason; recalc totals; restore stock if already fired; audit actor+reason; `VOID_FIRED` grant for fired orders. Blocked attempts audited via the S-06 Edge-Fn wrapper (M2-a).
- **Acceptance Criteria:** void unpaid Cake → total excludes Cake, audit recorded; void on PAID order → rejected (directs to refund); fired-then-voided restores ingredients; void-fired requires `VOID_FIRED`.
- **Dependencies:** S-09, S-07, S-14.

### S-22 — Refund (full/partial) as reversing transaction
- **Parent:** 1-10 (UC-06) · **Arch:** §5, §7.4 · **Path:** RPC (EF for digital refund in Epic 2)
- **Goal:** RPC `pos_refund`; reversing txn; cumulative ≤ paid under `SELECT … FOR UPDATE`; state →PARTIALLY_REFUNDED/REFUNDED; restore refunded lines; audit; live `REFUND` grant. Blocked attempts audited via the S-06 Edge-Fn wrapper (M2-a).
- **Acceptance Criteria:** full refund → REFUNDED + audit; partial item refund → PARTIALLY_REFUNDED + that item's ingredients restored; cumulative > paid → typed error (shows max); barista → permission error + logged.
- **Dependencies:** S-15, S-07, S-14, S-05.

### S-23 — Comp / discount with authorization
- **Parent:** 1-11 (UC-07) · **Arch:** §5, §6 · **Path:** RPC
- **Goal:** RPC `pos_adjust` — comp or %/amount discount at line or order scope with reason; recalc; live `COMP_DISCOUNT` grant; audit authorizer. Blocked attempts audited via the S-06 Edge-Fn wrapper (M2-a); `COMP_DISCOUNT` also authorizes the comp-to-zero close in S-20 (M2-b).
- **Acceptance Criteria:** comp Espresso 25k → total −25k, authorizer+reason recorded; user lacking `COMP_DISCOUNT` → blocked + logged.
- **Dependencies:** S-09, S-07.

---

## Track E — Shift / drawer

### S-24 — Open drawer session
- **Parent:** 1-12 (UC-08) · **Arch:** §3.4, §5 · **Path:** RPC
- **Goal:** RPC `pos_open_drawer` with opening float; one OPEN per register (`uq_one_open_drawer`).
- **Acceptance Criteria:** opening a 2nd session on the same register → rejected; session OPEN with float recorded.
- **Dependencies:** S-04.

### S-25 — Cash payments/refunds attach to session
- **Parent:** 1-12 · **Arch:** §5 · **Path:** RPC
- **Goal:** Cash `CHARGE`/`REFUND` reference the caller's OPEN session — enforced inside `pos_take_payment`/`pos_refund` (no separate endpoint), backed by `ck_cash_needs_drawer`.
- **Acceptance Criteria:** cash payment with no open session → `NO_OPEN_DRAWER`; cash txns carry `drawer_session_id`.
- **Dependencies:** S-24, S-16, S-22.

### S-26 — Close drawer + reconcile
- **Parent:** 1-12 (UC-08) · **Arch:** §7.5 · **Path:** RPC
- **Goal:** RPC `pos_close_drawer` with counted cash; compute expected & variance.
- **Acceptance Criteria:** float 500k + 1,200k cash, counted 1,690k → expected 1,700k, variance −10k; second close → conflict.
- **Dependencies:** S-25.

---

## Track F — Multi-branch & business day

### S-27 — Business-day boundary bucketing
- **Parent:** 1-13 · **Arch:** §8 · **Path:** RPC
- **Goal:** Per-branch configurable cutoff; compute `business_day` inside `pos_close_order` from server time.
- **Acceptance Criteria:** branch cutoff 04:00, sale at 23:30 on the 14th → business day = 14th; sale at 02:00 on 15th → still 14th.
- **Dependencies:** S-20.

### S-28 — Branch isolation via RLS + admin cross-branch read
- **Parent:** 1-13 (US-20/21) · **Arch:** §4, §8 · **DB:** §8.5 · **Path:** RPC/RD
- **Goal:** **Enable + FORCE RLS** on all tenant tables as the DB-enforced boundary, keyed on `branch_id`, reading identity via the **`auth.jwt()` seam** (`app.current_branch_id()`/`app.is_admin()`). Admin may read (not write) across branches.
- **Tasks:** RLS policy migration (USING branch match OR `app.is_admin()`; WITH CHECK branch match only); 404 (not 403) on cross-branch; boot assertion that the SPA never uses `service_role`.
  - **Note (artifact reconciliation):** `database-design.md` §8.5 expresses tenant context as `SET LOCAL app.current_branch` — that is the **§9 Spring migration target**. Supabase-native uses `auth.jwt()` via the seam; the policy bodies are otherwise identical. *(Follow-up: add a one-line clarifier to DB §8.5.)*
- **Acceptance Criteria:** with branch-A identity, querying a branch-B order returns nothing (RLS) → surfaced as 404; admin lists across branches but cannot insert into another branch (WITH CHECK); no/expired claim sees no rows (fail-closed); `service_role` never reachable from the browser.
- **Dependencies:** S-01, S-08, S-03, S-04.

---

## Track G — Frontend (Ionic Angular) — ⚠️ blocked by the UX gap (readiness UX-1)

> These slices need wireframes/interaction specs for the 4 POS screens before they can be built confidently. Each calls `supabase-js` directly: `.rpc()` for writes, `.from().select()` for RLS-filtered reads.

### S-29 — Order entry + modifier picker page
- **Parent:** 1-1/1-2 · **Path:** UI/RPC/RD
- **Goal:** Build draft order: product grid (catalog read), modifier picker, live totals, type/table/name; writes via `pos_create_order`/`pos_modify_lines`.
- **Acceptance Criteria:** totals update on add/remove; inactive products not selectable; dine-in requires table before fire.
- **Dependencies:** S-09, S-10, S-11, UX.

### S-30 — Tender / payment panel
- **Parent:** 1-4/1-5 · **Path:** UI/RPC
- **Goal:** Tender pad, method select, change display, split payments; generates an idempotency key per intent; calls `pos_take_payment`.
- **Acceptance Criteria:** change shown for cash; split until balance 0; retry reuses the same key (no double charge).
- **Dependencies:** S-16, S-17, UX.

### S-31 — Ticket board
- **Parent:** 1-3/1-6 · **Path:** RD/RPC
- **Goal:** Show IN_PREP/READY tickets per branch via RLS-filtered `.from().select()` (polling MVP; Supabase Realtime optional); advance READY/SERVED and re-fire via RPC.
- **Acceptance Criteria:** fired orders appear as tickets; state changes reflected; (polling MVP, Realtime deferred).
- **Dependencies:** S-13, S-19, UX.

### S-32 — Drawer reconciliation screen
- **Parent:** 1-12 · **Path:** UI/RPC
- **Goal:** Open drawer (float), close drawer (count), show expected/variance; refund/comp UI gated by JWT grant claims.
- **Acceptance Criteria:** variance displayed on close; refund button hidden without `REFUND` grant.
- **Dependencies:** S-24, S-26, S-07, UX.

---

## Coverage check (every epic story is covered)

| Epic story | Implementation slices |
|---|---|
| 1-1 order+modifiers | S-09, S-10, S-29 |
| 1-2 type/table/name | S-08, S-11, S-29 |
| 1-3 fire/hold/re-fire | S-12, S-13, S-31 |
| 1-4 take payment | S-15, S-16, S-18, S-30 |
| 1-5 split + idempotency | S-05, S-17, S-30 |
| 1-6 fulfillment + waste | S-19, S-31 |
| 1-7 inventory consumption | S-14 |
| 1-8 close + free table | S-20, S-27 |
| 1-9 void | S-21 |
| 1-10 refund | S-22 |
| 1-11 comp/discount | S-07, S-23 |
| 1-12 drawer reconciliation | S-24, S-25, S-26, S-32 |
| 1-13 branch + business day | S-27, S-28 |
| (cross-cutting) | S-00, S-01, S-02, S-03, S-04, S-06 |

---

## Edge Function inventory (orchestration only)

| Edge Function | Purpose | Epic |
|---|---|---|
| `pos_log_blocked_attempt` wrapper | guarantees BLOCKED audit survives RPC rollback (M2-a) | 1 |
| `stale-draft-cleanup` (cron) | expire abandoned DRAFTs, release held tables (UC-01 E2) | 1 |
| `payments-gateway` | external card/QR charge with secret, then `pos_take_payment` | 2 |
| `payments-webhook` | async gateway callback reconciliation (signature secret, no user JWT) | 2 |
| `receipt-render` | PDF/image receipt (non-relational compute) | 2 |

---

## Notes / open items carried into build

1. ✅ **M2-a — Blocked-attempt audit (RESOLVED 2026-06-17):** Edge-Fn-wrapper two-call pattern. Affects S-06/S-21/S-22/S-23.
2. ✅ **M2-b — Comp-to-zero close grant (RESOLVED 2026-06-17):** reuse `COMP_DISCOUNT`. Affects S-20/S-23.
3. ✅ **M2-c — Inventory consume timing (RESOLVED 2026-06-17):** in-transaction per §F2 (no outbox). Affects S-13/S-14.
4. **UX gap:** Track G (S-29…S-32) blocked until low-fi wireframes exist for the 4 POS screens. *(UX)*
5. **Artifact follow-up:** add a one-line clarifier to `database-design.md` §8.5 that `SET LOCAL` is the §9 migration target; Supabase-native uses the `auth.jwt()` seam (§4).
6. **Migrations** are Supabase CLI plain SQL under `supabase/migrations/`, portable to self-hosted Postgres. CI runs `supabase db push`.
7. These 32 (+S-00) slices remain compatible with the coarse 1-1…1-13 entries in `sprint-status.yaml`; no epic-level renumbering was required by this reconciliation.
