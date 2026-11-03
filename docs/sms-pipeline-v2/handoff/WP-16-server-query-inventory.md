# WP-16 server transaction query inventory

Baseline: committed integration checkpoint `5f820d4`. Inventory performed before implementation. Exact command required by WP-16: `rg -n "FROM transactions|JOIN transactions" api/src/*.js`. Expanded recursive, case-insensitive check: `rg -n -i '(from|join)\s+(public\.)?transactions\b' api/src --glob '*.js'`.

The exact baseline contains **67 query references in 11 files** (including nested v2 storage). The broader qualified-table search finds **69 references in 13 files**, adding two portable-backup ownership lookups. All 9 reporting query sites in `spend_reports.js` already filter active rows; real Postgres tests now execute all 9 with both a superseded legacy spend and its active v2 replacement. Existing Activity includes selected ignored refund/reversal rows and Deleted includes restorable ignored rows; both already exclude superseded. Existing raw identity, audit, mutation and archive reads are intentionally retained so retries, deletion history and backups keep their original records.

Added filters are limited to transaction visibility/eligibility. Detail and duplicate review exclude only superseded so previously valid ignored/deleted review behavior stays available. Duplicate review's parent query now gates both referenced transactions. Split parents, merchant search, self-transfer historical selection, account observations, category-related preview/count and assistant latest-SMS use active filters. A database trigger prevents stale legacy sync from reactivating a superseded row.

**Frozen Gmail/email:** no matching transaction query was found in `email_ingest.js`, `imap_*.js` or `card_discovery.js`; no frozen files were edited. Existing shared ingestion helpers keep their source retry identity lookups and historical records. No missing frozen query exception remains from this inventory.

The post-change broad API count is 72: the 69 broad baseline references plus two duplicate-review EXISTS subqueries and the projection's historical-event lookup. The supersede hook updates retained rows and joins facts, so it adds no FROM/JOIN transactions reference. Counts are lexical references, not endpoints.

| Baseline source | Decision |
| --- | --- |
| `api/src/user_merchant_category_rules.js:109` | Source loader asserts active in code |
| `api/src/user_merchant_category_rules.js:241` | Rule provenance join; retains historical source metadata |
| `api/src/user_merchant_category_rules.js:306` | Existing active filter |
| `api/src/self_transfer.js:112` | Add active filter before historical self-transfer rule application |
| `api/src/transaction_splits.js:63` | Add active filter to split parent visibility/eligibility |
| `api/src/transaction_splits.js:121` | Add active filter to split parent visibility/eligibility |
| `api/src/spend_reports.js:223` | Existing active filter |
| `api/src/spend_reports.js:254` | Existing active filter |
| `api/src/spend_reports.js:291` | Existing active filter |
| `api/src/spend_reports.js:320` | Existing active filter |
| `api/src/spend_reports.js:394` | Existing active filter |
| `api/src/spend_reports.js:460` | Existing active filter |
| `api/src/spend_reports.js:521` | Existing active filter |
| `api/src/spend_reports.js:617` | Existing active filter |
| `api/src/spend_reports.js:678` | Existing active filter (budgetSpend uses conditions array) |
| `api/src/import_resolvers.js:752` | Existing active filter |
| `api/src/import_resolvers.js:772` | Existing active filter |
| `api/src/index.js:1526` | Split invariant check after sync mutation; not a list/total |
| `api/src/index.js:1925` | Add active filter to merchant-derived search results |
| `api/src/index.js:3062` | Add active filter to current transfer-pairing row |
| `api/src/index.js:3090` | Existing active filter |
| `api/src/index.js:3182` | Source-alias retry identity; retains hidden history |
| `api/src/index.js:3242` | Source-key conflict retry identity; status checked by existing writer |
| `api/src/index.js:3738` | Rebind archived-card references across all retained history |
| `api/src/index.js:3795` | Existing active filter |
| `api/src/index.js:3878` | Existing active filter |
| `api/src/index.js:3896` | Existing active filter |
| `api/src/index.js:3933` | Existing active filter |
| `api/src/index.js:3989` | Existing active filter |
| `api/src/index.js:4054` | Existing active filter |
| `api/src/index.js:4155` | Existing active filter |
| `api/src/index.js:4303` | Existing active filter |
| `api/src/index.js:4381` | Existing active filter |
| `api/src/index.js:5443` | Existing active filter |
| `api/src/index.js:5550` | Add active filter to account-observation summaries |
| `api/src/index.js:5590` | Existing active filter |
| `api/src/index.js:5891` | Activity/recovery dynamic status predicate already excludes superseded |
| `api/src/index.js:5988` | Exclude superseded from detail; preserve deleted recovery |
| `api/src/index.js:6033` | Duplicate summary gated by new parent EXISTS excluding superseded |
| `api/src/index.js:6040` | Duplicate summary gated by new parent EXISTS excluding superseded |
| `api/src/index.js:6120` | Duplicate-resolution locked mutation; guard trigger blocks reactivation |
| `api/src/index.js:6280` | Edit loader rejects non-active rows in code |
| `api/src/index.js:6571` | Category source loader classified/rejected unless active |
| `api/src/index.js:6660` | Add active filter to category preview |
| `api/src/index.js:6673` | Add active filter to category preview count |
| `api/src/index.js:6839` | Bulk category mutation checks active eligibility/version |
| `api/src/index.js:7049` | Ignore mutation rejects non-active rows in code |
| `api/src/index.js:7099` | Restore explicitly permits only deleted/ignored |
| `api/src/index.js:7223` | Existing active filter |
| `api/src/index.js:7367` | Existing active filter |
| `api/src/index.js:7535` | Add active filter to latest assistant SMS timestamp |
| `api/src/index.js:7580` | Existing active filter |
| `api/src/index.js:7832` | Existing active filter |
| `api/src/index.js:8554` | Existing active filter |
| `api/src/index.js:8565` | Existing active filter |
| `api/src/index.js:9894` | Full data portability archive intentionally retains all rows/statuses |
| `api/src/sync_transaction_state.js:105` | Sync mutation before/after state; checks active; trigger blocks superseded reactivation |
| `api/src/sync_transaction_state.js:132` | Sync mutation before/after state; checks active; trigger blocks superseded reactivation |
| `api/src/foreign_payments.js:131` | Existing active filter |
| `api/src/foreign_payments.js:244` | Settlement mutation checks active in code |
| `api/src/sms_amount_audit.js:57` | Existing active filter |
| `api/src/sms_amount_audit.js:97` | Existing active filter |
| `api/src/transaction_tags.js:33` | Tag identity/provenance lookup; caller list/totals retain own status filter |
| `api/src/transaction_tags.js:35` | Tag identity/provenance lookup; caller list/totals retain own status filter |
| `api/src/transaction_tags.js:150` | Tag identity/provenance lookup; caller list/totals retain own status filter |
| `api/src/sms_v2/storage.js:591` | v2 projection maintenance/identity lookup; intentionally reads inactive rows |
| `api/src/sms_v2/storage.js:619` | v2 projection maintenance/identity lookup; intentionally reads inactive rows |
| `api/src/portable_backup/contract.js:25` | Backup split ownership; full archive intentionally retains all history |
| `api/src/portable_backup/restore.js:326` | Backup restore ownership; preserves archived rows and status |
