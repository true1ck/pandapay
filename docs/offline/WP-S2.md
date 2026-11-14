# WP-S2 — idempotent card and card-override creation

Additive. Requests without `id` behave exactly as before (only exception: `POST /card-overrides` now answers 400 `invalid_id` for a non-UUID `userCardId`/`categoryId` instead of a 500; FK/CHECK failures map through `http_db_errors`).

Files: `api/src/user_cards_add.js`, `api/src/card_overrides_write.js` (route call sites in `api/src/index.js`), tests `api/test/card_add_idempotency.test.js`, `api/test/card_overrides_write.test.js`.

## POST /user-cards
Body: `{ cardProductId, nickname?, last4?, id? }` — `id` is an optional client-generated UUID (v4). Invalid `id` -> 400 `{error:'invalid_id'}`.

| Situation | Response |
|---|---|
| New card | 201 `{userCard}` (id = submitted `id` when given) |
| Same `id` already owned by caller (replay) | 200 `{userCard, replayed:true}`; no new row, no repair scheduled |
| Same product+last4 already in wallet | 409 `{error:'card_already_added', message, userCard, clientId?}` — remap local id `clientId` -> `userCard.id` |
| Last4 completes an existing card without one | 200 `{userCard, linkedExisting:true, clientId?}` — same remap |
| Unique identity violation race | 409 `{error:'card_already_added', message, clientId?}` |
| `id` belongs to another profile | 409 `{error:'id_conflict'}` (ownership not revealed) |
| Unknown/unpublished product | 404 (unchanged) |

`clientId` is present only when `id` was submitted. The replay check runs before the product lookup, so a replay still succeeds if the product was later unpublished.

## PATCH /user-cards/:id
last4 unique violation (`uq_user_cards_active_identity`) now 409 `{error:'card_already_added'}` instead of 500.

## POST /card-overrides
Body: `{ userCardId, scope, vpa|merchantName|categoryId (per scope), reasonNote?, id? }`.

| Situation | Response |
|---|---|
| New | 201 `{override}` |
| Same `id` owned by caller | 200 `{override, replayed:true}` (stored row, never overwritten) |
| `id` owned by someone else | 409 `{error:'id_conflict'}` |
| Card not owned/archived | 404 |
| Scope/field mismatch, bad UUIDs | 400 |
| Unknown category (FK) | 409 `{error:'reference_conflict'}` |
| CHECK failure | 422 `{error:'data_rule_violation'}` |

## DELETE /card-overrides/:id
Unchanged: non-UUID 400 `invalid_id` (S0 guard, verified), repeat delete 404 `override not found` (client treats 404-on-delete as success).

## Not done
Sync-queue `user_cards` insert handler: skipped. The legacy writer cannot supply the product lookup / identity-conflict logic without a new SECURITY DEFINER function, which is out of scope. The command-outbox path above is the supported one.

## Tests
New + existing API suite: 2525 tests, 0 fail (known-defect TODO cases excluded). No Postgres available: the primary-key / `ON CONFLICT (id)` behaviour is exercised against a scripted client only; verify on a real DB (a foreign-id collision is hidden by RLS on SELECT, so it surfaces as 23505 on the user_cards PK and as an empty `ON CONFLICT DO NOTHING` result for overrides).
