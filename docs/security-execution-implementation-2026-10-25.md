# Remaining-security execution batch — 25 October 2026

The next execution slice implements targeted transaction boundary fixes and bounded retained-history scanning. It also captures the baseline/mobile/route inventories and completes a protected read-only restored-data review. **All 22 scoped findings remain unfinished (19 partial, three open).** No live database connection, migration, deployment, key replacement or feature activation occurred.

## Implemented changes

| Area | Result | Boundary |
| --- | --- | --- |
| Transaction splits | Malformed transaction IDs return 400 before SQL. Valid UUID lookup, ownership checks, fingerprint/retry and replacement behavior remain intact. | Current app callers use canonical UUIDs; broader route-family authorization/input coverage remains. |
| Tag changes | Non-object/array/null payloads, malformed nested tags and non-string timestamps/colors are rejected safely before writes. | Existing app ISO timestamp and color formats remain accepted. |
| Imported tags | The helper validates the complete bounded names array before locks/SQL, preventing a later invalid name from leaving helper-created partial writes. Normalized duplicates retain the first display spelling. | The defensive helper cap is 50; its only production caller already caps statement rows at 30 names, so accepted endpoint payloads are not reduced. Existing transaction wrapping remains. |
| History audit | Opt-in `--history-full-retained` traverses retained commit trees with NUL-safe path handling, object/path deduplication, bounded resources, accurate completed/attempted/read/scanned counters, shallow-clone refusal, bounded finding output and whole suspicious-path redaction. Resource/path truncation is explicit and incomplete. Default sampled mode remains available. | Recognized text within retained release-source paths only. No binary, full-repository or secret-validity/clean-release claim. |

Changed runtime/tool files: [splits](../api/src/transaction_splits.js), [tags](../api/src/transaction_tags.js), [history reviewer](../db/scripts/release_secret_audit.js). Focused regression tests cover malformed input, no-SQL rejection, original spelling, merges/branches/root/deleted/renamed history, unchanged trees, object/path failure and resource-limit completeness.

Coordinator review caught and corrected two issues before verification: normalized duplicate imports initially selected the last spelling, and the history traversal initially rescanned unchanged objects and could overstate early-stop completeness. A separate reviewer checked current transaction compatibility/atomicity against the recorded baseline and found audit path-redaction/output-budget/counter/shallow-history gaps; those were fixed and covered by regressions before the final run. No application storage path or dependency lock changed.

## Verification

[Exact-source verification](../artifacts/security-execution-2026-10-25/verification.json) records commands, hashes, results and limitations. Counts overlap and must not be added into a single suite total.

| Check | Result / scope |
| --- | --- |
| Sanitized API suite | 985 passed, two database-dependent skips; 987 total |
| Sanitized database-tool suite | 164 passed |
| Node 22 Docker boundary/import tests | 24 passed, one DB-dependent skip; cached image, read-only sanitized source, networking disabled |
| Complete product schema and DB integration | Fresh synthetic PostgreSQL 18 migration and checksummed repeat passed. Tag/split/SMS database tests passed 13/13 with zero skips; their synthetic data was rolled back and cluster removed |
| Retained-history text scan | All 646 retained commits completed in the declared scope; 4,204 distinct object/path reads; 52 heuristic flag records remain to classify. Raw values were not emitted. Native/binary and excluded-path coverage remain separate |
| Protected actual-data review | Existing encrypted paired backup restored with original keys into disposable RAM-backed PostgreSQL 17. Product: 357 checks/217 FK checks; auth: 10 checks/five FK checks; zero checked FK orphans. Both new v1 catalogue checks completed with zero duplicate groups/extra rows |

The protected review did **not** run the full pending upgrade or the new uniqueness migration on actual data. Zero current v1 collisions does not reconstruct the historical cap/benefit mapping or prove earlier consumption/usage merges. The original retained keys and data remain unchanged. Restore proof is bound to paired set `4f383a48d3111523e663f8791e4819f0`; its upgrade check remains `not_run`. Two initial local restore attempts stopped at missing command prerequisites; the final run supplied the existing recovery tools on PATH and passed. Their attempt records are retained.

No Flutter source changed, so the app/native suites were not repeated. Earlier app/storage evidence remains dated and unintegrated; this batch does not establish encrypted normal app storage.

## Inventories and remaining gates

- [Baseline](../artifacts/security-execution-2026-10-25/baseline-source.json): 1,311 release-source files captured before agent changes; private environment/key files excluded from that source inventory.
- [Mobile writer/support inventory](../artifacts/security-execution-2026-10-25/mobile-writer-support-inventory.json): foreground and background open paths, SMS/deferred spool, sync/queues, attachments/OCR/export/restore and checked-in platform metadata. Android minimum 24/compile SDK 37 and iOS 15.5 are source declarations, not deployed support evidence. The actual oldest supported/released client and resolved target SDK remain unverified.
- [Route surface inventory](../artifacts/security-execution-2026-10-25/route-surface-inventory.json): 249 literal declarations, 32 middleware mount locations and 37 factory/dynamic review locations. This is source inventory, not a complete effective authorization matrix; mounts/generated routes and role/client acceptance remain.
- Normal DB/receipts/deferred SMS still use plaintext paths. Current signed-out/user/session namespaces also need a compatible adapter to the draft secure-storage account/guest custody model; never rename stored namespaces implicitly during encryption integration.

[Server key-reader inventory](../artifacts/security-execution-2026-10-25/server-key-reader-inventory.json) prepares P05 without changing formats or keys. It identifies the recovery wrapper’s stored key ID with a currently single-key reader, plus unversioned phone/lookup/IMAP readers that need compatible retained-key support before new writes.

P00 is partial while effective route/entity and released-client/platform acceptance inputs are unresolved. P01 has current v1 read-only results; historical reconciliation and complete actual-data upgrade remain. P03 has complete retained-text traversal within its scope; flagged-record classification, native dependencies/binaries/licenses and signed release remain. P04 has a tested transaction-family subset; broader access/payload/capability work remains. P11 records this progress without promoting a finding prematurely.

Next: resolve historical/pending migration decisions and measured index retain/remove choices; expand the route/entity matrix and dependency/secret classification; then implement retained-key readers and complete recovery before changing normal encrypted startup/receipt paths. Keep current feature defaults off until the [implementation plan](security-data-dependency-mobile-documentation-plan-2026-10-25.md) and release gates are met.
