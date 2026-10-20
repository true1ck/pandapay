# Database explorer in the audit report

The existing HTML report now has Audit & architecture and Database explorer tabs. Its top panel includes the verified source technology stack and review-scope tags.

The database explorer contains 96 local PostgreSQL tables, 934 columns, all 139 enforced foreign-key relationships, full table dictionaries, primary/unique/check constraints, defaults, indexes, row-level policies and triggers. It also lists six views with their definitions, 26 enums, and 31 application-function signatures; extension-owned functions are excluded. Composite unique membership is distinguished from individual uniqueness.

The 934-column metadata recapture contains `recurring_series.user_edited`, which was absent from the original 933-column audit dictionary. Both files retain their original meaning; this report does not silently replace the earlier evidence.

Two migration-defined tables absent from the local snapshot and 19 source-defined device SQLite tables are listed separately. The SQLite supplement includes four columns added by guarded runtime ALTER operations. A transient outbox-rebuild table is not counted as persistent storage. No SQLite foreign-key clauses were found, so no enforced relationship diagram is invented for that store.

The auth users/product profiles connection is explicitly a logical service-coordinated identity bridge. No cross-database foreign key exists. The diagram draws only real local PostgreSQL foreign keys, child to parent.

## Database optimization follow-up

Section 10 adds the optimization assessment, and the Database tab includes an expandable 96-table usage/size inventory. `database-optimization-evidence.json` contains local exact row-count aggregates, allocated relation/index sizes, approximate tuple/scan statistics, strict FK-prefix candidates, equivalent index pairs, source-location matches, routine mentions and selected payload/retention aggregates. No customer values are exported. The optimization capture is newer than the initial audit snapshot; it must not silently overwrite older counts.

`audit_database_optimization.py` captures this evidence using read-only transactions against only 127.0.0.1, with a per-query timeout. It makes no application/schema changes. The databases have an unavailable statistics-reset timestamp, so local counters cannot prove an index/table unused. Partial indexes are excluded from the strict FK-prefix screen; its 93 candidates are not 93 confirmed defects. Literal code matches may include comments/dynamic registrations and another database's same-named table.

Four tables are candidates for retirement, subject to supported-consumer/dependency review. kill_switches and remote_config need a separate control-effectiveness/reader-contract decision. Indirect RPC consumers, auth/product device boundaries, provenance/splits and offline storage are explicitly preserved. No table is approved for deletion by this report. Recommendations prioritize security, retention, correctly wired configuration and safe dedupe before speculative performance changes.

## Scalability and storage follow-up

Section 13 adds repository-specific recommendations for low-RAM deployments, burst onboarding, bounded imports, OTP provider quotas, shared abuse controls, replica/pool budgets, database and object-storage growth, backup overhead, monitoring and staging load/failure tests. A top-of-report shortcut opens it from either report tab. Server configurations and capacity arithmetic are explicitly planning assumptions, not verified production hardware or benchmark results. Current provider guidance is linked inline. No production inspection, infrastructure purchase, load test or service/database change was performed.

Section 14 maps CDN eligibility to public versus private PandaPay routes/assets, with proposed cache policies, publication invalidation, private-file delivery, Redis counter/reconnection/eviction recommendations, queue boundaries and rollout tests. Recommendations were cross-checked against current source and official CDN/Redis documentation; they are not deployed changes. Graphify supplied orientation only, with a truncated broad query explicitly not treated as complete evidence.

## Inputs and regeneration

- `schema-details.json`: read-only local PostgreSQL catalog capture; no business rows or production connection.
- `schema-source-supplement.json`: exact current source declarations and source locations, independently checked against source files.
- `database_report.py`: standalone HTML, CSS and JavaScript explorer renderer.
- `render_html_report.py`: existing Markdown renderer, now including the database explorer.

From the repository root, regenerate HTML with:

```sh
python3 artifacts/security-review-2026-10-20/render_html_report.py
```

Refresh local metadata only when a new snapshot is intended:

```sh
python3 artifacts/security-review-2026-10-20/capture_schema_details.py
```

The capture script targets only `127.0.0.1` and wraps each catalog query in `BEGIN READ ONLY`. It does not read customer rows or change schema. It scans user-defined schemas in both local databases. Default expressions and view/trigger definitions are schema code, not user records.

## Verification and limits

`verify_report.cjs` parses the generated HTML in JSDOM with no external resources and checks tab/keyboard navigation, filtering, column search, empty state/reset, table inspection, FK navigation, zoom, metadata counts, unique IDs and all local links. Pass a path to a temporary JSDOM installation as its first argument; JSDOM is not added to the application dependencies.

The browser refused observation of the existing `file://` tab because of its protocol policy. No alternate browser or serving workaround was attempted. Interactive DOM checks passed; rendered screenshot and responsive visual verification remain unperformed. Responsive styles are included, but visual appearance is not independently confirmed.

Graphify was used for source orientation through the existing graph, using its vocabulary `database schema tables migration auth cards transactions sqlite`. Current catalog metadata and source definitions are authoritative for this addition. The original security findings remain unresolved; no application/backend/schema fixes, cleanup or deployment are part of this report update.
