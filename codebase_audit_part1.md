# PandaPay Comprehensive Financial Intelligence Audit: Part 1

**Audit Scope:** Codebase Audit of Ingestion, Parsing, Classification, Storage, and Reconciliation Pipelines  
**Audited Roots:** `app/lib/`, `app/test/`, `api/src/`, `api/test/`  
**Date:** October 2026  

---

## Executive Summary Matrix

| # | Capability | Classification | Key Source Files | Key Test Files |
|---|------------|----------------|------------------|----------------|
| 1 | **SMS Ingestion & Message Storage** | **Implemented and tested** | `sms_intake_repository.dart`, `financial_store.dart`, `sms_capture_worker.dart`, `sms_import_store.dart`, `import_source_key.js` | `sms_intake_repository_test.dart`, `financial_store_test.dart`, `sms_capture_worker_test.dart`, `sms_facts_route.test.js` |
| 2 | **Sender Identification & Normalization** | **Implemented and tested** | `financial_store.dart` (`canonicalBankSender`), `sms_gate_filter.dart` (`cleanDltHeader`), `import_source_key.js` | `local_sms_parser_test.dart`, `local_first_sms_test.dart`, `source_identity.test.js`, `import_source_key.test.js` |
| 3 | **Financial vs Non-Financial Classification** | **Implemented and tested** | `sms_gate_filter.dart`, `sms_text_hint.dart`, `local_sms_parser.dart`, `needs_review_repository.dart`, `sms_parser.js` | `sms_noise_stress_test.dart`, `false_positive_audit_test.dart`, `needs_review_repository_test.dart`, `sms_parser.test.js` |
| 4 | **Transaction Extraction (Amount, Date, Merchant, Acc, Ref)** | **Implemented and tested** | `local_sms_parser.dart`, `indian_narration_sanitizer.dart`, `flashtext_merchant_extractor.dart`, `sms_parser.js` | `local_sms_parser_test.dart`, `indian_narration_sanitizer_test.dart`, `local_sms_parity.test.js`, `sms_parser.test.js` |
| 5 | **Credit-Card & Bank Transaction Processing** | **Implemented and tested** | `card_bill_ledger.dart`, `providers.dart`, `financial_store.dart`, `cycles.js`, `card_state_reconciliation.js` | `card_bill_ledger_test.dart`, `card_bill_provider_test.dart`, `payments_due_test.dart`, `card_state_reconciliation.test.js` |
| 6 | **Investment & Brokerage Classification** | **Implemented and tested** | `investment_classifier.dart`, `specialized_domain_classifiers.dart`, `needs_review_repository.dart`, `recurring.js` | `recurrence_engine_test.dart`, `local_sms_parser_test.dart`, `needs_review_repository_test.dart` |
| 7 | **Promotions, Spam, Informational & Unknown Senders** | **Implemented and tested** | `local_sms_parser.dart`, `sms_gate_filter.dart`, `sms_text_hint.dart`, `sms_parser.js` | `sms_noise_stress_test.dart`, `false_positive_audit_test.dart`, `sms_parser.test.js` |
| 8 | **Due-Date & Recurring-Payment Detection** | **Implemented and tested** | `commitments_repository.dart`, `recurrence_engine.dart`, `local_sms_parser.dart`, `recurring.js`, `brand_catalog.js` | `commitments_repository_test.dart`, `recurrence_engine_test.dart`, `recurring.test.js`, `subscription_parser.test.js` |
| 9 | **Statement Import & Reconciliation** | **Implemented and tested** | `csv_statement_parser.dart`, `pdf_statement_parser.dart`, `statement_reconciler.dart`, `statement_import.js` | `csv_statement_parser_test.dart`, `pdf_statement_parser_test.dart`, `statement_reconciler_test.dart`, `statement_import.test.js` |
| 10 | **Reward Calculation & Card-Benefit Tracking** | **Implemented and tested** | `user_cards_repository.dart`, `providers.dart`, `reward_math.js`, `rewards_worker.js` | `reward_math.test.js`, `rewards_worker.test.js`, `owned_cards_with_product_test.dart` |
| 11 | **Duplicate Detection, Linking & Correction** | **Implemented and tested** | `transaction_dedup.js`, `needs_review_repository.dart`, `duplicate_resolution_outbox.dart`, `sms_intake_repository.dart` | `transaction_dedup.test.js`, `transaction_dedup_confidence.test.js`, `duplicate_resolution_outbox_test.dart` |
| 12 | **User Feedback, Configurable Rules & Persistence** | **Implemented and tested** | `sms_rule_bundle_store.dart`, `needs_review_screen.dart`, `sms_rule_exposure_outbox.dart`, `app_database.dart`, `sms_rule_bundle.js` | `sms_rule_bundle_integration_test.dart`, `sms_autonomous_learning_device_test.dart`, `needs_review_screen_test.dart` |

---

## Detailed Audit Findings by Capability

### 1. SMS Ingestion and Message Storage
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Durable Intake Queue:** Implemented in `app/lib/data/local/sms_intake_repository.dart`. Uses SQLite tables `sms_intake`, `sms_captured_messages` (with index `sms_captured_by_date`), and `sms_source_decisions`. Operates as an append/ack queue with exponential backoff (`next_attempt`). Never drops oldest messages.
  - **Idempotent Hashing:** Matches `api/src/import_source_key.js`. Uses SHA-256 of `[account, normalizedSender, normalizedBody]` via `smsSourceKey()`. Delivery timestamps are strictly excluded from identity computation to prevent double-counting across broadcast and inbox scanning.
  - **Background Isolate Processing:** `SmsCaptureWorker` in `app/lib/features/sms_import/sms_capture_worker.dart` isolates database ingestion and parsing from the main UI thread. Only plain serialization crosses isolate boundaries.
  - **Batch Intake Store:** `SmsImportStore.captureBatch()` in `app/lib/data/local/sms_import_store.dart` executes atomic SQLite savepoints (`SAVEPOINT sms_batch` and `SAVEPOINT sms_capture`).
  - **Financial Entity Storage:** `FinancialStore` in `app/lib/data/local/financial_store.dart` persists provisional transactions, verified sync status, and SMS observations to `financial_entities`.
  - **Server Endpoints:** `api/src/sms_facts_route.js` and `api/src/sms_facts.js` receive typed fact contracts from client outboxes.
- **Supporting Test Files:**
  - `app/test/data/local/sms_intake_repository_test.dart` (queue operations, retry backoff, idempotent inserts)
  - `app/test/data/local/financial_store_test.dart` (atomic upserts, conflict resolution, transaction coverage)
  - `app/test/features/sms_import/sms_capture_worker_test.dart` (isolate worker lifecycle and serialization)
  - `api/test/sms_facts_route.test.js`, `api/test/sms_fact_contract.test.js`

---

### 2. Sender Identification and Normalization
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **TRAI DLT Header Cleaning:** `SmsGateFilter.cleanDltHeader` (`app/lib/data/sms_gate_filter.dart` lines 74–79) strips 2-character telecom carrier prefixes (e.g. `VK-`, `AD-`, `JD-`, `BZ-`, `VM-`) and route suffixes (`-S`, `-P`, `-T`, `-G`, `-B`).
  - **Bank Canonicalization:** `canonicalBankSender` in `app/lib/data/local/financial_store.dart` (lines 25–119) maps noisy sender variations to standard bank codes:
    - Normalizes token aliases: `hdfcbk` → `hdfc`, `sbibk`/`sbibnk` → `sbi`, `icicib` → `icici`, `axisb`/`axisbnk` → `axis`, `pytm` → `paytm`, `eqt` → `equitas`.
    - Matches prefixes against `_bankCodePrefixes` (`canara`, `hdfc`, `kotak`, `icici`, `union`, `sbi`, `axis`, `equitas`, `aubank`, `indus`, `idbi`, `federal`, `paytm`, `citi`, `hsbc`, `dbs`, `scb`, `rbl`, `uco`, `bob`, `boi`, `pnb`, `yes`).
    - Maps canonical codes to display names via `_bankDisplayLabels` (e.g., `'sbi'` → `'SBI'`, `'hdfc'` → `'HDFC Bank'`).
  - **Server-Side Alignment:** `api/src/import_source_key.js` (`normalizeMessagePart`) and `api/src/card_identity.js` mirror this canonicalization.
  - *Note on naming:* There is no separate file named `sender_registry.dart`; the registry logic is embedded in `financial_store.dart`, `sms_gate_filter.dart`, and `card_identity.js`.
- **Supporting Test Files:**
  - `app/test/data/local_sms_parser_test.dart`
  - `app/test/data/local_first_sms_test.dart`
  - `api/test/source_identity.test.js`, `api/test/import_source_key.test.js`

---

### 3. Financial vs Non-Financial Message Classification
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **5-Gate Triage Filter:** `SmsGateFilter.evaluate()` (`app/lib/data/sms_gate_filter.dart`) provides microsecond-speed pre-filtering:
    - *Gate 1:* Empty or malformed length check (>20,000 chars dropped).
    - *Gate 2:* Fast OTP & security veto (`_otpSecurityRe`: "otp", "verification code", "cvv", "pin", "do not share").
    - *Gate 3:* Sender header validation (rejects 10-digit mobile P2P and 140-series telemarketing CLI).
    - *Gate 4:* Demat, CDSL/NSDL depository share movements & broker noise.
    - *Gate 5:* Financial indicators check (presence of currency tokens, amount numbers, or financial movement verbs).
  - **Triage Taxonomy:** `classifySmsTriage()` (`app/lib/features/sms_import/sms_text_hint.dart`) maps SMS to `SmsTriageKind` (`financialCandidate`, `promotion`, `unrelated`, `sensitive`). Sensitive messages are purged immediately without leaving the device.
  - **Non-Transaction Noise Guard:** `LocalSmsParser.isNonTransactionNoise()` (`app/lib/data/local_sms_parser.dart` lines 215–306) and `api/src/sms_parser.js` (`isNonTransactionNoise`, `isNonTransactionAlert`, `isRejectedTransaction`).
  - **Review Queue Triage:** `NeedsReviewRepository.isSecurityOrServiceAlert()` and `NeedsReviewRepository.isNoiseItem()` (`app/lib/data/needs_review_repository.dart` lines 415–433, 579–598) prune maintenance alerts, SIM swap alerts, ATM counters, and service notices.
- **Supporting Test Files:**
  - `app/test/features/sms_import/sms_noise_stress_test.dart` (313 lines covering aggressive EMI solicitations, spend-threshold offers, service notices, and P2P headers)
  - `app/test/features/sms_import/false_positive_audit_test.dart`
  - `app/test/data/needs_review_repository_test.dart`
  - `api/test/sms_parser.test.js`

---

### 4. Transaction Amount, Date, Merchant, Account, and Reference Extraction
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **On-Device Parser Engine:** `LocalSmsParser.parse()` (`app/lib/data/local_sms_parser.dart` lines 1126–1755):
    - *Amount:* Exact paise extraction via integer regex arithmetic, avoiding float rounding issues (`Money.fromPaise`).
    - *Date:* Resolves Indian relative and absolute date patterns (DD-MM-YYYY, DD/MM, DD-Mon, "today", "yesterday") anchored to message arrival time.
    - *Account/Card Last-4:* Distinguishes account suffixes from card suffixes using keyword proximity.
    - *Reference Extraction:* Captures UTR, RRN, UPI Ref, and Txn ID.
  - **Indian Narration Sanitizer:** `IndianNarrationSanitizer.sanitize()` (`app/lib/data/indian_narration_sanitizer.dart`):
    - Strips aggregator prefixes: Razorpay, Paytm, Cashfree, BillDesk, CCAvenue, PayU, PhonePe, CitrusPay.
    - Strips POS/channel prefixes: `POS`, `ECOM`, `IPS`, `EDC`, `MEST`, `IMPS`, `NEFT`, `RTGS`, `NACH`.
    - Parses NPCI UPI strings (`UPI/P2M/...`, `UPI/P2P/...`, `UPI/REV/...`) to extract the actual merchant token.
    - Normalizes UPI QR VPAs (`paytmqr...` → `Paytm QR`, `bharatpe...` → `BharatPe QR`).
    - Strips beneficiary prefixes (`Fvg:`, `Favoring`) and corporate legal markers (`Pvt Ltd`, `LLP`, `Inc`).
    - Cleans terminal location tags (Bangalore, Mumbai, Delhi, etc.) and sequence numbers.
  - **FlashText Dictionary Extractor:** `FlashTextMerchantExtractor` (`app/lib/data/flashtext_merchant_extractor.dart`) executes $O(N)$ single-pass Trie matching against a curated catalog of 150+ Indian brands.
  - **Server Parser:** `api/src/sms_parser.js` (`parseSms`, `parseSmsAgainstPatterns`, `parseBuiltInCardSpend`, `parseBuiltInUpiDebit`, `parseTransactionDate`).
- **Supporting Test Files:**
  - `app/test/data/local_sms_parser_test.dart` (comprehensive parsing tests across all bank formats)
  - `app/test/data/indian_narration_sanitizer_test.dart`
  - `app/test/fixtures/local_sms_cases.json`, `app/test/fixtures/sms_family_corpus.json`
  - `api/test/sms_parser.test.js`, `api/test/transaction_date.test.js`, `api/test/local_sms_parity.test.js`

---

### 5. Credit-Card and Bank Transaction Processing
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Bill Ledger Calculation:** `CardBillLedger`, `CardBill`, and `CardBillEvidence` (`app/lib/data/card_bill_ledger.dart` lines 1–120):
    - Synthesizes partial bill evidence lines (statement alert + minimum due reminder + payment confirmations).
    - Determines `amountDue`, `minimumDue`, `paidToward`, `outstanding`, and `isPaid`.
    - Handles payment tolerance (`_minimumCreditPaise = 100`) to settle bills despite small rounding discrepancies or interest pennies.
    - Keeps bills active 31 days past due date to show paid status gracefully.
  - **Riverpod State Management:** `cardBillLedgerProvider` and `paymentsDueProvider` (`app/lib/app/providers.dart`), displayed via `PaymentsDueScreen` (`app/lib/features/insights/payments_due_screen.dart`).
  - **Bank Account Aggregation:** `LocalSmsParser.isBankAccountMessage()` (`app/lib/data/local_sms_parser.dart` lines 311–344) and `FinancialStore.bankAccounts()` (`financial_store.dart` lines 572–645) aggregate non-card savings/current accounts and track running balances.
  - **Backend State Engines:** `api/src/cycles.js`, `api/src/card_state_reconciliation.js`, `api/src/card_limit_parser.js`.
- **Supporting Test Files:**
  - `app/test/data/card_bill_ledger_test.dart`
  - `app/test/data/card_bill_provider_test.dart`
  - `app/test/features/insights/payments_due_test.dart`
  - `api/test/card_state_reconciliation.test.js`

---

### 6. Mutual-Fund, Broker, Stock-Market, and Investment-Message Classification
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Domain Classifier:** `SpecializedDomainClassifiers.classifyBrokerMessage()` (`app/lib/data/specialized_domain_classifiers.dart` lines 108–198) classifies messages into `BrokerEventType`:
    - `ipoLienOrAsbaBlock`: Detects ASBA/IPO lien blocks (funds blocked, lien marked), maps to `TxnEntryKind.investment`.
    - `depositoryCustodyAlert`: Detects CDSL/NSDL depository share/unit debit/credit movements; marked as non-cash custody alerts.
    - `dividendIncome`: Detects dividend inflows, maps to `TxnEntryKind.income`.
    - `brokerSettlement`: Detects SEBI running-account quarterly payouts returning to the bank, maps to `TxnEntryKind.transfer`.
    - `brokerFunding`: Detects fund top-ups to Zerodha, Groww, Upstox, Angel One, Dhan, etc., maps to `TxnEntryKind.transfer`.
    - `brokerageFee`: Detects AMC, DP charges, demat charges, maps to `TxnEntryKind.spend`.
  - **Investment Utilities:** `investment_classifier.dart` (`isInvestmentMovementDescription`, `isBrokerSettlementMessage`).
  - **Queue Retention:** `NeedsReviewRepository.isInvestmentSettlement()` (`needs_review_repository.dart` lines 435–446) ensures investment settlements are tagged as `NeedsReviewKind.investmentSettlement` and never discarded as noise.
  - **Backend Matching:** `api/src/recurring.js` and `api/src/sms_parser.js` (`parseBuiltInInvestmentMovement`).
- **Supporting Test Files:**
  - `app/test/services/recurrence_engine_test.dart` (lines 118–157 test broker funding, broker settlement payout, dividend income, depository custody alert, ASBA/IPO lien blocks)
  - `app/test/data/local_sms_parser_test.dart` (lines 82, 256–281, 948–958 test SIP investment, redemption proceeds, broker settlement, ASBA lien block)
  - `app/test/data/needs_review_repository_test.dart` (lines 603–655 test ASBA/IPO lien blocks classified and persisted to `local_needs_review`)

---

### 7. Promotions, Spam, Informational Messages, and Unknown Senders
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Rejection Patterns:** `LocalSmsParser.isNonTransactionNoise()` (`local_sms_parser.dart` lines 215–306):
    - TRAI 140 telemarketing headers and 10-digit mobile P2P senders.
    - TRAI DLT 6-digit promotional sender headers.
    - Promotional route suffix `-P` (unless matching `isCompletedTransactionOrBill`).
    - Promotional keywords ("offer", "sale", "discount", "pre-approved", "apply now", "loan", "voucher").
    - EMI solicitations quoting past spend ("eligible for EMI conversion", "convert into easy EMIs").
    - Non-transaction service notices (KYC, positive pay, SIM swap, maintenance, ATM usage limits).
  - **Fast Gate Dropper:** `SmsGateFilter.evaluate()` drops non-financial messages prior to regex parsing.
  - **Decision Persistence:** `SmsImportStore` records `ignored_promotion` / `ignored_unrelated` in `sms_source_decisions` table and deletes raw bodies.
  - **Server Parser Guard:** `api/src/sms_parser.js` (`isNonTransactionNoise`, `isNonTransactionAlert`).
- **Supporting Test Files:**
  - `app/test/features/sms_import/sms_noise_stress_test.dart`
  - `app/test/features/sms_import/false_positive_audit_test.dart`
  - `api/test/sms_parser.test.js`

---

### 8. Due-Date and Recurring-Payment Detection
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **AutoPay and Bill Notice Parsers:** `LocalSmsParser._parseAutoPay()` and `hasBillMarker` (`app/lib/data/local_sms_parser.dart` lines 737, 1098). Detects mandate registration, scheduled auto-debits, and bill availability alerts.
  - **Commitments Framework:** `CommitmentsRepository` and `Commitment` model (`app/lib/data/commitments_repository.dart`):
    - Categorization across utility, telecom, insurance, loan/EMI, rent, education, subscription, tax.
    - Dynamic calculation of days until due, grace period bounds (`gracePeriodEndsOn`), and status transitions (`due`, `inGracePeriod`, `paid`, `paymentNotDetected`).
    - Offline-first persistence via SQLite table `local_commitments`.
  - **Recurrence Engine:** `RecurrenceEngine` (`app/lib/services/recurrence_engine.dart`) and `recurringReportProvider` (`app/lib/app/providers.dart` line 1702).
  - **AutoPay Artifact Repair:** `FinancialStore.repairAutoPayArtifacts()` (`app/lib/data/local/financial_store.dart` lines 820–940) runs DB migrations to reclassify incorrectly booked spend rows into bill/AutoPay observations.
  - **Backend Recurring Classifier:** `api/src/recurring.js`, `api/src/due_date_parser.js`, `api/src/brand_catalog.js`.
- **Supporting Test Files:**
  - `app/test/data/commitments_repository_test.dart`
  - `app/test/services/recurrence_engine_test.dart`
  - `app/test/features/insights/subscriptions_screen_test.dart`
  - `api/test/recurring.test.js`, `api/test/subscription_parser.test.js`

---

### 9. Statement Import and Reconciliation
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Multi-Format Parsers:**
    - `CsvStatementParser` (`app/lib/data/csv_statement_parser.dart`): Parses Indian bank CSV exports (HDFC, ICICI, SBI, Axis, etc.), normalizes date formats and DR/CR columns.
    - `PdfStatementParser` (`app/lib/data/pdf_statement_parser.dart`): Extracts statement tables from PDF documents, supported by `pdf_statement_ocr.dart`.
    - `SpreadsheetStatementParser` (`app/lib/data/spreadsheet_statement_parser.dart`): Handles Excel/XLS/XLSX statements.
  - **Reconciliation Engine:** `StatementReconciler` (`app/lib/data/statement_reconciler.dart`) reconciles imported statement lines against local/SMS transactions using fuzzy date tolerances, exact paise amounts, and merchant similarity.
  - **Pipeline Orchestrator:** `TransactionImportPipeline` (`app/lib/data/transaction_import_pipeline.dart`).
  - **Backend Statement Importer:** `api/src/statement_import.js`, `api/src/csv.js`, `api/src/import_resolvers.js`.
- **Supporting Test Files:**
  - `app/test/data/csv_statement_parser_test.dart`
  - `app/test/data/pdf_statement_parser_test.dart`
  - `app/test/data/statement_reconciler_test.dart`
  - `app/test/data/import_formats_test.dart`
  - `api/test/statement_import.test.js`

---

### 10. Reward Calculation and Card-Benefit Tracking
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **API Math Engine:** `api/src/reward_math.js` computes reward points and cashback against merchant categories, spending slabs, monthly caps, and excluded MCCs.
  - **Async Worker:** `api/src/rewards_worker.js` listens to transaction ingestion and updates rewards ledgers and milestone progress.
  - **Client Ledgers & Providers:**
    - `UserCardsRepository.fetchPointsLedger()` (`app/lib/data/user_cards_repository.dart` line 1999) queries `GET /user-cards/:id/points-ledger`.
    - `UserCardsRepository.adjustPointsBalance()` (`POST /user-cards/:id/points-adjustment`).
    - `pointsLedgerProvider` (`app/lib/app/providers.dart` line 2823) manages card points state.
    - `_sumLocalRewards()` (`app/lib/app/providers.dart` lines 4153–4428) provides local aggregation fallbacks.
    - UI routes: `AppRoute.pointsExpiry` (`/cards/points-expiry`) and `AppRoute.rewardsGroup` (`/insights/rewards`).
- **Supporting Test Files:**
  - `api/test/reward_math.test.js`
  - `api/test/rewards_worker.test.js`
  - `app/test/app/owned_cards_with_product_test.dart`

---

### 11. Duplicate Detection, Transaction Linking, and Correction Handling
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Deterministic Dedup:** SHA-256 `smsSourceKey()` in `sms_intake_repository.dart` and `import_source_key.js`. Verified in `financial_source_receipts` table.
  - **Cross-Source Fuzzy Duplicate Scorer:** `evaluateDuplicate()` (`api/src/transaction_dedup.js`):
    - `AMOUNT_TOLERANCE_INR` = 0.005.
    - `MAX_TIME_DISTANCE_MS` = 10 minutes.
    - `MAX_SMS_NOTIFICATION_DISTANCE_MS` = 15 minutes.
    - `REVIEW_THRESHOLD` = 0.72.
    - Strict reference token matching (`UTR`, `RRN`, `UPI REF`, `TXN ID`).
    - Rejects matches with conflicting card/instrument/account data.
  - **Receipt & e-Bill Spend Matching:** `NeedsReviewRepository.hasMatchingSpendTransactionSync()` (`app/lib/data/needs_review_repository.dart` lines 472–548) correlates receipt SMS with debit transactions within 24 hours.
  - **Review Queue Dedup:** `addNeedsReviewSync()` prunes duplicates matching on normalized sender, normalized body, and ±5 minute arrival window.
  - **Outbox Sync:** `DuplicateResolutionOutbox` (`app/lib/data/local/duplicate_resolution_outbox.dart`) syncs user resolution actions.
- **Supporting Test Files:**
  - `api/test/transaction_dedup.test.js`
  - `api/test/transaction_dedup_confidence.test.js`
  - `api/test/duplicate_ingestion.test.js`
  - `app/test/data/needs_review_repository_test.dart`
  - `app/test/data/local/duplicate_resolution_outbox_test.dart`

---

### 12. User Feedback, Configurable Rules, Testing, and Data Persistence
- **Classification:** **Implemented and tested**
- **Architecture & Implementation:**
  - **Dynamic Rule Bundles:** `SmsRuleBundleStore` (`app/lib/data/local/sms_rule_bundle_store.dart`) persists active and candidate rule bundles in SQLite tables `sms_rule_bundles` and `sms_candidate_rule_bundles`.
  - **Shadow Mode & Telemetry:** `SmsRuleExposureOutbox` (`app/lib/data/local/sms_rule_exposure_outbox.dart`) records shadow evaluation exposures, invariant breaches, and classification deltas without leaking raw message bodies.
  - **User Review Queue:** `NeedsReviewScreen` (`app/lib/features/activity/needs_review_screen.dart`) enables one-tap classification, manual correction, bill confirmation, and noise dismissal.
  - **Feedback Loop to Server:** `UserCardsRepository.overrideSmsFact()` (`app/lib/data/user_cards_repository.dart` lines 45–60) posts user feedback patches, correction reasons, and template annotations to server learning workers.
  - **Durable Local Storage:** SQLite tables in `AppDatabase` (`app_database.dart`): `local_needs_review`, `financial_entities`, `sms_intake`, `sms_source_decisions`, `sms_facts_outbox`, `local_commitments`.
  - **Server Learning Pipeline:** `api/src/sms_rule_bundle.js`, `api/src/sms_learning.js`, `api/src/sms_evaluator.js`, `api/src/sms_template_compiler.js`.
- **Supporting Test Files:**
  - `app/test/features/sms_import/sms_rule_bundle_integration_test.dart`
  - `app/test/features/sms_import/sms_autonomous_learning_device_test.dart`
  - `app/test/features/activity/needs_review_screen_test.dart`
  - `app/test/data/local/app_database_test.dart`
  - `api/test/sms_rule_bundle.test.js`, `api/test/sms_learning.test.js`, `api/test/sms_evaluator.test.js`

---

## Architectural Gaps & Recommendations

1. **Sender Registry Organization:** Sender canonicalization is spread across `financial_store.dart` (`canonicalBankSender`), `sms_gate_filter.dart` (`cleanDltHeader`), and `api/src/card_identity.js`. Extracting a shared Dart domain registry (e.g., `sender_registry.dart`) would consolidate alias mapping and display labels in one spot.
2. **Specialized Classifier Integration:** `SpecializedDomainClassifiers` (`specialized_domain_classifiers.dart`) is thoroughly implemented and unit-tested in `recurrence_engine_test.dart`, but `LocalSmsParser` directly relies on `investment_classifier.dart` for its internal checks. Directly wiring `SpecializedDomainClassifiers` into `LocalSmsParser` would unify domain detection logic.
3. **Client-Side Reward Rule Engine:** Full category-ladder reward calculation lives primarily in Node.js (`api/src/reward_math.js`). The Flutter app has point ledger synchronization and monthly aggregations (`_sumLocalRewards`), but cannot perform fine-grained offline reward calculation without network connectivity.
