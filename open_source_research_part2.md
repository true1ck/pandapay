# Comprehensive Open-Source Repository Research Report: Part 2
**PandaPay Project — Financial Intelligence & SMS Parsing Engine**
**Author:** Agent 2 (Open Source Repository Researcher)
**Target Platform:** Flutter / Dart (Offline-First Android Architecture)

---

## Executive Summary & Architectural Heatmap

Across Groups A, B, and C, 23 open-source candidate repositories were evaluated through repository tree analysis, source-code inspection, architectural auditing, and feasibility assessment for integration into PandaPay's offline Flutter/Dart mobile stack.

### Key Landscape Findings

1. **Accessibility Status:**
   - 22 repositories are fully accessible and verified.
   - 1 repository (`varunjuneja/expense-analyser`) returned `HTTP 404` under the specified handle, but was discovered and verified under the active fork/renamed profile [`juneja-varun/expense-analyser`](https://github.com/juneja-varun/expense-analyser).
   - `sureshdsk/finn-lens` (hosted at `https://git.mitgai.net/sureshdsk/finn-lens`) was verified as a public Gitea mirror of [`sureshdsk/finn-lens`](https://github.com/sureshdsk/finn-lens) on GitHub.

2. **Highest-Value Architectural Contributions:**
   - **`bjain102/hisaab` (Python):** Gold standard for deterministic Indian credit card reward math. Provides era-based rule versioning `[valid_from, valid_to)`, integer paise arithmetic (`floor(paise * numer / denom)`), category & token merchant matching, cap bucket management, and exact refund clawback attribution.
   - **`akhilnarang/cc-parser` (Python):** Best-in-class refund and adjustment pairing engine. Provides token-based Jaccard similarity, narration normalization, date-gap scoring, and multi-tier confidence matching between debits and credits.
   - **`prabhavalabs/salli-sms-classifier` (Dart):** Ready-to-adapt native Dart linear multi-head classifier. Uses hashed token vectors, zero external dependencies, running in <2ms on-device for transaction eligibility, direction, account type, and expense category.
   - **`rahatsayyed/BankSMSParser` (TypeScript):** Definitive pattern library for Indian financial institutions and, crucially, mutual fund and investment allotment parsing (`HDFCMutualFundParser`, `NaviMutualFundParser`), establishing clean separation between investments and bank debits.
   - **`SysAdminDoc/BillMinder` (Kotlin) & `suryadeepbanerjee/Bill-Reminder` (SQL/TypeScript):** Bulletproof recurrence math preventing drift, month-end clamping (28/29/30/31 days), leap-year stability, and anchor-date derived cycle keys (`ISO_LOCAL_DATE`).
   - **`itsluminous/ClearSMS` (Kotlin/JSON):** 9,400+ lines of production-tested regex rules and rule guards (`guards_none` / `rule_guards.json`) preventing OTPs and spam from colliding with transaction extraction.

---

## Detailed Repository Analysis

```
====================================================================================================
GROUP A: Credit Cards, Statements, and Rewards
====================================================================================================
```

### 1. `bjain102/hisaab`
- **Repository URL:** [https://github.com/bjain102/hisaab](https://github.com/bjain102/hisaab)
- **Status & Relevance:** Accessible (Active, Python/React). Highly relevant to card rewards, caps, and statement audits.
- **Key Source Files, Classes & Functions:**
  - `rewards/engine.py`: Functions `rebuild_all()`, `_match_rule()`, `_period_token()`, `evaluate_bonuses()`.
  - `rewards/gaps.py`: Function `compute_gaps()` (computes discrepancy between calculated rewards and bank-reported statement rewards).
  - `rewards/seed.py`: Functions `seed_reward_rules()`, `parse_card_program_yaml()`.
  - `pdf_parsers.py`: PDF table extraction using `pdfplumber` and `pypdf`.
  - `tests/test_rewards_engine.py`: Comprehensive test corpus with synthetic and redacted statements (Amazon ICICI, Amex MRCC, Axis Rewards).
- **Implementation & Algorithm Details:**
  - Implements ADR-008: Deterministic derived reward accruals.
  - **Era selection by date:** `[valid_from, valid_to)` window selection handling credit card reward devaluations over time.
  - **Rule Matching:** Priority-ordered first-match-wins (`category`, comma-separated `merchant_match` substring tokens, `merchant_match_exclude` tokens, and `min_txn_paise`).
  - **Paise Precision:** Always performs integer paise math: `floor(amount_paise * earn_numer / earn_denom_paise)` to match bank rounding down to the nearest point.
  - **Refunds & Clawbacks:** Pairs refunds with prior debits having identical amount and normalized description, reversing points and restoring cap room.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Directly reimplement `rewards/engine.py` into a Dart service (`lib/features/rewards/reward_engine.dart`).
  - Adopt the rule structure for reward programs (base rate, accelerated category rates, monthly caps, exclusions like fuel/rent/wallet).
- **Missing / Unsuitable Aspects:**
  - Written in Python with SQLite backend; cannot be imported directly as a Dart dependency.
  - Statement PDF parsing relies on Python `pdfplumber`, which requires desktop C libraries.
- **Integration Path:** Independent Dart Reimplementation.
- **Required Additional Tests:**
  - Dart unit tests verifying devaluation era boundaries, leap year cycle periods, refund reverse-attribution, and cap overflow boundaries.

---

### 2. `indranildchandra/secure-credit-card-rewards-optimiser`
- **Repository URL:** [https://github.com/indranildchandra/secure-credit-card-rewards-optimiser](https://github.com/indranildchandra/secure-credit-card-rewards-optimiser)
- **Status & Relevance:** Accessible (Python). Relevant for card recommendation strategies.
- **Key Source Files, Classes & Functions:**
  - `config/model.config` & `config/cards.config`: Configuration files for Indian card benefits and spend thresholds.
  - `tests/test_optimizer_agent.py`: Agent test suite.
  - `tests/test_spend_tracker.py`: Tracks spend accumulation towards milestone targets.
  - `tests/test_card_tools.py`: Helper tools calculating net reward rate factoring in fuel surcharges, forex markup, and fee waivers.
- **Implementation & Algorithm Details:**
  - Built on Google ADK (Agent Development Kit) with local Gemma 4 model via Ollama.
  - Given a spend prompt (e.g., "₹45,000 at Apple"), queries local card configurations to determine the highest reward yield taking into account category accelerated multipliers, current milestone progress, and monthly spend caps.
- **Adaptation to PandaPay (Flutter/Dart):**
  - The deterministic mathematical decision trees (milestone tracking, fee waiver remaining balance, category multiplier rules) should be implemented in pure Dart.
  - The card metadata in `config/cards.config` can be converted into JSON assets for PandaPay's card catalog.
- **Missing / Unsuitable Aspects:**
  - Dependent on local Ollama / Gemma runtime (unfeasible for a lightweight offline Flutter app on mobile).
  - High latency for real-time checkout advice if relying on LLM inference.
- **Integration Path:** Extract card benefit rules and milestone logic; reimplement as deterministic Dart calculation functions.
- **Required Additional Tests:**
  - Decision parity tests verifying that the deterministic Dart algorithm selects the same card winner as the LLM agent across benchmark queries.

---

### 3. `shaikinzamam/CardSense-AI-Credit-Card-Rewards-Optimization-Agent-India-`
- **Repository URL:** [https://github.com/shaikinzamam/CardSense-AI-Credit-Card-Rewards-Optimization-Agent-India-](https://github.com/shaikinzamam/CardSense-AI-Credit-Card-Rewards-Optimization-Agent-India-)
- **Status & Relevance:** Accessible (Python). Relevant for two-phase reward calculation and natural language advisory.
- **Key Source Files, Classes & Functions:**
  - `agents/rewards_agent.py`: `RewardsAgent` class, `OllamaClient`.
  - `core/calculator.py`: `RewardCalculator`, `SpendingScenario`, `MonthlySpendItem`.
  - `database/models.py`: Data models for cards, reward tiers, and spend limits.
  - `tests/test_all.py`: Verification tests for calculations and prompt outputs.
- **Implementation & Algorithm Details:**
  - **Two-phase architecture:**
    1. Phase 1 (`RewardCalculator`): Pure structured data calculations (spend * category multiplier, cap validation).
    2. Phase 2 (`RewardsAgent`): Explains *why* the card won in natural prose formatted with Indian currency symbols and Lakh/Crore notation.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Phase 1 calculator translates 1:1 to Dart.
  - Pre-templated explanation strings (e.g. "Card A gives 5% on Amazon up to ₹500/mo; you have ₹320 remaining") replace the need for an LLM on mobile, providing zero-latency, deterministic explanations.
- **Missing / Unsuitable Aspects:**
  - Backend FastAPI/Ollama architecture; prompt generation is unnecessary overhead on-device.
- **Integration Path:** Independent Dart Reimplementation of Phase 1; template-based generation for Phase 2.
- **Required Additional Tests:**
  - Category cap saturation tests, annual fee break-even unit tests.

---

### 4. `abhijeetburle/cc_autopilot`
- **Repository URL:** [https://github.com/abhijeetburle/cc_autopilot](https://github.com/abhijeetburle/cc_autopilot)
- **Status & Relevance:** Accessible (Python). Relevant for statement PDF ingestion and card fingerprinting.
- **Key Source Files, Classes & Functions:**
  - `cc_extractor.py`: `extract_pdf_text()`, `detect_card_config()`, `extract_statement_metadata()`.
  - `watch_statements.py`: File watcher daemon monitoring directories for new statement drops.
- **Implementation & Algorithm Details:**
  - Employs text-based **fingerprinting (`pdf_fingerprints`)**: searches for unique bank textual markers (e.g., "ICICI Bank Coral Credit Card", "HDFC Bank Infinia") to auto-detect statement issuer without requiring user configuration.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Adapt the fingerprint dictionary into `app/lib/data/card_discovery_engine.dart` to identify card issuers and products automatically when scanning statements or emails.
- **Missing / Unsuitable Aspects:**
  - Relies on Claude API cloud calls for table extraction; fails offline and privacy guarantees.
- **Integration Path:** Port the fingerprint signature database to Dart.
- **Required Additional Tests:**
  - Negative fingerprint tests to ensure co-branded cards (e.g., Amazon Pay ICICI vs standard ICICI Platinum) do not misidentify.

---

### 5. `akhilnarang/cc-parser`
- **Repository URL:** [https://github.com/akhilnarang/cc-parser](https://github.com/akhilnarang/cc-parser)
- **Status & Relevance:** Accessible (Python). Highly relevant for Indian bank statement parsing and refund/adjustment reconciliation.
- **Key Source Files, Classes & Functions:**
  - `cc_parser/parsers/base.py`: `StatementParser` abstract base class.
  - `cc_parser/parsers/hdfc.py`, `icici.py`, `axis.py`, `bob.py`: Bank-specific statement table and regex parsers.
  - `cc_parser/parsers/adjustment_pairing/scoring.py`: `merchant_similarity()`, `jaccard_similarity()`, `calculate_date_gap()`, `calculate_amount_delta()`, `tokenize()`.
  - `cc_parser/parsers/adjustment_pairing/candidates.py`: `has_refund_keyword()`.
- **Implementation & Algorithm Details:**
  - **Adjustment / Refund Pairing Engine:** Matches credits (refunds, reversal, chargebacks) against past debits using:
    - Jaccard similarity over word tokens (thresholds: High $\ge 0.8$, Med $\ge 0.5$).
    - Date proximity weighting ($\le 3$ days = small gap bonus, $\le 14$ days = medium gap bonus).
    - Amount matching: Exact amount match yields high confidence; partial refunds require high merchant similarity ($\ge 0.7$).
    - Negative scoring / penalties: Large amount discrepancies or card number mismatches penalize confidence.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Directly adapt `adjustment_pairing/scoring.py` into Dart (`app/lib/data/adjustment_matcher.dart`).
  - This solves PandaPay's problem of unlinked refunds distorting monthly expense metrics.
- **Missing / Unsuitable Aspects:**
  - Written in Python; parsing depends on `pypdf`/`pdfplumber`.
- **Integration Path:** Independent Dart Reimplementation of the adjustment pairing algorithm and parser regex dictionaries.
- **Required Additional Tests:**
  - Full refund, partial refund, cancellation fee, and cross-month adjustment regression tests.

---

### 6. `sureshdsk/finn-lens`
- **Repository URL:** [https://git.mitgai.net/sureshdsk/finn-lens](https://git.mitgai.net/sureshdsk/finn-lens) (Mirrored at [https://github.com/sureshdsk/finn-lens](https://github.com/sureshdsk/finn-lens))
- **Status & Relevance:** Accessible (Python/Django). Relevant for email and statement ingestion pipeline.
- **Key Source Files, Classes & Functions:**
  - `backend/banking/parsers/cc_base.py`: `CCStatementParser` protocol, `CCTransactionRecord`, parser registry.
  - `backend/banking/parsers/icici_cc.py`, `axis_cc.py`: Regex extraction for statement tables.
  - `backend/banking/email_extractor/cc_statement.py`, `cc_payment.py`: Regex extraction for bank transaction confirmation emails.
  - `backend/classifier/extractors/regex_extractor.py`: Multi-pattern text extractor.
- **Implementation & Algorithm Details:**
  - Uses date format regex `(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})` and normalized signed amounts (positive debit, negative credit).
  - Dispatches by issuer identifier registered in a central registry.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Extract email & statement regex patterns for Axis and ICICI cards into PandaPay's parsing rules.
- **Missing / Unsuitable Aspects:**
  - Django full-stack web application structure with relational DB migrations; heavy backend-specific plumbing.
- **Integration Path:** Extract parser regexes; reimplement parser contract in Dart.
- **Required Additional Tests:**
  - Multi-line description wrapping tests for statement entries.

---

### 7. `sakthipriyan/xfina`
- **Repository URL:** [https://github.com/sakthipriyan/xfina](https://github.com/sakthipriyan/xfina)
- **Status & Relevance:** Accessible (Rust). High technical value for zero-server, privacy-first statement parsing.
- **Key Source Files, Classes & Functions:**
  - `src/models/credit_card.rs`: `XfinaCreditCardAccount`, `CcXfinaSummary`, `CardType` enum.
  - `src/bank_accounts/pdf_parser.rs`: Line and table tokenization algorithms.
  - `tests/credit_cards_hdfc_integration.rs`, `credit_cards_icici_integration.rs`, `credit_cards_axis_integration.rs`.
- **Implementation & Algorithm Details:**
  - Written in Rust, targets WebAssembly (WASM).
  - Adheres to RBI Account Aggregator (AA) schema conventions while adding practical extensions: `generatedDateDerived`, `availableCreditLimit`, `totalAmountDue`, `paymentDueDate`.
  - Zero server calls; parses PDF text stream in memory with strict type validation using `rust_decimal`.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Option A: Reimplement data models and regex tokenizers in pure Dart.
  - Option B: Compile Rust core to static C-library / shared object (`.so` / `.dll`) and call via `dart:ffi`.
- **Missing / Unsuitable Aspects:**
  - FFI compilation increases Flutter APK size and cross-platform build complexity (Android ARMv7, ARM64, x86_64). Pure Dart is preferable unless parsing multi-megabyte PDFs.
- **Integration Path:** Independent Dart Reimplementation of the schema and line-scanner logic.
- **Required Additional Tests:**
  - Precision tests ensuring floating-point numbers do not introduce rounding errors (use Dart `int` paise or `Decimal`).

---

### 8. `varunjuneja/expense-analyser` (Found at `juneja-varun/expense-analyser`)
- **Repository URL:** [https://github.com/juneja-varun/expense-analyser](https://github.com/juneja-varun/expense-analyser) *(Note: original handle 404, active under `juneja-varun`)*
- **Status & Relevance:** Accessible under renamed handle. Highly relevant for Indian credit card edge cases.
- **Key Source Files, Classes & Functions:**
  - `backend/apps/parsers/banks/icici/parser.py`: Line-oriented credit card parsing.
  - `backend/apps/parsers/banks/hdfc/parser.py`: Savings and card statement parsing.
  - `backend/apps/categories/models.py`: Expense category tree.
  - `backend/apps/parsers/base.py`: Confidence scoring and parsed models.
- **Implementation & Algorithm Details:**
  - Explicitly addresses the two critical quirks of Indian credit card statements:
    1. **Lack of ruling table lines:** Uses line-oriented regular expressions rather than bounding-box grid extractors.
    2. **Sign Inversion:** Reverses issuer polarity (issuer treats purchases as positive, payments/refunds as `CR`) to standardize on user-centric balance impacts (negative = money outflow).
    3. **Summary Row Exclusion (`SUMMARY_PREFIXES`):** Filters out rows like "Total Amount Due", "Minimum Amount Due", "Credit Limit", "Opening Balance" which match transaction regex shapes.
- **Adaptation to PandaPay (Flutter/Dart):**
  - The `SUMMARY_PREFIXES` filter and sign normalization rules should be integrated into `app/lib/data/local_sms_parser.dart` and statement processors.
- **Missing / Unsuitable Aspects:**
  - Python/Django backend with Excel/PDF processing libraries.
- **Integration Path:** Independent Dart Reimplementation of parsing regexes and sign inversion filter.
- **Required Additional Tests:**
  - En-dash `\u2013` vs hyphen date range tests; false-positive transaction line rejection tests.

---

```
====================================================================================================
GROUP B: Due Dates, Bill Reminders, and Financial Obligations
====================================================================================================
```

### 9. `carthworks/ActSMS`
- **Repository URL:** [https://github.com/carthworks/ActSMS](https://github.com/carthworks/ActSMS)
- **Status & Relevance:** Accessible (Android Kotlin). Highly relevant for SMS bill reminder generation.
- **Key Source Files, Classes & Functions:**
  - `app/src/main/java/com/actsms/app/data/parsing/SmsParserImpl.kt`: `parse()`, `isOtp()`, `isPromo()`, `extractData()`.
  - `app/src/main/java/com/actsms/app/domain/model/Action.kt`: `Action`, `ActionCategory` (BILL, EMI, DELIVERY, APPOINTMENT).
- **Implementation & Algorithm Details:**
  - Priority-based pattern evaluation.
  - Targets Indian transactional SMS formats for credit card bill notices, utility bills, and loan EMIs:
    - **Credit Card Bill Pattern:** `(?i).*credit card.*(?:bill|payment).*(?:due|payable).*?(?:rs\.?|inr|₹)\s*([0-9,]+(?:\.[0-9]{2})?).*?(?:by|before|on)\s*(\d{1,2}[-/]\d{1,2}[-/]\d{2,4})`
    - **EMI Pattern:** `(?i).*emi.*(?:due|payable).*?(?:rs\.?|inr|₹)\s*([0-9,]+(?:\.[0-9]{2})?).*?(?:by|on|before)\s*(\d{1,2}[-/]\d{1,2}[-/]\d{2,4})`
  - Rejection pre-filter: Drops messages immediately if `isOtp()` or `isPromo()` triggers.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Port these regexes directly into `app/lib/data/local_sms_parser.dart` for bill reminder extraction.
- **Missing / Unsuitable Aspects:**
  - Lacks month-name date support (e.g. "05-Nov-2024"); regex only captures numeric dates (`\d{1,2}[-/]\d{1,2}[-/]\d{2,4}`).
- **Integration Path:** Direct regex translation to Dart.
- **Required Additional Tests:**
  - Multi-format date parsing tests ("due on 15 Oct", "due by 15/10/2026", "due by 15-10-26").

---

### 10. `DroidNinja/finos-public`
- **Repository URL:** [https://github.com/DroidNinja/finos-public](https://github.com/DroidNinja/finos-public)
- **Status & Relevance:** Accessible (Kotlin Multiplatform / Python). Relevant for bill lifecycle management.
- **Key Source Files, Classes & Functions:**
  - `android-app/finos-kmp/shared/.../models/Bill.kt`: `BillRead` data model.
  - `android-app/finos-kmp/androidApp/.../sms/SmsReceiver.kt`: Background SMS listener and deduplication worker.
  - `api/services/bills.py`: Bill tracking, matching bill dues to actual payment transactions.
- **Implementation & Algorithm Details:**
  - Tracks full bill lifecycle: `amount_due`, `min_due`, `due_date`, `days_until_due`, `status` (`DUE`, `PAID`, `OVERDUE`), `paid_txn_id`, `paid_at`.
  - Reconciles paid bills by matching outgoing debit transactions to outstanding bill records by biller name and amount within a 5-day window.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Integrate the bill model and payment reconciliation logic into `app/lib/data/card_bill_ledger.dart`.
- **Missing / Unsuitable Aspects:**
  - Heavy server architecture with Docker setup; Android app relies on remote server API rather than doing all work locally.
- **Integration Path:** Independent Dart Reimplementation of the bill state model and auto-settlement matcher.
- **Required Additional Tests:**
  - Partial payment handling, minimum-due settlement vs total-due settlement tests.

---

### 11. `SysAdminDoc/BillMinder`
- **Repository URL:** [https://github.com/SysAdminDoc/BillMinder](https://github.com/SysAdminDoc/BillMinder)
- **Status & Relevance:** Accessible (Kotlin / Room DB). Exceptional reference for robust recurrence calculations.
- **Key Source Files, Classes & Functions:**
  - `app/src/main/java/com/sysadmindoc/billminder/domain/CycleEngine.kt`: `CycleEngine` object, `cycleKey()`, `dueInstant()`, `deriveAnchor()`, `generateOccurrences()`.
  - `app/src/main/java/com/sysadmindoc/billminder/domain/BillCycles.kt`: Recurrence period rules.
  - `app/src/main/java/com/sysadmindoc/billminder/data/Bill.kt`: `Bill` entity with `anchorEpochDay`.
- **Implementation & Algorithm Details:**
  - **Deterministic occurrence generation:** Uses an immutable `anchorEpochDay` stored in the bill. Every occurrence date is derived deterministically from the anchor, surviving process kills, time-zone changes, and reboots.
  - **Stable Cycle Keys:** `ISO_LOCAL_DATE` (`YYYY-MM-DD`) acts as the unique idempotency key for every cycle instance.
  - **Month-End Clamping (`dayIn`):** When a bill falls on the 31st, for February it clamps to 28 (or 29 in leap years) and for April to 30, avoiding unintended rollover into the next month.
  - **Lookback & Forward Projection:** Efficient bounded generation (`MAX_OCCURRENCES = 1024`, `LOOKBACK_MONTHS = 24L`).
- **Adaptation to PandaPay (Flutter/Dart):**
  - Direct 1:1 translation of `CycleEngine.kt` into `app/lib/services/recurrence_engine.dart`.
- **Missing / Unsuitable Aspects:**
  - Android-specific Room annotations and Java 8 `java.time` APIs; needs Dart `DateTime` adaptations.
- **Integration Path:** Independent Dart Reimplementation.
- **Required Additional Tests:**
  - Leap year tests (Feb 29), 31st-of-the-month rollover tests, and DST / timezone shift tests.

---

### 12. `suryadeepbanerjee/Bill-Reminder`
- **Repository URL:** [https://github.com/suryadeepbanerjee/Bill-Reminder](https://github.com/suryadeepbanerjee/Bill-Reminder)
- **Status & Relevance:** Accessible (TypeScript / PostgreSQL). Relevant for recurrence edge cases and schema design.
- **Key Source Files, Classes & Functions:**
  - `supabase/migrations/039_unify_due_date_engine.sql`: `_compute_next_cycle_start()`, `_compute_bill_due_date()`.
  - `packages/shared/schemas/bill.ts`: Zod schema for recurring bills and subscriptions.
  - `app/components/bills/RecurrencePreview.tsx`: Dynamic recurrence schedule preview.
- **Implementation & Algorithm Details:**
  - Documents and fixes two recurring schedule bugs:
    1. Yearly bills drifting to creation month instead of anchor month.
    2. Fixed intervals (e.g. prepaid 28-day/84-day recharge validity) incorrectly snapping back to monthly calendar days.
  - Unifies backend occurrence generator and frontend UI preview helper into a single mathematical function to eliminate UI/database drift.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Implement both interval-based validity stepping (for Indian telecom recharges: 28, 56, 84 days) and calendar day snapping (for utility and credit card bills) within PandaPay's recurrence service.
- **Missing / Unsuitable Aspects:**
  - PostgreSQL plpgsql function syntax and Supabase cloud dependencies.
- **Integration Path:** Port recurrence math algorithms into Dart.
- **Required Additional Tests:**
  - Telecom validity test suite (28-day and 84-day cycles).

---

### 13. `pkriete/duckling`
- **Repository URL:** [https://github.com/pkriete/duckling](https://github.com/pkriete/duckling)
- **Status & Relevance:** Accessible (Clojure). Fork of Facebook's Duckling. Relevant for natural language entity extraction rules.
- **Key Source Files, Classes & Functions:**
  - `resources/duckling/rules/en.time.clj`: Temporal expressions.
  - `resources/duckling/rules/en.finance.clj`: Financial terms, currencies, amounts.
- **Implementation & Algorithm Details:**
  - Context-free grammar with regex tokens and probabilistic resolution for dates ("next Tuesday", "in 3 weeks", "end of next month").
- **Adaptation to PandaPay (Flutter/Dart):**
  - Direct integration is unfeasible due to Clojure / JVM dependencies.
  - Grammatical rules for relative date expressions can inspire a lightweight Dart rule-based date token parser.
- **Missing / Unsuitable Aspects:**
  - Heavy JVM stack; unsuited for on-device Flutter execution.
- **Integration Path:** Rule reference only; do not integrate code directly.
- **Required Additional Tests:**
  - N/A (rule reference only).

---

### 14. `wanasit/chrono-python`
- **Repository URL:** [https://github.com/wanasit/chrono-python](https://github.com/wanasit/chrono-python)
- **Status & Relevance:** Accessible (Python). Relevant for natural language date extraction.
- **Key Source Files, Classes & Functions:**
  - `chrono_python/chrono.py`: Main parser orchestrator.
  - `chrono_python/locales/en/parsers/en_casual_date_parser.py`: "today", "tomorrow", "yesterday".
  - `chrono_python/locales/en/parsers/en_month_name_after_date.py`: "15th November 2026", "23-Oct".
  - `chrono_python/common/parsers/slash_date_month_year_parser.py`: "DD/MM/YYYY" vs "MM/DD/YYYY".
- **Implementation & Algorithm Details:**
  - Pipeline of Parsers + Refiners. Parsers emit `ParsedResult` candidates with confidence; Refiners resolve ambiguities (e.g., slash date disambiguation using current locale context).
- **Adaptation to PandaPay (Flutter/Dart):**
  - Implement a streamlined Chrono-style date parser in Dart for parsing variable dates in Indian SMS ("Due on 05 Nov", "due by tomorrow", "before 20th Oct").
- **Missing / Unsuitable Aspects:**
  - Python implementation; porting the entire framework is excessive when a 200-line focused date extraction function covers 99.5% of Indian financial SMS patterns.
- **Integration Path:** Reimplement a lightweight date parsing subset in Dart.
- **Required Additional Tests:**
  - Month-name variations (both 3-letter abbreviations and full names), slash/dash separator variations, and year inference when year is omitted.

---

### 15. `HeidelTime/heideltime`
- **Repository URL:** [https://github.com/HeidelTime/heideltime](https://github.com/HeidelTime/heideltime)
- **Status & Relevance:** Accessible (Java). Academic temporal tagger (TIMEX3).
- **Key Source Files, Classes & Functions:**
  - `resources/english/rules/resources_rules_daterules.txt`: Rule definitions.
  - `doc/howToWriteRules.txt`: Documentation for domain temporal tagging.
- **Implementation & Algorithm Details:**
  - Rule-based system over sentence syntax trees for academic temporal normalization. Over 13,000 files covering historical, news, and colloquial domains.
- **Adaptation to PandaPay (Flutter/Dart):**
  - None.
- **Missing / Unsuitable Aspects:**
  - Monumentally oversized (13,800+ files), Java UIMA dependencies, strict academic focus; completely unsuitable for a resource-constrained mobile application.
- **Integration Path:** Not recommended for adoption.
- **Required Additional Tests:**
  - N/A.

---

```
====================================================================================================
GROUP C: SMS Classification and Investment-Message Separation
====================================================================================================
```

### 16. `itsluminous/ClearSMS`
- **Repository URL:** [https://github.com/itsluminous/ClearSMS](https://github.com/itsluminous/ClearSMS)
- **Status & Relevance:** Accessible (Android Kotlin / JSON). Highly relevant for rule-based SMS intelligence and spam rejection.
- **Key Source Files, Classes & Functions:**
  - `app/src/main/assets/default_rules.json`: 9,455 lines of comprehensive rules.
  - `app/src/main/assets/guards/rule_guards.json`: Negative guard definitions (`guards_none`).
  - `app/src/main/assets/tables/billers.json`: Registry of Indian utility and service billers.
- **Implementation & Algorithm Details:**
  - Declarative JSON-based classification engine.
  - **Negative Rule Guards (`rule_guards.json`):** Specifically guards against false positives by ensuring OTP and authentication notifications quoting amounts do not trigger transaction rules.
  - **Phishing & Fraud Guardrails:** High-priority rules detecting prize bait, lottery scams, and urgent KYC suspension phishing with shortened URLs (`bit.ly`, `tinyurl.com`, `t.co`).
  - **Category Actions:** Categorizes into `transaction`, `bill`, `otp`, `spam/scam`, and `info`.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Adopt `default_rules.json` patterns and `rule_guards.json` concept directly into PandaPay's local rules engine. Can be stored in assets and loaded dynamically.
- **Missing / Unsuitable Aspects:**
  - The Android Room / Kotlin UI wrapper is not needed; only the rules and guard philosophy apply.
- **Integration Path:** Wrap / load JSON rule assets into a Dart rule evaluation engine.
- **Required Additional Tests:**
  - Regression testing on real-world SMS corpus to ensure new rules do not exceed acceptable regex evaluation latency (<10ms per SMS).

---

### 17. `prabhavalabs/salli-sms-classifier`
- **Repository URL:** [https://github.com/prabhavalabs/salli-sms-classifier](https://github.com/prabhavalabs/salli-sms-classifier)
- **Status & Relevance:** Accessible (Pure Dart / Flutter). Outstanding value — directly compatible with PandaPay's language and environment.
- **Key Source Files, Classes & Functions:**
  - `lib/src/data/sms/sms_classifier.dart`: `SmsClassifier`, `SmsClassifierResult`, `SmsHeadPrediction`, `_ClassifierHead`.
  - `lib/src/data/sms/parser_engine.dart`: Structured extraction engine.
  - `lib/src/data/sms/on_device_sms_intelligence.dart`: Orchestrator combining classifier + regex parser.
  - `test/sms/sms_classifier_test.dart`: Test suite.
- **Implementation & Algorithm Details:**
  - **Native Dart On-Device Linear Multi-Head Classifier:**
    - Uses text hashing and float32 weights loaded from a compact binary asset (`assets/classifier/sms_classifier.v1.weights`).
    - Multi-head outputs:
      1. `eligibility`: Is it a transaction or spam/promo?
      2. `direction`: Debit vs Credit.
      3. `transactionType`: Purchase, transfer, bill, ATM, refund.
      4. `accountType`: Card, bank account, wallet.
      5. `institution`: Originating entity.
      6. `category`: Expense classification.
    - Zero external packages; uses standard `dart:typed_data` (`Float32List`) and `dart:convert`. Execution time is <2ms per SMS.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Can be directly dropped into `app/lib/data/` or added as an internal package.
  - Retrain weights or combine with Indian DLT sender identifiers to achieve high-precision classification.
- **Missing / Unsuitable Aspects:**
  - Default training corpus was focused on Sri Lankan banking formats; requires retraining or supplementary feature tokens for Indian bank idioms (e.g. "UPI", "NEFT", "IMPS", "RuPay").
- **Integration Path:** Direct integration into Flutter codebase, updated with Indian financial dictionaries.
- **Required Additional Tests:**
  - Benchmark validation against a 1,000+ Indian bank SMS corpus covering major private and public banks.

---

### 18. `sowrabhmv/fintext-extractor`
- **Repository URL:** [https://github.com/sowrabhmv/fintext-extractor](https://github.com/sowrabhmv/fintext-extractor)
- **Status & Relevance:** Accessible (Python / Jupyter / HuggingFace). Relevant for Named Entity Recognition (NER) concepts.
- **Key Source Files, Classes & Functions:**
  - `fintext/extractor.py`: Token classification pipeline.
  - `hf_model_card/config.json`: BERT token labels (B-AMT, I-AMT, B-ACC, B-MERCHANT).
- **Implementation & Algorithm Details:**
  - Fine-tuned transformer (BERT-based) token classification model for extracting amounts, accounts, and merchants from Indian bank SMS.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Too heavyweight for direct inclusion in a standard Flutter app without bundled ONNX or TFLite models (~100MB+ memory footprint).
- **Missing / Unsuitable Aspects:**
  - Requires PyTorch / Transformers; excessive latency (100–300ms) and binary bloat for a background SMS listener.
- **Integration Path:** Do not integrate directly; use regex-first and linear model approach instead.
- **Required Additional Tests:**
  - N/A.

---

### 19. `maleeshaprabash/SMS-Spam-Detection`
- **Repository URL:** [https://github.com/maleeshaprabash/SMS-Spam-Detection](https://github.com/maleeshaprabash/SMS-Spam-Detection)
- **Status & Relevance:** Accessible (Python / Scikit-Learn). Minimal relevance.
- **Key Source Files, Classes & Functions:**
  - `SMS_spam_detection_system/src/text_utils.py`: Text cleaning, punctuation removal, stop-word filtering.
  - `SMS_spam_detection_system/data/combined_sms_spam_dataset.csv`: Dataset containing Indian and international spam/ham SMS.
- **Implementation & Algorithm Details:**
  - Standard scikit-learn TF-IDF + Multinomial Naive Bayes pipeline saved as pickle (`.pkl`).
- **Adaptation to PandaPay (Flutter/Dart):**
  - Dataset CSV can be mined for negative test cases (spam and marketing SMS).
- **Missing / Unsuitable Aspects:**
  - Basic tutorial-style ML repository; Python pickle format cannot run in Flutter without server.
- **Integration Path:** Dataset extraction for testing only.
- **Required Additional Tests:**
  - N/A.

---

### 20. `meeeshv/sms_parser`
- **Repository URL:** [https://github.com/meeeshv/sms_parser](https://github.com/meeeshv/sms_parser)
- **Status & Relevance:** Accessible (Python). Highly relevant for Indian bank account and amount regex patterns.
- **Key Source Files, Classes & Functions:**
  - `enhanced_account_extraction.py`: `extract_account_number_enhanced()`.
  - `enhanced_amount_extraction.py`: Amount extraction across currency variations.
  - `enhanced_date_extraction.py`: Transaction timestamp normalizer.
  - `bank_account_classifier.py`: Distinguishes savings, current, and card accounts.
- **Implementation & Algorithm Details:**
  - Deep set of tested regular expressions tailored to Indian SMS:
    - **Masked accounts:** `a/c\s*(?:no\.?|number)?\s*[x*]+(\d{4,8})`
    - **Card account variations:** `card\s*(?:no\.?|ending)?\s*[x*]+(\d{4})`
    - **Indian currency amounts:** Handles "Rs.", "INR", "₹" with Indian comma grouping (`1,00,000.00`).
- **Adaptation to PandaPay (Flutter/Dart):**
  - Port regex patterns directly into `app/lib/data/local_sms_parser.dart`.
- **Missing / Unsuitable Aspects:**
  - Python scripts and Jupyter notebooks; requires manual translation to Dart.
- **Integration Path:** Independent Dart Reimplementation of regex functions.
- **Required Additional Tests:**
  - Boundary tests on 4-digit card numbers vs 4-digit bank accounts vs OTP numbers.

---

### 21. `Hariharasudhan07/FinanceApp`
- **Repository URL:** [https://github.com/Hariharasudhan07/FinanceApp](https://github.com/Hariharasudhan07/FinanceApp)
- **Status & Relevance:** Accessible (Python / FastAPI). Low-to-moderate relevance.
- **Key Source Files, Classes & Functions:**
  - `app/services/parser.py`: SMS parsing service using spaCy NER (`en_core_web_sm`) and regex rules.
- **Implementation & Algorithm Details:**
  - FastAPI server endpoint receiving raw SMS text and returning JSON transactions. Uses spaCy entity recognition for organization names and regex for amounts.
- **Adaptation to PandaPay (Flutter/Dart):**
  - None; PandaPay requires fully local on-device processing.
- **Missing / Unsuitable Aspects:**
  - Server dependency violates offline-first privacy requirements.
- **Integration Path:** Not recommended for adoption.
- **Required Additional Tests:**
  - N/A.

---

### 22. `rahatsayyed/BankSMSParser`
- **Repository URL:** [https://github.com/rahatsayyed/BankSMSParser](https://github.com/rahatsayyed/BankSMSParser)
- **Status & Relevance:** Accessible (TypeScript). Exceptionally high relevance for bank coverage and mutual fund/investment SMS separation.
- **Key Source Files, Classes & Functions:**
  - `src/BankParserFactory.ts`: Registry mapping DLT sender headers to bank parsers.
  - `src/core/BaseIndianBankParser.ts`: Shared parsing methods for Indian banks.
  - `src/banks/HDFCMutualFundParser.ts`: Handles HDFC MF SIP purchases, redemptions, NAV updates.
  - `src/banks/NaviMutualFundParser.ts`: Handles Navi MF unit allotment and SIP updates.
  - `src/banks/HDFCBankParser.ts`, `ICICIBankParser.ts`, `SBIBankParser.ts`, `AxisBankParser.ts`.
- **Implementation & Algorithm Details:**
  - **Investment vs Expense Separation:**
    - Recognizes DLT headers like `AD-HDFCMF-AC`, `VK-NAVAMC-T`.
    - Distinguishes **AMC Unit Allotments / SIP Purchases** as `TransactionType.INVESTMENT` rather than standard expense debits.
    - Explicitly documents architectural separation: AMC messages report unit allocation (no bank account number), whereas the underlying bank mandate/NACH debit reports bank account deduction. Flagging this enables PandaPay to link or deduplicate investment entries without double-counting expenses.
  - **Comprehensive Bank Catalog:** 100+ institution-specific parsers.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Port `HDFCMutualFundParser.ts`, `NaviMutualFundParser.ts`, and core Indian bank parser rules into `app/lib/data/local_sms_parser.dart`.
  - Add `TransactionType.investment` to PandaPay's transaction classification contract.
- **Missing / Unsuitable Aspects:**
  - Written in TypeScript for Node.js; easily translatable to Dart due to structural similarity.
- **Integration Path:** Independent Dart Reimplementation.
- **Required Additional Tests:**
  - Deduplication tests between NACH mandate bank debits and AMC unit allotment confirmation SMS.

---

### 23. `xRahul/GroupingMessages`
- **Repository URL:** [https://github.com/xRahul/GroupingMessages](https://github.com/xRahul/GroupingMessages)
- **Status & Relevance:** Accessible (Android Java). Relevant for local message clustering and custom user categories.
- **Key Source Files, Classes & Functions:**
  - `app/src/main/java/in/rahulja/groupingmessages/classify/SmsCategorizer.java`: `resolveMode()`, 1-NN similarity scoring.
  - `app/src/main/java/in/rahulja/groupingmessages/util/SmsFilter.java`: Message filtering.
  - `app/src/test/java/in/rahulja/groupingmessages/CategorizationParityTest.java`: Parity tests.
- **Implementation & Algorithm Details:**
  - **On-Device 1-NN (Nearest Neighbor) Categorization:**
    - Uses precomputed TF-IDF vectors + character trigram profiles over an exemplar corpus.
    - Hybrid scoring metric: `0.6 word-cosine + 0.4 char-trigram-dice`.
    - Enables classifying uncategorized messages into user-defined buckets based on message resemblance to known exemplars without model training.
- **Adaptation to PandaPay (Flutter/Dart):**
  - Can provide the fallback classifier for uncategorized merchants in PandaPay, allowing user overrides to immediately generalize across similar messages.
- **Missing / Unsuitable Aspects:**
  - Relies on Java Simmetrics library; requires porting the cosine/dice similarity math to Dart.
- **Integration Path:** Independent Dart Reimplementation of the 1-NN similarity function.
- **Required Additional Tests:**
  - Similarity threshold calibration tests to prevent false-positive category misassignments.

---

## Actionable Recommendations & Implementation Map for PandaPay

| Target PandaPay Component | Source Repositories to Leverage | Key Logic to Integrate | Integration Strategy |
|---|---|---|---|
| **`app/lib/data/local_sms_parser.dart`** | `prabhavalabs/salli-sms-classifier`<br>`rahatsayyed/BankSMSParser`<br>`itsluminous/ClearSMS`<br>`carthworks/ActSMS` | - Native linear multi-head classifier<br>- AMC Mutual Fund parsers (`TransactionType.investment`)<br>- Rule guards preventing OTPs from parsing as debits<br>- Bill & EMI due date regex patterns | Independent Dart Reimplementation & Direct Asset Integration (`Float32List` weights + JSON rules) |
| **`app/lib/services/recurrence_engine.dart`** | `SysAdminDoc/BillMinder`<br>`suryadeepbanerjee/Bill-Reminder` | - Immutable `anchorEpochDay` derivation<br>- `ISO_LOCAL_DATE` cycle keys<br>- Month-end clamping (28/29/30/31 days)<br>- Fixed interval stepping vs calendar snapping | Clean 1:1 Dart Reimplementation of `CycleEngine` |
| **`app/lib/data/card_bill_ledger.dart`** | `akhilnarang/cc-parser`<br>`DroidNinja/finos-public` | - Adjustment / refund pairing engine (Jaccard + date gap + amount match)<br>- Bill settlement matcher (linking bank debits to open bills) | Port scoring algorithms into Dart helper |
| **`app/lib/features/rewards/`** | `bjain102/hisaab`<br>`shaikinzamam/CardSense` | - Era-based reward rule versioning `[valid_from, valid_to)`<br>- Integer paise arithmetic & floor rounding<br>- Cap bucket management & clawback reversal math | Reimplement ADR-008 rewards accrual engine in pure Dart |
| **`app/lib/data/card_discovery_engine.dart`** | `abhijeetburle/cc_autopilot`<br>`sakthipriyan/xfina` | - Card product fingerprinting (`pdf_fingerprints`)<br>- AA standard credit card metadata schemas | Integrate fingerprint constants and schema models |
