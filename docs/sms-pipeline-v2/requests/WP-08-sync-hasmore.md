# Request to WP-01 (from WP-08): `hasMore` in the sync response

**What.** WP-08 says `GET /sms/v2/sync` returns "at most 1,000 rows per entity per call, with `hasMore`". The frozen `contracts/sms/v2/api/sync.response.schema.json` has `additionalProperties: false` and no `hasMore` property, so a body carrying it would fail `validateResponse('sync', ...)` and the Dart side.

**What WP-08 did instead (no contract change).** The server sends the paging signal in a response header, `X-Sms-Sync-Has-More: 1` or `0`. A client can also keep calling while any of `instruments`, `events` or `ledger` has exactly 1,000 rows. The cursor is the same in both cases.

**Suggested change (optional).** Add an optional `hasMore` boolean to `sync.response.schema.json` (a minor, backward-compatible change under "Versioning and change rules"), and have WP-14 read it. Until then WP-14 should read the header or the 1,000-row rule. If the change is approved, WP-08 adds the field next to the header in one line of `sync_route.js`.

**Files.** `contracts/sms/v2/api/sync.response.schema.json` and its embedded Dart copy (`node contracts/sms/v2/embed_dart.js`), plus one fixture. After that, `api/sms_v2_assets/` is refreshed with `node api/scripts/sync_sms_v2_assets.js`.
