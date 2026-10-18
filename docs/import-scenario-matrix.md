# Shared import pipeline: scenario coverage

18 October 2026. This supersedes the initial screen-specific implementation described in `import-investigation.md`.

## Decision

Use one transaction-import pipeline, with format-specific readers at its boundary. PDF text, PDF OCR, spreadsheets, JSON and screenshots normalize into `ParsedStatement` / `ParsedStatementLine`. One session then owns validation, explicit account destinations, row correction, selection, stable identities, batch submission and recovery.

A universal permissive regex cannot distinguish every report, bank statement, receipt, invoice, income credit and transfer. The fallback must be a visible unresolved row or a mapping/correction step, rather than invented dates, guessed currencies or silently discarded purchases.

## Coverage matrix

| Scenario | Current behavior / recovery |
| --- | --- |
| A user opens the old PDF or spreadsheet entry point | Both wrap `DocumentImportScreen`; they use the same picker and pipeline. |
| Data Transfer / Import Hub | A general spending-file entry accepts PDF, CSV, TSV, TXT, XLSX and JSON. Screenshot OCR remains a separate acquisition action with the same review component. |
| A file has an unfamiliar extension | PDF and ZIP signatures and text/JSON structure identify the contents. Supported contents can be read independently of the name. |
| A renamed file says PDF/XLSX but has different contents | Clear export-again message; the extension does not override contradictory content. |
| Empty file / cancelled picker / read failure | Cancellation preserves the screen; empty/read failures offer another file. |
| File larger than 20 MB | Rejected with a smaller-date-range export instruction. No silent truncation. |
| Text PDF | Extracted locally in a worker isolate; unprotected PDFs proceed straight to preview. |
| Protected PDF | Password requested only when opening fails; wrong passwords remain recoverable. Password is not trimmed or uploaded. |
| Image-only or mixed text/scanned PDF | Pages with little/no extracted text are sent to local OCR with the password. Existing text is retained. |
| OCR unavailable or failed | Visible incomplete-preview warning, with CSV/XLSX or another OCR-capable device as recovery. |
| More than 50 pages need OCR | Stops with a smaller-export instruction rather than reading only the first 50 pages. |
| Scan contains misleading text/watermarks | Not universally detectable. OCR warnings and row review remain necessary. Native-device verification is still required. |
| PDF table cells split across blank lines | Cells are joined within dated transaction blocks. |
| Period headers, totals, closing balances, page numbers | Not treated as dated purchases; closing balance stays separate. |
| Explicit DR/CR columns | Take precedence over numbers in account labels, merchant names or narration. |
| PDF has multiple monetary/reference columns without explicit direction | Candidate is held for amount review rather than selected automatically. |
| Unknown PDF table layout | Recognizable dated failures appear as correctable rows. Otherwise the screen explains that summary-only/unknown layouts cannot recreate history. |
| CSV comma, semicolon, tab or pipe | Delimiter is inferred from a larger sample; quoted fields, embedded newlines and escaped quotes are supported. |
| Unterminated quoted CSV field | Export-again error; the remainder is not silently swallowed. |
| UTF-8 BOM or UTF-16 BOM | Decoded locally; UTF-16 supports both byte orders. |
| Other legacy text encodings | Invalid UTF-8 is reported. Re-export as UTF-8 CSV/XLSX. No silent replacement characters. |
| Metadata before a table / headerless table | Header inference scans up to 200 rows. The mapping dialog accepts any existing header row number, or 0 for no header. |
| Unfamiliar column names/order | User maps date, description, amount or debit/credit, direction, account and currency. |
| Multiple XLSX worksheets | Each worksheet uses its own configurable column/date/number options. |
| Sparse XLSX cells / shared or inline strings | Coordinates and string tables are read before shared column normalization. |
| Excel serial dates / 1904 date system | Styled date cells are converted, including the fractional time component. |
| XLSX formula cells | Cached values are read. Formula recalculation is not performed. |
| Very large expanded workbook | 80 MB aggregate and 20 MB per-entry limits produce a smaller-export instruction. |
| Legacy/encrypted XLS / XLSB / ODS | Not supported. Recognized compound files get an XLSX/CSV export instruction; arbitrary ZIP files are not assumed to be workbooks. |
| JSON list of objects, or transactions/expenses/data list | Converted to the same table/column pipeline. Nested arbitrary schemas need flattening or CSV export. |
| XML / HTML export | Directed to the SMS backup importer for SMS XML, or CSV/XLSX for spending. |
| ISO / numeric / named-month dates and common times | Validated, with timestamp retained. Invalid calendar rollover dates are rejected. |
| Ambiguous 03/04/2026 | Held for explicit day-first/month-first choice or row editing. |
| Date without a year | Held for a chosen export year or explicit row correction. |
| Epoch date | Accepted only when it resolves to the supported calendar range. |
| Future-dated purchase | Held for explicit review. |
| Decimal point / decimal comma / Indian grouping | Configurable amount format; malformed grouping and excess precision are rejected. |
| Positive-spend vs negative-spend export | User-configurable sign convention. Explicit debit/credit columns or directions take precedence. |
| Both debit and credit populated in one row | Rejected as ambiguous; the user corrects it. |
| Zero debit with a nonzero credit | Detected as credit, rather than a zero purchase. |
| Credit-card account identifier / balance looks numeric | Not chosen as a money column merely because the header contains “credit” or a reference number exists. |
| Salary/refund/repayment-like description without a direction | Held for type review; not confidently labeled as spending. |
| Foreign currency | Explicit foreign currency is rejected with a warning. No exchange rate is invented. PDFs still need currency review. |
| Zero/negative canonical amount, NaN, huge value, sub-paise precision | Blocked before persistence; API independently validates amount range/precision. |
| Mixed card/bank/wallet history | Each selected source account requires an explicit card or Other spending destination. |
| No cards or card-list request failed | Other spending remains available; failed card lists can be reloaded. |
| Debit card vs credit card | API checks ownership and card type; debit/other spending cannot accrue credit-card state. |
| Long account identifiers | Masked to their last four digits before structured submission and again before server observation metadata. |
| Multiple matching same-day purchases | Retained. Repeated date/amount/merchant/account evidence requires review; it is not silently deduplicated. |
| Overlapping screenshot selections | Identical image files are read once; per-image row identity survives reordering and overlapping image sets. |
| OCR summary-only screenshot | Does not become a fabricated purchase. Clearer row-level screenshots or explicit correction are required. |
| A row was not parsed | Raw cells and source row location remain visible for correction. |
| A valid row has the wrong date, description, amount or type | Editable before submission. Invalid dates/amounts cannot be saved. |
| Another row is corrected and the parsed list changes | Original source locations define identities, so earlier rows retain their retry keys. |
| User deselects rows / imports a subset | Selection is explicit; excluded and unrecognized row counts appear in the result. |
| More than the API's 5,000-row per-request limit | Session sends deterministic batches of up to 250 rows and 64 KiB, below the API body limit, with per-batch progress. |
| Network fails after some batches | Successful batches remain counted. Retry skips acknowledged batches and resends the uncertain batch with the same key. |
| Connection fails after server commit but before response | Same batch/row keys make retry idempotent. Review is frozen after the first submission attempt to avoid changing an uncertain request. |
| App is closed mid-import | Preview is memory-only. Reselecting the original file/options and retrying remains idempotent; automatic draft restoration is not implemented. |
| Double tap Confirm / back during upload | Submission guard prevents concurrent requests; navigation is blocked while a batch is in flight. |
| Same purchase already arrived by SMS/email/another export | Existing shared cross-source duplicate review is retained. Possible duplicates are not reported as added spending or marked confirmed. |
| Exact retries / possible duplicates / actual additions | Displayed as separate result counts. |
| API receives a malicious or malformed structured batch | Source, card id, calendar/date range, timestamps, row count, digest, duplicate row keys, rail, text lengths and money precision are validated before database work. |
| A card belongs to another profile / is archived | Rejected before the import batch or transactions are written. |
| Database write fails inside one batch | The existing `withUserClient` transaction rolls that batch back. Earlier committed batches are recoverable through retry. |

## Shared boundaries across the rest of the app

Live SMS, SMS backups and email continue using their message-specific parsers and instrument/entry-kind resolution. They already converge on `insertTransactionAndUpdateState`, the same transaction writer used by financial-document imports. Applying a CSV/PDF parser to bank alert messages would weaken those established semantics.

Local financial-file parsing stays on-device. The server receives selected structured rows, masked source labels and digests. Preview data/passwords are not persisted as raw backup files. The import flow refreshes transaction, utilization, summary, card and import-history providers after batch progress.

Credits, repayments, transfers and investments are visibly excluded from this **spending** importer. Migrating these as income/refunds/linked transfers requires explicit entry-kind semantics and, for refunds/repayments, links to the original purchase/account. The current implementation does not relabel them as expenses or claim that full financial-account migration is complete. Source categories/tags/attachments also remain outside this flow; PandaPay's existing category resolver handles spending categories.

## Remaining validation and rollout

- Automated tests cover format normalization, manual mappings, dates/times/locales, repeated and rejected rows, account destinations, timeout/retry identities, result counts, API validation and screen review/correction.
- The real Axio report was rechecked through the shared pipeline: 53 detected rows, 45 selectable expenses, 6 credits, 2 debit transfers, INR 26,761.91 and seven expense source accounts.
- Live database execution of the migration/ingest and Android/iOS OCR/file permissions still need staging/device smoke tests. Mocks do not establish SQL/RLS or plugin correctness.
- Apply `20261018120000_non_card_statement_imports.sql`, deploy the updated API (including `statement_import.js`), then rebuild the app. No deployment or installation was performed here.
- For unfamiliar formats, extend the reader/adapter and its fixtures. Keep the review session, validator, row identity, ingestion and result contract shared.

## Final checks recorded

- 45 targeted Flutter import checks passed: the persistent parser/session/widget regressions plus a local-only check of the supplied Axio PDF. The temporary test containing the user's local file path was removed after verification.
- The complete API suite passed 387 tests in the current shared workspace, including the new structured-import validation/handler tests.
- The shared import files passed targeted static analysis after cleanup. No live database migration/ingest or physical-device OCR result is implied by these checks.
- Request planning considers UTF-8 byte size as well as row count; long Unicode descriptions are tested against the API's default 100 KB body limit. Import requests have a 60-second response timeout and preserve retry identities if the result is uncertain.

## Duplicate confidence and category follow-up (18 October 2026)

All server ingestion channels share the same matching decision. Exact source-row retries are idempotent. A unique matching bank reference plus exact amount, within the 36-hour candidate window and without conflicting card/account/instrument evidence, is automatically consolidated. This also works within a channel. Unknown payment instrument may be reconciled with a known one; contradictory known instruments are rejected.

Automatic consolidation retains an ignored audit row, links its source observation to the existing transaction, and applies no additional spending/reward state. Retries follow that alias. Import summaries count these skips under already imported, without overwriting the canonical transaction's statement association. Probable matches without bank identity and ambiguous reused references remain in Duplicate Review. Scores rank evidence; they are not calibrated probabilities.

CSV/XLSX preserve explicitly labelled UTR, RRN, bank reference, UPI reference and transaction reference columns through edits and batching. App-local ID columns are not global identities. PDF/OCR descriptions can supply labelled references when extraction retains them. Different references protect real repeated purchases. The unsafe SMS-backfill whole-day shortcut was removed; reference-less SMS retries rely on source identity.

Unknown merchants/categories remain importable in Other. Transaction detail exposes Assign category through the existing editor. User merchant/VPA history supports future classification, while generic Unknown/Other placeholders cannot teach categories for unrelated purchases. Import completion refreshes duplicate review.

Limits: omitted references cannot be recovered; ambiguous identities require review. Posting delays beyond 36 hours do not automatically consolidate. Existing historical duplicates are unchanged. Tests cover mocked ingestion, not a deployed database or physical device. Verification: 409 API tests and 34 focused Flutter tests pass. Targeted import analysis is clean; transaction detail has five pre-existing analyzer info notices.
