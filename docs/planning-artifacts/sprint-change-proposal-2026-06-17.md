# Sprint Change Proposal — Reconcile Story Breakdown to Supabase-Native Architecture

**Project:** store_management_hub · **Author:** John (PM) · **Date:** 2026-06-17
**Trigger:** Implementation-readiness finding **C1** (see `implementation-readiness-report-2026-06-17.md`)
**Mode:** Batch · **Output:** rewrite `story-breakdown-epic-1.md` in place · **Open decisions (M2):** flagged, not resolved

---

## Section 1 — Issue Summary

The Epic-1 implementation breakdown (`docs/implementation-artifacts/story-breakdown-epic-1.md`) was authored against a **Spring Boot REST API tier** ("Angular → REST → Spring Boot → Supabase PostgreSQL"). The authoritative architecture (`architecture.md`, dated 2026-06-15) **superseded that design** with a **Supabase-native, RPC-first topology**: Angular/Ionic + `supabase-js` → PostgREST/RPC → PL/pgSQL, with RLS as the tenant boundary and Edge Functions for orchestration only. No REST, no ORM in Phase 1.

A developer building from the current breakdown would implement the wrong architecture (Java services, REST controllers, `@Transactional`, request-scoped principals) instead of SECURITY DEFINER RPCs, RLS policies, and `supabase-js` calls.

**Evidence:** breakdown platform note ("Spring Boot API tier (business logic)"); S-01 ("`com.smh.pos` module", "AuthProvider port", "Spring Modulith"); S-08/S-09/S-16 REST endpoints; S-14 outbox/event-consumer framing already contradicted by architecture §F2 (in-transaction consume).

## Section 2 — Impact Analysis

- **Epic impact:** NONE at epic/story level. Stories 1-1…1-13, their ACs, and the 28 FRs remain valid and fully covered. The change is confined to *how* slices are implemented.
- **Story (slice) impact:** all 32 `S-NN` slices need tech-mapping revision (Java/REST → RPC/Edge/RLS/`supabase-js`). Severity ranges from cosmetic (S-03/S-04 were already plain-SQL migrations) to substantial (S-01, S-05, S-06, S-07).
- **New slice required (M1):** add **S-00** greenfield project initialization (Ionic Angular app + Supabase project/CLI + CI). Currently absent.
- **Artifact conflict:** `database-design.md` §8.5 uses `SET LOCAL app.current_branch` (Spring mechanism). Architecture §4 uses `auth.jwt()` via `app.current_branch_id()`. **Resolution:** breakdown follows architecture §4 (Supabase-native); DB §8.5's GUC form is the §9 migration target. *Recommend a one-line note added to DB §8.5 — tracked as a follow-up, not done in this proposal.*
- **Decision-matrix fold-in:** every slice gains an explicit call-path tag — **Angular-only / →Supabase Client (read) / →RPC / →Edge Fn→RPC** — from the RPC-vs-Edge matrix produced this session.
- **Technical impact:** test stack changes (pgTAP for RPCs + Deno test for Edge Fns + Angular tests, instead of JUnit). CI runs `supabase db push`. Deploy: Vercel (frontend) + Supabase (backend).

## Section 3 — Recommended Approach

**Option 1 — Direct Adjustment (SELECTED).** Rewrite slice internals within the existing epic/story structure; add one setup slice. Effort **Medium**, risk **Low**, timeline impact **none** (nothing is built yet). Options 2 (rollback) and 3 (MVP review) are N/A — no code exists and scope is unchanged.

## Section 4 — Detailed Change Proposals (per-slice old → new)

> Call-path legend: **UI** = Angular only · **RD** = → Supabase Client (read) · **RPC** = → RPC · **EF** = → Edge Fn → RPC

### Track A — Foundations
| Slice | OLD (Spring) | NEW (Supabase-native) | Path |
|---|---|---|---|
| **S-00** *(NEW, M1)* | — | **Project init:** `supabase init` + linked project; Ionic Angular app scaffold + `supabase-js` client; CI = `supabase db push` + Vercel deploy; `.env` for anon key only | UI/RD |
| S-01 | `com.smh.pos` module, AuthProvider port, Spring Modulith, request-scoped principal | **Auth & tenant seam:** Supabase Auth (PIN/password→JWT); **Custom Access Token Hook** injects `branch_id`/`role`/`grants`; `app.current_branch_id()` + `app.is_admin()` helpers; DB roles (`authenticated` non-bypass, `pos_definer` definer-owner); **REVOKE table DML from `authenticated`**; boot assertion it cannot INSERT | RPC infra |
| S-02 | `Money` Java VO | **Money convention:** `BIGINT` minor-unit discipline + CHECK ≥0 in SQL; small TS helper in Angular for display/format (no float) | UI |
| S-03 | Migration: order tables (already SQL) | **Unchanged** — Supabase CLI plain SQL; drop "`@Version`" Java phrasing (keep `version int` column) | — |
| S-04 | Migration: payment/drawer/adjustment/audit | **Unchanged**; `REVOKE UPDATE,DELETE` from **`pos_definer`+`authenticated`** (not "app_role") | — |
| S-05 | HTTP `Idempotency-Key` interceptor | **In-RPC idempotency:** `INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING`; client generates key per intent | RPC |
| S-06 | `REQUIRES_NEW` audit writer | **Append-only audit RPC helper** (success path in-txn); **blocked-attempt via Edge Fn wrapper** that catches typed RPC error and logs in its own txn ⚠️*(M2-a open)* | RPC/EF |
| S-07 | Spring annotation/guard RBAC | **Live grant re-check inside RPCs** (`EXISTS auth.user_grant …`, not stale JWT); blocked attempts audited via S-06 | RPC |

### Track B — Order lifecycle
| Slice | OLD | NEW | Path |
|---|---|---|---|
| S-08 | `POST /api/pos/orders` | RPC `pos_create_order` — DRAFT/OPEN, stamp `branch_id` from JWT | RPC |
| S-09 | `PATCH /orders/{id}/lines` | RPC `pos_modify_lines` — snapshot price/recipe, recalc, DRAFT-only | RPC |
| S-10 | modifier endpoint | folded into `pos_modify_lines` (surcharge snapshot) | RPC |
| S-11 | assign endpoint | table assign/clear + `AVAILABLE→OCCUPIED` inside create/modify txn | RPC |
| S-12 | Java FSM guard | `pos.assert_fulfillment_transition(from,to)` PL/pgSQL helper + pgTAP | RPC |
| S-13 | `POST /fire` + emit `OrderConfirmed` | RPC `pos_fire_order`; Realtime/trigger notify is *optional*, not a correctness dep | RPC |
| S-14 | event consumer / outbox seam | **In-txn** `INSERT inventory.SALE` inside `pos_fire_order` (arch §F2 — no outbox); restore on void/refund ⚠️*(M2-c: arch F2 already resolves to in-txn; confirm)* | RPC |

### Track C — Money
| Slice | OLD | NEW | Path |
|---|---|---|---|
| S-15 | Java financial FSM | `pos.assert_financial_transition()` + balance derived from `payment_transactions` | RPC |
| S-16 | `POST /payments` | RPC `pos_take_payment` (cash; server-computed change; cash⇒OPEN drawer). Card/QR recorded via RPC in Epic 1; gateway is Epic 2 | RPC |
| S-17 | split + idempotent | multiple `pos_take_payment`, `ON CONFLICT` dedup | RPC |
| S-18 | declined digital | **Epic-2 dependent** (gateway Edge Fn returns 402, no RPC write). Epic-1: N/A until gateway exists — flag | EF |

### Track D — Completion & corrections
| Slice | OLD | NEW | Path |
|---|---|---|---|
| S-19 | ready/served + waste | RPC `pos_advance_fulfillment` + `inventory.WASTE` row | RPC |
| S-20 | `POST /close` | RPC `pos_close_order` — CLOSED + `business_day` + table→DIRTY ⚠️*(M2-b: comp-to-zero grant open)* | RPC |
| S-21 | void endpoint | RPC `pos_void` — restore if fired; `VOID_FIRED` grant; blocked-audit ⚠️*(M2-a)* | RPC |
| S-22 | refund endpoint | RPC `pos_refund` — live `REFUND` grant, ceiling under `FOR UPDATE`, reversing row, restore; blocked-audit ⚠️*(M2-a)* | RPC |
| S-23 | comp/discount endpoint | RPC `pos_adjust` — `COMP_DISCOUNT` grant, recalc, audit | RPC |

### Track E — Shift / drawer
| Slice | OLD | NEW | Path |
|---|---|---|---|
| S-24 | `POST /drawer-sessions` | RPC `pos_open_drawer` (one-open-per-register index) | RPC |
| S-25 | attach cash | cash linkage inside `pos_take_payment`/`pos_refund` (no separate endpoint) | RPC |
| S-26 | `POST /close` drawer | RPC `pos_close_drawer` — expected/variance | RPC |

### Track F — Multi-branch & business day
| Slice | OLD | NEW | Path |
|---|---|---|---|
| S-27 | business-day bucketing | computed in `pos_close_order` (server `now()` + branch cutoff) | RPC |
| S-28 | RLS + GUC from app | **RLS policies via `auth.jwt()` seam** (not `SET LOCAL`); admin read via `is_admin()`; WITH CHECK blocks cross-branch write; 404 on cross-branch; boot assert no `service_role` in browser | RPC/RD |

### Track G — Frontend (Ionic Angular)
| Slice | OLD | NEW | Path |
|---|---|---|---|
| S-29 | order-entry page (→REST) | page calls `supabase-js.rpc()` for writes, `.from().select()` for catalog reads ⚠️*(blocked by UX gap)* | UI/RPC/RD |
| S-30 | tender panel (→REST) | tender pad; generates idempotency key per intent; `.rpc('pos_take_payment')` ⚠️*(UX)* | UI/RPC |
| S-31 | ticket board (→REST) | RLS-filtered `.from().select()` (+ optional Realtime); advance via RPC ⚠️*(UX)* | RD/RPC |
| S-32 | drawer screen (→REST) | open/close via RPC; grant-gated buttons from JWT claims ⚠️*(UX)* | UI/RPC |

### New Edge Function inventory (introduced by reconciliation)
- **`pos_log_blocked_attempt` wrapper** (M2-a) — guarantees BLOCKED audit survives RPC rollback.
- **`stale-draft-cleanup`** (cron) — UC-01 E2.
- **Epic 2 (noted, out of Epic-1 scope):** `payments-gateway`, `payments-webhook`, `receipt-render`.

## Section 5 — Implementation Handoff

- **Scope classification:** **Moderate** — backlog/breakdown reorganization, no strategic replan.
- **Recipients:** PM/Dev (this rewrite) + Architect (the 3 flagged M2 decisions) + UX (S-29…S-32 wireframes, separate track).
- **Success criteria:** `story-breakdown-epic-1.md` contains zero Spring/REST references; every slice carries a call-path tag; S-00 exists; M2 items marked blocked-pending-decision; epic/story (1-1…1-13) structure and `sprint-status.yaml` unchanged.

## Flagged for the Architect (M2 — not resolved here)
- **M2-a** Blocked-attempt audit mechanism (affects S-06/S-21/S-22/S-23).
- **M2-b** Comp-to-zero close authorization grant (affects S-20/S-23).
- **M2-c** Inventory consume sync-vs-outbox — *architecture §F2 already chose in-transaction*; recommend formally closing this as resolved.
