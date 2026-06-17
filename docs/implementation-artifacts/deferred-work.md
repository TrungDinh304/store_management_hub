# Deferred Work

## Deferred from: code review of 1-1-order-creation-with-modifiers (2026-06-17)

- **Table integrity (→ Story 1-2 / S-11):** `pos_create_order` does not validate that `p_table_id` belongs to the caller's branch; a TAKEAWAY order can carry a `table_id` and silently occupy a table; `uq_table_active_order` is a global partial unique index (not branch-scoped), enabling cross-branch table "squatting"/DoS; a second active order on a table raises raw `23505` instead of a `TABLE_OCCUPIED` domain error. These belong to the table-assignment & occupancy story.
- **Discount underflow (→ comp/discount story S-23):** if `discount_minor` ever exceeds the recomputed subtotal, `total_minor >= 0` CHECK throws `23514` and wedges the order with an opaque error. Discount is always 0 in story 1-1, so latent until discounts ship; add a `DISCOUNT_EXCEEDS_SUBTOTAL` guard then.
- **Idempotency (→ S-05):** `pos_create_order`/`pos_modify_lines` have no idempotency key; a retried request duplicates lines / re-creates orders. Covered when idempotency infrastructure lands.
- **Opaque error surface (cross-cutting hardening):** malformed input (non-UUID ids, non-array `p_ops`, bigint overflow on huge quantity, etc.) surfaces raw Postgres SQLSTATEs instead of named domain errors. Worth a consistent input-validation pass across all RPCs.
- **Auth defense-in-depth:** `app.is_admin()` and `created_by` trust JWT claims without re-validating against `app.user_account`; `current_claims()` is not fail-closed on malformed claims JSON. Acceptable under verified-JWT assumptions, but harden alongside the grants/RBAC story.
