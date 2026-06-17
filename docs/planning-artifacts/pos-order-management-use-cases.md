# POS Order Management — User Stories, Use Cases & Acceptance Criteria

**Project:** Multi-Branch Coffee Shop Management System
**Feature:** POS Order Management
**Author:** TRUNG
**Date:** 2026-06-14
**Scope:** Business logic only. No implementation, no schema, no API. Derived from `brainstorm.md` v1.0 and the brainstorming session (`docs/brainstorming/brainstorming-session-2026-06-14.md`).

**Glossary (business terms used below):**
- **Fire / Send to bar** — release an order to be made.
- **Fulfillment state** — where the drink is in being made (Draft → In Prep → Ready → Served).
- **Financial state** — money status of the order (Open/Unpaid → Paid → Closed → Refunded).
- **Void** — remove an item/order *before* it is paid.
- **Refund** — reverse money *after* it is paid (a reversing transaction, partial or full).
- **Comp** — give an item for free with authorization and a reason.
- **Shift / drawer session** — a staff member's open cash session for reconciliation.

---

## 1. User Stories

### Order entry
- **US-01** — As a **Barista**, I want to build an order from products and modifiers quickly, so that I can keep the queue moving at peak.
- **US-02** — As a **Barista**, I want to mark an order as Dine-In or Takeaway, so that the order is handled and served correctly.
- **US-03** — As a **Barista**, I want to assign a Dine-In order to a table, so that staff know where to serve it.
- **US-04** — As a **Barista**, I want to name a Takeaway order (e.g., a customer name), so that the right cup reaches the right person.
- **US-05** — As a **Barista**, I want to add, change, or remove items on an order before it is fired, so that I can correct mistakes without starting over.
- **US-06** — As a **Barista**, I want to hold an order and fire it later, so that I can wait for a customer's group to arrive.

### Payment
- **US-07** — As a **Barista**, I want to take payment by cash, card, or QR, so that customers can pay how they prefer.
- **US-08** — As a **Barista**, I want to enter cash tendered and see the change due, so that I give correct change.
- **US-09** — As a **Barista**, I want to split a bill across multiple payments, so that a group can pay separately.
- **US-10** — As a **Barista**, I want a declined or failed payment to not lock the order, so that the customer can try another method.

### Fulfillment
- **US-11** — As a **Barista**, I want fired orders to appear as tickets to make, so that nothing is missed during a rush.
- **US-12** — As a **Barista**, I want to mark an order Ready and then Served, so that staff and customers know its progress.
- **US-13** — As a **Barista**, I want to re-fire a lost ticket, so that an order isn't forgotten when the bar misses it.

### Corrections, voids, refunds, comps
- **US-14** — As a **Barista**, I want to void an item before payment, so that mistakes don't get charged.
- **US-15** — As a **Manager**, I want to refund a full or partial order after payment, so that I can resolve customer issues fairly.
- **US-16** — As a **Manager**, I want to comp an item with a reason, so that I can handle goodwill and staff drinks while keeping it auditable.
- **US-17** — As a **Manager**, I want every void, refund, comp, and discount to be recorded with who did it and why, so that I can control loss and theft.

### Shift & accountability
- **US-18** — As a **Barista**, I want to open and close a cash drawer session and count cash, so that I can reconcile my shift.
- **US-19** — As a **Manager**, I want to see expected vs. counted cash for a shift, so that I can investigate discrepancies.

### Multi-branch & oversight
- **US-20** — As a **Manager**, I want every order to belong to a branch, so that revenue and stock are attributed correctly.
- **US-21** — As an **Admin**, I want to view orders and refunds across all branches, so that I can oversee the whole business.

### Inventory linkage (business-level)
- **US-22** — As a **Manager**, I want ingredient stock to be consumed when a sale is confirmed, so that stock levels reflect what was sold.
- **US-23** — As a **Manager**, I want a refunded/cancelled order's consumed ingredients to be restored, so that stock stays accurate.
- **US-24** — As a **Barista**, I want to still complete a sale when the system thinks an ingredient is at zero, so that the register never blocks a paying customer.

---

## 2. Use Cases

> Each use case states business behavior only.

### UC-01 — Create and Fire an Order
- **Goal:** Capture a customer's order and release it to be made.
- **Actor:** Barista (primary), Customer (secondary).
- **Preconditions:** Barista is logged in to a branch; an open drawer/shift session exists; products are active.
- **Main Flow:**
  1. Barista starts a new order and selects type (Dine-In or Takeaway).
  2. For Dine-In, Barista assigns a table; for Takeaway, Barista names the order.
  3. Barista adds products; for each, selects applicable modifiers.
  4. System shows running subtotal, applicable discounts, and total.
  5. Barista fires the order (or takes payment first per shop policy).
  6. Order becomes visible as a ticket to make.
- **Alternative Flow:**
  - A1: Barista edits items (add/remove/change modifier) before firing → totals recalculate.
  - A2: Barista holds the order to fire later.
- **Exception Flow:**
  - E1: Selected product is inactive/unavailable → item cannot be added; Barista is informed.
  - E2: Order abandoned (customer leaves) → order remains a Draft and is eligible for stale-draft cleanup; any held table is released.
- **Post Conditions:** Order exists with captured line items and prices snapshotted at time of sale; fulfillment state = In Prep (or Draft if held).

### UC-02 — Take Payment
- **Goal:** Collect money for an order.
- **Actor:** Barista (primary), Customer.
- **Preconditions:** An order exists with a positive balance due.
- **Main Flow:**
  1. Barista selects pay and chooses method (Cash, Card, QR).
  2. For cash, Barista enters tendered amount; system shows change due.
  3. Payment is captured; order balance reduces by the paid amount.
  4. When balance reaches zero, order financial state becomes Paid.
- **Alternative Flow:**
  - A1: Split payment — multiple payments of different methods/amounts are applied until balance is zero.
  - A2: Customer pays after the drink is made (table service) — payment occurs post-fulfillment.
- **Exception Flow:**
  - E1: Card/QR declined or fails → no balance change; order stays Open; another method may be tried.
  - E2: A repeated/duplicate pay action must not charge twice for the same intent.
  - E3: Overpayment in cash → change due reflects the difference.
- **Post Conditions:** Each successful payment is recorded against the order and the open drawer session; order is Paid when balance is zero.

### UC-03 — Fulfill an Order
- **Goal:** Make and deliver the ordered items.
- **Actor:** Barista.
- **Preconditions:** Order has been fired (In Prep).
- **Main Flow:**
  1. Barista sees the ticket and prepares the items.
  2. Barista marks the order Ready.
  3. Barista marks the order Served (Dine-In) or handed over (Takeaway).
- **Alternative Flow:**
  - A1: A drink is remade due to a mistake → fulfillment continues; the remake is recorded as waste, separate from the sale.
  - A2: Ticket lost → Barista re-fires it.
- **Exception Flow:**
  - E1: An ingredient runs out mid-prep → Barista substitutes with authorization; the substitution is recorded.
- **Post Conditions:** Order fulfillment state = Served; order eligible to be Closed once also Paid.

### UC-04 — Close an Order
- **Goal:** Finalize a completed, paid order.
- **Actor:** Barista.
- **Preconditions:** Order is Paid (balance zero) and Served.
- **Main Flow:**
  1. Barista closes the order.
  2. For Dine-In, the table becomes Dirty/Cleaning, then Available.
- **Alternative Flow:**
  - A1: Order is comped to zero with authorization → may be closed without a customer payment.
- **Exception Flow:**
  - E1: Attempt to close an unpaid order without authorization → blocked.
- **Post Conditions:** Order is Closed; revenue is recognized in the branch's business-day bucket; table freed.

### UC-05 — Void an Item or Order (before payment)
- **Goal:** Remove an unpaid item or cancel an unpaid order.
- **Actor:** Barista (item before fire); Manager (after fire, per policy).
- **Preconditions:** The target has not been paid.
- **Main Flow:**
  1. Actor selects an item or the order to void and provides a reason.
  2. System removes the item/order from the bill and recalculates totals.
- **Alternative Flow:**
  - A1: If ingredients were already consumed (order was fired), a restoration of stock is triggered.
- **Exception Flow:**
  - E1: Void requested on a paid order → not allowed; must use Refund instead.
- **Post Conditions:** Voided item/order no longer contributes to revenue; reason and actor recorded.

### UC-06 — Refund an Order (after payment)
- **Goal:** Return money for a paid order, fully or partially.
- **Actor:** Manager (Admin may also).
- **Preconditions:** Order has captured payment; refund amount ≤ amount paid and not already refunded.
- **Main Flow:**
  1. Manager selects the order and the item(s) or amount to refund and provides a reason code.
  2. System records a reversing transaction for the refund amount.
  3. Order financial state becomes Partially Refunded or Refunded accordingly.
- **Alternative Flow:**
  - A1: Partial refund of one item → remaining items stay Paid; order becomes Partially Refunded.
  - A2: Second partial refund → cumulative refunds may not exceed amount paid.
- **Exception Flow:**
  - E1: Refund amount exceeds remaining refundable amount → blocked.
  - E2: Original payment method unavailable → refund issued by an allowed alternative method per policy, recorded as such.
- **Post Conditions:** Refund recorded with actor + reason; consumed ingredients for refunded items are restored; audit entry created.

### UC-07 — Comp / Discount an Order
- **Goal:** Reduce or zero an order's price intentionally.
- **Actor:** Manager (authorizer), Barista (requester).
- **Preconditions:** Authorizer has permission to comp/discount.
- **Main Flow:**
  1. Actor applies a discount (percentage/amount) or comps item(s), selecting a reason.
  2. Totals recalculate; the authorizing user and reason are recorded.
- **Alternative Flow:**
  - A1: Discount applied at item level vs. whole-order level.
- **Exception Flow:**
  - E1: Actor lacks permission → action blocked and logged as an attempt.
- **Post Conditions:** Adjusted total reflects comp/discount; full audit of who/why.

### UC-08 — Open / Close Shift and Reconcile Cash
- **Goal:** Account for cash handled during a shift.
- **Actor:** Barista (own drawer), Manager (oversight).
- **Preconditions:** Barista is logged in; no other open drawer session conflicts on that register.
- **Main Flow:**
  1. Barista opens a drawer session with a starting float.
  2. Cash payments and cash refunds attach to the session during the shift.
  3. At shift end, Barista counts cash and closes the session.
  4. System shows expected vs. counted and any variance.
- **Alternative Flow:**
  - A1: Manager reviews variance and adds a note.
- **Exception Flow:**
  - E1: Attempt to open a second session on the same register → blocked.
- **Post Conditions:** Closed session with expected, counted, and variance recorded.

---

## 3. Acceptance Criteria (Gherkin)

```gherkin
Feature: POS Order Management - Business Rules

  Background:
    Given a barista is logged in to branch "Branch A"
    And an open drawer session exists for the barista

  # --- Order creation ---
  Scenario: Create a dine-in order with modifiers
    When the barista creates a "DINE_IN" order at table "5"
    And adds "Latte" with modifier "Oat Milk"
    Then the order total includes the latte price plus the oat milk surcharge
    And the order is recorded with the prices captured at the time of sale

  Scenario: Edit an order before it is fired
    Given an unfired order with "Latte" and "Espresso"
    When the barista removes "Espresso"
    Then the order total is recalculated to exclude the espresso
    And no inventory has been consumed yet

  Scenario: Abandoned draft does not hold resources
    Given a draft order assigned to table "5"
    When the order is abandoned and the draft is cleaned up
    Then table "5" becomes available
    And no revenue and no inventory consumption are recorded

  # --- Payment ---
  Scenario: Cash payment shows correct change
    Given an order with a total of 50,000
    When the customer pays 100,000 in cash
    Then the change due is 50,000
    And the order financial state becomes "PAID"

  Scenario: Split payment across two methods
    Given an order with a total of 100,000
    When the customer pays 60,000 by "CARD"
    And pays 40,000 by "CASH"
    Then the remaining balance is 0
    And the order financial state becomes "PAID"

  Scenario: Declined card does not lock the order
    Given an order with a balance due
    When a "CARD" payment is declined
    Then the order remains "OPEN"
    And the customer may attempt another payment method

  Scenario: Duplicate payment attempt is not double charged
    Given an order with a total of 50,000 being paid by "CARD"
    When the same payment is submitted twice for the same intent
    Then only one payment of 50,000 is recorded

  # --- Inventory linkage at business level ---
  Scenario: Confirming a sale consumes recipe ingredients
    Given "Latte" consumes 18g beans and 150ml milk
    When an order containing one "Latte" is confirmed
    Then 18g beans and 150ml milk are consumed from "Branch A" stock

  Scenario: Sale is allowed even when stock appears depleted
    Given the system shows 0 beans at "Branch A"
    When the barista confirms an order requiring beans
    Then the sale is completed
    And the stock is flagged as negative for review

  # --- Fulfillment ---
  Scenario: Order progresses through fulfillment states
    Given a fired order
    When the barista marks it "READY"
    And then marks it "SERVED"
    Then the order is eligible to be closed once it is also paid

  Scenario: Remaking a drink records waste separate from the sale
    Given a fired order for one "Latte"
    When the barista remakes the latte after spilling it
    Then exactly one sale is recorded for the latte
    And the spilled latte's ingredients are recorded as waste

  # --- Void vs refund boundary ---
  Scenario: Void an unpaid item
    Given an unpaid order containing "Cake"
    When the barista voids "Cake" with reason "customer changed mind"
    Then the order total excludes "Cake"
    And the void is recorded with the barista and reason

  Scenario: Voiding a paid order is not allowed
    Given a "PAID" order
    When a void is attempted on the order
    Then the action is rejected
    And the user is directed to issue a refund instead

  # --- Refund ---
  Scenario: Full refund of a completed order
    Given a "PAID" and "SERVED" order of 50,000
    When a manager refunds the full order with reason "wrong order"
    Then a reversing transaction of 50,000 is recorded
    And the order financial state becomes "REFUNDED"
    And an audit entry captures the manager and reason

  Scenario: Partial refund of one item
    Given a "PAID" order with "Latte" 40,000 and "Cake" 30,000
    When a manager refunds only "Cake"
    Then a reversing transaction of 30,000 is recorded
    And the order financial state becomes "PARTIALLY_REFUNDED"
    And the consumed ingredients for "Cake" are restored

  Scenario: Cumulative refunds cannot exceed amount paid
    Given a "PAID" order of 70,000 with 30,000 already refunded
    When a manager attempts to refund 50,000
    Then the refund is rejected
    And the maximum refundable amount of 40,000 is shown

  Scenario: Barista cannot refund
    Given a "PAID" order
    When a barista attempts a refund
    Then the action is rejected due to insufficient permission
    And the attempt is logged

  # --- Comp / discount ---
  Scenario: Manager comps an item with a reason
    Given an order containing "Espresso" 25,000
    When a manager comps "Espresso" with reason "staff drink"
    Then the order total is reduced by 25,000
    And the authorizing manager and reason are recorded

  # --- Shift reconciliation ---
  Scenario: Close shift shows cash variance
    Given a drawer session opened with a float of 500,000
    And cash payments totaling 1,200,000 during the shift
    When the barista counts 1,690,000 and closes the session
    Then the expected cash is 1,700,000
    And a variance of -10,000 is recorded

  Scenario: Only one open drawer per register
    Given an open drawer session on register "R1"
    When another session is opened on register "R1"
    Then the action is rejected

  # --- Multi-branch attribution ---
  Scenario: Order is attributed to its branch
    Given a barista logged in to "Branch A"
    When the barista completes an order
    Then the order's revenue and inventory consumption belong to "Branch A"

  # --- Business-day boundary ---
  Scenario: Late sale falls into the correct business day
    Given the branch business day ends at 04:00
    When an order is completed at 23:30 on the 14th
    Then the revenue is recorded in the business day of the 14th
```

---

## Resolved business decisions (this document is now the stable acceptance baseline)

These were carried from brainstorming and are now **locked**. Authority: `epics.md` *Locked architectural decisions* + `docs/planning-artifacts/architecture.md` (POS Order Management). Where `brainstorm.md` v1.0 conflicts, the decisions below win.

| # | Decision | Resolution | Affects |
|---|---|---|---|
| 1 | **Deduction timing** | **At confirmation (fire)** — ingredients are consumed when an order is fired (DRAFT→IN_PREP), as one atomic event, reconciled later by periodic physical count. *Not* tied to a manual prep-state tap. Overrides `brainstorm.md §13` (deduct at PREPARING). | UC-01, UC-05, UC-06; inventory scenarios in §3 |
| 2 | **Pay-before-make vs make-before-pay** | **Both supported, no shop default forced.** The order's fulfillment and financial states are orthogonal, so `PAID + DRAFT` (pay-first) and `SERVED + OPEN` (table service) are both first-class. | UC-02 (A2), UC-03, UC-04 |
| 3 | **Refund model** | **Reversing transaction** (append-only), supporting partial and cumulative refunds capped at amount paid. Never a status flip. | UC-06; refund scenarios in §3 |
| 4 | **Permissions** | **3 base roles + per-action grants** (`VOID_FIRED`, `COMP_DISCOUNT`, `REFUND`). Grants are per-user, not implied by role; blocked attempts are audited. | UC-05, UC-06, UC-07; RBAC matrix in architecture §9 |

**Additional locks confirmed during architecture:**
- **Money** is stored as integer **minor units**; product name / price / modifier surcharge / recipe (BOM) are **snapshotted onto the order line at sale time** — later catalog or recipe edits never alter historical orders, revenue, or COGS.
- **Sales are never blocked** by zero/negative theoretical stock — the system flags for review and completes the sale (US-24, §3 "stock appears depleted").
- **Idempotency:** every payment and refund carries an idempotency key; a duplicate intent records exactly one transaction (UC-02 E2, §3 "duplicate payment").
- **"Confirmation" = the fire action** (DRAFT→IN_PREP). Re-firing a lost ticket reproduces the ticket but does **not** re-consume ingredients — one sale consumes once (UC-03 A2, story 1-6).

> ✅ With these resolved, this document is the **stable acceptance baseline** for the POS Order Management epic. Downstream stories, schema (`architecture.md §4`), and tests should treat the Gherkin in §3 plus the locks above as authoritative.
