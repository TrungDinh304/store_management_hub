---
stepsCompleted: [1, 2, 3, 4, 5, 6]
documentsInScope:
  - 'architecture.md (PRIMARY architecture — Supabase-native)'
  - 'database-design.md (companion schema)'
  - 'epics.md (epics & stories)'
  - 'pos-order-management-use-cases.md (acceptance baseline)'
documentsExcluded:
  - 'architecture-springboot-migration-target.md (superseded — future migration target only)'
documentsMissing:
  - 'PRD (none found)'
  - 'UX specification (none found)'
---

# Implementation Readiness Assessment Report

**Date:** 2026-06-17
**Project:** store_management_hub

## Step 1 — Document Discovery

### Documents in scope
| Type | File | Status |
|---|---|---|
| Architecture (primary) | architecture.md | ✅ Authoritative (Supabase-native; supersedes Spring) |
| Architecture (DB) | database-design.md | ✅ Companion schema |
| Epics & Stories | epics.md | ✅ |
| Use cases (acceptance baseline) | pos-order-management-use-cases.md | ✅ |

### Excluded / reference-only
- `architecture-springboot-migration-target.md` — explicitly superseded; future migration target (§9). Excluded from scoring.

### Missing (flagged, non-blocking)
- ❌ **PRD** — no `*prd*.md` found. Requirements load currently carried by epics + use-cases docs.
- ❌ **UX specification** — no `*ux*.md` found. Epic-1 frontend stories (S-29…S-32) have no UX artifact.

### Notes
- No sharded document folders; all artifacts are whole files.
- No `project-context.md` present.
- Supporting implementation artifacts (not architecture inputs): `docs/implementation-artifacts/story-breakdown-epic-1.md`, `sprint-status.yaml`.

## Step 2 — PRD Analysis

> ⚠️ **No PRD document exists.** Requirements below are **reconstructed** from the acceptance baseline
> (`pos-order-management-use-cases.md`, US-01…US-24 + locked decisions) and the architecture/DB docs.
> This is a substitute, not a source PRD — treated as a gap in Step 5 scoring.

### Functional Requirements (derived from user stories + locked decisions)

| FR | Requirement | Source |
|---|---|---|
| FR1 | Build an order from active products and their modifiers | US-01 |
| FR2 | Mark an order Dine-In or Takeaway | US-02 |
| FR3 | Assign a Dine-In order to a table | US-03 |
| FR4 | Name a Takeaway order | US-04 |
| FR5 | Add/change/remove items before fire, totals recalc | US-05 |
| FR6 | Hold an order and fire it later | US-06 |
| FR7 | Take payment by cash, card, or QR | US-07 |
| FR8 | Enter cash tendered and show change due | US-08 |
| FR9 | Split a bill across multiple payments | US-09 |
| FR10 | A declined/failed payment must not lock the order | US-10 |
| FR11 | Fired orders appear as tickets to make | US-11 |
| FR12 | Mark an order Ready then Served | US-12 |
| FR13 | Re-fire a lost ticket without duplicating the sale | US-13 |
| FR14 | Void an item before payment | US-14 |
| FR15 | Refund full or partial order after payment (reversing txn) | US-15 |
| FR16 | Comp an item with a reason | US-16 |
| FR17 | Record actor + reason for every void/refund/comp/discount, incl. BLOCKED attempts | US-17 |
| FR18 | Open/close a cash drawer session and count cash | US-18 |
| FR19 | Show expected vs counted cash variance | US-19 |
| FR20 | Every order belongs to a branch | US-20 |
| FR21 | Admin can view orders/refunds across all branches | US-21 |
| FR22 | Consume recipe ingredients when a sale is confirmed (fire) | US-22 |
| FR23 | Restore consumed ingredients on refund/cancel | US-23 |
| FR24 | Complete a sale even when theoretical stock is zero/negative (flag, don't block) | US-24 |
| FR25 | Idempotent payments/refunds — one effect per intent key | Locked decision |
| FR26 | Snapshot name/price/surcharge/recipe at sale time | Locked decision |
| FR27 | Per-action grants (VOID_FIRED, COMP_DISCOUNT, REFUND) over 3 base roles | Locked decision |
| FR28 | Per-branch configurable business-day boundary buckets revenue | US-20/21 + scenario |

**Total FRs: 28**

### Non-Functional Requirements (from architecture + DB design)

| NFR | Requirement | Source |
|---|---|---|
| NFR1 | Multi-branch scale: 100+ branches, 1M+ orders; partition path on `branch_id` | arch §8 |
| NFR2 | Performance: low-latency create-order; zero-network-hop in-DB RPC transactions | arch §5; story-breakdown GAP (<500ms) |
| NFR3 | Security: RLS mandatory + FORCEd, fail-closed, `branch_id` tenant key | arch §4 / DB §8.5 |
| NFR4 | Money exactness: integer minor units, never float/numeric | DB §0 |
| NFR5 | Auditability: append-only payments/inventory/audit (REVOKE + trigger) | DB §6 |
| NFR6 | Idempotency infrastructure for all money/side-effecting ops | arch §13 |
| NFR7 | Portability: vanilla Postgres; credible Spring Boot migration seam (§9) | arch §9 |
| NFR8 | Concurrency correctness: `SELECT … FOR UPDATE`; one active order/table; one open drawer/register | arch §3 / DB §4 |

**Total NFRs: 8**

### Architecture rules / constraints (locked)
- No REST API · No ORM in Phase 1 · CRUD may use Supabase client directly (reads; admin config)
- Transaction-heavy business logic belongs to PL/pgSQL RPC · Edge Functions own orchestration only

### PRD Completeness Assessment
- **Coverage of functional intent: HIGH** — the use-cases doc is unusually complete (goals, flows, exceptions, Gherkin, locked decisions) and serves as a strong acceptance baseline.
- **Formal PRD: ABSENT** — no problem statement, success metrics/KPIs, target personas, scope boundaries beyond epics, or release/MVP cut documented in a single PRD. Traceability has no canonical anchor.
- **NFRs: present but scattered** across architecture/DB docs rather than consolidated; the `<500ms` create-order budget is an open GAP (story-breakdown note 5).

## Step 3 — Epic Coverage Validation

### FR → Epic/Story coverage matrix

| FR | Requirement (short) | Epic 1 story | Status |
|---|---|---|---|
| FR1 | Order from products + modifiers | 1-1 | ✅ |
| FR2 | Dine-In / Takeaway | 1-2 | ✅ |
| FR3 | Assign table (Dine-In) | 1-2 | ✅ |
| FR4 | Name Takeaway | 1-2 | ✅ |
| FR5 | Add/change/remove before fire | 1-1 | ✅ |
| FR6 | Hold and fire later | 1-3 | ✅ |
| FR7 | Pay cash/card/QR | 1-4 | ✅ |
| FR8 | Cash tendered + change | 1-4 | ✅ |
| FR9 | Split bill | 1-5 | ✅ |
| FR10 | Declined payment doesn't lock | 1-4 | ✅ |
| FR11 | Fired orders as tickets | 1-3 | ✅ |
| FR12 | Ready → Served | 1-6 | ✅ |
| FR13 | Re-fire, no duplicate sale | 1-3 | ✅ |
| FR14 | Void before payment | 1-9 | ✅ |
| FR15 | Refund full/partial (reversing) | 1-10 | ✅ |
| FR16 | Comp item with reason | 1-11 | ✅ |
| FR17 | Record actor+reason incl. BLOCKED | 1-10, 1-11 | ✅ |
| FR18 | Open/close drawer + count | 1-12 | ✅ |
| FR19 | Expected vs counted variance | 1-12 | ✅ |
| FR20 | Order belongs to a branch | 1-13 | ✅ |
| FR21 | Admin cross-branch view | 1-13 | ✅ |
| FR22 | Consume on confirmation | 1-7 | ✅ |
| FR23 | Restore on refund/cancel | 1-7 | ✅ |
| FR24 | Sale not blocked at zero stock | 1-7 | ✅ |
| FR25 | Idempotent payments/refunds | 1-5 | ✅ |
| FR26 | Snapshot price/name/recipe | 1-1 | ✅ |
| FR27 | Per-action grants over roles | 1-10, 1-11 | ✅ |
| FR28 | Per-branch business-day bucket | 1-8, 1-13 | ✅ |

### Coverage statistics
- **Total reconstructed FRs:** 28
- **FRs covered by Epic-1 stories:** 28
- **Coverage:** **100%** of the *defined* requirement set

### Caveats (traceability integrity)
1. **The FR set is POS/Epic-1 only.** Because no PRD exists, FRs were derived from the POS use-cases. Epic 2 (production hardening) and Epic 3 (growth) features are **not requirement-traced** — they are candidate bullet lists, not FRs. "100% coverage" means *of what's defined*, not *of the full product vision*.
2. **No reverse gaps:** every Epic-1 story maps to ≥1 FR; no orphan stories.
3. **FR17 BLOCKED-attempt audit** is covered in epics but depends on an unresolved architecture decision (the autonomous-audit pattern) — a quality risk surfaced in later steps, not a coverage gap.

## Step 4 — UX Alignment Assessment

### UX Document Status
❌ **Not Found.** No `*ux*.md` (whole or sharded) in `docs/planning-artifacts/`.

### Is UX implied?
**Yes — strongly.** This is a user-facing, touchscreen-driven POS:
- Tech stack is **Ionic Angular** (a UI framework).
- Epic-1 frontend stories exist and depend on it: **S-29** order-entry + modifier picker, **S-30** tender/payment panel, **S-31** ticket board, **S-32** drawer reconciliation.
- Use cases describe interactive flows: live running totals, change-due display, ticket board "nothing missed during a rush," grant-gated buttons (refund hidden without `REFUND` grant).

### Alignment issues / warnings
| # | Severity | Finding |
|---|---|---|
| UX-1 | ⚠️ HIGH | **No UX specification at all** for a UI-first product. Frontend stories (S-29…S-32) have no wireframes, interaction specs, screen flows, or component inventory to build against — high rework / interpretation risk. |
| UX-2 | ⚠️ MED | **Peak-throughput UX is a stated business goal** ("keep the queue moving at peak," US-01) but there is no UX target for it (taps-to-fire, layout density, one-handed operation). Architecture optimizes backend latency (NFR2) but nothing specifies the *interaction* budget. |
| UX-3 | ⚠️ MED | **Ticket-board freshness UX undecided.** Architecture leaves Realtime-vs-polling open (arch Appendix #6); this is a UX decision (does a ticket appear instantly?) with no owner. |
| UX-4 | ℹ️ LOW | **Grant-gated UI** (hide refund/comp without grant, S-32) is implied but not specified as an explicit UX state/empty-state design. |

### Architecture support (where UX *is* implied)
- **Supported:** live totals (RPC returns authoritative totals), change computation (server-side), branch-scoped reads (RLS), grant-aware UI (claims in JWT).
- **Open / unspecified:** real-time ticket updates (Realtime vs poll), offline capture UX (deferred to Epic 2), error/empty/loading states.

### Verdict
UX is a **material gap** but **non-blocking for backend-first slices** (Track A foundations, RPCs, migrations). It **does block** the frontend stories S-29…S-32 from being built confidently. Recommend a lightweight UX pass (or at minimum low-fi wireframes for the 4 POS screens) before those stories reach `ready-for-dev`.

## Step 5 — Epic Quality Review

### Epic structure
| Check | Epic 1 | Epic 2 | Epic 3 |
|---|---|---|---|
| User-value focus (not technical) | ✅ "run a full trading day" | ⚠️ name "Production Hardening" leans technical; stories are user/ops-facing | ✅ loyalty, QR ordering |
| Independent (no forward dependency on later epic) | ✅ stands alone | ✅ builds on Epic 1 only | ✅ builds on Epic 1+2 (AI needs ≥6–12mo POS data — data dep, valid) |
| Detailed to story level | ✅ 1-1…1-13 | ⚠️ candidate bullets only (expected at this phase) | ⚠️ candidate bullets only (expected) |

**No epic requires a later epic.** Epic independence: **PASS.**

### Story quality (Epic 1)
- **Structure:** every story has As-a / I-want / so-that + acceptance criteria + source mapping. ✅
- **Sizing:** decomposed into 32 ≤1-day slices in the breakdown — strong granularity. ✅
- **Forward dependencies:** none found within Epic 1. Dependencies are all *backward* (e.g. 1-8 close depends on 1-4 pay + 1-6 fulfillment existing). ✅
- **Acceptance criteria:** epics.md ACs are bullet-form rather than strict Given/When/Then, **but** the `pos-order-management-use-cases.md` Gherkin (§3) provides testable BDD scenarios as the baseline. Acceptable — testability is preserved. 🟡

### Findings by severity

#### 🔴 Critical
- **C1 — Story breakdown describes the WRONG architecture.** [story-breakdown-epic-1.md](docs/implementation-artifacts/story-breakdown-epic-1.md) (and S-01) specify a **Spring Boot REST API tier** (`com.smh.pos`, `@Transactional`, REST endpoints). The authoritative [architecture.md](docs/planning-artifacts/architecture.md) **supersedes that** with a Supabase-native, RPC-first, no-REST topology. A developer building S-08/S-13/S-16 from the breakdown today would build the wrong system. **This is the single highest-priority defect.** *Remediation:* regenerate the story breakdown against the Supabase-native architecture (RPCs, Edge Functions, RLS, `supabase-js`), or annotate every slice with its Supabase-native equivalent.

#### 🟠 Major
- **M1 — No greenfield project-setup stories.** This is greenfield (only "first commit" in git; `frontend/` + `supabase/` are untracked scaffolding). There is **no story** for: Ionic Angular app bootstrap, Supabase project/CLI initialization, or CI/CD pipeline. S-01 covers only a backend module skeleton — and in the wrong stack. *Remediation:* add an Epic-1 Story 0 / S-00 "Initialize project (Ionic Angular app + Supabase project + CI)".
- **M2 — Unresolved architecture decisions block specific stories.** Three decisions remain open and gate story readiness: (a) **blocked-attempt audit pattern** → blocks 1-9/1-10/1-11 (FR17); (b) **comp-to-zero close authorization grant** → blocks 1-8/1-11; (c) **inventory sync vs outbox confirmation** → gates 1-7/1-3. *Remediation:* resolve before those stories go `ready-for-dev`.
- **M3 — Upfront schema creation vs create-when-needed.** S-03/S-04 create all order/payment/drawer/audit tables in two foundation migrations rather than each story creating only what it needs. This deviates from the "tables created when first needed" standard. *Mitigation:* defensible for a DB-centric design with cross-cutting RLS — but document the rationale explicitly so it's a decision, not an accident.

#### 🟡 Minor
- **m1 — Epic 2 naming** ("POS Production Hardening") reads as a technical milestone; reframe toward operator value (e.g. "Run the POS reliably in real operations — offline, kitchen display, receipts").
- **m2 — ACs in epics.md** are not strict BDD; rely on the use-cases Gherkin. Consider linking each story to its Gherkin scenarios for traceability.
- **m3 — No PRD/UX anchor** (carried from Steps 2 & 4) weakens long-term traceability as Epic 2/3 are detailed.

### Best-practices compliance checklist
- [x] Epic delivers user value
- [x] Epic can function independently
- [x] Stories appropriately sized
- [x] No forward dependencies
- [~] Database tables created when needed — **deviation (M3)**, mitigated
- [x] Clear acceptance criteria (via Gherkin baseline)
- [x] Traceability to FRs maintained
- [ ] **Greenfield setup story present — FAIL (M1)**
- [ ] **Stories match authoritative architecture — FAIL (C1)**

## Summary and Recommendations

### Overall Readiness Status
**🟠 NEEDS WORK** — *not* NOT-READY (the planning core is strong), but not READY to start coding either.

**Why this verdict:** Requirements coverage is **100%**, the architecture and database design are mature and self-critiqued, and epic/story structure passes the independence and sizing tests. But one **critical** defect (stories describe a retired architecture) plus missing greenfield setup and three unresolved architecture decisions mean a developer starting today would build the wrong thing or stall.

### Scorecard
| Dimension | Result |
|---|---|
| Document discovery | ✅ Clear; 2 missing (PRD, UX) |
| FR coverage | ✅ 28/28 (100% of defined set) |
| NFRs | 🟡 Present but scattered; `<500ms` budget open |
| UX alignment | 🟠 No UX spec for a UI-first product |
| Epic independence | ✅ Pass |
| Story quality | 🟠 Strong structure, but stack-mismatched |
| **Overall** | **🟠 NEEDS WORK** |

### Critical issues requiring immediate action
1. **C1 — Story breakdown targets the wrong (Spring Boot) architecture.** Must be reconciled to the Supabase-native (RPC-first) design before any Epic-1 slice is built.

### Major issues
2. **M1** — Add greenfield project-setup story (Ionic Angular app + Supabase project + CI).
3. **M2** — Resolve 3 open architecture decisions (blocked-attempt audit; comp-to-zero close grant; inventory sync-vs-outbox) — they gate stories 1-7/1-8/1-9/1-10/1-11.
4. **M3** — Document the upfront-schema-migration rationale (or split per-story).

### Lower-priority
5. No PRD (functional intent covered by use-cases; add a thin PRD for traceability/metrics if a stakeholder needs it).
6. No UX spec — blocks frontend stories S-29…S-32; produce low-fi wireframes for the 4 POS screens.
7. Reframe Epic 2 name toward operator value; link story ACs to Gherkin scenarios.

### Recommended next steps (in order)
1. **Fix C1** — regenerate `story-breakdown-epic-1.md` against the Supabase-native architecture (RPCs / Edge Functions / RLS / `supabase-js`). Use `bmad-correct-course` or re-run `bmad-create-epics-and-stories`.
2. **Resolve M2** — get the architect (Winston) to close the 3 open decisions; record them in `architecture.md`.
3. **Add M1** — create the greenfield setup story.
4. **Contextualize story 1-1 → `ready-for-dev`** via `bmad-create-story`, then implement with `bmad-dev-story`.
5. **(Parallel, before S-29…S-32)** — lightweight UX wireframes for the 4 POS screens.
6. *(Optional)* author a thin PRD to anchor traceability as Epic 2/3 are detailed.

### Final note
This assessment identified **10 issues across 5 categories** (1 critical, 3 major, 6 minor/info). The planning foundation is genuinely good — this is a *reconciliation and sequencing* problem, not a *redo-the-thinking* problem. Address C1 and M2 before implementation; the rest can proceed in parallel.

**Assessor:** John (PM) · **Date:** 2026-06-17
