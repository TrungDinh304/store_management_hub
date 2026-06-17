---
stepsCompleted: [1]
inputDocuments: ['brainstorm.md']
session_topic: 'POS Order Management for a Multi-Branch Coffee Shop System'
session_goals: 'Comprehensive feature brainstorm — business goals, actors, flows, edge cases, domain entities, state machines, business rules, future extensions, risks, and MVP vs Production recommendations. Challenge assumptions in the existing spec.'
selected_approach: ''
techniques_used: []
ideas_generated: []
context_file: 'brainstorm.md'
---

# Brainstorming Session Results

**Facilitator:** TRUNG
**Date:** 2026-06-14

## Session Overview

**Topic:** POS Order Management for a Multi-Branch Coffee Shop Management System (Spring Boot 3, Angular 20, PostgreSQL, JWT+PIN, event-based Inventory Ledger)

**Goals:** Produce a critical, comprehensive brainstorm of the POS Order Management feature across 10 dimensions, challenging assumptions baked into the v1.0 spec (`brainstorm.md`).

### Context Guidance

Existing spec `brainstorm.md` defines roles (Admin/Manager/Barista), order lifecycle (DRAFT→CONFIRMED→PREPARING→READY→COMPLETED, plus CANCELLED/REFUNDED), payment (CASH/CARD/QR), and an event-based inventory ledger with deduction at CONFIRMED→PREPARING. This session pressure-tests those decisions.

### Session Setup

Approach: **[3] Hybrid** — full 10-section critical brainstorm delivered, plus 6 open decisions surfaced for the user to resolve collaboratively. Technique: **Assumption Reversal** (attack each spec assumption).

---

## Critical Brainstorm Output

### Key challenges raised against spec v1.0
1. Inventory deduction tied to manual `CONFIRMED→PREPARING` tap is unreliable in a café → recommend theoretical deduction at confirmation + nightly physical-count reconciliation.
2. Single linear order FSM can't represent pay-before-make vs. make-before-pay, nor partial refunds → split into two axes (fulfillment state + financial state).
3. Refund modeled as status flip (`COMPLETED→REFUNDED`) → must be a reversing financial transaction to allow partial refunds + audit integrity.
4. No offline mode → production-blocking for a real shop; decide if MVP or v2.
5. Price/name FK to live catalog → must snapshot price+name+recipe at sale time (most common fatal mistake).
6. 3 hardcoded roles too coarse → action-level permissions for voids/comps/discounts (theft vectors).
7. Missing: Payment-as-entity (1:N), Shift/CashDrawer, Tax line, KitchenTicket, IdempotencyKey, Discount/Comp.
8. Over-engineering for 100 branches / 1M orders before one branch works.

### 10 sections covered
Business goals · Actors · User flows · Edge cases · Domain entities · State machines · Business rules · Future extensions · Risks/mistakes · MVP vs Production recommendations.

### 6 open decisions awaiting user
1. Inventory deduction timing (rec: confirmation + reconciliation)
2. Offline mode in MVP? (architectural fork)
3. Pay-before-make vs make-before-pay (drives two-axis FSM need)
4. Refund model: status flip vs reversing transaction (rec: reversing)
5. Permissions: 3 roles vs action-level
6. v1 scale target: one branch vs real multi-branch deadline

### Recommended next artifacts
`docs/01-domain-model.md` and `docs/02-database-schema.md` once the 6 decisions are locked.

