---
baseline_commit: 4a6e4b1632390ed8e3901209ddc5c7cad3bf1a99
---

# Story 1.5: Split Payments & Duplicate-Charge Prevention

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **Barista**,
I want to **split a bill across several payments of different methods/amounts without ever double-charging on a retry**,
so that **groups can pay separately and a customer is never charged twice for the same intent**.

> **Scope note (read first).** Story 1-4 already built the append-only ledger, the financial FSM guard, and `pos_take_payment` — and **split already works** because balance is recomputed from the ledger sum on every call (multiple partial payments naturally accumulate to PAID). What 1-5 adds is the **graceful idempotency layer (S-05)**: today a replayed `idempotency_key` hard-fails with a raw `23505`; this story makes a replay return the **original** result with **no second charge, no second `version` bump, and no error** — and turns a cross-order key reuse into a typed error. It also adds the **split-payment regression tests (S-17 / UC-02 A1)**.
>
> This is the realization of the idempotency deferral logged in the **1-4 code review** (deferred-work.md): "graceful replay must short-circuit BEFORE the `version` bump + FSM re-assert." That note is the core design constraint here.
>
> **OUT of scope:** declined digital / gateway (Epic 2 / S-18); refund (1-10); drawer linkage (1-12); applying the idempotency pattern to *other* RPCs (`pos_fire_order` is already idempotent via the FSM; refund will adopt the pattern in 1-10). This story touches **only** `pos_take_payment`.
>
> Maps to **S-05 + S-17**. See [story-breakdown-epic-1.md](story-breakdown-epic-1.md), [architecture.md](../planning-artifacts/architecture.md) §5 (`ON CONFLICT (idempotency_key) DO NOTHING RETURNING`), §13, the §7.3/§duplicate-payment risk-table row, and UC-02 A1/E2 in [pos-order-management-use-cases.md](../planning-artifacts/pos-order-management-use-cases.md).

## Acceptance Criteria

1. **Split across methods reaches PAID.** Multiple partial `pos_take_payment` calls of different methods/amounts accumulate until the balance is 0, at which point the order is `PAID`. Example: on a 100 000-minor order, `CARD 60000` → `PARTIALLY_PAID` (balance 40 000), then `CASH 40000 tendered 40000` → `PAID` (balance 0). Each call carries its **own** idempotency key. *(epics 1-5 AC1; UC-02 A1; S-17)*
2. **A replayed key records exactly one payment and returns the original result.** Submitting `pos_take_payment` twice with the **same** `idempotency_key` (same order) results in exactly **one** `payment_transactions` row; the second call returns the original effect (same `change_minor`, the order's current state, current balance) with **no error**, **no second ledger row**, and **no second `version` bump**. *(epics 1-5 AC2; S-05; arch §5)*
3. **Replay short-circuits before re-validation.** A replay whose original payment already drove the order to `PAID` must **not** raise `ALREADY_PAID` (nor `AMOUNT_EXCEEDS_BALANCE`, nor re-run the FSM guard) — the idempotent hit is detected and returned **before** the balance/state checks. The response is flagged (e.g. `idempotent_replay: true`). *(S-05; resolves the 1-4 review deferral)*
4. **Cross-order key reuse is a typed error.** Reusing an `idempotency_key` that belongs to a **different** order raises a typed `IDEMPOTENCY_KEY_CONFLICT` (not a raw `23505`/PostgREST 409). *(hardening of the global-unique key; addresses a 1-4 review finding)*
5. **Concurrency backstop — never a double charge.** A race between two concurrent calls with the **same new** key produces exactly one row: the insert uses `ON CONFLICT (idempotency_key) DO NOTHING`, and the loser resolves to the replay/typed-error path rather than inserting a duplicate or erroring opaquely. *(arch §5 "duplicate payment"; §3.5 pessimistic lock)*
6. **No regression to 1-4 behavior.** Single-payment cash/card, server-computed change, ledger-derived balance, the financial guard, append-only immutability, branch isolation, and all 1-4 typed errors still hold. *(regression)*

## Tasks / Subtasks

- [x] **Task 1 — Migration: graceful idempotency in `pos_take_payment`** (AC: 2,3,4,5,6) — *breakdown S-05, arch §5*
  - [x] New migration `supabase/migrations/<ts>_pos_take_payment_idempotent.sql` that `create or replace`s `pos.pos_take_payment` (preserves the `pos_definer` owner + execute grant from 1-4). Do **not** edit the shipped 1-4 migration.
  - [x] Keep the existing signature `(p_order_id, p_method, p_amount_minor, p_tendered_minor default null, p_idempotency_key default null)` and all 1-4 input guards (`NO_BRANCH_CONTEXT`, `NO_USER_CONTEXT`, `IDEMPOTENCY_KEY_REQUIRED`, `INVALID_METHOD`, `INVALID_AMOUNT`) and the branch-scoped `SELECT … FOR UPDATE` (`ORDER_NOT_FOUND`).
  - [x] **Replay fast-path (AC3) — placed immediately after locking the order, BEFORE the balance/ALREADY_PAID/amount checks:** `select * into v_existing from pos.payment_transactions where idempotency_key = p_idempotency_key;`
    - if found and `v_existing.order_id <> v_order.id` → `raise exception 'IDEMPOTENCY_KEY_CONFLICT'` (AC4);
    - if found (same order) → recompute balance from the ledger and `return jsonb_build_object('order', to_jsonb(v_order), 'change_minor', v_existing.change_minor, 'balance_minor', v_order.total_minor - v_paid, 'idempotent_replay', true)` — **no insert, no version bump, no FSM re-assert** (AC2/AC3).
  - [x] **Normal path unchanged from 1-4**: balance derive → `ALREADY_PAID`/`AMOUNT_EXCEEDS_BALANCE` → cash/non-cash tender handling → compute change.
  - [x] **Insert with race backstop (AC5):** `insert into pos.payment_transactions (…) values (…) on conflict (idempotency_key) do nothing returning id into v_inserted_id;`
    - if `v_inserted_id is null` (lost a same-key race after the fast-path SELECT) → re-`select` the existing row; if its `order_id <> v_order.id` raise `IDEMPOTENCY_KEY_CONFLICT`, else return the same replay shape as AC2. (Do **not** fall through to the version bump.)
  - [x] On a genuine new insert: recompute `paid`/`balance`, `v_new := case when balance = 0 then 'PAID' else 'PARTIALLY_PAID' end`, `perform pos.assert_financial_transition(...)`, `update pos.orders set financial_state = v_new, version = version + 1 …`, return with `idempotent_replay: false` (or omit the flag).
  - [x] Add `v_existing pos.payment_transactions;` and `v_inserted_id uuid;` declarations. Keep `set search_path = pos, catalog, app, public`.
- [x] **Task 2 — Tests (pgTAP)** (AC: all) — new file `supabase/tests/09_split_idempotent_payment.sql`
  - [x] **Split → PAID (AC1):** 100 000 order; `CARD 60000` (key A) → `PARTIALLY_PAID`, balance 40 000; `CASH 40000 tendered 40000` (key B) → `PAID`, balance 0; assert exactly 2 ledger rows.
  - [x] **Idempotent replay (AC2/AC3):** pay `CARD 50000` (key K) on a 50 000 order → `PAID`; capture `version`. Call again with the **same** key K → returns the same `change_minor`, `idempotent_replay = true`, order still `PAID`, `version` **unchanged**, and exactly **one** ledger row for that key/order. (Critically: the replay does **not** raise `ALREADY_PAID`.)
  - [x] **Mid-split replay (AC2):** after `CARD 60000` (key A) on a 100 000 order, replay key A → returns original (balance still 40 000, `PARTIALLY_PAID`, no new row, version unchanged).
  - [x] **Cross-order key reuse (AC4):** use key A again on a **different** order → `throws_ok 'IDEMPOTENCY_KEY_CONFLICT'`.
  - [x] **Regression (AC6):** re-run the whole suite (`01`–`09`). Spot-check that 1-4's `08` still passes unchanged (single payment, rejections, append-only, branch isolation). Current baseline before this story: 139/139 across 8 files.
  - [x] (Note in a comment) a true two-session concurrency race (AC5) isn't expressible in single-session pgTAP; assert the logical guarantee — the `ON CONFLICT` backstop + replay path mean a same-key second call never creates a second row — via the replay test, and document the `FOR UPDATE` + `ON CONFLICT` reasoning.
- [ ] **Frontend (deferred)** — split-tender UI / multi-payment list is UX-blocked (readiness UX-1), same as prior stories. Not in this story.

### Review Findings (2026-06-21)

_Adversarial review: Blind Hunter + Edge Case Hunter + Acceptance Auditor (money + concurrency scrutiny). All 6 ACs implemented & tested; confirmed clean superset of 1-4. One real money bug found + fixed; two defensive hardenings. 3 patches, 0 deferred, 2 dismissed._

- [x] [Review][Patch] **Cross-branch key collision → false idempotent success (HIGH)** — FIXED in `20260621090002`: the backstop now raises `IDEMPOTENCY_KEY_CONFLICT` when a swallowed conflict's row is RLS-invisible (another branch / uncommitted concurrent). New test proves a branch-B key → typed conflict for a branch-A caller, not a false success.
- [x] [Review][Patch] **Param-mismatch replay (money-safety)** — FIXED in `20260621090002`: both replay branches raise `IDEMPOTENCY_KEY_MISMATCH` when the stored `amount_minor`/`method` differ from the request. New test asserts a same-key/different-amount replay → mismatch.
- [x] [Review][Patch] **Replay could match a future REFUND row** — FIXED in `20260621090002`: both replay SELECTs scoped to `kind = 'CHARGE'` (zero behavior change today).
- Dismissed: **balance-NOW vs balance-at-original** — `change_minor` (this charge's change) and `balance_minor` (the order's current balance) describe two different facts, both correct; documented as the intended contract, not an inconsistency. **owner/grant not re-asserted** — `create or replace` preserves the `pos_definer` owner + execute grant (signature byte-identical); verified safe.

## Dev Notes

### Files this story CREATES (forward-only)
- `supabase/migrations/<ts>_pos_take_payment_idempotent.sql` — `create or replace pos.pos_take_payment` with graceful replay.
- `supabase/tests/09_split_idempotent_payment.sql` — pgTAP for split + idempotency.
- Use the next free timestamp after `20260620090004` (e.g. `20260621090001`). Do **not** edit shipped migrations.

### Files/objects this story MODIFIES-BY-REPLACE (read before editing — preserve 1-4 behavior)
- **`pos.pos_take_payment`** ([20260620090003_pos_take_payment.sql](../../supabase/migrations/20260620090003_pos_take_payment.sql), as built in 1-4): the *current* body locks the order branch-scoped, derives balance from the ledger, validates (`ALREADY_PAID`, `AMOUNT_EXCEEDS_BALANCE`, tender rules), inserts a plain CHARGE (raw `23505` on duplicate key), recomputes state, guards the financial transition, bumps `version`, returns `{order, change_minor, balance_minor}`. **This story inserts the replay fast-path before the validation block and swaps the plain INSERT for `ON CONFLICT … DO NOTHING RETURNING` with a backstop — everything else stays byte-for-byte equivalent.** The 1-4 pgTAP file `08` must continue to pass unchanged.

### Files/objects this story READS (do not modify)
- **`pos.payment_transactions`** ([20260620090001](../../supabase/migrations/20260620090001_payment_transactions.sql) + hardening [20260620090004](../../supabase/migrations/20260620090004_payment_ledger_hardening.sql)): `idempotency_key` is **globally UNIQUE** (`uq_payment_idem`) — this is the locked design (arch §2). Append-only (trigger). The replay SELECT keys on `idempotency_key`.
- **`pos.assert_financial_transition`** ([20260620090002](../../supabase/migrations/20260620090002_financial_fsm_guard.sql)): unchanged; only the *new-insert* path calls it (the replay path must NOT, to avoid `PAID→PAID` → INVALID_STATE on replay).

### Architecture patterns & constraints (LOCKED — carry forward)
- **Idempotency = `INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING …`; on conflict, SELECT and return the original** [arch §5, §444 risk table]. The client generates a key per intent and persists it for retries [S-05]. Global uniqueness of the key is intentional [arch §2].
- **Balance is derived from the ledger**, never the cached total [arch §2]. Split works because each call re-sums.
- **Pessimistic concurrency:** `SELECT … FOR UPDATE` on the order serializes same-order payments; `ON CONFLICT` is the cross-session backstop for the unique key [arch §3.5, §5].
- **One RPC = one transaction**, SECURITY DEFINER as `pos_definer`. Two orthogonal axes — payment never touches `fulfillment_state`.
- **Append-only:** never UPDATE a payment row to "fix" a replay; the replay returns the existing row's data read-only.

### Previous Story Intelligence (1-4 & the 1-4 review — apply directly)
- **The 1-4 review's #1 deferral IS this story's core rule:** the replay must short-circuit **before** `version = version + 1` and before `assert_financial_transition` — otherwise a replay of a now-PAID order re-bumps version and the guard throws `PAID→PAID` INVALID_STATE. Detect the replay right after the order lock.
- **Why a SELECT fast-path AND `ON CONFLICT`:** the fast-path SELECT handles the common sequential retry cleanly (and lets us return the original `change_minor`); `ON CONFLICT` is the backstop for a true concurrent same-key race that slips past the SELECT. Belt and suspenders.
- **Cross-order key reuse** was flagged in the 1-4 review (global key → raw 23505 on a different order). Convert it to `IDEMPOTENCY_KEY_CONFLICT` here.
- **Carry-forward gotchas:** explicit `branch_id = v_branch` on the order lookup (P2); pin `search_path`; `create or replace` preserves owner+grants (no re-`alter`/`grant` needed, but harmless to repeat); pgTAP `throws_ok` 3-arg for named errors / 4-arg for SQLSTATEs; seed TAKEAWAY orders with explicit `total_minor` as postgres; assert RPCs under `set local role authenticated` + claims; apply via `supabase migration up`, run `supabase test db`.
- **Capturing the RPC result in pgTAP:** `select (pos.pos_take_payment(...)->>'change_minor')::bigint` / `->>'idempotent_replay'` / `->>'balance_minor'` — call once inside `is(...)` to avoid an extra charge.

### Source tree
```
supabase/
  migrations/
    <ts>_pos_take_payment_idempotent.sql   # create or replace pos_take_payment (S-05)
  tests/
    09_split_idempotent_payment.sql        # split + idempotency (S-17)
frontend/                                  # NOT touched (UX-blocked)
```

### Testing standards
- pgTAP via `supabase test db` after `supabase migration up`. Prove: split→PAID with 2 rows; same-key replay returns original with no new row / no version bump / no `ALREADY_PAID`; mid-split replay; cross-order reuse → `IDEMPOTENCY_KEY_CONFLICT`. Re-run the full suite (now `01`–`09`) — `08` must pass unchanged (no 1-4 regression).

### References
- [Source: docs/planning-artifacts/epics.md#1-5 — Split payments and duplicate-charge prevention]
- [Source: docs/planning-artifacts/architecture.md#5 — RPC catalog + idempotency pattern], [#13 — idempotency], [risk table "Duplicate payment"]
- [Source: docs/planning-artifacts/pos-order-management-use-cases.md#UC-02 A1 (split) / E2 (duplicate)]
- [Source: docs/implementation-artifacts/story-breakdown-epic-1.md — S-05, S-17]
- [Source: docs/implementation-artifacts/1-4-take-payment-cash-digital.md — pos_take_payment body, Model A, ledger]
- [Source: docs/implementation-artifacts/deferred-work.md — "Graceful idempotency replay" note from the 1-4 review]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Claude Code dev-story)

### Debug Log References

- `supabase migration up` applied the redefinition cleanly; `supabase test db` → 159/159 across 9 files. Story 1-4's `08` passed unchanged (no regression from the create-or-replace).

### Completion Notes List

- **S-05 — graceful idempotency:** `pos_take_payment` redefined (create-or-replace, owner/grants preserved). After the branch-scoped `SELECT … FOR UPDATE`, a **replay fast-path** selects any existing row by `idempotency_key`: same order → returns the original effect (`change_minor`, current state, current balance, `idempotent_replay: true`) with no insert / no version bump / no FSM re-assert; different order → `IDEMPOTENCY_KEY_CONFLICT`. The normal insert uses `ON CONFLICT (idempotency_key) DO NOTHING RETURNING` as a concurrency backstop; a null return resolves to the same replay/conflict path. Critically the replay sits BEFORE the `ALREADY_PAID`/balance checks, so replaying a now-PAID payment returns success instead of erroring (the 1-4 review deferral).
- **S-17 — split:** already supported by the ledger-derived balance; added regression tests (CARD 60000 + CASH 40000 → PAID, 2 rows).
- **Behavioral contrast proven:** a replayed key on a PAID order → `idempotent_replay=true` (test B); a *new* key on a PAID order → `ALREADY_PAID` (test E). Same key across orders → `IDEMPOTENCY_KEY_CONFLICT` (test D).
- **No regression:** full suite 159/159 (139 prior + 20 new); 1-4's `08` unchanged.

### File List

- `supabase/migrations/20260621090001_pos_take_payment_idempotent.sql` (new) — `create or replace pos.pos_take_payment` with graceful replay (S-05) + concurrency backstop.
- `supabase/migrations/20260621090002_pos_take_payment_idem_hardening.sql` (new) — code-review patches P1/P2/P3: backstop conflict null-guard (cross-branch false-success fix), `kind='CHARGE'` replay scope, param-match `IDEMPOTENCY_KEY_MISMATCH`.
- `supabase/tests/09_split_idempotent_payment.sql` (new) — 22 pgTAP assertions: split→PAID, replay (paid + mid-split), cross-order conflict, param-mismatch, cross-branch conflict, ALREADY_PAID regression, branch isolation.
- `docs/implementation-artifacts/1-5-split-payments-idempotency.md` (this story).
- `docs/implementation-artifacts/sprint-status.yaml` (1-5 → in-progress → review → done).
- `docs/implementation-artifacts/deferred-work.md` (1-4 "graceful idempotency replay" deferral marked resolved by 1-5).

### Change Log

- 2026-06-21 — Story drafted (S-05 + S-17). Adds graceful idempotency replay to `pos_take_payment` (short-circuit before version bump + FSM re-assert; `ON CONFLICT` backstop; cross-order reuse → typed error) and split-payment tests. Scope excludes gateway/refund/drawer and other RPCs. Status → ready-for-dev.
- 2026-06-21 — Implemented S-05 + S-17. Redefined `pos_take_payment` with replay fast-path + `ON CONFLICT` backstop + `IDEMPOTENCY_KEY_CONFLICT`; added `09_split_idempotent_payment.sql` (20 assertions). Full suite 159/159 green, no 1-4 regression. Status → review.
- 2026-06-21 — Code review (3 adversarial layers). Confirmed clean superset of 1-4. Found + fixed a HIGH money bug (cross-branch key collision returned a false idempotent success with no payment recorded) plus 2 defensive hardenings (param-match `IDEMPOTENCY_KEY_MISMATCH`, `kind='CHARGE'` replay scope) in `…090002`; 2 dismissed. Added cross-branch + param-mismatch tests. Full suite 161/161 green. Status → done.
