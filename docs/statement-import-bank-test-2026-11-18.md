# Statement import across banks — test results, 18 Nov 2026

What was asked: run bank statements from several banks through the import flow, compare the
detected transactions with the source, and record misses, duplicates and wrong results by bank.
Make the owner's two uploaded statements work first, then make the reading general enough that a
wrong result is never silent.

## The headline

The owner's real ICICI statement (6 pages, 83 transactions) **did not import correctly before this
work**: every one of the 83 amounts was wrong. After it: 83 of 83 rows have the right date, amount,
direction and balance, nothing is flagged, and the rows add up exactly (opening balance + credits
− debits = last printed balance).

| | Before | After |
|---|---|---|
| Amount right | 0 of 83 | 83 of 83 |
| Direction right | 35 of 83 (by luck: everything was "money out") | 83 of 83 |
| Rows lost | 2 lost, 4 rejected | 0 |
| Rows flagged for review | 83 of 83 | 0 |
| Proved against the running balance | no | yes, every row |

Why it failed: the PDF library's plain text puts each table cell on its own line and forgets which
column an amount sat in. The SBI/ICICI readers written on 12 Nov expected a whole row on one line, so
they never matched a real file (they were tested only on invented text), and the generic fallback took
the running balance as the amount. The fix reads the PDF's word positions instead: amounts of one
column line up at one edge, the header over them names the column, so debit and credit are *read*
from the column, not guessed.

## What was built

- `packages/pandapay_domain/lib/src/statements/table_reader.dart`: reads a statement table from
  positioned words (pure Dart). Finds the date column and the amount columns from the data, names
  each from its header, starts a row at each date, reads direction from the column, and returns null
  rather than guess when it cannot prove the table.
- `app/lib/data/pdf_statement_parser.dart`: `PdfStatementReader.extract` returns word positions
  as well as text; `parseStatementPdf` prefers the table reader and falls back to the text reader.
  Scanned PDFs read by OCR keep the text path (OCR has no positions).
- The running-balance proof (`verifyStatement`) now covers CSV and XLSX too
  (`_proveAgainstBalance` in `csv_statement_parser.dart`).
- Fixes found by the tests, listed by area below.
- `scripts/check_statement.sh`: reads one real file through the app's import path and prints only
  counts, totals and the proof result (no narrations); rows go to `~/.pandapay-statement-checks`.

## Results by bank

"Modelled" means the layout is drawn from invented transactions in the shape that bank commonly
prints (`app/test/support/statement_pdf_builder.dart`); it shows the reader copes with that kind of
layout, not that a specific file from that bank imports correctly. Only ICICI is a real file.

| Bank / layout | PDF | CSV | XLSX | Basis |
|---|---|---|---|---|
| ICICI savings (S No, cheque no, remarks, withdrawal / deposit / balance) | exact | exact | exact | **real PDF** (83 rows), CSV and XLSX modelled |
| SBI (txn date + value date, quoted Indian amounts, blank or "-" cells) | exact | exact | exact | modelled; the owner's real SBI file is not yet checked |
| HDFC (dd/mm/yy, value dt, Closing Balance) | exact, also newest-first, centred cells, small narration font, opening / totals rows | exact | – | modelled |
| Axis (Tran Date, DR, CR, BAL, SOL) | exact | exact | – | modelled |
| Kotak (one amount column with Dr/Cr markers, balance with Cr) | exact | exact | – | modelled |
| IDFC First (dd-Mon-yyyy) | exact | – | – | modelled |
| Yes Bank (0.00 in the empty column) | exact | exact | – | modelled |
| Federal (amounts left-aligned) | exact | – | – | modelled |
| PNB (balance with a separate "Cr" word) | exact | – | – | modelled |
| One signed amount column | – | exact (balance decides the sign) | – | modelled |
| Credit card (no balance column) | exact via the text reader | – | – | modelled; date order still asks once |

"Exact" = every row has the right date, amount, direction and full narration, with no flags,
no rejected rows and no warnings.

## Misses, wrong results and duplicates found, by area

**ICICI PDF (real file).** All 83 amounts wrong (balance taken as amount), directions wrong,
2 rows lost, 4 rejected. Fixed by the table reader.

**Any bank: short second page.** The reader chose left-aligned columns on a page with few amounts and
lost the debit/credit amounts of 3 rows (seen with the SBI layout). Fixed: columns are calibrated on the
richest page and reused on pages whose amounts line up.

**Any bank: a statement with one debit.** A column with a single amount was ignored. Fixed: a lone amount
counts when a Debit / Credit / Balance header sits over it.

**Narration lost silently (found by stress layouts, fixed).** A smaller narration font than the date's,
cells centred on a long narration, and a footer that opens with a word like "Total" each made the
reader cut or mis-end a narration. Guards now compare a narration with its own font, allow narration
above a centred date, and treat a "footer-like" word as a footer only after a visible gap.

**A summary block above the header** could rename amount columns. Fixed: only the header band nearest the
first row names columns.

**Credit card / unknown layouts (text reader).** Only 15 of 40 amounts were right: reference numbers inside a
narration (`Bank/<12-digit ref>/YBL…`) were taken for amounts. Fixed: an amount must stand alone, and when a
row has decimals, whole numbers are not considered. Now 40 of 40.

**CSV.**
- `Withdrawal Amount (INR)` was mistaken for the "billed INR" column of a foreign-currency card export, so
  **every deposit row was dropped** (ICICI CSV). Fixed.
- Axis `DR` / `CR` headers were not recognised as debit and credit columns: all rows rejected. Fixed
  (short keywords match whole words only, because "cr" is inside "description").
- A footer line ("Statement generated on …", totals, closing balance) was listed as an unrecognised row.
  Fixed: such lines are ignored; a line with a date or amount that still cannot be read is still reported.
- One signed amount column read money out as money in (card exports print spending as positive, bank
  exports as negative). Fixed when a balance column exists: the balance decides. With no balance the
  import says the direction rests on the sign.
- A balance that is printed but cannot be read was silently skipped. Now the row is flagged.

**Duplicates.**
- The same file imported twice has identical row keys: covered by a test.
- Two genuinely identical payments in one statement are kept as two transactions: covered by a test.
- The same transaction saved from a CSV and later seen in a PDF was not caught when the PDF had wrapped a
  long reference across lines (a space where it broke). Fixed: the merchant comparison ignores spaces and
  punctuation.

**Classification seen on the real statement.** Credit-card payments from the savings account
(`BIL/INFT/…/CC BillPay-…`, `ATD/Auto Debit CC…`) counted as spending on the real file. They
are now transfers, in both PDF and CSV.

## Safety nets (a wrong read is flagged, never silent)

- A row whose balance does not follow from the row before it is flagged ("does not follow the statement's
  running balance"), and a warning gives the count. Tested with a dropped row and with a changed balance,
  in PDF and CSV.
- A page that prints dated lines the reader cannot read is named in a warning ("Page 3 … its
  transactions are not in this list").
- A table that cannot be proven (no balance and no debit/credit pair) is left to the text reader and is
  never guessed at by the table reader.
- Flagged rows are not selected for import until the person resolves them (existing behaviour).

## Not covered, and what could still go wrong

- **The two password-protected statements** (`Email_Statement_<id>.pdf`,
  `Email_Statement_<id>.pdf` in Downloads) have not been read: the password is not known
  to the tooling. Run `scripts/check_statement.sh <file>` on each and read the proof line.
- **Real files from SBI, HDFC, Axis, Kotak and the others.** Only layouts modelled on them were tested. A
  real file with an unusual header word, a column the reader cannot name, or a stream order that is not row
  by row will fall back to the text reader (and say so by the number of flagged rows) rather than import
  wrongly with confidence, but it will not import cleanly until its layout is seen.
- **Legacy `.xls`** (BIFF) workbooks are refused with a message to export CSV or XLSX. Some banks export `.xls`.
- **Scanned PDFs** are read by OCR as text only (no positions), so they use the text reader.
- **Statements in newest-first order with many rows on one day** rely on the order printed within a day.
- Narrations can still be wrong in cosmetic ways (a long reference broken by a space where the PDF wrapped
  it); amounts, directions and dates are what the proof covers.
- Day/month order: PDF tables read day first (Indian banks) unless a date can only be month first; the
  text reader and CSV still ask the person to confirm an ambiguous order.

## Running it

```
cd app
flutter test test/data/statement_bank_matrix_test.dart test/data/statement_csv_matrix_test.dart
cd ../packages/pandapay_domain && dart test test/statements
scripts/check_statement.sh ~/Downloads/some-statement.pdf     # one real file
```
