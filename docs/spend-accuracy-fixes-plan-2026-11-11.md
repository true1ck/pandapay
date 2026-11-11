# Spend accuracy: fixes to build later (11 Nov 2026)

Status: plan only, nothing built. Counts and shares only, no merchants, people, names or amounts from any private corpus. The real figures live in the owner's private workbook, not here. Section A was rewritten on 12 Nov 2026: the first version let card bill payments drop out of every total and had no row for income, split bills, lending, cash or loans.

## What the evidence says

A two-year replay of one owner's real messages (about 9,500 from institutions) through the phone pipeline, with the owner's name set and then not set. Money in held up. **Spending was overstated**, and totals that move money between accounts were wrong. The causes, largest first:

| # | Cause | Size on this owner's data |
| --- | --- | --- |
| 1 | Large payments to people counted as everyday spending | 13 payments of 50,000 rupees or more are about 46% of all spend by value (overlaps with cause 2) |
| 2 | Payees who are family (same surname or father's name) counted as spending | About 1 in 5 rupees of spend |
| 3 | Own-name payments counted as spend when no profile name is set | 17 payments out, about 8% of spend; 5 credits in, about 2% of money in |
| 4 | Another person's bank account alerts arriving on the owner's number | 37 transactions, about 4% of spend and 4% of money in |
| 5 | Card bill payments counted twice (bank debit plus card credit, or two card SMS) | Card bills paid read 52% too high; they now match card spend within 2% |
| 6 | A friend's money passed through and repaid, read as income, then as spend | 1 credit, about 2% of money in |
| 7 | Credits to a card from a merchant (refunds) read as card bill payments | 5 in two years |

Spend and income totals were not affected by cause 5. Causes 1 to 4, 6 and 7 move them.

## What already exists (do not rebuild)

- Own-name matching: `packages/pandapay_domain/lib/src/sms_v2/linker/person_name.dart` accepts a shortened name, an initial, or words run together, and first plus last for a three-word name. It only runs when an owner name is set. The phone reads it from the server profile `display_name` (`app/lib/features/sms_v2/providers/runtime_provider.dart`, `app/lib/data/local/app_database.dart` `profile_name_cache`). **A one-word profile name never matches.**
- Per-transaction "Transfer between my accounts" and "Credit card bill payment" (`app/lib/features/activity/mark_transaction_kind.dart`), with an offer to apply to other payments to the same payee (`app/lib/features/sms_v2/similar/similar_offer_sheet.dart`).
- Tags: "Add tag" on the transaction screen and bulk "Add tags" in Activity (`TransactionTagsRepository`, `app/lib/app/providers.dart`; picker in `app/lib/app/transaction_tag_picker.dart`).
- "Not mine" per account (`app/lib/features/sms_v2/ui/found_instruments_screen.dart`, `InstrumentActions.reject`): a rejected account's movements are hidden. Reached from Home, Accounts.
- Activity's **Money out** filter already means spending plus investments (`_ActivityTypeFilter.moneyOut` in `app/lib/features/activity/activity_screen.dart`). Home shows only "Money in" and "Total spent". Section A keeps that meaning and makes Home use the same definition.

## Goals

1. **Money out means everything that left the owner** (spending plus investments), **Spending is the headline for what was bought, and every other flow gets its own line** (Invested, Card bills paid, Transfers, From people, Lent), so nothing vanishes and the lines bridge to what left the bank accounts (section A).
2. **Detect family from the owner's own name and tag it automatically** (section B).
3. **Recognise self-transfers without a profile name, and stop hiding unrelated payments under one shared "UNKNOWN" payee** (section C).
4. Fold in the smaller fixes this review found (section D).

Non-goals: new bank rules in a release, server changes, AI changes. Sections A, B and the app side of C are app changes (one app build). C4 and D1 to D2 are rule changes and need a rule-bundle version through the admin console.

## A. What counts as spending, income and everything else (what to show)

*Rewritten 12 Nov 2026 after review.* The first version had three problems:

- A withdrawal of investment principal was labelled "Investment returns". Only dividends and interest are returns.
- A card bill payment vanished from every total, even when the card's own spends never reached the phone. Section E found that about half of statement rows had no SMS, so for those cards the bill was the only trace.
- It had no row for salary, a friend's share of a bill, money lent, cash or loans, which are the flows most people have most often.

**Definitions.**

- **Money out** is every rupee that left the owner's own money and did not come back to it: Spending plus **Invested**. This follows the owner's decision of 11 Nov 2026 that Money out includes investments. A card spend counts when the card is used, so paying the card bill is not counted again. The part of a bill that tracked spends do not explain (A2) is Spending, so it is in Money out too.
- **Spending** is what the owner bought or paid for, counted when it happened. It is the headline figure for "how much did I spend". Money out and Spending differ only by Invested, so a month of investing never reads as overspending.
- **Income** is new money that belongs to the owner: salary and other pay, rent received, interest on savings.
- **Money in** is Income, plus **Investment returns** (dividends and interest only), plus **Withdrawn from investments**, plus **From people**. Each is its own line.
- **Money that only changes place** is in neither figure: moves between own accounts, card bill payments, loan principal received. Each gets its own line so nothing disappears.
- **Left your accounts** is the cash view: every debit on the owner's bank accounts, with card bills counted when paid. It is the one figure that should match a bank statement, and the app shows how to get from Money out to it (A7).

| Event | Money out | Money in | Spending | Note |
| --- | --- | --- | --- | --- |
| purchase, subscription, bill payment, fee, tax, insurance premium | yes | no | yes | Taxes and interest are spending. A card spend counts when the card is used. |
| payment to a person | yes | no | yes, family included | Shown as Spending with a **Family** slice. A setting leaves all Family payments out of Spending (B5), and Edit transaction leaves out one payment (A8); either way it stays in Money out. Money lent is a separate row. |
| cash withdrawal | yes | no | yes | Category Cash, counted when withdrawn. |
| card bill payment | only the part the card's tracked spends do not explain | no | the same part | The rest is the **Card bills paid** memo line. The unexplained part is Spending "not itemised" (A2). Counted once, after the bank debit and the card credit are merged (D1). |
| investment, SIP, IPO application, FD booking | yes (gross) | no | no | Shown as the **Invested** line of Money out. |
| investment withdrawal, maturity, redemption | no | yes, as **Withdrawn from investments** | no | Shown next to Invested, with the net beside it. Not Income, and never called a return. |
| dividend, interest on an investment | no | yes, as **Investment returns** | no | Never mixed into salary or other income. |
| salary, other pay, rent received, interest on savings | no | yes, as Income | no | |
| credit from a person | no, or reduces it once marked "Split" | yes, as **From people**, never Income; no once marked "Split or paid back" | no, or reduces it once marked "Split" | A share of a bill the owner paid reduces Spending and Money out. A repayment of money lent is excluded. D4 pairs the clear cases. |
| money lent to a person | no, once marked Lent | no | no | **Lent** line until repaid. The repayment is excluded from Money in. |
| refund, reversal | netted against what it refunds | no | reduces it | Already how the totals work. |
| loan received | no | no | no | Shown under Loans. Not income. |
| loan EMI | yes | no | yes, in full; interest only when the SMS splits principal and interest | |
| move between own accounts, wallet top-up | no | no | no | Shown under Transfers. A wallet whose spends the phone does not see is treated like a card (A2). |

**Trade-off.** Payments to family and large payments to people stay inside Spending and Money out by default. Causes 1 and 2 in the evidence table become visible slices of the headline instead of being dropped from it. The owner can leave Family out of Spending with the setting in B5, and any single payment can be left out of Spending from Edit transaction (A8), with a reason, so a large payment to someone can be marked Family, Lent or something else.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| A1 | Add to the totals next to `spendMinor`, `incomeMinor`, `investmentMinor`: money out (spending plus invested), invested, withdrawn, investment returns, family (a slice of spend, not an extra amount), from people, lent, card bills paid, transfers, and left your accounts. | `packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart` (`totals`), tests in `packages/pandapay_domain/test/sms_v2/ledger/golden_totals_test.dart` | A golden case per row of the table. Money out equals Spending plus Invested; transfers and card bills never appear in it except the not-itemised part. |
| A2 | **Card spending not itemised.** Per card, keep a running balance of tracked card spends minus bills paid. When bills paid exceed tracked spends, the excess counts as Spending "not itemised" (and so as Money out) and is flagged on the card page. The same rule applies to a wallet. Run it after D1, so a bill paid through an app (bank debit plus card credit) is counted once. Use the issuer's statement-total SMS where one exists instead of the running balance. A card's first bill pays spends from before tracking began, so the first bill and the edge of a cycle need settling on one real card's data before this ships. | `packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart`, linker, the card page | Golden: a bill of 10,000 with 7,000 tracked puts 3,000 in Spending "not itemised"; a bill below tracked spends adds nothing and is never negative; the cause-5 double count does not return. |
| A3 | Home shows **Money in**, **Money out** and **Spent**, each with its split: Money in (Income, Investment returns, Withdrawn, From people), Money out (Spending, Invested), Spent (with Family inside it). A link opens "Where your money went": Spending, Invested, Card bills paid, Transfers. | `app/lib/features/home/home_screen.dart` (`_HomeSpendMetric`), report model in `app/lib/features/sms_v2/ledger/reports.dart` | Widget test: the figures add up on a month that has every kind of row. |
| A4 | Activity's Money out chip and its header total use the same definition as Home (it already means spending plus investments). Add chips for Spending, Card bills and Transfers. | `app/lib/features/activity/activity_screen.dart` (`_ActivityTypeFilter.moneyOut`) | One definition shared by Home and Activity; a test fails if they differ. |
| A5 | Investments: **Invested** (in Money out) and **Withdrawn** (in Money in) on one line, with the net beside it. Dividends and interest are **Investment returns**. A redemption is never labelled returns. | Home, Activity, Insights (`app/lib/features/insights/spend_trends_screen.dart`) | A month with a withdrawal and a dividend shows them on separate lines. |
| A6 | **From people.** A credit from a person is its own line in Money in. One tap, "Split or paid back", nets it against Spending and Money out or marks it a repayment. A payment the owner marks "Lent" leaves Spending and Money out. D4 pairs the clear cases in both directions (credit then repaid; paid then paid back). | linker, tags (`TransactionTagsRepository`), Home | A friend paying back a split dinner reduces Spending and adds nothing to Income. Nothing is netted without a pair or a tap. |
| A7 | **Left your accounts**, the cash view, with a bridge from Money out: take off spending on cards and wallets, add Card bills paid, Wallet top-ups, Transfers out and Lent. | "Where your money went" or Insights, `reports.dart` | For an account with complete data the bridge equals the bank's debit total for the month. An account with missing SMS shows the gap (section E). |
| A8 | **Leave one payment out of spending, from Edit transaction.** Today the Type dropdown offers Spending, Money in, Investment, Transfer and Refund, so the only way out of Spending is to call a payment a transfer, which is wrong for a family payment and also removes it from Money out. Add a visible switch **Count in spending** (on by default) under the Type dropdown, shown for any row that counts as spending. Switching it off asks "Why?": **Family** (adds the Family tag, stays in Money out), **Lent** (marks it Lent, leaves Money out too until repaid, A6) or **Something else** (stays in Money out). Saving then offers the existing similar-payments sheet with nothing ticked, plus "Remember for this payee". The choice is stored as a user edit next to `eventType` and `category`, not as a type change, so a family payment is never turned into a transfer and a re-read of history never undoes it (precedence rule 1). Make it visible: the Activity row and the detail screen say "Left out of spending · reason", Where your money went shows "N left out, amount" with a one-tap "Count again", and Spending falls by exactly that amount (Money out too for Lent). | `app/lib/features/activity/edit_transaction_screen.dart` (the Type dropdown, near line 943), `app/lib/features/activity/transaction_detail_screen.dart` (a "Counted in spending" row beside Status), `app/lib/features/activity/activity_screen.dart` (the "Excluded from spend" marker near line 3660 gains the reason), `app/lib/features/sms_v2/ui/transaction_actions.dart` (`SmsTransactionActions.edit` takes the new field), `packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart` (`totals`), `app/lib/features/sms_v2/similar/similar_offer_sheet.dart` | Widget test: switching off moves the amount from Spending to "left out" and leaves Money out unchanged (Lent changes both). A golden totals case per reason. A re-read of history keeps it. Home, Activity and the detail screen show the same state, and "Count again" restores it. |

## B. Family detection from the owner's name, with an automatic tag

Indian names usually run first name, father's name, surname. A payee that shares the **surname** or the **father's name** with another word is very likely family. A shared first name alone is never enough.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| B1 | Split the owner's name into parts: first, middle (father's name), surname. A one-word profile name gets a one-time prompt "add your full name". | `person_name.dart`, `runtime_provider.dart` | Tests for one-, two-, three- and four-word names. |
| B2 | `familyLikeName(payee, ownerNames)`: true when the payee shares the surname (whole, cut to 4 or more letters, or as an initial after other words) or the father's name together with one more word, including forms with an honorific (Smt, Shri, Mr, Mrs). False for a business, for the first name alone, and for very common words (a short stoplist plus any word that appears in many unrelated payees). | `person_name.dart` | Synthetic matrix below passes. |
| B3 | **Automatic tag.** When a payment or credit to a person matches, set the tag **Family** through `TransactionTagsRepository`, marked as automatic. A tag the person removes is never re-added; "Not family" remembers the payee. A weak match shows a "Family?" suggestion and does not tag. | `app/lib/app/providers.dart`, `transaction_tag_picker.dart`, pipeline write after the ledger projection | Re-reading history does not undo a manual removal; a test covers tag, remove, re-read. |
| B4 | Offer "Tag all payments to this payee" through the existing similar-changes sheet. | `app/lib/features/sms_v2/similar/` | Same sheet as the own-transfer flow. |
| B5 | Reports: **Family** is a slice inside Spending by default. A setting "Leave family payments out of Spending" moves it out into its own line (see Open questions). It is the bulk form of A8's per-payment switch. | `reports.dart`, Home, Insights | Switching the setting moves the figure between Spending and the Family line; Money out does not change. |
| B6 | Only person payees are eligible (counterparty kind person), never a merchant or a card. | linker output | A merchant with a family surname in its name is not tagged. |

Synthetic cases for B2 (invented names, owner "Ravi Mohan Patil"): `SMT PATIL` yes; `MOHAN R P` yes; `ASHA MOHAN PATIL` yes; `RAVI MOHAN` (the owner) is self, not family; `RAVI SHARMA` no (first name only); `PATIL HARDWARE STORES` no (business); `MOHAN` alone no (one word); `ANITA MOHAN` yes only with a second shared word, otherwise "Family?".

## C. Self-transfers and the "UNKNOWN" payee

**Where UNKNOWN comes from.** `packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart` falls back to the text `UNKNOWN` when an SMS carries neither a payee name nor a UPI address, and `app/lib/features/sms_v2/ledger/reports.dart` groups every such payment under that one word. Unrelated payments then look like one payee.

**What it was on this owner's data.** The group had 40 payments. 12 were the other person's account (cause 4) and are gone once that account is marked Not mine. Of the remaining 28:

- 27 are wallet payments, autopay bills or bank fees whose SMS name no payee (25 of them under 1,000 rupees): a vending-machine wallet, a meal-card convenience fee, a quick-commerce wallet, a bank "InfoBIL" autopay line, a debit-card annual fee on a dormant account.
- **None** has a matching credit (same amount, within a day) in another of the owner's accounts or wallets.
- One is a large bank transfer (over 50,000 rupees) whose SMS says "transfer to <first name> Ac x####". The name is in the message; the rule does not capture it.

**Owner's expectation (11 Nov): the unknown payee was mostly the owner's own self-transfers, with only a few truly unknown payees.** The measurement above did not confirm that for the group as it stands now. Before the fixes, own-name payments were a real problem (cause 3, 17 payments), and they are what the owner saw. Keep the self-transfer safety net in C5 and re-measure after C1.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| C1 | **Learn the owner's name from messages.** Banks print it on the owner's own messages ("Dear <NAME>", "Hi <NAME>", tax and utility notices). Collect the repeated full name, ask once "Is this you?", and store it as an owner alias, so own-name payments are recognised without a profile name. | `runtime_provider.dart` (`ownerNames`), `app_database.dart` | On the owner's data with no profile name: 0 own-name payments counted as spend or income. |
| C2 | Stop the shared `UNKNOWN` key. Show "No payee in the SMS" per payment and group by sender and purpose, never as one payee. | `projector.dart` (line 172), `reports.dart` (lines 160, 198, 204) | No report shows a payee called UNKNOWN with many unrelated payments. |
| C3 | Name wallet, autopay and fee payments from the sender brand and the rule's purpose, so they read as "Wallet payment (brand)", "Autopay bill", "Bank fee". | rule `purpose` plus `merchant_aliases.json` under `rules/sms/v2/` | The 27 wallet, autopay and fee cases above each get a readable name. |
| C4 | **Rule gap.** Capture the beneficiary in "debited for transfer to <name> Ac x####", including a lowercase first name. New rule version through the console; imports never replace an existing id. | bank rules under `rules/sms/v2/banks/` | A golden case per bank wording. |
| C5 | Safety net: pair an unnamed debit with a same-amount credit in another of the owner's accounts within a day and offer "Transfer between my accounts". Low priority: it matched 0 of 28 here. | linker | A golden case. |

## D. Smaller fixes found on the way

| Step | Problem | Fix | Where |
| --- | --- | --- | --- |
| D1 | A card bill paid through a bill app shows as a bank debit and as a card credit whose amounts differ by 1 to 18 rupees; some issuers send two card SMS per payment. | Merge a bank debit and a card credit on the same day (plus or minus one) whose amounts differ by at most 25 rupees or 0.5%. Drop a repeated card SMS (same card, same amount, within 3 days). | `rules/sms/v2/link_rules.json` (`LINK-CARD-BILL`), `packages/pandapay_domain/lib/src/sms_v2/linker/rule_driven_linker.dart` |
| D2 | "An amount of INR X received on your card from UPI_<merchant>" is a refund, read as a bill payment. | Type it as a refund and link it to the charge. | issuer rules |
| D3 | Another person's account alerts on the owner's number show as a confirmed account. | Keep "Not mine". Suggest it when an account's messages never show the owner's name and it has no transfer with the owner's other accounts. Test what new alerts do after Not mine (they may land in Needs review). | `found_instruments_screen.dart`, `instrument_resolver.dart` |
| D4 | A credit from a person repaid to the same person within weeks is read as income, then as spending. | Detect the pair and tag **Repaid**, excluded from income and spending. | linker |
| D5 | A card paid twice in a cycle shows an available limit above its limit. | Show "credit balance on this card". | card page |
| D6 | Two instruments for one card (the card number and the card account number). | Alias them in the resolver. | `app/lib/features/sms_v2/instruments/` |
| D7 | A card bill paid through the Kiwi app (payee Gokiwi Tech) is read as a payment to a person and counted as spending: 3 payments on this owner's data, about 1% of spend. The card's own SMS and the statement total confirm each is a bill. | Add the payee next to the other card-bill apps (CRED, CHEQ, BBPS, Tata Neu, PayZapp) as a new id with purpose `card_payment` and a credit card as the target. Then review the list for other bill-pay apps. Imports never replace an existing id, so this is a new id and a new bundle version. | `rules/sms/v2/counterparty_purposes.json`, a golden case in `tools/sms_rules_cli` |
| D8 | Activity rows for bank payments say "Bank account · unmatched" when the row carries no account digits (the SMS does name the account), and "Pending confirmation" on any SMS row whose reward state is "estimated", which means nothing for a bank payment. | Show the account's last digits from the instrument. Show "Pending confirmation" only when a card reward is actually pending. | `app/lib/features/activity/activity_screen.dart` (the subtitle parts, around lines 3646 to 3662) |
| D9 | The same person shows as two merchants when the bank prints the full name on credits and a cut-short name on debits, so a search or filter splits their history. | Treat names as one payee when one is a prefix of the other (at least 8 letters) on the same rail, and keep both printed names as aliases. | payee keying in `packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart` (`keyer`), `app/lib/features/sms_v2/ledger/reports.dart` |
| D10 | Merchants stay in "other" because of how a bank or acquirer prints them, not because the brand is unknown: names glued together (DOMINOSPIZZA, NYKAAKIOSK...), cut short by a bank (ZEPTO MARKETPLAC), in the plural (CLINICS) or a kind of business with no brand (BAKEHOUSE, NON VEG). | Done 12 Nov 2026 as data only: 141 whole-token rules (food chains and food words, pharmacies, clinics and labs, broadband and power and gas, dating, matrimony and streaming, edtech, online shops, groceries, travel, fuel), 10 prefix rules for long distinctive stems, 12 aliases for cut or glued names. A UPI payee is still categorised only when its WHOLE name is a known business, so people stay "other". Measured on one owner's 1,841 spend entries: 23 moved from "other" to a category (₹13,664), none changed from one category to another. The rest of "other" (about 65% of rupees on this owner's data) is payments to people and venues that nothing can name from an SMS: only a payee label from the person settles it. | `rules/sms/v2/category_rules.json`, `merchant_aliases.json`, `test/sms_v2/category/merchant_generalization_test.dart` |
| D11 | 243 of 2,416 transactions on one owner's data (10%) showed the raw word UNKNOWN as the merchant. Reading the SMS behind them: 174 were a wallet's own credits (the message names only the wallet), refunds named nobody, fees named no bank, and a few messages printed a payee or payer the rules dropped. | One cascade, no hard-coded names (`counterparty_resolution.dart`, used by the ledger snapshot for both the category and the ledger entry): the printed name; else the name on a linked leg (the purchase a refund reverses, the bank record a payer's notice confirms); else the issuer, only where the issuer necessarily is the other side (a wallet's own movements, a bank's own fee); else nobody. Three rules now capture a name the message prints (`counterparty_names.json`: "transfer to <name> Ac x1234", RTGS or NEFT credit "by <account><NAME>", refund "for your order from <merchant>"), the payer-side notice captures its "From <name>" signature, and a refund that is only promised is no longer read as money in. The screen says "Unknown sender" for money in and "Unknown merchant" for the rest instead of UNKNOWN. Result: UNKNOWN 243 to 24, same 2,416 entries, every total identical to the paisa, 4 Zepto Cash payments gained the groceries category. **Left on purpose:** a card refund that prints its merchant first ("IND*AMAZON refund of Rs X credited to ... card") is not named, because naming it makes the linker search for the purchase, a partial refund with several candidates goes to review and leaves the totals (4 refunds, Rs 2,489 on this owner's data). Deciding how an ambiguous refund should be counted is a linker policy question. | `app/lib/data/merchant_identity.dart`, `packages/pandapay_domain/lib/src/sms_v2/ledger/`, `rules/sms/v2/generalization/counterparty_names.json` |

D7 entry shape (same as `CPP-CHEQ`): id `CPP-KIWI`, a UPI-address pattern for the Kiwi handle, a name pattern for "Gokiwi Tech" with or without "Priv" or "Limited", purpose `card_payment`, target kind `credit_card`. Until the rule ships, the per-transaction fix works: mark the payment as a credit card bill payment and tick the other payments to the same payee in the similar-changes sheet.

## E. SMS is not complete: reconcile against bank statements

Checked against two real bank statements covering 2026 so far (about 600 rows, parsed and proven against each bank's own totals): **about half of the statement rows had no matching SMS** (a strict one-to-one match on amount, direction and date, own transfers left out; a looser match gave about 40%), worth about 21% of money in and 20% of money out. The categories SMS missed most were interest and rewards, money from individuals, small UPI payments, and payments to individuals. They included a month's salary credit, a run of monthly person-to-person credits, and several large transfers in both directions. The balance trail had already shown the gap; the statements located it. SMS cannot be made complete, so the app should be able to close the gap itself.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| E1 | Import a bank statement (PDF, with the password the person types, never stored) and add the rows no SMS explains. The app already has a "Statement import" source label. | `app/lib/features/activity/transaction_detail_screen.dart` (`_sourceLabel`), a new import path under `app/lib/features/sms_import/` | A statement whose rows all have SMS adds nothing; one with a missing credit adds exactly that row. |
| E2 | Match statement rows to SMS by amount and date (plus or minus two days). Take care that amounts printed as "Rs.12345.00" match, which a naive pattern misses. Verify the parse with the statement's own running balance and printed totals before trusting any row. | pure functions in `packages/pandapay_domain/lib/src/sms_v2/ledger/` | Unit tests with an invented statement: balance chain intact, a row with and without SMS, a statement with printed totals that do not match. |
| E3 | After an import, show "N rows came from your statement, M have no SMS" and the money in and out they add. | Home or Needs review | The count is visible and dismissible. |

**What exists today, and why it cannot simply be switched on.** The PDF import (`app/lib/features/import/statement_pdf_import_screen.dart`, `app/lib/data/transaction_import_pipeline.dart`) only calls a row a duplicate of a saved one when amount, merchant text and account are identical and the time is within 10 minutes. A statement row carries a bank narration and a date with no time, while the SMS row carries the merchant name and a time, so almost nothing would match and every row SMS already has would be added a second time. E2 (the matcher) has to land before E1 is turned on.

**Precedence (decided 11 Nov 2026).** Field by field, never record by record:

1. The person's own edits (category, tag, payee label, "this is family") always win. An import never overwrites one, and a matched row keeps the transaction it matched, so the edit stays attached.
2. The statement beats SMS for whether the transaction exists, its amount, date, direction, account and the bank's narration.
3. SMS beats the statement for time of day and for the richer merchant name.
4. If SMS and the statement disagree on the amount, take the statement and raise one review item.
5. A statement row with no SMS becomes a new transaction marked as coming from the statement. That needs a new source value in the SMS v2 data contract (provenance today is `rules`, `ai` or `user`), so it ships with an app build.

Match rule to start from: same amount, same direction, within two days, one SMS per row, an amount counted only as a decimal or after a currency or debit/credit word and not before a month name, and an SMS whose direction word contradicts the row is never a match. Own transfers between the person's own accounts match each other first, and only then are the leftovers compared with SMS.

**E2 built (12 Nov 2026), pure and not yet wired to anything.** `packages/pandapay_domain/lib/src/sms_v2/ledger/statement_check.dart` and `statement_match.dart`, exported from `sms_v2_ledger.dart`, tested in `test/sms_v2/ledger/statement_check_test.dart` and `statement_match_test.dart` with invented statements only.

- `verifyStatement(rows, opening, closing, printed totals and counts)` checks the running balance row by row. One misread amount marks one row; a dropped row marks the row after the gap; a statement printed newest first is turned around; a layout with no debit/credit column has its directions read from the balance; a statement that prints nothing to check against is never trusted. Only a `trusted` statement should be imported; `suspectRows` are shown to the person instead.
- `reconcileWithSms(rows, candidates, ownerNames)` pairs transfers between the person's own accounts (one partner each side, or a narration naming the owner or the account), then links rows to SMS by shared reference (an amount disagreement is flagged, rule 4), then by amount, direction, account and Indian calendar day within two days. Every compatible pair is ranked by day gap and the closest are taken first, so a row never takes the SMS another row needs; one SMS explains one row. The summary gives the E3 numbers: rows with and without SMS, own-transfer rows, conflicts, and the money in and out an import would add. Linear in rows plus candidates (an index by amount); 1,000 rows against 20,000 messages runs well under a second.
- Candidates: `StatementCandidate.fromFact` for a parsed movement on a bank account (a card spend, a wallet, an evidence-only receipt or a foreign amount is not one), and `StatementCandidate.fromText` for an SMS the phone could not parse. Text amounts count only as a decimal or after a currency or movement word, never before a month name and never after a balance, limit or due word.

Two differences from the one-off measurement quoted above: it now refuses an SMS from another account (the measurement did not), and it ignores balances printed in a message. Both make "no SMS" counts a little higher. Matching parsed movements only, without `fromText`, will report more rows without SMS than the roughly half measured on raw messages.

Not done: reading a PDF into rows (E1), writing anything, the new source value, the screen (E3). `app/lib/data/statement_reconciler.dart` already checks a statement against itself at parse time (totals, transposed digits, refund and transfer pairs on `ParsedStatementLine`); E1 should feed its lines to `verifyStatement` rather than keep two checks that can disagree.

**E1 built (12 Nov 2026), readers and the double-count guard; not yet tried on a real PDF.** The server never reads a PDF (`POST /statement-imports` takes rows the phone already parsed, and the password stays on the phone), and the phone's generic parser rejected every SBI-style row and read ICICI-style credits as debits. So:

- `packages/pandapay_domain/lib/src/sms_v2/ledger/statement_layouts.dart`: `readBankStatement` picks the layout by counting row-shaped lines (not by a bank name) and returns `StatementRow`s plus the account, opening and closing balance and printed totals where a labelled line gives them. SBI style: two dates, debit and credit columns with a dash for empty, direction printed, narration that may wrap, a signed footer balance glued to the last row removed. ICICI style: serial number, dot dates, amount and balance, no direction; direction comes from the running balance through `verifyStatement`, and the first row needs the opening balance. A dated line that cannot be read is listed in `skipped`, never dropped or guessed.
- `app/lib/data/pdf_statement_parser.dart`: `parseStatementText` tries these readers first and falls back to the generic reader. Rows that do not follow the running balance, or whose direction cannot be read, carry a review reason; the statement's problems are warnings; the account is labelled `SBI ••8648` or `ICICI ••4911`.
- `app/lib/data/statement_sms_match.dart` and `TransactionImportSession.checkSavedDuplicates`: a row that an SMS-derived bank transaction already explains (amount, direction, account, within two days, one saved transaction per row) is shown as "Probably already in your SMS history" and left out unless the person keeps both. This is the guard against adding every SMS-known row twice, and it applies to every import source, not only these two.

What is not done or not proven: the layouts are written from real statements but tested only on invented text in those layouts, and the PDF library may order a table's words differently from the text the tests use; printed row counts are not read; a statement-only row is still saved as an ordinary imported transaction, not yet marked with the new source value from precedence rule 5; the E3 "N rows came from your statement" card is not built; card statements are not read.

## Order of work

1. C1 and the one-time name prompt (largest effect, no rule release).
2. A1 to A8 (definitions, one shared total, card spending not itemised, the bridge to the bank total, the per-payment "Count in spending" switch). A2 needs one real card's data before it ships.
3. B1 to B6 (family tag).
4. C2, C3, D1, D2, C4 (rule bundle).
5. D3 to D6, C5.

## Open questions (decisions for the owner)

Questions 1 to 3 were answered by the 12 Nov 2026 rewrite of section A. The owner approved the rewrite, not each answer, so change one here if it is wrong.

1. Should family payments count in **Spending** by default? Adopted: yes, as a visible Family slice, with a setting to leave them out (B5). Reason: a surname match is a guess, and money to a spouse or parent is often household spending.
2. Do you also want a **cash view** (what left your bank accounts, card bills counted when paid)? Adopted: yes, as **Left your accounts** (A7), separate from Spending.
3. Investment withdrawals: **Investment returns**, or net against investments? Adopted: neither. A withdrawal is **Withdrawn from investments** in Money in, shown next to Invested with the net beside it; only dividends and interest are Investment returns (A5).
4. One large transfer names a first name only in the SMS. Is that person you, family, or someone else? That decides whether C5 matters.
5. A credit from a person defaults to **From people**, not Income, and is netted only on a pair or a tap (A6). Is that the right default, or should an unpaired credit count as Income?
6. A loan EMI counts as Spending in full unless the SMS splits principal and interest (section A table). Is that right for a home loan, where most of the EMI is principal?

## Checking it

Tests use invented messages and names only (see `tools/sms_rules_cli/README.md`). To re-measure on a real corpus, run the private replay (`app/test/tool/sms_private_replay_test.dart`) with and without `SMS_OWNER_NAMES`, and compare spend, income, own-transfer and review counts. Never paste messages, names or amounts into the repository.
