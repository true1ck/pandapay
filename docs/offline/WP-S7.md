# WP-S7 (server): sync of bill-card assignments, bank balances, subscription overrides

Branch `offline/s7`, built on `feature/offline-first`. Server only; additive; old clients unaffected. Nothing deployed or pushed.

## 1. What was added

| File | What |
|---|---|
| `db/supabase/migrations/20261123060000_user_local_state.sql` | table `user_local_state`, sequence `user_local_state_seq`, RLS owner-only (`profile_id = pandapay.uid()`, forced), `app_user` grants |
| `db/tests/20261123060000_user_local_state_test.sql` | RLS isolation (two profiles), LWW statement shape, tombstone, server_seq, check constraints (kind, key length, payload size/shape, no plaintext `bank_balance`) |
| `api/src/user_local_state_route.js` | `GET /user-state`, `PUT /user-state/:kind/:key`, `DELETE /user-state/:kind/:key` (mounted in `index.js`) |
| `api/test/user_local_state_route.test.js` | 10 scripted-client tests |
| `api/src/portable_backup/coverage.json` | `user_local_state` classified `excluded_with_intent` (see 5) |

Table: `(profile_id, kind, state_key)` primary key; `payload jsonb` (non-sensitive kinds), `payload_enc text` (ciphertext, `bank_balance` only), `client_edited_at`, `deleted`, `updated_at`, `server_seq` (re-numbered on every write, drives the cursor). Kinds: `bill_card_assignment`, `bank_balance`, `subscription_override`. Key 1..200 chars. Payload object, at most 4096 bytes (also a DB check).

Account erase / data reset: both loop over every table having a `profile_id` column (`20261028150000`), so the new table is cleared with no edit; `on delete cascade` covers profile deletion.

## 2. API (all require auth; JSON)

Errors are `{error: <code>}`. `kind` outside the allow-list is `400 invalid_kind`; key not 1..200 chars `400 invalid_key`.

### GET /user-state?since=&kind=
- `since`: optional. Either the `cursor` from a previous response (digits) or an ISO timestamp (matches `updated_at > since`). Bad value: `400 invalid_since`. `kind` optional filter.
- Response `200`:
```json
{ "items": [ { "kind": "subscription_override", "key": "netflix", "payload": {"hidden": true},
               "clientEditedAt": "2026-11-01T10:00:00.000Z", "deleted": false,
               "updatedAt": "2026-11-01T10:00:01.000Z" } ],
  "cursor": "42", "hasMore": false }
```
- Tombstones are returned (`deleted:true`, `payload:null`). Ordered by server change order, at most 500 per page; when `hasMore` is true call again with `since=<cursor>`. With no new items `cursor` echoes `since` (or `"0"`). Store `cursor` as an opaque string.
- `bank_balance` payloads are decrypted for the owner. If a row cannot be decrypted (key removed from the ring, or no ring configured) the item has `payload:null` and `undecryptable:true`; the rest of the page is unaffected. Do not treat that as a delete.

### PUT /user-state/:kind/:key
Body `{ "payload": {...}, "clientEditedAt": "<ISO>", "deleted"?: false|true }`.
- `clientEditedAt` required (`400 invalid_client_edited_at`); more than 5 minutes ahead of the server is clamped to server time.
- Last writer wins per (kind,key): stored `client_edited_at` newer than the request: `200 {"superseded": true, "item": <stored item>}`, nothing written. Equal or older stored: upsert, `200 {"item": ...}`. Replaying the same body is safe.
- `deleted:true` writes a tombstone (payload ignored). A tombstone also loses to a newer stored edit.
- Validation, all `422`: body not an object (`invalid_body`); payload not an object or kind shape wrong (`invalid_payload`); over 4096 bytes (`payload_too_large`). Unknown extra fields are allowed.
  - `bill_card_assignment`: `userCardId` (uuid), `billKey` (non-empty string).
  - `bank_balance`: `amount` (finite number), `accountLabel` (non-empty string; `label` is accepted as an alias).
  - `subscription_override`: optional `hidden:boolean`, `manual:boolean`, `displayName:string`, `amountInr:number`, `cadenceDays:number`, `nextExpectedOn:string`, `autopayStatus:string`.
- `bank_balance` with no encryption key configured: `503 {"error":"encryption_unavailable"}`, nothing stored. Client: treat as retry-later, keep the local value, do not drop the queue row permanently. Other kinds are unaffected.
- DB failures map through `respondDbError` (e.g. `409`/`503 transient_db_error` with `Retry-After`); other errors `500 internal_error`.

### DELETE /user-state/:kind/:key
Header `X-Client-Edited-At: <ISO>` (optional, defaults to server now; clamped like above). Same LWW rule; response `200 {"item": {..."deleted":true,"payload":null}}` or `200 {"superseded":true,"item":...}`. Deleting a missing key creates a tombstone and returns 200 (idempotent). Needs no encryption key.

## 3. Encryption of `bank_balance`

- Reuses the repo's existing sealed-secret mechanism: AES-256-GCM in the API process, the same key ring as stored IMAP passwords (`imap_credentials.js`: `IMAP_ENCRYPTION_KEY`, `IMAP_ENCRYPTION_KEY_ID`, `IMAP_ENCRYPTION_PREVIOUS_KEYS`, loaded into `config.imapKeyring`). The key never reaches PostgreSQL.
- Stored text in `payload_enc`: `v1:<keyId>:<base64(nonce12 || tag16 || ciphertext)>`. The key id is in the envelope, so rotation works exactly as for IMAP: set a new `IMAP_ENCRYPTION_KEY`/`_ID`, move the old one into `IMAP_ENCRYPTION_PREVIOUS_KEYS`; old rows stay readable, new writes use the new key; rows are re-sealed the next time the phone writes them. Dropping an old key makes its rows `undecryptable` (the phone still holds its own copy and re-uploads on its next edit).
- Associated data: `["pandapay-user-state-v1", profileId, kind, key, keyId]`. The label separates this use from IMAP passwords (same key bytes, different AAD), and a ciphertext copied to another row, user or key name fails authentication.
- `payload` is always null for `bank_balance` (route never sets it; a DB check forbids it), and the SQL parameters of a balance write carry only the ciphertext (asserted in the tests). Decryption happens only inside the GET/PUT handlers for the authenticated owner; payloads are never logged (only error codes are).
- No key ring (dev): PUT answers `503 encryption_unavailable`; plaintext is never stored.
- Decision for the owner: this shares the IMAP key ring. If you prefer an independent blast radius, add a dedicated ring (a 2-line change: pass a different `keyring` to `registerUserLocalStateRoutes`).
- Caveat: server-side encryption protects against database/backup leaks, not against someone who holds both the database and the API's environment. The server can read balances.
- Optional future end-to-end variant: the phone encrypts the balance with a key only the user holds (for example derived from a passphrase or kept in the platform keystore with a user-visible recovery code) and uploads `payload_enc` as an opaque blob; the server stores it unseen. No server change beyond accepting a client-supplied `payload_enc`. Trade-off: if the user loses that key the balances are unrecoverable (a phone change without the key means re-typing them), and no server-side feature can ever read them.

## 4. Verification

- `node --test test/user_local_state_route.test.js`: 10/10 pass (LWW/superseded, tombstone, replay, validation, clamp, ciphertext-only with SQL params inspected, AAD binding + key rotation + missing key, 503 without ring, pagination, db error mapping).
- Migration and `db/tests/20261123060000_user_local_state_test.sql` were run on PGlite in a temp dir outside the repo (with a stub `profiles` and `pandapay.uid()` and an `app_user` role, so the RLS policy was exercised as `app_user`): pass. **Not run on a real PostgreSQL** (no `psql`/`initdb`): run the SQL test on a migrated scratch DB before deploy. The route's upsert (`ON CONFLICT ... WHERE`, `nextval`) was only exercised against a scripted fake client in Node; its SQL shape is mirrored in the SQL test.
- `portable_backup_*` pass; `migration_prefix_policy` pass.

## 5. Notes

- `db/security/product-runtime-privileges.json` lists routine access, not tables; no table entry exists for budgets or user_commitments, so none was added. The table grants live in the migration like the other user tables.
- Portable backup: classified `excluded_with_intent`. Exporting would put balances in a plaintext archive; the phone re-pulls `/user-state` after a restore instead.
- Rows written by a replayed PUT get a new `server_seq`, so another phone may re-receive an unchanged item once. Harmless (LWW on the client).
