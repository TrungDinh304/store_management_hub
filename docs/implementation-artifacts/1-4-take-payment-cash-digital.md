---
baseline_commit: 42ad03b3096d068b6b0b22ddb7da53b3e1f89bb2
---

# Story 1.4: Take Payment (Cash + Digital), with Change

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **Barista**,
I want to **take a cash, card, or QR payment against an order and have change computed server-side**,
so that **customers pay their preferred way, receive correct change, and the order is marked Paid when the balance reaches zero**.

> **Scope note (read first).** This story opens the **financial axis**. It delivers three breakdown slices: the **payment ledger table** (S-04, *only* `pos.payment_transactions` — the drawer/adjustment/audit tables come with their own stories), the **financial FSM guard** (S-15, the single source of truth for financial edge legality — the money-side twin of the `pos.assert_fulfillment_transition` built in 1-3), and **`pos_take_payment`** (S-16: record a CHARGE, recompute balance from the ledger, advance OPEN→PARTIALLY_PAID→PAID, compute cash change).
>
> **Explicitly OUT of scope (do NOT implement here) — each has a marked seam:**
> - **Drawer/shift linkage.** Architecture §3.4/§5 say a CASH payment must attach to an OPEN `drawer_session`. `drawer_sessions` does not exist yet (Story 1-12 / S-24). So in 1-4 cash is recorded with `tendered`/`change` but `drawer_session_id` stays **NULL** and the "cash requires OPEN drawer" guard is **deferred to 1-12**. (Epics 1-4 explicitly requires cash+change, so cash itself cannot be deferred.)
> - **Graceful idempotency replay.** The `idempotency_key` column is **NOT NULL UNIQUE** now (S-04 AC: "duplicate key fails"), and `pos_take_payment` **requires** a key. But the *graceful* replay (same key → return the original transaction with no error, via `ON CONFLICT … DO NOTHING RETURNING`) is **Story 1-5 / S-05**. In 1-4 a duplicate key is simply rejected by the UNIQUE constraint. **Split / multi-method-until-zero** scenarios are also 1-5 (they work naturally via the ledger sum, but are formally owned/tested there).
> - **Declined / failed digital (UC-02 E1).** Needs the Epic-2 `payments-gateway` Edge Function (S-18). In Epic 1 there is **no DB work**: digital is recorded only on success via the RPC, so a decline = no RPC call = the order simply stays OPEN. Satisfied by construction; nothing to build.
> - **Refund** (1-10/S-25), **comp/discount & comp-to-zero** (1-11), **close→CLOSED + business_day + table→DIRTY** (1-8), **inventory** (1-7). The financial guard *defines* the refund/close edges (single-source-of-truth) but `pos_take_payment` never drives them.
>
> Maps to **S-04 (partial) + S-15 + S-16**. See [story-breakdown-epic-1.md](story-breakdown-epic-1.md), [architecture.md](../planning-artifacts/architecture.md) §2/§3.2/§3.5/§5, [database-design.md](../planning-artifacts/database-design.md), and UC-02 in [pos-order-management-use-cases.md](../planning-artifacts/pos-order-management-use-cases.md).

## Acceptance Criteria

1. **Payment ledger exists, append-only.** A `pos.payment_transactions` table is created per the locked data model (architecture §2): `kind(CHARGE|REFUND)`, `method(CASH|CARD|QR)`, `amount_minor>0`, `tendered_minor?`, `change_minor?`, `idempotency_key` **NOT NULL UNIQUE**, denormalized `branch_id`, `actor`, `created_at`, soft `drawer_session_id?`. It is **append-only**: `UPDATE`/`DELETE` on a payment row is rejected **even for `pos_definer`** (a `BEFORE UPDATE OR DELETE` → `pos.forbid_mutation()` trigger), and `TRUNCATE`/`UPDATE`/`DELETE` are revoked. *(S-04)*
2. **Cash payment computes change server-side and reaches PAID.** `pos_take_payment(order, 'CASH', amount, tendered, idem)` requires `tendered ≥ amount`, records the CHARGE with server-computed `change = tendered − amount` (the client value is never trusted), and when the recomputed balance hits 0 sets `financial_state = 'PAID'`. Example: a 50 000-minor order, `amount=50000`, `tendered=100000` → `change=50000`, state `PAID`. *(epics 1-4 AC1+AC2; UC-02; S-16)*
3. **Card/QR payment is recorded via the RPC (Epic 1, no gateway).** A `CARD`/`QR` CHARGE reduces the balance and advances state the same way; `tendered`/`change` must be NULL for non-cash. *(epics 1-4; S-16; S-18 note)*
4. **Partial payment → PARTIALLY_PAID; balance is always derived from the ledger.** A payment for less than the balance sets `PARTIALLY_PAID`; the financial-state decision recomputes `paid = Σ(CHARGE) − Σ(REFUND)` from `payment_transactions` and **never trusts the cached `total_minor`** as the paid amount. A later payment that closes the balance sets `PAID`. *(architecture §2 "derived-vs-stored"; §3.2; S-15)*
5. **Illegal money moves are rejected by a single reusable guard.** `pos.assert_financial_transition(from, to)` encodes the complete financial matrix and raises `INVALID_STATE` otherwise. **Charge after PAID** (balance already 0) is rejected with a typed error; **non-cash overpay** (`amount > balance`) is rejected; an **amount ≤ 0**, an **unknown method**, or a **missing idempotency key** are typed errors. *(architecture §3.2 "Rejected"; S-15/S-16)*
6. **Idempotency key is mandatory and unique.** `pos_take_payment` requires a non-empty `idempotency_key`; inserting a duplicate key fails (UNIQUE constraint). *(S-04 AC; graceful replay deferred to 1-5)*
7. **Branch isolation (RLS).** `pos.payment_transactions` is ENABLE+FORCE RLS, branch-scoped (admin cross-branch read); direct DML is revoked from `authenticated` (writes only via the RPC). `pos_take_payment` looks the order up with an explicit `branch_id = app.current_branch_id()` predicate → a cross-branch order is `ORDER_NOT_FOUND`. *(architecture §4; carries forward the 1-2 P2 patch)*

## Tasks / Subtasks

- [x] **Task 1 — Migration: `pos.payment_transactions` (append-only ledger) + RLS** (AC: 1,7) — *breakdown S-04 (partial), arch §2/§4/§6*
  - [x] New migration `supabase/migrations/<ts>_payment_transactions.sql`.
  - [x] Table per the data model: `id uuid pk default gen_random_uuid()`, `order_id uuid not null references pos.orders(id)`, `branch_id uuid not null` (denormalized for RLS), `drawer_session_id uuid` (soft ref, **no FK yet** — drawer_sessions is Story 1-12; nullable), `kind text not null check (kind in ('CHARGE','REFUND'))`, `method text not null check (method in ('CASH','CARD','QR'))`, `amount_minor bigint not null check (amount_minor > 0)`, `tendered_minor bigint`, `change_minor bigint check (change_minor is null or change_minor >= 0)`, `idempotency_key text not null`, `reason text`, `actor uuid not null`, `created_at timestamptz not null default now()`.
  - [x] Constraints: `constraint uq_payment_idem unique (idempotency_key)`; cash-only tender: `constraint ck_tender_cash_only check (method = 'CASH' or (tendered_minor is null and change_minor is null))`; `constraint ck_cash_change check (method <> 'CASH' or tendered_minor is null or change_minor = tendered_minor - amount_minor)`. Indexes: `(order_id)`, `(branch_id, created_at)`.
  - [x] **Append-only backstop:** `create function pos.forbid_mutation() returns trigger` (`set search_path = ''`) that `raise exception 'APPEND_ONLY'`; `create trigger … before update or delete on pos.payment_transactions for each row execute function pos.forbid_mutation();`. This fires for **every** role (incl. the table owner / `pos_definer`), so a payment row can never be altered. (Reusable for the other append-only tables in later stories.)
  - [x] Privileges: `grant select, insert on pos.payment_transactions to pos_definer;` `grant select on pos.payment_transactions to authenticated;` `revoke update, delete, truncate on pos.payment_transactions from pos_definer, authenticated;` (defence-in-depth alongside the trigger).
  - [x] RLS: `enable` + `force`; `pt_sel using (app.is_admin() or branch_id = app.current_branch_id())`; `pt_ins with check (branch_id = app.current_branch_id())`. **No** update/delete policies (append-only).
- [x] **Task 2 — Migration: financial FSM guard** (AC: 4,5) — *breakdown S-15, arch §3.2/§3.5*
  - [x] New migration `supabase/migrations/<ts>_financial_fsm_guard.sql`.
  - [x] `pos.assert_financial_transition(p_from text, p_to text) returns void` — `immutable`, `set search_path = ''`, row-constructor `IN` over the legal set, `INVALID_STATE` otherwise. Mirror the structure of `pos.assert_fulfillment_transition` (Story 1-3).
  - [x] Encode the **complete** matrix (single source of truth; 1-8/1-10 reuse it): legal = `OPEN→PARTIALLY_PAID`, `OPEN→PAID`, `PARTIALLY_PAID→PARTIALLY_PAID` (further partial), `PARTIALLY_PAID→PAID`, `PAID→CLOSED`, `PAID→PARTIALLY_REFUNDED`, `PAID→REFUNDED`, `CLOSED→PARTIALLY_REFUNDED`, `CLOSED→REFUNDED`, `PARTIALLY_REFUNDED→PARTIALLY_REFUNDED`, `PARTIALLY_REFUNDED→REFUNDED`. Everything else → `INVALID_STATE`. (Only the four payment edges are exercised in 1-4; the refund/close edges are validated by their own stories — note in a comment, and ensure 1-8/1-10 *call* this guard to avoid the dead-edge gap logged for the fulfillment guard.)
  - [x] `revoke all … from public; grant execute … to pos_definer;` (internal helper).
- [x] **Task 3 — Migration: `pos_take_payment` RPC** (AC: 2,3,4,5,6,7) — *breakdown S-16, arch §5/§7.3*
  - [x] New migration `supabase/migrations/<ts>_pos_take_payment.sql`.
  - [x] `create function pos.pos_take_payment(p_order_id uuid, p_method text, p_amount_minor bigint, p_tendered_minor bigint default null, p_idempotency_key text default null) returns jsonb … security definer set search_path = pos, catalog, app, public`.
  - [x] Input guards (typed): `NO_BRANCH_CONTEXT`, `NO_USER_CONTEXT`, `IDEMPOTENCY_KEY_REQUIRED` (null/blank), `INVALID_METHOD` (not in CASH/CARD/QR), `INVALID_AMOUNT` (`p_amount_minor is null or <= 0`).
  - [x] Lock the order: `select * into v_order from pos.orders where id = p_order_id and branch_id = v_branch for update;` → `ORDER_NOT_FOUND` (explicit branch scope, P2).
  - [x] Derive balance from the **ledger**, not the cache: `v_paid := coalesce(sum(case when kind='CHARGE' then amount_minor else -amount_minor end), 0)` over `payment_transactions where order_id = v_order.id`; `v_balance := v_order.total_minor - v_paid`.
  - [x] `if v_balance <= 0 then raise 'ALREADY_PAID'` (no charge after PAID); `if p_amount_minor > v_balance then raise 'AMOUNT_EXCEEDS_BALANCE'` (can't apply more than owed — covers non-cash overpay).
  - [x] Cash vs non-cash: CASH → require `p_tendered_minor is not null and >= p_amount_minor` else `INSUFFICIENT_TENDER`; `v_change := p_tendered_minor - p_amount_minor`. Non-cash → `p_tendered_minor` must be null else `TENDER_ON_NON_CASH`; `v_change := null`.
  - [x] Insert the CHARGE row (`kind='CHARGE'`, method, amount, tendered (cash only), change, idempotency_key, actor=`app.current_user_id()`, branch). **Leave a comment**: graceful `ON CONFLICT` replay is Story 1-5/S-05; drawer linkage is Story 1-12.
  - [x] Recompute `v_paid := v_paid + p_amount_minor`; `v_balance := v_order.total_minor - v_paid`; `v_new_state := case when v_balance = 0 then 'PAID' else 'PARTIALLY_PAID' end`.
  - [x] `perform pos.assert_financial_transition(v_order.financial_state, v_new_state);` then `update pos.orders set financial_state = v_new_state, version = version + 1 where id = v_order.id returning * into v_order;`.
  - [x] Return `jsonb_build_object('order', to_jsonb(v_order), 'change_minor', v_change, 'balance_minor', v_balance)`.
  - [x] Ownership + grants: `alter function … owner to pos_definer; grant execute … to authenticated;`.
- [x] **Task 4 — Tests (pgTAP)** (AC: all) — new file `supabase/tests/08_take_payment.sql`
  - [x] **Append-only (AC1):** insert a payment row (as postgres), then `throws_ok` on `update` and on `delete` of it (`APPEND_ONLY`); `throws_ok` a duplicate `idempotency_key` insert (`23505`/`unique`); confirm `authenticated` has no direct INSERT (42501).
  - [x] **Guard matrix (AC5):** `lives_ok` for each legal edge; `throws_ok 'INVALID_STATE'` for representative illegal edges (PAID→PARTIALLY_PAID backward, OPEN→CLOSED skip, REFUNDED→PAID, PAID→OPEN). Run as postgres (internal helper).
  - [x] **Cash full → PAID + change (AC2):** seed an OPEN order with `total_minor=50000`; `pos_take_payment('CASH',50000,100000,key)` → returns `change_minor=50000`, `balance_minor=0`; order `financial_state='PAID'`; a `payment_transactions` row exists with `change_minor=50000`.
  - [x] **Card → PAID (AC3):** seed OPEN order 50000; `pos_take_payment('CARD',50000,null,key)` → PAID, `change_minor` null; `TENDER_ON_NON_CASH` when a non-cash call passes a tender.
  - [x] **Partial then close (AC4):** order 50000; pay `CARD 20000` → `PARTIALLY_PAID`, balance 30000; pay `CASH 30000 tendered 30000` → `PAID`, balance 0, change 0. Assert the balance was derived from the ledger (two rows).
  - [x] **Rejections (AC5/6):** `ALREADY_PAID` (charge a PAID order); `AMOUNT_EXCEEDS_BALANCE` (amount > balance, e.g. card 60000 on 50000); `INSUFFICIENT_TENDER` (cash tendered < amount); `INVALID_AMOUNT` (0/negative); `INVALID_METHOD`; `IDEMPOTENCY_KEY_REQUIRED` (null key).
  - [x] **Branch isolation (AC7):** branch B `pos_take_payment` on a branch-A order → `ORDER_NOT_FOUND`; branch A succeeds. Mirror `06_cross_branch_rpc.sql`.
  - [x] Re-run the **whole** suite (`01`–`08`) to prove no regression (current baseline: 105/105 across 7 files).
- [ ] **Frontend (deferred)** — pay sheet / method picker / tender keypad / change display are UX-blocked (readiness UX-1), same as 1-1/1-2/1-3. Track as a follow-on pass; not in this story.

### Review Findings (2026-06-21)

_Adversarial review: Blind Hunter + Edge Case Hunter + Acceptance Auditor (money-grade scrutiny). All 7 ACs implemented; 6 fully tested. 3 patches, 5 deferred, several dismissed. Same-order double-charge verified SAFE (lock-then-read) by all three layers._

- [x] [Review][Patch] Append-only TRUNCATE gap — FIXED in `20260620090004`: statement-level `before truncate` trigger; test asserts `TRUNCATE → APPEND_ONLY`.
- [x] [Review][Patch] `change_minor` without tender — FIXED in `20260620090004`: `ck_change_requires_tender`; test asserts the bad insert → `23514`.
- [x] [Review][Patch] Untested cash-overpay-via-amount — FIXED: added a CASH `amount > balance` → `AMOUNT_EXCEEDS_BALANCE` assertion to `08`.
- [x] [Review][Defer] Graceful idempotency replay (Story 1-5/S-05) MUST short-circuit BEFORE the `version` bump + FSM re-assert — adding `ON CONFLICT DO NOTHING` naïvely would re-bump version / re-run the guard (`PAID→PAID` → INVALID_STATE) on replay [deferred] — implementation note for 1-5
- [x] [Review][Defer] Post-refund re-charge reaches the ledger insert before the guard → opaque `INVALID_STATE` after a wasted insert. Add an up-front payable-state gate (`financial_state not in ('OPEN','PARTIALLY_PAID','PAID') → NOT_PAYABLE`) when refund states become reachable [deferred] — Story 1-10; unreachable today (no refund RPC)
- [x] [Review][Defer] Zero-total / fully-comped order can't be settled by `pos_take_payment` (balance 0 → `ALREADY_PAID`, misleading) — comp-to-zero must drive `OPEN→PAID` directly [deferred] — Story 1-11 (comp) + 1-8 (close) own the zero-total terminal path
- [x] [Review][Defer] Cash-refund-hostile CHECKs — `ck_tender_cash_only`/`ck_cash_change` assume CHARGE semantics; scope them to `kind='CHARGE'` when cash refunds land [deferred] — Story 1-10 (survivable today: a refund with null tender/change passes)
- [x] [Review][Defer] No branch-consistency between `payment_transactions.branch_id` and its order's branch (FK-less soft refs, per codebase convention); a direct owner insert could diverge [deferred] — schema hardening, same class as the 1-2 `(table_id, branch_id)` FK item
- Dismissed: "idempotency broken / scope key to (order_id, key)" — global `idempotency_key UNIQUE` is the LOCKED design (arch §2 line 103) and graceful `ON CONFLICT … RETURNING` replay is explicitly Story 1-5 (arch §266/§444); `public` in the RPC `search_path` — already tracked as cross-cutting hardening from the 1-2 review; `immutable` guard marker — consistent with the fulfillment guard, valid; `version int` overflow — unreachable; `now()` — no money impact; refund/close guard edges untested — owned by 1-8/1-10 (which must call the guard).

## Dev Notes

### Files this story CREATES (all new; forward-only migrations)
- `supabase/migrations/<ts>_payment_transactions.sql` — table + `pos.forbid_mutation()` + append-only trigger + RLS.
- `supabase/migrations/<ts>_financial_fsm_guard.sql` — `pos.assert_financial_transition`.
- `supabase/migrations/<ts>_pos_take_payment.sql` — `pos.pos_take_payment`.
- `supabase/tests/08_take_payment.sql` — pgTAP for this story.
- Use the next free timestamps after `20260619090003` (e.g. `20260620090001/002/003`). Do **not** edit any shipped migration.

### Files/objects this story READS (do not modify)
- **`pos.orders`** ([20260617120003_pos_orders.sql](../../supabase/migrations/20260617120003_pos_orders.sql)): `financial_state text not null default 'OPEN' check (… in ('OPEN','PARTIALLY_PAID','PAID','CLOSED','PARTIALLY_REFUNDED','REFUNDED'))`, `total_minor bigint not null default 0 check (>=0)`, `version`. `total_minor` is the **cache** (architecture §2); the RPC derives `paid`/`balance` from the ledger and only reads `total_minor` as the order total.
- **`app.current_branch_id()` / `app.current_user_id()`** ([20260617120001_app_auth_seam.sql](../../supabase/migrations/20260617120001_app_auth_seam.sql)) — pinned `search_path=''` (migration `…090003`).
- **RLS pattern** ([20260617120005_rls_policies.sql](../../supabase/migrations/20260617120005_rls_policies.sql)) and the **append-only / branch-scope conventions** to mirror.
- **`pos.assert_fulfillment_transition`** ([20260619090001_fulfillment_fsm_guard.sql](../../supabase/migrations/20260619090001_fulfillment_fsm_guard.sql)) — copy its shape for the financial twin.

### Architecture patterns & constraints (LOCKED — carry forward)
- **Balance is derived, never trusted from the cache.** "financial-state transitions always recompute `balance = Σ(CHARGE) − Σ(REFUND)` from `payment_transactions`" [arch §2]. `subtotal/discount/total_minor` are a persisted cache for lists, not a source of truth for paid amount.
- **Money is BIGINT minor units**, never float; all CHECKs `>= 0` (amount strictly `> 0`). Server is authoritative for all money arithmetic, including change [breakdown S-01].
- **Append-only ledgers.** Payment rows are immutable; corrections are *new* rows (a REFUND is a reversing entry, Story 1-10) — never an UPDATE. Enforced by trigger + revoked privileges [arch §6, breakdown S-04].
- **One RPC = one transaction**, SECURITY DEFINER owned by `pos_definer`, `SELECT … FOR UPDATE` on the order first, FSM guard, writes, `return …jsonb`. Idempotency uses `INSERT … ON CONFLICT (idempotency_key)` — the graceful form lands in 1-5 [arch §5].
- **Two orthogonal axes.** `pos_take_payment` touches only `financial_state`; `fulfillment_state` is untouched. `PAID + DRAFT` (pay-first) and `SERVED + OPEN` (table service) are both first-class — never couple them [arch §3].
- **Cash⇒OPEN drawer** is a real invariant but its enforcement + `drawer_session_id` population is **Story 1-12** (table doesn't exist yet). Record cash now; link it then.

### Previous Story Intelligence (1-1/1-2/1-3 — apply these, they bit us)
- **Explicit branch scope on the order lookup** (`where id = … and branch_id = v_branch for update`) — 1-2 code-review P2; this is AC7, non-negotiable.
- **Pin `search_path`** on every new function (guard `''`; RPC `pos, catalog, app, public`) to avoid Supabase linter 0011 — don't make us retrofit it again (`…090003`).
- **`ALTER FUNCTION … OWNER TO pos_definer`** works for new functions in schema `pos` (pos_definer already has CREATE on `pos`, and `postgres` is a member of `pos_definer`). For the new **table**, grant INSERT/SELECT to `pos_definer` explicitly (it is not the owner).
- **`SECURITY DEFINER` runs as `pos_definer` (non-owner) so FORCE RLS applies** even in superuser pgTAP — good for coverage.
- **pgTAP `throws_ok` with a named error** uses the 3-arg form `throws_ok(sql, 'ERROR_NAME', 'desc')` (arg2 = expected message); for a 5-char SQLSTATE use the 4-arg form `throws_ok(sql, '23505', NULL, 'desc')` (lesson from 1-1). A unique-violation is SQLSTATE `23505`.
- **pgTAP isn't visible under `set local role pos_definer`** — assert from postgres or `set local role authenticated` (which *does* have USAGE on `extensions`); see `04`/`05`/`07`.
- **Apply new migrations** with `supabase migration up` (not `db reset` — Realtime seed bug on CLI v2.101). Run the suite with `supabase test db`.
- **Test fixtures:** seed orders directly as postgres (bypasses RLS). For payment tests use **TAKEAWAY** orders (no table_seat needed) with a positive `total_minor` (set it explicitly on insert, since no lines drive it here). Claims pattern: `set local request.jwt.claims = '{"sub":"…","branch_id":"…","role":"BARISTA"}'`; fixed UUIDs distinct from seed demo ids; identity tables in `app`.

### Design decisions to surface for the dev / reviewer
- **`amount` vs `tendered` semantics:** the caller passes `amount` = the charge to apply (must be `≤ balance`) and, for cash, `tendered` = cash handed over (`≥ amount`); `change = tendered − amount`. Cash **overpayment** is expressed via a larger `tendered`, never a larger `amount` — so `amount > balance` is always an error, even for cash. This keeps "you can't pay more toward the order than it owes" uniform across methods while still supporting cash change.
- **Idempotency in 1-4 is the constraint, not the graceful replay.** The key is required and UNIQUE (so a duplicate hard-fails with `23505`); the friendly "same key returns the original transaction, no error" is Story 1-5/S-05. Don't read the missing graceful path as a defect.
- **Full financial matrix encoded now.** The guard includes refund/close edges so it is the single source of truth; `pos_take_payment` only ever drives the 4 payment edges. 1-8 (close) and 1-10 (refund) must *call* this guard (logged so we don't repeat the fulfillment-guard dead-edge gap).

### Source tree
```
supabase/
  migrations/
    <ts>_payment_transactions.sql   # ledger + append-only trigger + RLS (S-04 partial)
    <ts>_financial_fsm_guard.sql    # pos.assert_financial_transition (S-15)
    <ts>_pos_take_payment.sql       # pos.pos_take_payment (S-16)
  tests/
    08_take_payment.sql             # new pgTAP file for this story
frontend/                           # NOT touched (UX-blocked)
```

### Testing standards
- pgTAP via `supabase test db` after `supabase migration up`. Cover every AC incl. negatives (`ALREADY_PAID`, `AMOUNT_EXCEEDS_BALANCE`, `INSUFFICIENT_TENDER`, `TENDER_ON_NON_CASH`, `INVALID_AMOUNT`, `INVALID_METHOD`, `IDEMPOTENCY_KEY_REQUIRED`, `ORDER_NOT_FOUND`, append-only `APPEND_ONLY`/`23505`). Prove balance is ledger-derived via a multi-payment case. Re-run the full suite (now `01`–`08`).

### References
- [Source: docs/planning-artifacts/epics.md#1-4 — Take payment (cash + one digital), with change]
- [Source: docs/planning-artifacts/architecture.md#2 — Domain model (PaymentTransaction, derived balance)], [#3.2 — Financial state], [#3.5 — FSM enforcement], [#5 — RPC catalog (`pos_take_payment`)], [#7.3 — payment sequence]
- [Source: docs/planning-artifacts/pos-order-management-use-cases.md#UC-02 — Take Payment (E1 declined, E2 duplicate, E3 overpay)]
- [Source: docs/implementation-artifacts/story-breakdown-epic-1.md — S-04, S-15, S-16 (and S-05/S-17→1-5, S-24→1-12, S-18→Epic 2)]
- [Source: docs/implementation-artifacts/1-3-fire-hold-refire-orders.md — guard pattern, RPC/test conventions, branch-scope P2]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Claude Code dev-story)

### Debug Log References

- `supabase migration up` applied all three migrations cleanly to the running stack; `supabase test db` → 136/136 across 8 files. No CLI/linter/ownership issues (1-1/1-2/1-3 lessons applied up front).

### Completion Notes List

- **S-04 (partial) — `pos.payment_transactions`:** append-only money ledger per the locked data model. Immutability enforced by a reusable `pos.forbid_mutation()` `BEFORE UPDATE OR DELETE` trigger that fires for every role (proven: even a postgres `UPDATE`/`DELETE` raises `APPEND_ONLY`), plus revoked UPDATE/DELETE/TRUNCATE. `idempotency_key` NOT NULL UNIQUE (duplicate → 23505). RLS ENABLE+FORCE, branch-scoped; `authenticated` has SELECT only (direct INSERT → 42501, proven).
- **S-15 — `pos.assert_financial_transition`:** the money-side twin of the fulfillment guard; full §3.2 matrix encoded (single source of truth), `immutable`, `search_path=''`, execute granted only to `pos_definer`. 1-4 exercises the 4 payment edges; refund/close edges await 1-8/1-10 (which must call this guard).
- **S-16 — `pos_take_payment`:** one txn, SECURITY DEFINER, `SELECT … FOR UPDATE` with explicit `branch_id = v_branch` (P2). Balance derived from the ledger (`Σcharge − Σrefund`), never the cached total. Model A: caller passes `amount` (≤ balance) + cash `tendered` (≥ amount); server computes `change = tendered − amount`. Advances OPEN→PARTIALLY_PAID→PAID via the guard. Typed errors: `ALREADY_PAID`, `AMOUNT_EXCEEDS_BALANCE`, `INSUFFICIENT_TENDER`, `TENDER_ON_NON_CASH`, `INVALID_AMOUNT`, `INVALID_METHOD`, `IDEMPOTENCY_KEY_REQUIRED`, `ORDER_NOT_FOUND`.
- **Scope seams honored:** `drawer_session_id` left NULL (drawer guard → 1-12); graceful idempotency replay → 1-5 (key required + UNIQUE now); declined-digital = no DB work (record only on success); fulfillment/financial axes kept orthogonal (payment never touches `fulfillment_state`).
- **No regressions:** full suite 136/136 (105 prior + 31 new).

### File List

- `supabase/migrations/20260620090001_payment_transactions.sql` (new) — append-only ledger + `pos.forbid_mutation()` trigger + RLS (S-04 partial).
- `supabase/migrations/20260620090002_financial_fsm_guard.sql` (new) — `pos.assert_financial_transition` (S-15).
- `supabase/migrations/20260620090003_pos_take_payment.sql` (new) — `pos.pos_take_payment` (S-16).
- `supabase/migrations/20260620090004_payment_ledger_hardening.sql` (new) — code-review patches P1/P2: BEFORE TRUNCATE trigger + `ck_change_requires_tender`.
- `supabase/tests/08_take_payment.sql` (new) — 34 pgTAP assertions covering AC1–AC7 incl. append-only (update/delete/truncate), guard matrix, cash/card, partial→close, rejections (incl. cash-overpay-via-amount), branch isolation.
- `docs/implementation-artifacts/1-4-take-payment-cash-digital.md` (this story; status/checkboxes/records).
- `docs/implementation-artifacts/sprint-status.yaml` (1-4 → in-progress → review → done).
- `docs/implementation-artifacts/deferred-work.md` (5 code-review deferrals logged 2026-06-21).

### Change Log

- 2026-06-21 — Story drafted (S-04 partial + S-15 + S-16). Scope excludes drawer linkage (1-12/S-24), graceful idempotency replay & split (1-5/S-05/S-17), declined-digital gateway (Epic 2/S-18), refund (1-10), close (1-8), comp (1-11), inventory (1-7). Status → ready-for-dev.
- 2026-06-21 — Implemented S-04(partial)+S-15+S-16. Added `payment_transactions` (append-only ledger + trigger + RLS), `assert_financial_transition` guard, `pos_take_payment` RPC (3 migrations) and `08_take_payment.sql` (31 assertions). Cash Model A (amount + tendered → server change). Full suite 136/136 green. Status → review.
- 2026-06-21 — Code review (3 adversarial layers, money-grade). All 7 ACs verified; same-order double-charge confirmed safe (lock-then-read). 3 patches applied in `…090004` (TRUNCATE trigger, change-requires-tender CHECK, cash-overpay test); 5 items deferred (graceful idempotency → 1-5; payable-state gate → 1-10; zero-total settlement → 1-11/1-8; cash-refund CHECK scoping → 1-10; branch-consistency FK). Full suite 139/139 green. Status → done.
