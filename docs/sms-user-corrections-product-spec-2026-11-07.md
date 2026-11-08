# User edits and shared learning: product spec (draft for the owner)

Written 7 Nov 2026 from a code audit, a throwaway test run on the real pipeline, and read-only checks of production. **Updated 8 Nov 2026:** the personal-consistency work (build order P1) is largely built; the table in section 2 shows where each requirement now stands. Decisions marked **Decide** need the owner.

## 1. What we want

1. A user can fix **anything** on a transaction (amount, date, type, payment method, merchant, category) and sees it at once, on that transaction.
2. A merchant or category fix applies to **all of that user's similar transactions**, past and future, until the admin approves a shared fix.
3. A **payment-method** fix is remembered too, so the next SMS from the same card is detected correctly for that user.
4. Amounts, dates and typed values are **never** sent to the admin. What is sent is categorical or structural only.
5. When many users hit the same misdetection (card, payment method, type, category, shop), the **admin sees it as a pattern**, fixes the rules once, and everyone's next transaction is right.
6. The user's own fix always wins over the shared one, and the user can undo it.

## 2. Where we are today (verified)

| Requirement | Status | Evidence |
|---|---|---|
| Any edit shows on the edited transaction | **Implemented** | Throwaway test on the real pipeline: merchant, amount, date and category all changed on the saved row. Type and payment method follow the same code path and existing tests. |
| Payment method can be changed | **Partial** | Only to a *confirmed* account or card the app already knows; otherwise the save fails with "Choose a confirmed account or card in Needs review". |
| Merchant rename applies to all similar transactions of that user | **Implemented (8 Nov)** | A rename is remembered for later SMS at once. For earlier ones the app shows a checklist (Select all, a tick per transaction, a live count) and applies the ticked ones in the background with a progress bar, Stop and Undo. Shown by 7 Nov audit as missing. |
| Category applies to similar transactions | **Implemented for the same payee (8 Nov)** | A per-shop personal rule for new SMS, plus the same checklist for earlier ones (all ticked to start; the person's own earlier choices are never overwritten). The "name and category in one save" case (gap D) has not been re-checked. |
| Payment-method fix applies to similar transactions | **Implemented as an offer (8 Nov)** | The checklist offers the other transactions of the same card and layout, nothing ticked to start because totals and limits move. |
| A type change (own transfer, card bill, income, investment) applies to the same payee | **Implemented (8 Nov)** | Matched by payee and current type, not by SMS layout (a layout match would have flipped every payment that layout reads). Nothing ticked to start. One-tap "Transfer between my accounts" and "Credit card bill payment" actions on a transaction; a "Transfer type" choice in Edit. |
| The person is told the edit worked | **Implemented (8 Nov)** | "Saved on this phone. Syncing in the background.", an offline wording, a thin progress bar for the bulk change with Stop, then a result bar with Undo for names. SMS edits are saved on the phone first; only a category or shop key can reach the server. |
| Choosing a category is easy | **Implemented (8 Nov)** | Tall sheet, search, grouped with subcategories, "Add category" pinned, its own scroll controller. |
| Amount, date and typed values stay private | **Implemented** | The server keeps only `category` and `merchantKey` from a correction; the phone sends no values. |
| Repeated misdetections reach the admin | **Partial** | A case is stored with its stage (instrument, extraction, category, linking, gate) and, for opted-in users, the anonymised message layout. The admin list groups by layout. There is **no count of distinct users** and no right answer attached. |
| Admin approval improves detection for everyone | **Partial** | Category and shop-key rules: yes, through drafts, golden check and a signed bundle. Payment method, type, amount and date: only by the admin writing a rule from the layout; no automatic path. Approved shop-name aliases change grouping, **not the displayed name**. |
| The path works end to end in production | **Broken today** | Every correction that carries a fact or event reference was refused with HTTP 400 (6 of 6 attempts on 6 Nov); the 10 accepted cases carried no references. The server does not log the reason. |
| The admin can see a single user's changes | **Blocked** | Learning page needs K different people (K now 1, not deployed) **and** phones that passed App Check; the owner's iPhone cannot, so all 45 of its signals are stored as not eligible. |

## 3. The correct flow, in two layers

**Layer 1: personal (immediate, local, private).** Every edit applies on the phone at once. The app also saves a *personal rule* so the same fix applies to similar transactions of that user.

**Layer 2: shared (opt-in, anonymised, admin-approved).** The edit also produces a case or signal that helps the admin improve the shared rules. Shared rules reach everyone through the signed rule bundle, rolled out by cohort (testers, then 5%, 25%, everyone) with auto-pause if corrections spike.

**Precedence, always:** the user's own fix, then the shared rule, then the engine's default. A later shared rule never overwrites something the user set.

### What each edit does

| Edit | This transaction | Same user, similar transactions | Sent to admin (opted in) | Admin action |
|---|---|---|---|---|
| Merchant name | changes | changes, past and future (personal alias keyed on the shop name **printed in the SMS**) | anonymised shop-name signal (printed key to new name) | approve alias; add a display name |
| Category | changes | changes, past and future (personal rule keyed on the printed shop name) | category signal and case | approve category rule |
| Payment method | changes | remembered per sender and mask; past and future with the same mask follow | case: "payment method wrong for this layout" (no digits) | rule fix for the layout, or a card-alias hint |
| Type (spend, income, refund, transfer) | changes, totals update | personal reading per layout, after a preview ("12 similar") | case: "type wrong for this layout" | rule fix |
| Amount | changes | never copied; if the layout is misread, use the personal format reading (select the right number) | never the value; only "amount wrong" and the layout | rule fix with a synthetic example |
| Date | changes | never copied; same as amount | never the value | rule fix |
| Notes, tags | change | no | never | none |

## 4. Product decisions (recommended)

1. **Apply merchant and category fixes to all similar transactions automatically, with an undo toast** ("Updated 12 similar transactions. Undo"). Why: a tester who fixes one shop expects it fixed everywhere; asking every time trains people to tap through. Show the count; cap bulk changes above a threshold with a confirm.
2. **Ask first for payment method and type, after Save, with a count and examples** (section 4a). Why: they move money between cards, caps and totals, so a mistaken bulk change is costly.
3. **Key every personal rule on the name printed in the SMS**, not on the name the user typed. Store a rename as a personal alias (printed shop to my name).
4. **Show "edited by you" and a one-tap "reset to automatic"** per transaction, and "stop applying this to similar ones" per rule.
5. **Never share amounts, dates or typed free text.** For wrong amounts and dates, share only *which field was wrong* and the anonymised layout. Later (not now): let the user tap the right number in the message and send only its *position* in the redacted layout, not its value.
6. **Closing the loop:** when the admin decides a case, tell the user ("Fixed in rules v7"). The phone already receives each case's open or decided status; whether the app tells the user is not verified.
7. **Thresholds:** testers (all opted in, all known): K = 1 with a "tester" badge. Public launch: at least 10 people and 90% agreement (the old design's numbers), and attested phones only.
8. **Eligibility for testers (Decide):** count tester profiles even without App Check, behind an admin setting, and add the owner's profile to the tester list (currently empty). Without this the admin never sees a free-account iPhone.
9. **Display names (Decide):** let an approved rename change the name everyone sees. This needs a `displayName` field in the rule-bundle format and a minimum-engine-version gate so older phones ignore it safely.
10. **Personal rules belong to the account (Decide):** back them up and sync them across the user's devices. Today the personal format readings are device-only by design, and whether category rules sync under SMS v2 is unverified. Without this, a reinstall or a second phone loses every fix.

## 4a. The Save-time flow and a fast history search

**Flow.**
1. The user taps **Save**. The edit to *this* transaction is committed immediately and the screen closes. The lookup never delays or risks the save.
2. Only if merchant, category, payment method or type changed, the app looks up similar older transactions (below). If it takes longer than about 150 ms, show a small loading indicator; most of the time nothing is visible.
3. If there are matches, a bottom sheet appears: *"12 other transactions look the same (newest: Swiggy, 3 Oct). Apply this change to them and to future ones?"* with up to 3 examples, **Apply to all** and **Only this one**. With no matches, nothing appears.
4. Merchant and category: apply to future ones automatically (see decision 1) and ask only about the past ones. Payment method and type: ask about both.
5. **Apply** saves the personal rule, then re-processes the matched transactions in small chunks with a progress bar, then shows **Undo**.
6. "Only this one" is remembered for that shop and field, so the user is not nagged. If the same fix is made a second time, offer to make it a rule.

**What "similar" means (exact, never fuzzy).** Merchant and category: the same normalised shop name as printed in the SMS. Payment method: the same card or account the app originally detected, from the same sender. Type: the same rule and the same current type. Transactions the user already edited are excluded, and the count says so.

**Why it is fast.** Today the history has no index for any of these questions: `v2_facts` is indexed by source and date only, and the shop name and rule id live inside a JSON text column. The shop key is a Dart normalisation, so without a stored key the app would have to read and parse every fact. The fix:
- Store the normalised `merchant_key` and the `rule_id` as real columns on each fact when it is written, and index `(namespace, merchant_key, observed_at)`, `(namespace, instrument_id, observed_at)` and `(namespace, rule_id, observed_at)`. A one-time, chunked backfill fills existing rows.
- Count first (cheap), then fetch only 3 to 5 examples, never all rows. Walk the rest with keyset paging (`observed_at > cursor`, 50 per chunk), yielding between chunks.

**Measured** on synthetic histories in the app's real schema (Mac; expect a phone to be roughly 3 to 5 times slower, which is still well inside budget):

| History size | Today: read and parse every fact | With the columns and indexes: count of similar | Newest 5 examples | Walk all matches (chunks of 50) | One-time upgrade |
|---|---|---|---|---|---|
| 10,000 | 42 ms | 0.03 ms | 0.9 ms | 2 ms | 28 ms |
| 50,000 | 118 ms | 0.14 ms | 10 ms | 10 ms | 162 ms |
| 150,000 | 349 ms | 0.4 ms (card: 1.2 ms) | 31 ms | 21 ms for 20,200 matches | 583 ms |

The lookup is not the bottleneck. The heavy part of "Apply" is re-processing each matched transaction (rewriting its display row and ledger entry), so it must run in chunks of about 50, off the critical path, with progress, cancel and undo. Its per-transaction cost should be measured on a real phone in phase 1.

## 5. Edge cases

**Matching and merging**
- The same shop appears under several printed names (SWIGGY, SWIGGY INSTAMART, a company name). Offer "apply to all names I see for this shop".
- Names with city or reference numbers. Normalise, match on the exact key, and *suggest* near matches rather than apply them.
- A rename that collides with another merchant (a merge), or looks like a person or the user's own account. Never share it; keep it personal.
- Two users disagree on a category. Show the split to the admin; change the shared rule only at high agreement; leave the rest personal.
- A user flips an answer several times. Latest vote per user counts; undo withdraws the signal.

**Payment method**
- The same last four digits on different banks or cards. Match on issuer *and* mask, never mask alone.
- A reissued card with a new last four. Map the new mask to the same card; keep the old mask for history.
- Wallet or phone-pay tokens and UPI on a credit card show a different last four than the plastic. Map the token to the card.
- Add-on and joint cards.
- The card the user wants is not in the app yet. Offer to add it right in the edit screen, instead of the current error text.
- Moving a spend between cards changes caps, rewards, utilisation and the statement cycle. Recalculate and test it.

**Money**
- Refunds, duplicates, EMIs and foreign-currency payments have more than one amount. Say which amount is being edited.
- A date edit across a month or statement boundary moves budgets and caps; a date later than the SMS is already refused.
- Changing type (spend to income or transfer) changes totals; for own-account transfers, keep both legs consistent.
- Editing a transaction that is part of a split.
- Edits must never be overwritten by a rule update or re-read; the transaction stays "user confirmed".

**Privacy and abuse**
- Consent states: never opted in, opted in later (past edits are not shared retroactively unless the user agrees), opted out (withdraw and delete what was shared).
- One account sending many signals counts once; unattested phones count zero; admin approval stays mandatory, with no auto-publish.

**Reliability**
- Offline: queue, retry with backoff, send facts before corrections, and **park** a permanently refused correction instead of retrying forever. Today a refused correction is retried forever and stops that upload pass.
- Show status to the user and tester: queued, sent, not shared (no opt-in), rejected with a reason.
- If the server says "facts not found", re-send the facts for that source and retry once.
- Two devices on one account, reinstall, and app updates that change the rule format.

## 6. The admin experience

- A per-layout view with **distinct users**, cases, and the mix of what was wrong (payment method, amount, date, type, category, shop), tester versus other, ranked by volume times impact.
- One-click drafts: category rule, alias with display name, rule from the layout; a golden test case is required before publishing code-level fixes.
- Rollout by cohort with auto-pause; every decision audited; "released in rules v N" feeds back to the phones.
- Total counts of shared versus not shared (opted out), so the admin knows how much they cannot see.

## 7. Tester acceptance scenarios

1. Edit each field on one transaction. It shows at once, and it survives an app restart.
2. Rename a merchant. Older and new transactions from that shop show the new name. Undo restores them.
3. Change category and rename in the same save. The next SMS from that shop gets the new category.
4. Change the payment method to another card. Spend, caps and utilisation move; the next SMS with that mask goes to the chosen card.
5. Change the amount. Only that transaction changes; nothing amount-related reaches the admin.
6. Change type to income, then to transfer. Totals move once, not twice.
7. Reset a fix. The transaction and its similar ones return to automatic.
8. Offline: make an edit, reconnect, and see the case reach the admin.
9. Opted out: edits stay on the phone and the admin sees nothing.
10. A rule update arrives. The user's edited transactions do not change; others do.
11. Two phones on one account see the same personal fixes; after a reinstall they are restored.
12. A shop fixed by two testers appears on the admin's Learning page with the right counts; approve; both phones get the shared rule on the next sync.
13. Run steps 1 to 12 on an iPhone with a free Apple account (no App Check) and on a phone that can attest; the admin view differs, and that must be intended.

**Tester tooling to build:** a "Corrections status" screen (queued, sent, rejected with reason, and the personal rules with reset), seeded SMS layouts, and an automated end-to-end test from the phone's own upload code to the server's check, which would have caught today's rejections.

## 8. What to measure

Needs-review rate; repeat-edit rate per shop (should fall after a personal rule); correction rate per rule; share of corrections that were shared; time from case to published rule; payment-method mismatch rate; share of phones that cannot attest.

## 9. Build order

| Phase | Work | Size |
|---|---|---|
| **P0 reliability** | Find and fix why corrections that reference facts are refused (log the reason); park or re-send; end-to-end test; decide tester eligibility | 1 to 2 days |
| **P1 personal consistency** | Personal merchant alias and category rule keyed on the printed name; apply to past and future with a preview and undo; payment-method mapping; "edited by you" and reset; "Corrections status" screen | **Largely built (8 Nov):** checklist, background run with Undo for names, payee-based type changes, own-transfer and card-bill actions. Not on a device in real use yet |
| **P2 admin loop** | Distinct-user counts and per-field mix; display-name alias with bundle versioning; one-click approvals; "fixed" notification | about 1 week |
| **P3 depth** | Layout-level personal readings from the Edit screen (amount, date, type); privacy-safe "which number" hints; account backup and multi-device sync of personal rules | larger, after P1 and P2 |

## 10. Open questions for the owner

1. Bulk apply: automatic with undo for merchant and category (recommended), or ask each time?
2. Should an approved rename change the name everyone sees (needs the bundle-format change)?
3. Count tester profiles without App Check, controlled by a setting?
4. Back up and sync personal fixes to the account?
5. Public-launch thresholds: at least 10 people and 90% agreement?
