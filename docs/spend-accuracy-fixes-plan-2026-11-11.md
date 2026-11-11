# Spend accuracy: fixes to build later (11 Nov 2026)

Status: plan only, nothing built. Counts and shares only, no merchants, people, names or amounts from any private corpus. The real figures live in the owner's private workbook, not here.

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
- Activity's **Money out** filter already means spending plus investments (`_ActivityTypeFilter.moneyOut` in `app/lib/features/activity/activity_screen.dart`). Home shows only "Money in" and "Total spent".

## Goals

1. **Money out means everything that left the owner**, so it includes spending and investments, not spending alone (section A).
2. **Detect family from the owner's own name and tag it automatically** (section B).
3. **Recognise self-transfers without a profile name, and stop hiding unrelated payments under one shared "UNKNOWN" payee** (section C).
4. Fold in the smaller fixes this review found (section D).

Non-goals: new bank rules in a release, server changes, AI changes. Sections A, B and the app side of C are app changes (one app build). C4 and D1 to D2 are rule changes and need a rule-bundle version through the admin console.

## A. Money out and Money in (what to show)

**Definition.** Money out is every rupee that left the owner's own money and did not come back to it. It counts card spending when the card is used, so paying the card bill is not counted again.

| Event | Money out | Money in | Spending | Note |
| --- | --- | --- | --- | --- |
| purchase, subscription, bill payment, fee, tax | yes | no | yes | Taxes and interest are spending. |
| payment to a person | yes | no | yes, unless tagged Family or self | Family shows as its own line (section B). |
| investment, IPO application | yes (gross) | no | no | Shown as the **Investments** line of Money out. |
| investment withdrawal, dividend | no | yes, as **Investment returns** | no | Never mixed into salary or other income. |
| refund, reversal | netted against what it refunds | no | reduces it | Already how the totals work. |
| card bill payment | no | no | no | Counted when the card was used. Shown as a memo line "paid to cards". |
| move between own accounts, wallet top-up | no | no | no | Shown under Transfers. |
| credit from a person later repaid to the same person | no | no | no | See D4. |

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| A1 | Add money out, investments out and people-and-family out to the totals next to `spendMinor`, `incomeMinor`, `investmentMinor`. | `packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart` (`totals`), tests in `packages/pandapay_domain/test/sms_v2/ledger/golden_totals_test.dart` | Money out equals spending plus investments plus people; transfers and card bills never appear in it. A golden case per row of the table. |
| A2 | Home gets a **Money out** figure beside Money in and Total spent, with the split Spending, Investments, Family and other people. | `app/lib/features/home/home_screen.dart` (`_HomeSpendMetric`), report model in `app/lib/features/sms_v2/ledger/reports.dart` | Widget test: the three figures add up on a month that has all four kinds. |
| A3 | Activity's Money out chip and its header total use the same definition as Home. | `app/lib/features/activity/activity_screen.dart` | One definition shared by Home and Activity; a test fails if they differ. |
| A4 | Investment withdrawals appear as Investment returns in Money in, labelled so they are not read as income. | Home, Activity, Insights (`app/lib/features/insights/spend_trends_screen.dart`) | A month with a withdrawal shows it on its own line. |

## B. Family detection from the owner's name, with an automatic tag

Indian names usually run first name, father's name, surname. A payee that shares the **surname** or the **father's name** with another word is very likely family. A shared first name alone is never enough.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| B1 | Split the owner's name into parts: first, middle (father's name), surname. A one-word profile name gets a one-time prompt "add your full name". | `person_name.dart`, `runtime_provider.dart` | Tests for one-, two-, three- and four-word names. |
| B2 | `familyLikeName(payee, ownerNames)`: true when the payee shares the surname (whole, cut to 4 or more letters, or as an initial after other words) or the father's name together with one more word, including forms with an honorific (Smt, Shri, Mr, Mrs). False for a business, for the first name alone, and for very common words (a short stoplist plus any word that appears in many unrelated payees). | `person_name.dart` | Synthetic matrix below passes. |
| B3 | **Automatic tag.** When a payment or credit to a person matches, set the tag **Family** through `TransactionTagsRepository`, marked as automatic. A tag the person removes is never re-added; "Not family" remembers the payee. A weak match shows a "Family?" suggestion and does not tag. | `app/lib/app/providers.dart`, `transaction_tag_picker.dart`, pipeline write after the ledger projection | Re-reading history does not undo a manual removal; a test covers tag, remove, re-read. |
| B4 | Offer "Tag all payments to this payee" through the existing similar-changes sheet. | `app/lib/features/sms_v2/similar/` | Same sheet as the own-transfer flow. |
| B5 | Reports: a **Family** line in Money out. A setting "Count family payments as spending" (see Open questions). | `reports.dart`, Home, Insights | Switching the setting moves the figure between Spending and Family, Money out does not change. |
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

D7 entry shape (same as `CPP-CHEQ`): id `CPP-KIWI`, a UPI-address pattern for the Kiwi handle, a name pattern for "Gokiwi Tech" with or without "Priv" or "Limited", purpose `card_payment`, target kind `credit_card`. Until the rule ships, the per-transaction fix works: mark the payment as a credit card bill payment and tick the other payments to the same payee in the similar-changes sheet.

## E. SMS is not complete: reconcile against bank statements

Checked against two real bank statements covering 2026 so far (about 600 rows, parsed and proven against each bank's own totals): **about half of the statement rows had no matching SMS** (a strict one-to-one match on amount, direction and date, own transfers left out; a looser match gave about 40%), worth about 21% of money in and 20% of money out. The categories SMS missed most were interest and rewards, money from individuals, small UPI payments, and payments to individuals. They included a month's salary credit, a run of monthly person-to-person credits, and several large transfers in both directions. The balance trail had already shown the gap; the statements located it. SMS cannot be made complete, so the app should be able to close the gap itself.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| E1 | Import a bank statement (PDF, with the password the person types, never stored) and add the rows no SMS explains. The app already has a "Statement import" source label. | `app/lib/features/activity/transaction_detail_screen.dart` (`_sourceLabel`), a new import path under `app/lib/features/sms_import/` | A statement whose rows all have SMS adds nothing; one with a missing credit adds exactly that row. |
| E2 | Match statement rows to SMS by amount and date (plus or minus two days). Take care that amounts printed as "Rs.12345.00" match, which a naive pattern misses. Verify the parse with the statement's own running balance and printed totals before trusting any row. | pure functions in `packages/pandapay_domain/lib/src/sms_v2/ledger/` | Unit tests with an invented statement: balance chain intact, a row with and without SMS, a statement with printed totals that do not match. |
| E3 | After an import, show "N rows came from your statement, M have no SMS" and the money in and out they add. | Home or Needs review | The count is visible and dismissible. |

## Order of work

1. C1 and the one-time name prompt (largest effect, no rule release).
2. A1 to A4 (definitions, one shared total).
3. B1 to B6 (family tag).
4. C2, C3, D1, D2, C4 (rule bundle).
5. D3 to D6, C5.

## Open questions (decisions for the owner)

1. Should family payments count in **Spending** by default? Proposal: no, they are in Money out and shown as Family; a setting flips it.
2. Money out counts card spending when the card is used. Do you also want a **cash view** (what left your bank accounts, card bills counted when paid)?
3. Investment withdrawals: show as **Investment returns** in Money in (proposal), or net them against investments?
4. One large transfer names a first name only in the SMS. Is that person you, family, or someone else? That decides whether C5 matters.

## Checking it

Tests use invented messages and names only (see `tools/sms_rules_cli/README.md`). To re-measure on a real corpus, run the private replay (`app/test/tool/sms_private_replay_test.dart`) with and without `SMS_OWNER_NAMES`, and compare spend, income, own-transfer and review counts. Never paste messages, names or amounts into the repository.
