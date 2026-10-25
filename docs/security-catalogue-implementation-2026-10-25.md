# Catalogue identity and gap-review implementation — 25 October 2026

This batch implements the next D05 source remedy and corrects W03 catalogue comments. **D05 is partial; W03 remains partial.** No live migration, deployment, key change or feature activation occurred. The normal mobile storage and recovery flags remain disabled. All 22 unfinished D/N/M/W findings are listed in the [per-finding gap review](security-focused-gap-review-2026-10-25.md).

## Implemented behavior

- [Versioned identity](../api/src/catalogue_label_identity.js) folds ASCII A–Z and collapses/trims ASCII space, TAB, LF, VT, FF and CR. Non-ASCII case, accents, nonbreaking spaces and punctuation remain exact. Stored display labels remain unchanged. This conservative v1 contract does not authorize Unicode identity merging.
- The [additive migration](../db/supabase/migrations/20261025074636_catalogue_label_identity_v1.sql) adds unique expression indexes for cap rules and benefits with the same expression used by the read-only reviewer. Every other existing business discriminator remains in the key. `NULLS NOT DISTINCT` prevents nullable-key duplicates while preserving null versus empty-string distinctions.
- Existing raw-label unique indexes remain. A bounded full-visibility preflight refuses normalized collisions with a fixed message before creating either new index. It never selects a survivor, rewires references, or updates/deletes labels, IDs, cap consumption or lounge history.
- Admin create/update routes return HTTP 409 `rule_definition_conflict` for either retained or new identity indexes. Unrelated failures retain the existing safe error response. Successful display-label and audit behavior remain intact.
- The [cleanup reviewer](../db/scripts/review_data_cleanup.js) has separate v1 cap/benefit checks. Its older broad label/name candidate checks remain locale-sensitive and are explicitly described separately. Candidate equality is not merge approval. Historical actual-data results did not run the new v1 checks.
- [Catalogue comments](../api/src/index.js) now describe source migration 0015 and the published/active export filter. API authorization, table RLS, owner bypass and effective target acceptance are distinguished.

## Transaction and migration limits

PostgreSQL 15+ is required; this batch's disposable local integration used PostgreSQL 18.4. The migration checks exact current column names, refuses an already-present v1 index outside its ledger, caps each table review at 100,000 rows, sets a two-second lock timeout and a 30-second per-statement timeout, and holds a writer-conflicting lock across the checks and index creation. A busy writer causes rollback rather than an unbounded migration wait. Timings on real data and the intended provider remain unaccepted.

The supported checksummed migration runner owns the transaction and safely skips an already-applied file. Manual SQL replay refuses existing v1 names for review. Do not edit applied migration history or remove its ledger entry. The historical dedupe migration remains byte-for-byte unchanged and can mutate data if pending: **review the complete pending inventory and historical mapping/state reconciliation before running the full candidate on any real dataset.** This additive migration does not make earlier destructive migrations safe.

No new SQL function, definer, trigger, table or grant is added. Expression indexes enforce uniqueness for every writer. Imports with colliding definitions must be reviewed and rehearsed; silently dropping an import row or merging state is not part of this remedy.

## Verification

[Machine-readable evidence](../artifacts/security-catalogue-2026-10-25/verification.json) records the commands, source hashes and scope.

| Check | Result / boundary |
| --- | --- |
| Sanitized full API suite | 981 passed, two database-dependent tests skipped; 983 total |
| Sanitized database-tool unit suite | 155 passed |
| Cached Node 22 Docker route/validation checks | 25 passed; networking disabled and source read-only; overlaps full API suite |
| Disposable PostgreSQL integration | Actual base catalogue/history schema, matching SQL/JS identity, both-table collision refusal, unknown-column refusal, lock timeout, transaction rollback, all other rule discriminators, null/empty distinction, conservative Unicode behavior, competing writers and failed-update preservation passed |
| Source publication policy | Actual migration 0015 exercised under a non-owner role: public sees published parents/children; fixture admin sees drafts. Effective target policies and public-view execution ownership remain separate gates |
| Migration repeat and portability | Checksummed runner repeated safely; manual replay refused; full PostgreSQL dump/restore to a second empty local database preserved row IDs, labels, cap/lounging history and uniqueness. This was same-major local portability, not intended-provider or cross-major acceptance |
| Existing read-only data/index review fixtures | Passed on synthetic PostgreSQL; no customer values or IDs emitted |

The full Flutter suite was not repeated in this batch because no Flutter source or dependency changed. Earlier app/native results remain dated evidence in the [storage record](security-storage-implementation-2026-10-25.md), not evidence for integrated whole-app encryption.

## Remaining acceptance

1. Freeze the full candidate and restore a fresh complete protected database pair with original keys. Check current schema, owners, ACLs, migration ledger and v1 collision counts. Retain/map collisions only through a reviewed business decision.
2. Rehearse the exact pending migrations and catalogue import/admin/public API/oldest-supported-client flows on that clone. Reconcile original IDs, amounts, cap consumption and benefit usage, including historical D01/D02 changes.
3. Repeat on the intended PostgreSQL provider, including deployment-role visibility, extension/collation compatibility, lock/load budgets, schema/data export and post-write failback. A local dump/restore does not close this gate.
4. Preserve the existing supported behavior and original history through rollout. Removing the new indexes can remove this additional enforcement but cannot undo an earlier data merge; historical repair needs its own reviewed mapping/replay procedure.

Across the full register, 76 findings now comprise 26 implemented in source, 43 partial and seven open; 50 remain unfinished. In these four sections, four are implemented in source, 19 partial and three open; 22 remain unfinished. No production-completion claim is made.
