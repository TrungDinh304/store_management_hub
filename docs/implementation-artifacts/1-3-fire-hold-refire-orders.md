---
baseline_commit: 42ad03b3096d068b6b0b22ddb7da53b3e1f89bb2
---

# Story 1.3: Fire, Hold, and Re-fire Orders

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **Barista**,
I want to **fire an order to the bar, hold it as a draft, or re-fire a lost ticket**,
so that **nothing is missed during a rush and one sale is never produced twice**.

> **Scope note (read first).** This story implements the **fulfillment state machine** for the *first* transition out of DRAFT. It delivers two breakdown slices: **S-12** (the centralized, reusable `pos.assert_fulfillment_transition` guard — the single source of truth for fulfillment edge legality, used by every later fulfillment RPC) and **S-13** (`pos_fire_order`: DRAFT→IN_PREP fire, idempotent re-fire, hold-as-no-op).
>
> **Explicitly OUT of scope (do NOT implement here):**
> - **Inventory consumption on fire** — architecture §5 lists `pos_fire_order` as *also* writing `inventory.SALE` rows, but that is **Story 1-7 / S-14**. There is no `inventory` schema yet. 1-7 will *redefine* `pos_fire_order` via `create or replace` to add consumption — exactly the incremental pattern Story 1-2 used to extend `pos_create_order`. Build the fire skeleton; leave a clearly-marked seam for 1-7.
> - **Table occupancy** — architecture §5 says fire assigns the table OCCUPIED, but in **our** implementation the table is already occupied at **create** (Story 1-2 decision). `pos_fire_order` must **not** touch `catalog.table_seat`.
> - **READY/SERVED progression** — that is Story 1-6 / S-19 (`pos_advance_fulfillment`). This story only builds the guard matrix (which 1-6 reuses) and the fire/re-fire RPC.
> - **Idempotency-key infrastructure** — the dedicated idempotency ledger is **Story 1-5 / S-05**. It does not exist yet. Fire-safety in this story rests on the locked architectural primitives already proven in 1-1/1-2: `SELECT … FOR UPDATE` (pessimistic serialization) + the FSM guard + `version`. See AC4 and the design note.
> - **Audit log** — the audit/grant Edge-Fn wrapper (S-06/S-07) is later; no audit rows here.
>
> Maps to breakdown slices **S-12 + S-13**. See [story-breakdown-epic-1.md](story-breakdown-epic-1.md), [architecture.md](../planning-artifacts/architecture.md) §3.1/§3.5/§5, and the UC-01/UC-03 Gherkin in [pos-order-management-use-cases.md](../planning-artifacts/pos-order-management-use-cases.md).

## Acceptance Criteria

1. **Firing moves a DRAFT order to IN_PREP, atomically.** `pos_fire_order` transitions a `DRAFT` order's `fulfillment_state` to `IN_PREP`, stamps `fired_at = now()`, and bumps `version`, in a single transaction. The fired order is now visible as an active ticket (it falls into the existing `ix_orders_active_tickets` partial index on `(branch_id, fulfillment_state) where fulfillment_state in ('IN_PREP','READY')`). *(epics 1-3 AC1; UC-01 step 5; arch §3.1)*
2. **An order cannot be fired empty.** Firing an order with **zero `ACTIVE` order_lines** raises a typed `EMPTY_ORDER` error and changes nothing. (Lines with `line_state` `VOIDED`/`COMPED` do not count.) *(S-13 AC; UC-01 — an order must have items to make)*
3. **Holding keeps the order in DRAFT.** "Hold" is the *absence* of a fire — a created order stays `DRAFT` until `pos_fire_order` is called. No new RPC is required for hold; this AC is satisfied by Story 1-1/1-2 behavior and is asserted (a never-fired order remains `DRAFT`). *(epics 1-3 AC2; UC-01 A2)*
4. **Re-firing reproduces the ticket without duplicating the sale; concurrent fires are serialized.** Calling `pos_fire_order` on an order **already** `IN_PREP` succeeds idempotently — it re-surfaces the ticket (the `IN_PREP→IN_PREP` edge) and performs **no** duplicate state change beyond an optional `fired_at` refresh; it creates no second sale and (when inventory lands in 1-7) will trigger no second consumption. Two concurrent `pos_fire_order` calls on the same `DRAFT` order are serialized by `SELECT … FOR UPDATE`: exactly one performs the `DRAFT→IN_PREP` fire; the other observes `IN_PREP` and resolves as an idempotent re-fire (never a second fire). *(epics 1-3 AC3; arch §3.1 re-fire edge; UC-03 A2)*
5. **Illegal fulfillment transitions are rejected by a single reusable guard.** A `pos.assert_fulfillment_transition(from, to)` helper encodes the **complete** legal edge set and raises `INVALID_STATE` for anything else. `pos_fire_order` rejects firing a `READY`, `SERVED`, or `CANCELLED` order via this guard. The guard's full matrix (so later stories reuse it unchanged): **legal** = DRAFT→IN_PREP, DRAFT→CANCELLED, IN_PREP→READY, IN_PREP→IN_PREP (re-fire), READY→SERVED; **illegal** = every backward move, any `SERVED→*`, any `CANCELLED→*`, and all skips (e.g. DRAFT→READY, DRAFT→SERVED). *(S-12; arch §3.1 "Valid/Rejected" + §3.5)*
6. **Branch isolation holds on the fire path.** `pos_fire_order` operates only within the caller's branch: the order is looked up with an **explicit** `branch_id = app.current_branch_id()` predicate (in addition to FORCE RLS), so a cross-branch order id returns `ORDER_NOT_FOUND` — not a silent no-op. *(carries forward the Story 1-2 code-review patch P2; arch §4, §10 "no cross-branch mutation")*

## Tasks / Subtasks

- [x] **Task 1 — Migration: fulfillment FSM guard helper** (AC: 5) — *breakdown S-12, arch §3.5*
  - [x] New migration `supabase/migrations/20260619090001_fulfillment_fsm_guard.sql`.
  - [x] `pos.assert_fulfillment_transition(p_from text, p_to text) returns void` — `immutable`, `set search_path = ''` (pure logic, no object refs → no linter 0011 warning). Row-constructor `IN` over the legal edge set; `raise exception 'INVALID_STATE'` otherwise.
  - [x] Encoded the EXACT matrix from AC5 — single source of truth for 1-6/1-8 reuse.
  - [x] `revoke all … from public; grant execute … to pos_definer` — internal helper, not granted to `authenticated`.
- [x] **Task 2 — Migration: `pos_fire_order` RPC** (AC: 1,2,4,6) — *breakdown S-13, arch §5*
  - [x] New migration `supabase/migrations/20260619090002_pos_fire_order.sql`.
  - [x] `create function pos.pos_fire_order(p_order_id uuid) returns jsonb … security definer set search_path = pos, catalog, app, public`.
  - [x] `v_branch := app.current_branch_id()`; `NO_BRANCH_CONTEXT` if null.
  - [x] `select … where id = p_order_id and branch_id = v_branch for update;` → `ORDER_NOT_FOUND` (explicit branch scope, P2 lesson).
  - [x] Re-fire short-circuit: IN_PREP → refresh `fired_at`, return; idempotent, no version bump. (AC4)
  - [x] Fire: `perform pos.assert_fulfillment_transition(v_order.fulfillment_state, 'IN_PREP')` rejects READY/SERVED/CANCELLED. (AC5)
  - [x] `EMPTY_ORDER` if no ACTIVE line. (AC2)
  - [x] `update … set fulfillment_state='IN_PREP', fired_at=now(), version=version+1 …`. (AC1)
  - [x] Commented S-14 seam (inventory deferred to Story 1-7).
  - [x] Does NOT touch `catalog.table_seat` (commented; occupied at create in 1-2).
  - [x] `return to_jsonb(v_order);`
  - [x] `alter function … owner to pos_definer; grant execute … to authenticated;`.
- [x] **Task 3 — Tests (pgTAP)** (AC: all) — new file `supabase/tests/07_fire_hold_refire.sql`
  - [x] Guard unit tests (AC5): 5 legal edges `lives_ok`, 4 illegal edges `throws_ok 'INVALID_STATE'` (run as postgres — internal helper).
  - [x] Fire happy path (AC1): IN_PREP, `fired_at` not null, `version`=1.
  - [x] Empty order (AC2): `EMPTY_ORDER`; stays DRAFT (VOIDED line doesn't count).
  - [x] Hold (AC3): never-fired order stays DRAFT.
  - [x] Re-fire idempotent (AC4): still IN_PREP, version stays 1, line count unchanged (no second sale).
  - [x] Illegal fire (AC5): SERVED / CANCELLED / READY → `INVALID_STATE`.
  - [x] Branch isolation (AC6): branch B → `ORDER_NOT_FOUND`; branch A fires its own.
  - [x] Concurrency reasoning documented (single-txn pgTAP asserts the logical outcome: one fire bumps version once, re-fire doesn't).
  - [x] Full suite re-run — 103/103 across 7 files, no regression.
- [ ] **Task 4 — (Optional, defense-in-depth) FSM trigger backstop** (AC: 5) — *arch §3.5 "optional backstop"* — **DEFERRED** (see deferred-work.md; guard covers correctness, trigger is pure redundancy)
  - [ ] **Deferred by default.** Architecture marks the `BEFORE UPDATE` trigger that rejects illegal `(old,new)` fulfillment pairs as *optional* (it duplicates the guard). Recommend **not** building it in this slice to keep it tight; if the team wants the rogue-RPC backstop, generate it from the same edge set as Task 1. Logged to deferred-work either way.
- [ ] **Frontend (deferred)** — ticket-board / "Fire" + "Hold" buttons are UX-blocked (readiness UX-1), same as 1-1/1-2. Track as a follow-on pass; not in this story.

### Review Findings (2026-06-21)

_Adversarial review: Blind Hunter + Edge Case Hunter + Acceptance Auditor. All 6 ACs implemented & tested; scope fences honored. 1 patch, 5 deferred, 7 dismissed._

- [x] [Review][Patch] Re-fire bypasses the EMPTY_ORDER guard — FIXED in `20260619090003`: restructured so the FSM guard AND the active-line check both run before the fire/re-fire split (guard-first preserves INVALID_STATE precedence and now exercises the IN_PREP→IN_PREP edge; EMPTY_ORDER applies to re-fire too). New regression test (Section E2) asserts re-firing an all-VOIDED IN_PREP order → `EMPTY_ORDER`. Suite 105/105.
- [x] [Review][Defer] `pos_abandon_order` (DRAFT→CANCELLED) does not call `assert_fulfillment_transition`, so the guard's DRAFT→CANCELLED edge is unreachable — the "single source of truth" isn't yet literally single [deferred] — retrofit abandon to call the guard, or document; abandon's inline check is correct today
- [x] [Review][Defer] No IN_PREP/READY→CANCELLED route — an erroneously-fired DINE_IN order can't be cancelled and its table stays OCCUPIED indefinitely [deferred] — covered by Story 1-8 (close+free table) / 1-9 (void)+1-10 (refund)+restore
- [x] [Review][Defer] Fire-vs-void-last-line concurrency — the EMPTY_ORDER line read isn't under the order lock; the future void/comp RPC must `SELECT … FOR UPDATE` the parent order so the order-row lock serializes it [deferred] — no void RPC exists yet (Story 1-9)
- [x] [Review][Defer] `pos_fire_order` ignores `financial_state` — when payments land, block firing a CLOSED/REFUNDED order (but still ALLOW PAID — pay-first DRAFT→fire is first-class) [deferred] — no financial transitions until Story 1-4
- [x] [Review][Defer] AC5 negative matrix is sampled (4 illegal edges), not an exhaustive property-test over the transition table [deferred] — the allowlist guard makes untested illegal edges unreachable; correctness holds, thoroughness optional
- Dismissed (7): version-not-bumped-on-re-fire (BY DESIGN — AC4 idempotent, test asserts version stays 1); `immutable` marker on guard (deterministic, input-only, no failure path — technically valid); re-fire UPDATE lacks `branch_id` filter (row already FOR UPDATE-locked + branch-verified; consistent with 1-2 RPC pattern); `now()` constant within a txn (benign — each RPC is its own txn from PostgREST); `version int` overflow (unreachable at POS scale); AC4 concurrency reasoned-not-executed (pgTAP single-session limitation, spec-disclosed); guard can't distinguish garbage `p_from` from illegal edge (CHECK-constrained column can't produce garbage).

## Dev Notes

### Files this story CREATES (all new; forward-only migrations)
- `supabase/migrations/<ts>_fulfillment_fsm_guard.sql` — `pos.assert_fulfillment_transition`.
- `supabase/migrations/<ts>_pos_fire_order.sql` — `pos.pos_fire_order`.
- `supabase/tests/07_fire_hold_refire.sql` — pgTAP for this story.
- Use the next free timestamps after `20260618090004` (e.g. `20260619090001`, `20260619090002`). Do **not** edit any shipped migration.

### Files/objects this story READS (do not modify)
- **`pos.orders`** ([20260617120003_pos_orders.sql](../../supabase/migrations/20260617120003_pos_orders.sql)): `fulfillment_state text not null default 'DRAFT' check (… in ('DRAFT','IN_PREP','READY','SERVED','CANCELLED'))`, `fired_at timestamptz` (currently null — this story first populates it), `version int not null default 0`, `closed_at`/`business_day` (set in later stories). Partial index `ix_orders_active_tickets … where fulfillment_state in ('IN_PREP','READY')` — firing makes the order a "ticket" by landing it here (AC1). `uq_table_active_order … where fulfillment_state not in ('SERVED','CANCELLED')` already treats IN_PREP as active.
- **`pos.order_lines`**: `line_state text not null default 'ACTIVE' check (… in ('ACTIVE','VOIDED','COMPED'))` — the ≥1-ACTIVE-line check (AC2) keys on this.
- **`app.current_branch_id()`** ([20260617120001_app_auth_seam.sql](../../supabase/migrations/20260617120001_app_auth_seam.sql)) — now pinned `search_path=''` (migration `…090003`); returns the caller's branch uuid from JWT claims, null if absent.
- **RLS** ([20260617120005_rls_policies.sql](../../supabase/migrations/20260617120005_rls_policies.sql)): `pos.orders` is ENABLE+FORCE RLS, branch-scoped policies; `pos_definer` is non-owner so it **is** subject to them. The explicit `branch_id = v_branch` predicate (AC6) is belt-and-suspenders on top of this.

### Architecture patterns & constraints (carry forward — these are LOCKED)
- **One RPC = one transaction**, `SECURITY DEFINER` owned by `pos_definer`, `SELECT … FOR UPDATE` on the order first, then the FSM guard, then writes, then `return to_jsonb(order)`. [arch §5, §3.5]
- **FSM legality lives in the RPC body, not RLS.** RLS scopes rows; it cannot express transition legality. The guard helper is the single source of truth. [arch §3.5, §4]
- **Two orthogonal axes.** This story only moves the *fulfillment* axis; `financial_state` is untouched (a fired order is still `OPEN` until 1-4). `SERVED+OPEN` and `PAID+DRAFT` are both first-class — never couple the axes. [arch §3, §3.2]
- **`fired_at` is the "confirmation" timestamp.** "Confirmation = the fire action (DRAFT→IN_PREP)." [use-cases Decisions table #1; arch §3.1]
- **Re-fire = reproduce the ticket, never re-consume / never re-sell.** In 1-3 there is no sale row or inventory to duplicate; the rule is enforced structurally by the idempotent IN_PREP short-circuit, and 1-7 must preserve it when it adds consumption. [arch §3.1; use-cases §358; UC-03 A2]
- **Money/snapshot/no-inventory** unchanged — this story records no revenue and no consumption.

### Previous Story Intelligence (1-1 & 1-2 — these bit us; apply them)
- **Explicit branch scope on order lookups (1-2 code-review P2):** always `where id = … and branch_id = v_branch for update`. Do not rely on RLS alone. This is AC6 and is non-negotiable.
- **Supabase CLI statement splitter chokes on `current_user`** in `GRANT … TO current_user` → use the explicit role `postgres`.
- **`ALTER FUNCTION … OWNER TO pos_definer`** requires (a) the migration role be a member of `pos_definer` (`grant pos_definer to postgres;`, already done in 1-1) and (b) `pos_definer` hold `CREATE` on the schema (already granted on `pos`). New functions in schema `pos` are fine; no extra grants needed.
- **Pin `search_path` on every new function** (`SET search_path = …`) to avoid Supabase linter 0011 — we already had to retrofit this in `…090003`. Do it up front here.
- **`SECURITY DEFINER` runs as `pos_definer` (non-owner) so RLS applies** even in superuser-invoked pgTAP — good for coverage.
- **pgTAP `throws_ok` with a 5-char SQLSTATE / a bare code** → use the 4-arg form `throws_ok(sql, 'INVALID_STATE', NULL, 'desc')` so arg 3 isn't mistaken for an expected message.
- **pgTAP isn't visible under `set local role pos_definer`** (no USAGE on `extensions`) — assert with `lives_ok`/`throws_ok` from the postgres context, or wrap role-switched writes in a `DO` block (see [04_rls_write_path.sql](../../supabase/tests/04_rls_write_path.sql)).
- **Applying new migrations locally:** use **`supabase migration up`** against the running stack; `supabase db reset` trips a Realtime container seed bug on CLI v2.101. Run the suite with `supabase test db`.
- **Test claims pattern:** `set local role authenticated; set local request.jwt.claims = '{"sub":"…","branch_id":"…","role":"BARISTA"}'`; use fixed UUIDs distinct from `seed.sql` demo ids. Identity tables are in `app` (Supabase reserves `auth`).
- **Seeding a fired-able order in tests:** insert the order + at least one `pos.order_lines` row (it has NOT-NULL `product_name_snapshot`, `unit_price_minor`, `quantity>0`, `recipe_snapshot jsonb`, `line_subtotal_minor`). As postgres (superuser) you bypass RLS for fixtures; supply `branch_id` on both order and line (denormalized).

### Design decision to surface for the dev / reviewer (AC4)
The breakdown's S-13 phrasing "double-fire race → one wins, loser gets a conflict" is realized here **without** a hard conflict error, because the dedicated idempotency ledger (S-05) is not built until Story 1-5. With pessimistic `FOR UPDATE` + the FSM guard, a double-fire serializes to exactly one `DRAFT→IN_PREP` transition; the second call sees `IN_PREP` and returns success as an idempotent re-fire. This is the architecture's intended behavior ("re-fire reproduces the ticket, no duplicate") and is safe. **If** strict optimistic-conflict signalling is later required, add an optional `p_expected_version` arg and raise `STALE_VERSION` on mismatch — but that belongs with the S-05 idempotency work, not here. Flagged so the reviewer doesn't read the missing hard-conflict as a defect.

### Source tree
```
supabase/
  migrations/
    <ts>_fulfillment_fsm_guard.sql   # pos.assert_fulfillment_transition (S-12)
    <ts>_pos_fire_order.sql          # pos.pos_fire_order (S-13)
  tests/
    07_fire_hold_refire.sql          # new pgTAP file for this story
frontend/                            # NOT touched (UX-blocked)
```

### Testing standards
- pgTAP via `supabase test db` after `supabase migration up`. Cover every AC including negatives (`EMPTY_ORDER`, `INVALID_STATE`, `ORDER_NOT_FOUND`) and the guard matrix edge-by-edge. Re-run the full suite (now `01`–`07`) to prove no 1-1/1-2 regression. Current baseline before this story: 77/77 across 6 files.

### References
- [Source: docs/planning-artifacts/epics.md#1-3 — Fire, hold, and re-fire orders]
- [Source: docs/planning-artifacts/architecture.md#3.1 — Fulfillment state], [#3.5 — Where the FSM is enforced], [#5 — RPC catalog (`pos_fire_order`)]
- [Source: docs/planning-artifacts/pos-order-management-use-cases.md#UC-01 step 5 / A2 (hold)], [#UC-03 A2 (re-fire)], [Gherkin "Order progresses through fulfillment states"], [Decisions table #1 "confirmation = fire", §358 "re-fire does not re-consume"]
- [Source: docs/implementation-artifacts/story-breakdown-epic-1.md — S-12, S-13 (and S-14 dependency to Story 1-7)]
- [Source: docs/implementation-artifacts/1-2-order-type-table-name-assignment.md — RPC/test patterns, code-review patch P2 (explicit branch scope), File List]
- [Source: docs/implementation-artifacts/deferred-work.md — idempotency → S-05; cross-cutting hardening]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Claude Code dev-story)

### Debug Log References

- `supabase migration up` applied both new migrations cleanly to the running local stack; `supabase test db` → 103/103 across 7 files. No CLI splitter / ownership / search_path issues (the 1-1/1-2 lessons were applied up front).

### Completion Notes List

- **S-12 — FSM guard (`pos.assert_fulfillment_transition`):** pure `immutable` PL/pgSQL guard, `search_path=''`, row-constructor `IN` over the 5 legal edges, `INVALID_STATE` otherwise. Execute revoked from `public`, granted only to `pos_definer` (internal helper, not an API surface). It is now the single source of truth for fulfillment legality — 1-6/1-8 will call it unchanged.
- **S-13 — `pos_fire_order`:** one txn, SECURITY DEFINER owned by `pos_definer`, `SELECT … FOR UPDATE` with **explicit `branch_id = v_branch`** (P2 lesson) → cross-branch = `ORDER_NOT_FOUND`. Re-fire of an IN_PREP order short-circuits to an idempotent `fired_at` refresh (no version bump, no second sale). Fire path: guard (rejects READY/SERVED/CANCELLED) → `EMPTY_ORDER` if no ACTIVE line → flip to IN_PREP + stamp `fired_at` + bump `version`.
- **Scope seams honored:** no inventory writes (commented seam for Story 1-7/S-14), no `table_seat` mutation (occupied at create in 1-2), financial axis untouched. Verified by the suite.
- **AC4 concurrency:** realized via pessimistic `FOR UPDATE` + guard + version, not a hard conflict error (idempotency ledger is Story 1-5/S-05) — matches the design decision signed off pre-implementation.
- **Task 4 (optional FSM trigger backstop) deferred** to deferred-work.md — the guard covers correctness; the trigger is pure redundancy until many RPCs exist.
- **No regressions:** full suite 103/103 (77 prior + 26 new).

### File List

- `supabase/migrations/20260619090001_fulfillment_fsm_guard.sql` (new) — `pos.assert_fulfillment_transition` (S-12).
- `supabase/migrations/20260619090002_pos_fire_order.sql` (new) — `pos.pos_fire_order` (S-13).
- `supabase/migrations/20260619090003_pos_fire_order_empty_guard.sql` (new) — code-review patch P1: guard + EMPTY_ORDER moved before the re-fire split (redefines `pos_fire_order`).
- `supabase/tests/07_fire_hold_refire.sql` (new) — 28 pgTAP assertions covering AC1–AC6 incl. the guard matrix, negatives, and the empty-re-fire regression (Section E2).
- `docs/implementation-artifacts/1-3-fire-hold-refire-orders.md` (this story; status/checkboxes/records).
- `docs/implementation-artifacts/sprint-status.yaml` (1-3 → in-progress → review).
- `docs/implementation-artifacts/deferred-work.md` (Task 4 optional trigger backstop logged).

### Change Log

- 2026-06-21 — Story drafted (S-12 + S-13). Scope explicitly excludes inventory consumption (Story 1-7/S-14), table occupancy (done at create in 1-2), READY/SERVED (1-6/S-19), and idempotency-key infra (1-5/S-05). Status → ready-for-dev.
- 2026-06-21 — Implemented S-12 + S-13. Added `pos.assert_fulfillment_transition` guard + `pos_fire_order` RPC (2 migrations) and `07_fire_hold_refire.sql` (26 assertions). Full suite 103/103 green. Optional FSM trigger backstop deferred. Status → review.
- 2026-06-21 — Code review (3 adversarial layers): all 6 ACs verified, scope fences honored. 1 patch applied (P1: EMPTY_ORDER now guards the re-fire path too, migration `…090003` + Section E2 test), 5 items deferred to deferred-work.md, 7 dismissed. Full suite 105/105 green. Status → done.
