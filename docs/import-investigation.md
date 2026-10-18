# Import investigation and implementation

Date: 18 October 2026

**Follow-up:** The implementation sections below record the initial fix. The shared pipeline, all-account review, manual mapping/correction, JSON support and retry behavior now supersede those screen-specific paths. See [current scenario coverage](import-scenario-matrix.md).

## Finding

The supplied three-page Axio expense report is a text PDF, rather than an Excel workbook. Its actual transaction table contains 53 rows: 45 expenses totaling INR 26,761.91, six credits, and two debit transfers marked `EXPENSE=No`. The expense sum matches the report's rounded INR 26.76 K summary. The original screenshot's `01/10 · TO · INR 1.00` is a report-period/summary false positive, not a purchase.

Syncfusion extracts the table as individual cells separated by blank lines. The old parser flushed a transaction on every blank line, losing the transaction table. It also accepted report dates as transaction dates, interpreted time/reference/account digits as possible amounts, and interpreted the word `credit` in an account name as a credit direction. These are independent problems; adding a single Axio filename check would not solve them.

## Existing app-wide architecture

There are six ingestion channels and four main parsing families, not one universal import algorithm:

| Channel | Extraction / parsing | Persistence |
| --- | --- | --- |
| Statement PDF | Local Syncfusion text extraction; local PDF rendering + ML Kit OCR fallback; `parseStatementText` | `POST /statement-imports` |
| CSV/TSV and now XLSX | Local decoding / workbook cell extraction; shared `parseStatementRows` column inference | `POST /statement-imports` |
| Spending screenshots | Local ML Kit OCR; `parseSpendingScreenshotText`, which reuses the statement text parser and separately recognizes category summaries | `POST /statement-imports` |
| Live SMS | SMS intake; server built-in and database-configured SMS patterns | Shared transaction writer |
| SMS backup files | Local XML / CSV message decoding, followed by the SMS ingestion pipeline | Shared transaction writer |
| Email forwarding / IMAP polling | Email ingestion and configured transaction parsing | Shared transaction writer |

The import hub, Data Transfer screen, and Spending entry points expose these channels. SMS backup files contain messages rather than financial spreadsheet rows, so they correctly retain a separate decoder. IMAP's current UI describes itself as a login test; backend polling code also exists, and its deployment scheduling was not verified here. Backup/export tools are separate from transaction parsing.

The shared server transaction writer already handles categorization, observation provenance, exact source-key retries, cross-source duplicate review, historical backfill, and card-state updates. Reusing it is essential: a separate importer writing directly to transactions would bypass those behaviors.

## Changes implemented

### PDF recognition

- Blank lines no longer discard split transaction cells.
- Period metadata, report summaries, page footers and standalone table headers do not become purchases.
- Explicit monetary `DR` / `CR` columns take precedence over positional number guessing.
- Date/time tokens are consumed before amount recognition. AM/PM and transaction time are retained.
- Account names containing `credit`, account suffixes, and numbers inside merchant names do not override an explicit amount/direction.
- Axio-style account and expense/income flags are retained; an explicit `EXPENSE=No` marks a debit transfer for exclusion.
- Existing generic bank-statement parsing remains as a fallback. It is still heuristic, particularly for tables without explicit directions or column structure.

### Spreadsheet recognition

- CSV, TSV, semicolon and pipe-delimited files share one row/column parser.
- UTF-8 and BOM-marked UTF-16 are supported, including Excel's UTF-16 TSV exports.
- XLSX reads multiple worksheets, shared/inline strings, sparse cell coordinates, styled Excel serial dates, and the 1904 date system, then uses the same column parser as CSV.
- Common DATE/PLACE/AMOUNT/DR-CR/ACCOUNT/EXPENSE exports are recognized.
- Zero debit values no longer hide a populated credit column.
- Arbitrary alphanumeric text is no longer stripped down to digits and treated as money.
- Invalid calendar dates are rejected. A declared non-INR currency is rejected rather than relabeled INR.
- Unrecognized nonempty spreadsheet rows generate review warnings, including when a worksheet has footer/summary rows.

### Review and persistence

- PDF and spreadsheet previews show every detected row, with full calendar year and wrapping descriptions.
- Users choose the source account from a mixed-account file and its destination in PandaPay. Changing source clears the destination selection.
- Individual spending rows can be deselected. Credits and transfers are visibly excluded.
- `Other spending (no card)` supports history without assigning it to a credit card.
- Selected debit cards use `debit_card`; credit cards use `credit_card`; other destinations do not accrue credit-card state. Ownership is checked for a selected card before importing.
- Import buttons guard against repeated taps during submission.
- The API now accepts `csv` and `xlsx` sources. Previously the CSV screen sent `csv` while the API allowed only `statement` and `screenshot`, so confirmation failed independently of parsing.
- Batch identity covers the file digest plus selected original row indices. Each row has a stable, profile-scoped file/row identity independent of the selection subset, allowing another account or remaining rows to be imported later without reinserting previously accepted rows.
- Existing category resolution and duplicate review are reused. A different export of the same purchases can still produce possible duplicates for user review.
- Screenshot ingestion also excludes rows explicitly recognized as transfers.
- Files/passwords remain local; the API receives structured, approved spending rows and identity digests.

## Validation

- Ran the actual user PDF through the production Syncfusion reader and statement parser: exactly 53 rows, 6 credits, 2 debit transfers, 45 expenses, and 2,676,191 paise. Every row retained a source account.
- Added synthetic regressions for Axio's cell-per-line structure, numeric merchant names, account/direction confusion, transaction time, expense flags, zero-debit/credit columns, UTF-16, unsupported currency/invalid dates, sparse XLSX cells, serial dates, shared strings, and multiple worksheets.
- Widget coverage exercises the real generated-PDF extraction through preview and confirmation, mixed-account selection, a non-card destination, structured row identity, and password errors.
- Existing screenshot parser compatibility is tested alongside the import tests.
- API syntax checks and the existing API suite passed (367 tests at the time of the run). No live database ingest or native-device OCR run was performed.
- Targeted analyzer found no type errors; it reports flow-control style informational lints, including existing unbraced statements.
- Other chats are changing this workspace concurrently. Their cache, transaction-split, calculator, and related changes were preserved.

## Rollout

1. Apply `db/supabase/migrations/20261018120000_non_card_statement_imports.sql`. It makes the import batch's card foreign key nullable; transaction rows already support non-card spending.
2. Deploy the API before the updated app, so CSV/XLSX sources, non-card batches, and stable row identities are accepted.
3. Rebuild/install the app. Pick the Axio file, parse it, choose a source account, choose its matching card or Other spending, review the selected expenses, and confirm. Repeat for the remaining source accounts.
4. Smoke-test against a staging database: importing the same selection twice, importing two disjoint selections, importing a bank-account selection without a card, and importing a debit-card selection should preserve counts and avoid inappropriate credit-card reward/utilization changes.

The migration, API, and app were prepared locally; they were not deployed or installed on the user's phone.

## Limits and next steps

This improves supported imports substantially; it does not establish reliable recognition of every arbitrary document.

- Binary `.xls`, `.xlsb`, encrypted Excel workbooks, arbitrary document formats, and formula recalculation are not supported. Export as `.xlsx` or CSV. XLSX formulas need cached values.
- Scanned PDFs still rely on OCR quality. The existing OCR fallback runs when no rows are found, has a 50-page cap, and has not been validated here on a physical device. Password-protected scanned PDFs need further OCR-path verification.
- Ambiguous numeric dates retain the existing day-first default; missing years retain the existing inferred/current-year behavior. Large or ambiguous exports need explicit date-format mapping rather than stronger guessing.
- Explicit income/credits/transfers are detected for exclusion, but this spending-import flow does not create income, repayments or transfers. Importing a credit as spending would inflate budgets and card utilization.
- Foreign currency conversion is not implemented. XLSX/CSV with an explicit foreign currency are skipped with a warning; PDF currency/layout ambiguity still requires review.
- Source categories, tags, notes, attachments and complete account models are not migrated. Categorization uses PandaPay's existing merchant/category resolver.
- Accounts are selected one batch at a time. Screenshot review remains more limited than PDF/spreadsheet review. Unknown formats need an editable column-mapping/date/currency review or a dedicated adapter before claiming full support.
- Generic PDF fallback still guesses monetary columns in layouts without explicit DR/CR structure. A future version should add positional table extraction, per-format confidence, reconciliation totals and explicit unresolved-row mapping.
- The existing API caps a batch at 5,000 rows. Large-history imports need chunking and progress/resume support.
- No remote model receives financial files in this implementation. An optional model-assisted parser would need a separate product/privacy decision and must still produce validated, reviewable structured rows.

The durable design is a pipeline: file decoder -> structural extractor -> shared transaction model -> validation/account/date mapping -> review -> shared idempotent ingestion. Different file formats need different decoders; they should share transaction semantics and persistence rather than one increasingly permissive regex.


## Import-all transaction history follow-up (18 October 2026)

The screenshot’s six “credits” and two “transfers” were not parser failures. The import page treated every parsed row as a spending candidate, so it intentionally excluded valid incoming and transfer entries. The Activity page and transaction model already support spending, money in, investments, and transfers. The exclusion was therefore a mismatch between the import workflow and the app’s transaction model, not a reason to omit those rows.

The shared import preview now selects recognized transaction kinds by default and sends the kind with every row to the existing transaction API. The API persists the kind in the existing transaction model; spend-only rewards and reporting continue to apply only to spending. CSV type fields can identify investments explicitly, and PDF narrations only do so for clear investment terms. Ambiguous or invalid rows remain held with their parser or field-validation reason. Repeated rows in a statement are no longer treated as duplicates merely because their date, amount, and description match.

The preview has filters for ready rows, needs review, skipped, money in, money out, investments, transfers, and duplicate candidates. Each row shows its transaction type, source location, source account, amount, and review reason. The summary separates incoming and outgoing totals. Users can correct an uncertain row, explicitly keep both sides of a possible duplicate, or leave a row unselected and continue. Unrecognized rows retain their raw cells and reason and can be corrected into transactions.

Before import, the panel fetches active saved transactions from the authenticated repository and flags exact local candidates using date, amount, description, destination, and transaction kind. This is a review aid, not proof: it is not fuzzy matching. The server checks again. Server-side spend matching retains its existing cross-source confidence logic; for income, investments, and transfers, automatic deduplication requires an exact bank reference, matching transaction kind, account evidence, time window, and amount. That avoids merging recurring same-amount salaries or transfers.

Scope: import review, parsers, request payload, and shared import persistence only; no Activity page, database schema, or other product pages changed. API regression coverage passes. Flutter formatting and syntax checks pass, but Flutter analysis/widget tests could not run in this sandbox because the existing Pub cache is outside the permitted filesystem; those checks should be run in the normal development environment before installing the build.
