# PandaPay SMS Classification: Gaps, Fixes and Plan

Nov 2, 2026 · @ck

## Summary

Keep the capture plumbing and redesign the middle layer, where a message becomes money in the ledger. Build it in internal milestones and ship it as one release; no in-between version reaches users. No more one-off regex patches, and no full rewrite.

- **Measured:** on 35 realistic test messages covering the reported problems, the server got 16 fully right. Its result replaces the phone's after sync, so that is what users see; the phone alone got 21. Ordinary card and UPI spends mostly work. IPO holds, card bill payments, wallets and reward points mostly don't.
- **Most errors are not category errors.** They are "what kind of money event is this?" and "is this the same event as another message?" errors. A parser that reads one message at a time cannot fix the second kind.
- **Accounts and wallets have nowhere to live.** Only cards have a table. A bank account is a 4-character string on a transaction, so there is nothing to auto-detect into.
- **Phone and server both parse every message.** About 5,250 lines of hand-synced rules, in Dart and JavaScript, disagree with each other. One rule source and one parse removes the duplicate code and half the work.
- **Nothing measures accuracy.** About 47 labeled test messages exist, against tens of thousands on one real phone. Step one is a golden set built from real messages, grouped by template.
- **Target:** at least 99% on event type, amount and account/card (weighted by amount), at least 95% on category, and zero double-counted transfers. When the system is less sure than that, it asks instead of guessing.

## Answers to your questions

### 1. Testers flag a wrong transaction, admin reviews it. How does that become a fix?

Today a flagged case reaches the admin page but cannot become a fix. Each case carries:

- the original decision and the rule that produced it
- the corrected fields
- a redacted copy of the message
- an AI diagnosis

Admin approval only feeds automatic shared rules. A category rule needs 10 different users agreeing on the same merchant, sender and wording; a parser rule needs 5 users with the same template. With 14–15 testers those thresholds will rarely be met. Nothing turns an approved case into a code change. The case also does not record the app version, parser version, rule-bundle version or which stage went wrong.

The fix is two lanes from the same admin case (details in "Tester correction loop"):

- **Lane A, data fix, no app release:** wrong category, unknown merchant, new bank wording, or noise to ignore. The admin approves, the rule is added to the downloadable rule bundle, and phones pick it up. For the tester group, one admin-verified case is enough, since the admin replaces the crowd vote.
- **Lane B, code fix, next release:** wrong event kind, double counting, or a missing account or card. The admin clicks "Send to engineering", and the case becomes a failing test in the golden set, tagged with the stage that failed.

A project skill, `sms-fix-case`, then does the developer side for a case ID:

1. Replays the message and finds the stage and file at fault.
2. Writes the failing test at that stage.
3. Makes the smallest fix.
4. Runs the whole golden set to prove nothing else broke.

This skill does not exist yet. It only works well once every decision records why it was made, which WP-12 adds.

### 2. Did you check the phone and the server? Are there wasted calls?

Yes. The main waste:

- **Every financial SMS is parsed twice.** The phone parses it, uploads the raw text, and the server re-parses it with different rules. The server's answer replaces the phone's.
- **About 20–40 database queries per message on the server, one message at a time.** The transaction writer alone runs 11 queries, plus category, card, limit, due-day and pairing lookups.
- **One HTTP request per message** for facts upload and for AI job submission.
- **AI status polling:** one GET per pending review item, every 90 seconds while the app is open, plus on every resume.
- **AI capacity is hard-capped at 30 requests a minute for all users combined**, about 7,200 messages an hour, and AI runs per message rather than per template.
- **The bank-account list is rebuilt on every read** by scanning all stored observations.
- **Card discovery also exists twice**, about 1,360 lines of mirrored Dart and JavaScript.

Already done well: regexes are compiled once and cached, inbox reads are paged with checkpoints, transaction uploads are batched 200 at a time, AI requests are grouped 4 at a time, and retries are durable with backoff.

### 3. Will it hold up at millions of users?

Not as it stands. The breaking points, in order:

1. AI throughput and cost
2. Per-message HTTP traffic and polling
3. Double parsing and per-message queries during history import
4. One 10,219-line `index.js` that mixes every concern

The direction: parse once on the phone, upload compact facts in batches, and let the server validate and store them with set-based writes. Run AI once per template and cache the answer. Replace polling with one batched status call or a push notification.

### 4. Auto-detection of cards, wallets and accounts. Was something removed?

Partly. What exists today:

- Bank accounts are derived from SMS, but the logic is fragile.
- Card discovery runs only when someone opens Find Cards.
- The Gmail card discovery screen was hidden on 20 October 2026, but its service file is still in the code.

These never existed:

- payment wallets (Paytm, Amazon Pay, Zomato Money)
- broker and demat accounts
- points balances read from SMS
- an automatic "we found a new card" prompt

Credit limits are filled from SMS only once and never updated. The plan is one Instrument registry, filled automatically from every message, which the user confirms once.

### 5. How do we avoid redundant code?

Each decision gets exactly one owner:

- one parser, with rules shipped as shared data rather than mirrored code
- one category resolver
- one instrument resolver
- one discovery engine

The pull request that moves a piece also deletes its old path.

## What was tested

The server ends fully correct on 16 of 35 targeted messages, and the phone on 21. The cases were picked because they are hard, so this is not overall accuracy. It does reproduce every symptom reported.

Method: 35 synthetic SMS in real Indian bank formats (HDFC, ICICI, SBI, Axis, Kotak, Amex, Paytm, Zomato, Amazon Pay) were run through the phone parser (`LocalSmsParser.parse`) and the server parser (`parseSmsAgainstPatterns`). "Fully correct" means four things were right:

- whether a ledger row should exist
- event kind
- amount
- card or account

Merchant name was not scored, so real accuracy on these cases is lower. Test file: `docs/sms-pipeline-v2/seed/probe_cases.json; WP-00 turns it into golden cases`.

| Area | Phone | Server (what users see) | What goes wrong |
| --- | --- | --- | --- |
| Card bill payments | 0/5 | 0/5 | The bank debit and the card's "payment received" become two rows. Amex "ending 10005 on 10 Nov 2026" is read as card 2026. A CRED payment is labelled "Money received". |
| Rewards and refunds | 1/4 | 0/4 | "Earned 50 points worth ₹50" is booked as a ₹50 transfer. A refund loses its merchant and has no refund kind. Phone and server disagree on redemptions. |
| Wallets | 2/5 | 2/5 | A Paytm top-up from the bank is booked as spending, then the wallet purchase is spending again. Zomato Money and Amazon Pay balance payments are not recognised. "Paytm" is stored in the account last-4 field. |
| Bank accounts | 5/6 | 3/6 | "A/c no. XX123456" (Axis), "AC X1234" (Kotak) and "Acct XX1234" (ICICI) produce no account. A cheque debit goes to review on the server. |
| IPO and Groww | 4/6 | 4/6 | The phone books an ASBA block as a ₹14,250 investment, and the release as a second one. The server has no IPO rules: the allotment debit becomes spending with merchant "Rs 14". |
| Subscriptions | 4/4 | 3/4 | Kind is right, but merchants are lost or raw: "Bank debit", "UPI Mandate NETFLIX", "SPOTIFY SI". Nothing links the debit to its mandate. |
| Credit limits | 5/5 | 4/5 | "Limit enhanced to ₹3,00,000" is not recognised, and a limit offer lands in Needs Review. "Avl Lmt" on every card spend is ignored. |

## What real messages showed

Today's pipeline was also run on a year of real bank and service messages from one phone. That data stays private and is never committed. It confirmed every synthetic finding and added failure families the probes missed. Counts, names and amounts are left out on purpose.

| Failure family | What happens today | Fix (work package) |
| --- | --- | --- |
| Card statements and bill reminders | Booked as spending | `bill_due` rules (03c) |
| Card bill payments | Counted twice: a bank debit plus the card's own "payment received" | `LINK-CARD-BILL` (05) |
| Card bills paid through bill-pay apps (CHEQ, CRED, BBPS billers, Tata Neu, PayZapp) | Booked as spending, often with no card-side receipt | Counterparty-purpose rules (03b), linker (05) |
| Failed and upcoming standing-instruction debits | Booked as spending or transfers | `attempt` rules (03c) |
| IPO and UPI one-time mandate holds | Filed as bills or AutoPay mandates; no hold is shown | `hold` rules (03c), `LINK-IPO` (05) |
| Debits made under a mandate | Missed | `movement` with `mandateRef` (03c) |
| Wallets (Zomato Money, Pluxee, Amazon Pay and others) | Not recognised, or loads booked as spending | Wallet rules (03b) plus the decision below |
| Biller and app receipts | Booked as spends, duplicating the real debit | `evidenceOnly` receipts and `LINK-RECEIPT` (05) |
| One bank account under several sender IDs | Split into separate accounts | Issuer-level instrument key (04), sender registry (03a) |
| Cards with no printed digits | Spends not linked to a card | Mask rules and the date-overlap guard (02, 03a) |
| iOS sender tag such as `YESBNK-S(smsft_fi)` | No code handles it | `normalizeSenderBrand` (02); verify the Shortcut's format (14) |
| Finance messages neither parser understands | Each becomes a review item or an AI job | Rules, plus ignore rules for broker payable notices, collect requests and loan-consent offers |
| Refunds | Booked as plain transfers, or missed | Refund rules (03a, 03b) |
| Dividends and broker payouts | Not recognised | Purpose `dividend`, broker payout rules (03a, 03c) |
| Phone and server disagree | Answers change after sync | Removed by design: one parser |

Other measured facts:

- **OTPs** were all ignored correctly.
- **iOS filter tags** include Transactions, Finance, Promotions, Reminders and Orders. The Promotions tag is a free signal for the safety gate.
- **Scale:** roughly ten to fifteen messages a day per user means more than ten million a day at one million users. AI per message is not viable; AI per template is.

**Capture risk (P0, check first).** On iPhone, the archive stores senders as `ICICIT-S(smsft_fi)`. The app's capture check (`looksLikeContactName`) treats a sender with that tag as a personal contact. If the Shortcut passes the tagged sender, almost nothing from banks gets in, salary included. The fix is to strip the tag before the safety gate (WP-14) and test it with every tag.

Changes this made to the plan, already applied in the tabs:

- **Contracts:** `SmsMessage.iosFilter`, movement purpose `dividend`, movement attribute `evidenceOnly`, the `LINK-RECEIPT` link rule, and sender entries `walletSpendVisibility` and gateway senders.
- **WP-02:** strips the iOS tag before matching senders.
- **WP-03:** works through a real-template checklist, in order of weight.
- **WP-05:** joins receipts to the debit they confirm.
- **WP-14:** checks what sender string the Shortcut actually delivers.
- **WP-00:** imports a redacted set as the first real golden set.

**Decided on 3 November 2026: Amazon Pay top-ups count as spending.**

- A top-up from a card or bank account becomes a purchase at Amazon, in category `online`.
- Amazon Pay balance-payment messages only update the wallet's balance and activity list. They never count as spending and never go to review, so nothing counts twice.
- Refunds and cashback paid into the Amazon Pay balance still reduce spending or count as cashback.
- Wallets that send an SMS for every purchase (Zomato Money, Pluxee, Paytm) keep the other model: the top-up is a transfer, and each wallet purchase is the spend.

### Subscriptions, IPOs, investments and money in

The messages are there, but today's app files them under the wrong kind. That is why subscriptions, IPOs and income look wrong.

- **Subscriptions:** today's detector finds few series and shows no names. The new list comes from mandates plus charge events. It shows active, cancelled and failed-payment states, keeps past subscriptions, and never includes one-time mandates.
- **IPOs:** block, unblock and mandate messages are filed as bills or AutoPay. The fix: an IPO application becomes one event (applied, amount blocked, then allotted as a debit counted as investment, or released). It never appears in spending, bills or subscriptions. A **Your IPO applications** screen lists each one.
- **Investments:** money to brokers is booked inconsistently, money back is never seen as a withdrawal, and NSE and BSE fund-balance reports are ignored although they are free balance data. The fix: Investments becomes its own area, never a spend category. Per platform it shows money put in, money taken out, net invested, the latest fund balance and dividends.
- **Money in:** salary credits are classified as income by both parsers, so if salary is missing in the app the cause is upstream (the capture risk above) or the screen. Dividend credits are missed, and many incoming credits are booked as plain transfers. The fix: a Money in view showing:
  - salary, auto-detected after 2 months from the same payer, or confirmed once by the user
  - dividends, refunds and cashback
  - money from people

  Transfers between your own accounts stay out of it.

## Gaps found

23 gaps were found: 8 are P0, meaning they put wrong totals or counts in front of users today. Each one was reproduced or read directly in the code. "Verify" means it needs real messages to confirm. The "Where" column points at the code (paths are relative to the repository root).

| # | Area | Gap | Where | Severity | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Events | The card bill payment is counted twice: the bank debit and the card's "payment received" become two rows. Linking only works bank-to-bank with an identical reference number. | `api/src/index.js:3052` | P0 | Open |
| 2 | Events | The phone books an IPO/ASBA block as an investment, and its release as a second investment. | `app/lib/data/local_sms_parser.dart:1558` | P0 | Open |
| 3 | Events | The server has no IPO rules: the allotment debit becomes spending with merchant "Rs 14". | `api/src/sms_parser.js` | P0 | Open |
| 4 | Events | A wallet top-up from the bank is booked as spending, then the wallet purchase is booked again. | both parsers | P0 | Open |
| 5 | Counts | The Activity count includes every transfer row, and "money out" adds investments. | `app/lib/features/activity/activity_projection.dart:72` | P0 | Open |
| 6 | Accounts | There is no record type for bank accounts, wallets or broker accounts. Accounts are rebuilt on every read using sender-name regex lists, and temporary filters repeat in two places. | `app/lib/data/local/financial_store.dart:1622`, `app/lib/app/providers.dart:3685` | P0 | Open |
| 7 | Accounts and cards | Card or account last-4 extraction breaks on the year ("2026" read as a card), 5-digit Amex, 6-digit masks, "AC X1234" and "Acct XX1234". | both parsers | P0 | Open |
| 8 | Process | There are about 47 labeled examples and no accuracy measurement on real messages. | `app/test/fixtures` | P0 | Open |
| 9 | Architecture | Two parsers (about 3,500 lines of Dart and 1,750 of JavaScript) disagree, and the server's answer replaces the phone's. The IPO rule is copied 4 times in Dart and missing in JavaScript. | `local_sms_parser.dart`, `sms_parser.js` | P1 | Open |
| 10 | Rewards | "Earned 50 points worth ₹50" is booked as a ₹50 transfer. The points balance is never read from SMS. | both parsers | P1 | Open |
| 11 | Accounts | A filter drops every account from senders containing "UPI". SBI UPI alerts likely name the user's own account, so SBI accounts may never appear. | `app/lib/data/local/financial_store.dart:1654` | P1 | Verify |
| 12 | Limits | "Limit enhanced to ₹3,00,000" is missed. A limit is written only when empty, so it never updates. "Avl Lmt" on every card spend is ignored. | `api/src/card_limit_parser.js`, `api/src/import_resolvers.js:237` | P1 | Open |
| 13 | Events | Refunds have no kind of their own. A refund loses its merchant and does not reduce that category's spending. | both parsers | P1 | Open |
| 14 | Data types | An unknown entry kind silently loads as spending. | `app/lib/data/user_cards_repository.dart:282` | P1 | Open |
| 15 | Merchants | Merchant names are lost or left raw: "Bank debit", "UPI Mandate NETFLIX", "SPOTIFY SI", "Money received" on a debit. | both parsers | P1 | Open |
| 16 | Categories | A wrong category is never sent to AI or review. The server's history lookup can lock in an old wrong label. | `api/src/import_resolvers.js` | P1 | Open |
| 17 | AI checks | AI can use the available limit as the spent amount and still score 0.995. | `api/src/ai_fact_evidence.js` | P1 | Open |
| 18 | Corrections | Correction cases lack app, parser and rule-bundle versions and the failing stage. Approval cannot lead to a code fix, and thresholds are too high for 15 testers. | `api/src/sms_learning.js:465` | P1 | Open |
| 19 | Scale | Double parsing, one HTTP request per message, 90-second status polling, a 30-requests-a-minute AI cap, and 20–40 queries per message. | see "Phone vs server efficiency and scale" | P1 | Open |
| 20 | Wallets | Zomato Money and Amazon Pay balance payments are not recognised, and "Paytm" is stored in the account last-4 field. | both parsers | P2 | Open |
| 21 | Subscriptions | Mandates are not linked to the debits they trigger. | `api/src/subscription_parser.js` | P2 | Open |
| 22 | Categories | An Amazon purchase on a card is filed as Wallet, because the "Amazon Pay" alias wins. | `api/src/merchant_category.js` | P2 | Open |
| 23 | Duplication | Card discovery is mirrored in Dart and JavaScript. Gmail code uses both copies, so all of it stays untouched while Gmail is paused. | `card_discovery_engine.dart`, `card_discovery.js`, `gmail_discovery_service.dart` | P2 | Open |

## Target architecture and data types

Keep capture, the safety gate and the outboxes. Replace the two parsers and the per-screen guessing with four steps that run once, and make every screen read one ledger.

&#91;embedded content: target pipeline · kept, new middle layer, screens\]

The four middle boxes replace today's single-message rule "SMS → at most one row with 4 kinds". Corrections flow back into the extractor as rules, or into the golden set as tests.

| Type | One per | Key fields | Example |
| --- | --- | --- | --- |
| Instrument | Account, card, wallet, broker or loan you own | Kind, issuer, mask pattern (known digits + length), aliases (sender IDs, UPI IDs), links, confirmed or not | HDFC savings ••1234, linked to debit card ••5678 and a UPI ID |
| Fact | Thing a message states | Type: one of the 10 in Contracts (movement, attempt, hold, balance\_snapshot, limit\_change, bill\_due, mandate, reward, instrument\_hint, info); amount in paise + role; unit (INR or points); instrument mention; counterparty; references (UPI ref, UMRN, cheque no.); time; text span; rule + version that produced it | Hold placed: ₹14,250 on HDFC ••1234 for the TATA TECH IPO |
| Event | Real-world thing, possibly spread over several messages | Type (Purchase, CardBillPayment, WalletTopUp, IpoApplication, Refund, SubscriptionCharge, Salary, …); its facts; status; confidence | CardBillPayment = bank debit ₹25,000 + card "payment received" ₹25,000 |
| Ledger entry | Money or points moving between two places | From, to (your instrument or an outside party), amount, unit, event; category only for outside spends | ₹25,000 from HDFC ••1234 to HDFC card ••5678: own to own, not spending |

Rules for the types:

- Each fact type is its own sealed class in Dart (and a tagged union on the wire), never one class with many optional fields.
- Money is whole paise everywhere. The local table that stores amounts as `REAL` (floating point) should change.
- Every field records which rule, model or user set it, so a correction shows exactly which step was wrong.

## Tester correction loop

Each tester flag ends one of two ways. A data fix reaches phones without an app release. A code fix ships in the next release, after a test proves it and the whole golden set still passes.

&#91;embedded content: tester correction loop · 2 lanes\]

The admin page already lists correction cases and records approvals. It needs four additions:

- **Each case carries a trace:**
  - app version, platform, parser version and rule-bundle version
  - the stage that went wrong: gate, extraction, instrument, linking, category or sync
  - which rule set each field
  - the tester's corrected values
- **Cases are grouped by template**, so one admin decision covers every message that shares it.
- **Three buttons instead of approve/reject:**
  - "Data fix" opens a rule draft prefilled from the correction
  - "Code fix" exports a redacted golden case
  - "Not a bug" closes the case with a reason
- **Tester thresholds:** one admin-verified case is enough for a rule that only testers receive. Keep the 10-user rule for automatic rules sent to the public.

The `sms-fix-case` skill, which needs to be built, works as follows for a case ID:

1. Pull the redacted case through the admin API and add it to the golden set at the failing stage.
2. Replay it through the decision trace to confirm the stage and the rule.
3. Write the failing test first, then the smallest fix in the module that owns that decision.
4. Run the whole golden set and both parsers' tests (while both still exist), and report any metric change.
5. Open a pull request that names the case. The admin closes the case when the release ships.

Guardrails: no fix without a failing test first, no rule copied into a second place, no drop in any golden-set metric, and a user's own correction always beats any rule.

## Phone vs server efficiency and scale

At millions of users, AI throughput and per-message network traffic break first. Parsing once on the phone, batching every upload, and running AI per template fix most of it.

| Area | Today | Cost at scale | Fix |
| --- | --- | --- | --- |
| AI capacity | Hard-capped at 30 requests a minute for all users (`Math.min(30, …)` in `ai_provider_quota_route.js`), 4 messages per request, run per message | About 7,200 messages an hour in total; cost grows with every message | Run AI once per template and cache by sender brand + template hash. Make the cap configurable. Give live messages priority over history, with per-user fairness. |
| Parsing | The phone parses, uploads the raw text, and the server parses again with different rules | Double the CPU, raw SMS text on the server, and results that disagree | The phone is the only parser. It uploads typed facts with no raw text; the server checks invariants and stores them. |
| Server writes | 20–40 queries per message, one message after another, up to 200 per request | A 20,000-message history import is roughly 400,000–800,000 queries for one user | Resolve instruments and categories for the whole batch at once, insert in bulk, and run history import as a background job. |
| Facts upload | One HTTP request per message (`logSmsFacts`) | 20,000 requests for one history import | Send 200–500 facts per compressed request. |
| AI job submission | One request per message | Same as above | Submit in batches. |
| AI status checks | One GET per pending review item, every 90 seconds while the app is open, plus on resume | Grows with review backlog × active users | One batched "what changed since" call, or a push notification when a job finishes. Stop polling stale items. |
| Bank-account list | Rebuilt by scanning every stored observation on each refresh, which happens after every capture | Slows down as history grows, and is worst during an import | A stored Instrument table, updated once per message. |
| Rule matching | 329 regex calls in one ordered tree; every learned server pattern is tried on every message | Gets slower with each new rule | Index rules by sender brand so only that bank's templates run, and look up known templates by hash. |
| Server code | `index.js` is 10,219 lines | Risky changes, and every fix needs a full deploy | Move SMS ingestion into its own module and worker. |

Already good: cached regexes, paged inbox reads with checkpoints, 200-message transaction batches, 4-message AI batches, durable retries with backoff, and memoised local repairs.

Privacy also improves: once facts replace raw text, SMS bodies leave the phone only for consented learning samples and redacted AI fallback.

## Security when the phone does the work

Moving parsing to the phone is safe as long as the server never trusts the phone for anything that affects other users or costs money. Someone with the APK can read the rules and fake their own data, but not anyone else's.

| What someone with the APK can do | Why it is acceptable, or how we stop it |
| --- | --- |
| Read every parsing rule | Rules describe public bank SMS formats, so they are not secrets. Real secrets (AI keys, admin tokens, HMAC keys) stay on the server only; the AI key already does. |
| Send fake facts for their own account | That only changes their own data, because row-level security already limits every write to the signed-in user. The server still checks every fact: schema, amount roles, sane ranges, dates, and one event per source key. |
| Flood the API to run up server or AI cost | Per-user and per-device rate limits on facts, AI jobs and status checks (today only the feedback route is limited). Capped batch sizes. AI only for templates not already cached. |
| Poison shared learning with fake corrections | Shared rules come only from admin-reviewed cases, which is already true. Count distinct verified devices, not requests. |
| Run a modified app | Add Play Integrity (Android) and App Attest (iOS) checks at sign-in and on facts upload. An unverified device keeps its own data but gets lower limits and no shared learning. No such check exists today. |
| Tamper with rule downloads | Bundles already carry a SHA-256 checksum. Add a server signature that the app verifies, so a compromised CDN or proxy cannot push rules. |

Still on the server either way: validation, dedupe, storage, cross-device sync, AI calls, shared-learning decisions and rule publishing.

## Tracking and the admin rules table

When the phone decides, every decision still leaves a record the admin can see, without any SMS text.

- **Every fact carries its origin:** rule ID, rule version, engine version and app version. The server stores these with the fact.
- **Phones send daily counts per rule:** hits, sent to review, and corrected by the user. A rule-exposure outbox already exists for downloaded rules; extend it to every rule. No message text is sent.
- **Correction cases carry the full trace** (see "Tester correction loop").
- **New rules start in shadow mode,** which already exists: they run beside the current rule and report disagreements before they are switched on.

The admin console gets a Rules page, extending the existing Parser patterns, Correction cases and Category proposals screens. One row per rule:

| Column | Example |
| --- | --- |
| Rule ID and name | `HDFC-CARD-SPEND-03`, HDFC card spend with available limit |
| Bank and sender | HDFCBK |
| Template preview | `Rs <AMT> spent on HDFC Bank Card x<MASK> at <MERCHANT> on <DATE>. Avl Lmt: Rs <AMT>` |
| Produces | Movement (spend, card) + BalanceSnapshot (available credit) |
| Source | Built-in, admin, learned or AI draft |
| Status | Draft, Testers, Everyone, Paused or Rolled back |
| Version, changed by, changed on | v4, the admin's name, the date |
| Last 7 days | Hits, review rate, correction rate |
| Golden tests | 6 cases, all passing |

Actions on each rule: edit a draft, test against the golden set, publish to testers, promote to everyone, pause, or roll back. AI can draft a rule from a correction case, but it stays a draft until the golden set passes and an admin publishes it. Every change is therefore confirmed by an admin and proven by tests.

The release ships every rule as bundle data (WP-03), so the Rules page shows all of them from day one. No rule stays hidden in code.

## Dynamic rules and protecting them

Rules already download from the server into the running app with no app update and no backend deploy. The gap is that most of the logic is still compiled into the app; WP-02 and WP-03 move it into the bundle before release.

What exists today:

- `GET /sms/rules/active` (signed-in users only) serves the active admin-published bundle from the `sms_rule_bundles` table, plus staged candidates and category rules.
- The app caches the bundle and asks only for newer versions.
- Publishing and rollback are admin API calls.

The limit: a bundle holds only learned templates and category rules. The core 3,500-line Dart grammar ships inside the app, so most fixes still need a release.

| Part | Design |
| --- | --- |
| Where rules live | Versioned, immutable bundles in the database, authored on the admin Rules page and exportable to JSON for review. Not a JSON file in the backend repo: a file still needs a deploy and has no audit trail or staged rollout. |
| What a rule can say | Template (sender brand, pattern, fields, amount roles), event kind, instrument hints, linking hints (such as "a card's payment receipt pairs with a bank debit"), category hints, and ignore rules. Data only, never code. |
| What still needs a release | New fact types, new linking logic and engine changes. Apple and Google forbid downloading code that changes app behaviour; downloading data is allowed. |
| Baseline in the app | Each build ships the latest bundle, so first launch and offline import work. Newer downloads replace it. |
| Rollout | Draft, then the golden set must pass, then testers, 5%, 25% and everyone. The rule pauses automatically if its correction rate rises, and rollback is one click. The existing stages (shadow, limited, expanded, active) already do this. |
| Re-running old messages | When a rule changes, the phone re-runs only the messages that matched the old rule or went unparsed. It shows a preview of changes and never overwrites user edits. |
| Delivery | Only to signed-in, entitled, attested devices. Each bundle is signed by the server and is valid for a fixed period (for example 7 days), so devices must refresh. |

Protection against a cracked or shared APK:

- **Encryption alone does not stop a cracker.** The app must decrypt the rules to use them, so the key is on the device. Encryption only slows them down.
- **What works:**
  - Rules are fetched only by a signed-in account with an active subscription on an attested device.
  - Each bundle is encrypted for that device, with the key held in Android Keystore or the iOS Secure Enclave, and expires after a set number of days.
  - A per-user watermark lets a leaked bundle be traced and that account revoked.
- **The real paywall is freshness.** A cracked APK keeps only the baseline it shipped with, and goes stale within weeks: no new rules, no sync, no AI and no fixes from other users.
- **Timing:** build entitlement-gated delivery, expiry and signing in WP-09 and WP-13. Add per-device encryption and watermarking only when the subscription launches.
- **Do not move parsing back to the server to stop piracy.** It would cost privacy, scale and offline use.

## Auto-detection of cards, accounts and wallets

Only cards are stored as records today. Everything else is either guessed when a screen loads or not detected at all. The fix is one Instrument registry, filled from every message, which the user confirms once.

| Instrument | Today | Gap | Design |
| --- | --- | --- | --- |
| Credit and debit cards | Saved by hand, or via Find Cards, which scans SMS on demand. A transaction links to a card only if that card is already saved. | A new card seen in SMS never prompts the user. Last-4 errors attach spends to the wrong card or none. | Create a "detected card" from issuer + masked number on its first spend or bill SMS, and confirm with one tap. Match the product with the existing on-device discovery engine, run automatically on captured SMS instead of only from Find Cards. SMS alone is enough; Gmail is not needed. |
| Bank accounts | Rebuilt on every read from observations using sender-name regexes and temporary filters, then merged with a server list | Missed formats, the "UPI" sender filter, and no way to rename or confirm an account | Store an Instrument (bank account) on first evidence: issuer from the sender brand, full mask pattern, linked debit cards and UPI IDs. |
| Payment wallets (Paytm, Amazon Pay, Zomato Money, PhonePe, MobiKwik) | Nothing | Top-ups are double counted and balances ignored | Store an Instrument (wallet), detected from wallet senders and top-up UPI IDs such as `add-money@paytm`, and track its balance snapshots. |
| Broker and demat (Groww, Zerodha, Upstox) | Deliberately excluded from accounts | IPO and SIP flows cannot be shown as money moving between your own accounts | Store an Instrument (broker), and link ASBA holds and allotments to it. |
| Credit limit and usage | Limit set once, from explicit wording only | Never updates, and "Avl Lmt" is ignored | Limit-change facts update the limit and keep its history. Usage = limit − latest available limit. |
| Reward points | Points balance typed in by hand | SMS ignored, and points booked as rupees | Track a points balance per card, in points, from reward SMS. |
| Loans and Pay Later | Filtered out as "non-deposit" | Not shown anywhere | Supported by the contract and detection (WP-04); its own screen comes after release. |
| Gmail card discovery | Screen hidden on 20 October 2026; `gmail_discovery_service.dart` remains | Paused, not in this plan | Leave all Gmail code exactly as it is. No changes in this plan. |

How matching works:

- Every fact names an instrument mention: issuer (from the sender brand), masked number and type words.
- The resolver matches the mention to a known instrument, or creates one marked "detected, not confirmed".
- Unconfirmed instruments still count in totals.
- The user sees one grouped prompt: "We found 3 accounts and 2 cards. Are these yours?"
- Never key by last 4 alone. The key is issuer + kind + mask pattern.

## Before we start

Lock these eight decisions first. Each is cheap to settle now and expensive to change later.

1. **Fact contract v1.** The exact fact types and fields shared by phone and server, with a version number. Everything else depends on it.
2. **Who approves rules.** Admins publish, AI only drafts, the golden set must pass, and rollback is one click.
3. **Old app versions.** The server keeps the raw-text path only for app versions older than the first facts-capable release. Set a minimum supported version and a removal date.
4. **Security baseline.** Rate limits, device attestation, signed rule bundles, and no secrets in the app.
5. **Privacy and consent.** Testers share redacted templates only, with a stated retention period and deletion path. India's DPDP Act 2023 covers SMS-derived financial data; confirm the obligations with counsel.
6. **Existing data.** Existing transactions move to the new model through a previewed replay. User edits stay locked, and totals are compared per user before and after.
7. **Success numbers.** The golden-set targets, plus one way for testers to report: the in-app flag.
8. **Scope fence.** Gmail code stays frozen, and the category list does not change in this release. Categories still come from a versioned registry (WP-07), so adding them later needs no rework.

## Build plan: one release

Everything ships to users in a single release. The work is split into 18 work packages across four internal milestones, and no milestone build reaches users. New code sits behind a build flag (`SMS_PIPELINE_V2`) until cutover, so the integration branch `sms-v2/main` always builds, passes its tests and runs today's pipeline unchanged. It starts from the production line (`codex/ios-shortcuts-prototype`) and merges back only at release; pushing either production branch deploys.

&#91;embedded content: build plan · 4 internal milestones, 18 work packages, one release\]

Each work package is written so one agent can build it alone. It states what the agent owns, which contracts it codes against, its tests and its done criteria. Read the Agent playbook tab first, then Contracts, then your work package.

The current production app keeps working against the server's existing endpoints until a minimum-version cutoff after release (WP-17).

## Measuring accuracy to reach 95–99%

You cannot reach 99% on a number nobody measures. WP-00 builds a golden set of real templates and runs it on every change.

1. **Collect.** Read only bank and service senders (DLT headers such as `VM-HDFCBK-S`), never personal contacts:
   - your phone, via the Mac Messages archive (needs Full Disk Access); nothing leaves the Mac
   - testers, via an in-app consented export of redacted templates
2. **Group into templates.** Strip carrier prefixes and suffixes. Replace amounts, dates, masked numbers, UPI IDs, reference numbers and names with placeholders, then group by sender brand + skeleton. Tens of thousands of messages should shrink to a few hundred templates.
3. **Label per template.** Current parsers and AI pre-fill each label: event kind, amount role, instrument, linking rule, and category when it is fixed. A person confirms it.
4. **Store and run.** Commit the set to the repo as redacted cases with synthetic values. Run it in CI on every change, weighting each template by its real message volume. Any drop in any metric fails the build.

| Metric | Meaning | Target |
| --- | --- | --- |
| Capture recall | Financial messages that reach the parser | ≥ 99.5% |
| Amount and role | Right number, in the right role (spent, held, limit, balance) | ≥ 99.5% |
| Event kind | Spend, income, own transfer, investment, hold, refund or reward | ≥ 99% |
| Instrument | Right account, card or wallet | ≥ 99% |
| Linking | Card bill pairs, top-ups and IPO chains joined into one event | 0 double counts |
| Category | Right spending category | ≥ 95% |
| Ask rate | Messages that need the user to decide | ≤ 2% |

Report each metric weighted both by amount and by message count, and broken down by bank. Category has a lower target because a bank SMS often does not say what was bought.

## Rules to avoid redundant code

Every decision has exactly one owner, and the change that moves a piece also deletes its old path.

- **One owner per decision.** Each step has a single owner:
  - extraction: the fact extractor
  - who owns the money: the instrument resolver
  - same event or not: the event resolver
  - category: the category resolver
  - totals and counts: the ledger projection

  Screens never re-derive any of these.
- **Rules are data, not code.** Bank templates live in one versioned rule file, read by one engine. No regex is copied between Dart and JavaScript. During the move, the server parser is frozen (no new rules) and deleted once transactions arrive as facts.
- **Delete in the same pull request.** Removals already queued:
  - server raw re-parsing for new app versions (WP-17)
  - the temporary "ponytail" filters in `providers.dart` and `financial_store.dart`
  - the 4 IPO regex copies
  - the legacy transaction path in `index.js`
- **No repairs in read paths.** Data fixes run once, at upgrade, and are recorded.
- **Unknown never means something.** An unknown kind stays unknown and goes to review; it never defaults to spending.
- **Every fix ships with its golden case**, placed at the stage that failed.

**Gmail code is frozen.** The `gmail_*` files, email forwarding, IMAP, and both card discovery engines (which Gmail uses) are not changed or deleted by this plan.
