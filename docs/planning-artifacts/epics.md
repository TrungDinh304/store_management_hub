# Epics — Multi-Branch Coffee Shop Management System

**Project:** store_management_hub
**Author:** TRUNG
**Date:** 2026-06-14
**Sources:** `brainstorm.md` v1.0, `docs/brainstorming/brainstorming-session-2026-06-14.md`, `docs/planning-artifacts/pos-order-management-use-cases.md`

**Locked architectural decisions (from brainstorming):**
- Inventory consumption occurs at **order confirmation**, reconciled by periodic physical count (NOT tied to a manual prep-state tap).
- Order has **two state axes**: fulfillment (Draft→In Prep→Ready→Served) and financial (Open→Paid→Closed→Refunded). Supports both pay-before-make and make-before-pay.
- **Refunds are reversing transactions** (support partial), never a status flip.
- **Per-action permissions** for void/refund/comp/discount, layered over the 3 base roles.
- **Money stored as integer minor units**; **price/name/recipe snapshotted at sale time**.
- **Sales never blocked** by zero/negative theoretical stock (flag, don't block).

---

## Epic 1 — POS Order Management (MVP)

**Objective:** Enable one branch to run a full trading day end-to-end — take orders, take money correctly, make drinks, and reconcile the drawer — without falling back to paper.

**Business value:** Throughput at peak, trustworthy revenue and cash reconciliation, and honest inventory consumption that feeds COGS/profit analytics.

**In scope:** Order entry with modifiers, Dine-In/Takeaway, payments (cash + one digital) with split + idempotency, fulfillment states, void/refund/comp with permissions, shift/drawer reconciliation, branch attribution, business-day boundary, inventory consumption at confirmation.

**Out of scope (later epics):** Offline-first sync, KDS hardware, loyalty/promotions engine, multi-branch transfers reporting, AI forecasting, QR self-order.

### Stories

#### 1-1 — Order creation with products and modifiers
**As a** Barista **I want** to build an order from active products and their modifiers **so that** I can capture what the customer wants quickly.
**Acceptance criteria:**
- Given active products, when items + modifiers are added, then totals reflect base price + modifier surcharges captured at sale time.
- Inactive products cannot be added.
- An unfired order's items can be added/removed/changed with totals recalculated.
**Source:** UC-01, US-01/02/05.

#### 1-2 — Order type and table/name assignment
**As a** Barista **I want** to mark an order Dine-In (with table) or Takeaway (with name) **so that** it is served to the right place/person.
**Acceptance criteria:**
- Dine-In requires a table; assigning sets the table Occupied.
- Takeaway captures an order name.
- Abandoned drafts release any held table and record no revenue/consumption.
**Source:** UC-01, US-02/03/04.

#### 1-3 — Fire, hold, and re-fire orders
**As a** Barista **I want** to fire an order to the bar, hold it, or re-fire a lost ticket **so that** nothing is missed during a rush.
**Acceptance criteria:**
- Firing moves fulfillment to In Prep and makes the order visible as a ticket.
- A held order stays Draft until fired.
- Re-firing reproduces the ticket without duplicating the sale.
**Source:** UC-01/UC-03, US-06/11/13.

#### 1-4 — Take payment (cash + one digital), with change
**As a** Barista **I want** to take cash, card, or QR payment and compute change **so that** customers pay their preferred way and receive correct change.
**Acceptance criteria:**
- Cash payment with tendered amount shows correct change.
- Order becomes Paid when balance reaches zero.
- Declined/failed digital payment leaves the order Open for retry.
**Source:** UC-02, US-07/08/10.

#### 1-5 — Split payments and duplicate-charge prevention
**As a** Barista **I want** to split a bill across payments without double-charging **so that** groups can pay separately and customers are never charged twice.
**Acceptance criteria:**
- Multiple payments of different methods/amounts apply until balance is zero.
- A repeated pay action for the same intent records only one payment.
**Source:** UC-02, US-09.

#### 1-6 — Fulfillment progression and waste on remake
**As a** Barista **I want** to advance an order Ready→Served and record remakes as waste **so that** progress is visible and one sale never consumes ingredients twice.
**Acceptance criteria:**
- Order can be marked Ready then Served.
- A remake records exactly one sale and the spoiled unit as waste.
**Source:** UC-03, US-12, US-22.

#### 1-7 — Inventory consumption at confirmation
**As a** Manager **I want** recipe ingredients consumed when a sale is confirmed and never blocked by zero stock **so that** stock reflects sales without freezing the register.
**Acceptance criteria:**
- Confirming an order consumes recipe quantities from the branch's stock.
- Sale completes even when theoretical stock is zero/negative; stock is flagged.
- Cancelled/refunded items restore consumed ingredients.
**Source:** UC-05/UC-06, US-22/23/24.

#### 1-8 — Close order and free table
**As a** Barista **I want** to close a paid, served order **so that** revenue is recognized and the table is freed.
**Acceptance criteria:**
- An order can be closed only when Paid (or comped to zero with authorization) and Served.
- Closing recognizes revenue in the branch business-day bucket and sets the table Dirty→Available.
**Source:** UC-04.

#### 1-9 — Void items/orders before payment
**As a** Barista **I want** to void unpaid items/orders with a reason **so that** mistakes aren't charged.
**Acceptance criteria:**
- Voiding an unpaid item recalculates totals and records actor + reason.
- Voiding a paid order is rejected and directs to refund.
- If ingredients were already consumed, stock is restored.
**Source:** UC-05, US-14.

#### 1-10 — Refund (full and partial) as reversing transaction
**As a** Manager **I want** to refund all or part of a paid order with a reason **so that** customer issues are resolved with full auditability.
**Acceptance criteria:**
- Refund records a reversing transaction; partial refund sets Partially Refunded.
- Cumulative refunds cannot exceed amount paid.
- Baristas cannot refund; attempts are logged.
- Refunded items' ingredients are restored; audit captures actor + reason.
**Source:** UC-06, US-15/17.

#### 1-11 — Comp and discount with authorization
**As a** Manager **I want** to comp items or apply discounts with a reason **so that** goodwill/staff drinks are handled and auditable.
**Acceptance criteria:**
- Comp/discount recalculates totals and records authorizer + reason.
- Users lacking permission are blocked and the attempt is logged.
**Source:** UC-07, US-16/17.

#### 1-12 — Shift/drawer session and cash reconciliation
**As a** Barista **I want** to open/close a drawer session and count cash **so that** I can reconcile my shift.
**Acceptance criteria:**
- Cash payments/refunds attach to the open session.
- Only one open session per register.
- Closing shows expected vs. counted and records variance.
**Source:** UC-08, US-18/19.

#### 1-13 — Branch attribution and business-day boundary
**As a** Manager **I want** every order attributed to its branch and bucketed by a configurable business day **so that** revenue and stock are correct per branch.
**Acceptance criteria:**
- Order revenue and consumption belong to the logged-in branch.
- A configurable business-day boundary buckets late sales correctly.
**Source:** US-20/21, business-day scenario.

---

## Epic 2 — POS Production Hardening (later)

**Objective:** Make the POS resilient and complete for real operations.
**Candidate stories (not yet detailed):** offline-first capture & sync, KDS + ticket routing + receipt printing, tips/gratuity, discounts/promotions engine, periodic physical-count reconciliation workflow, card/QR gateway webhook reconciliation, concurrency hardening (optimistic locking), multi-branch transfer reporting.

---

## Epic 3 — Growth Features (future)

Loyalty/membership/stored value, QR self-ordering & pay-at-table, online/pickup ordering, scheduled pre-orders, AI demand forecasting & auto-purchasing (depends on ≥6–12 months of clean POS data).
