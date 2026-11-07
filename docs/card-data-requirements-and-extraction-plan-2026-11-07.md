# Card data: what we need, how we get it, how we detect cards

**Date:** 2026-11-07 · **Status:** proposal for review · **Extends:** `card-rewards-intelligence-feature-spec-2026-11-05.md` (§6 Part 0 and §8) and `card-rewards-later-phases.md`.
Nothing here changes production data. Evidence comes from researching 35 cards from issuer documents on 2026-11-07 and from counts over the owner's real SMS (aggregates only).

## 1. What researching 35 cards taught us

### 1.1 Source quality, in order of trust

1. Issuer MITC / KFS / schedule of charges PDF (regulated, lists every product and every fee).
2. Issuer card page read in a real browser session (JS-rendered; some detail hides behind "view more").
3. Partner terms (CheQ, Scapia, CRED, Paisabazaar): needed for reward value, but not the bank's own.
4. Fetch-tool summaries: **not usable as facts.** They summarise text the tool did not show, and several contradicted the documents.

Practical limits met: `au.bank.in` pages return 403 to a plain fetch but load in a real browser; WebFetch stops at 10 MB (AU MITC); two YES Bank PDFs timed out repeatedly; a firewall rejected a guessed Bandhan URL (the site's own links worked); PDFs need a text step (`pdftotext`) and a few need a page image to read tables correctly (Axis interest table, AU fee table).

### 1.2 Things the current schema and engine cannot express

These affect the 35 as follows; each needs a field or an engine input, not more research.

| # | Pattern | Examples in this batch | What is needed |
|---|---|---|---|
| 1 | A headline "% rewards" is points, not cash | Scapia (Axis, BOBCARD, Federal): "10%" is 2% (5 coins = ₹1); CheQ AU: "12%" is 6% (2 pts = ₹1) and 3% on bills; ICICI Times Black "2%" is 0.8% on statement credit; Axis Shoppers Stop, RBL Shoppers Stop | `value_per_point_inr` **per redemption channel** on every earn rule, plus a `headline_percent` kept separately |
| 2 | Rate depends on the user | Google Pay Flex (Google One member, previous-cycle spend ≥ ₹100, cycle spend > ₹15,000); SBM Paisa Plus (FD size); Bandhan interest (existing vs new-to-bank) | A `user_state` block on rules, and the add-card flow collecting those facts |
| 3 | Cap depends on other earnings | super.money 3%: capped at the larger of ₹100 and the cashback earned elsewhere that cycle | `dependent_cap` (expression over other earn buckets) |
| 4 | Instant discount vs statement cashback vs points | Eternal SBI (10% instant discount, shared ₹2,000 cap), AU Tejas partner offers, Bandhan BookMyShow/EazyDiner, Flex category boosts | A separate **offer** entity with type, merchant list, cap, period, quota, validity, and a flag for "reduces price at checkout" |
| 5 | Milestones that are not annual or not rupees | Bandhan monthly milestones (1,200 / 5,000 / 10,000 points); RBL quarterly vouchers; AU Ananta tiers paid in points | `period` = month/quarter/anniversary-year/calendar-year, `reward_unit` = points/INR/voucher, `claim_window_days` |
| 6 | Linked networks on one account | Scapia ×3, CheQ AU, Eternal SBI (Mastercard + RuPay) | Already stored as `verified_network_research`; the engine must pick the variant's rule (RuPay 1% vs Mastercard 2%), and the add-card flow must ask which card was issued |
| 7 | Two documents disagree, or a newer one exists | CheQ AU fee (resolved by KFS v1.9), SBM Paisa Plus annual fee, Stable Money (26 May vs 5 Oct KFS), Bandhan Lumina fuel cap (₹500 vs ₹1,000), super.money effective date | Per-field `source_doc`, `effective_from`, `superseded_by` and a conflict log that blocks publish until resolved |
| 8 | A product listed but not yet on sale, or legacy | IOB RuPay Platinum/Select ("proposed to be launched"), Citi/legacy cards | Lifecycle: `announced`, `active`, `legacy`, `discontinued`; only `active` can be recommended |
| 9 | Category taxonomy too small | The app has ~15 categories; real rules use department stores, apparel, electronics, jewellery, tolls, gift cards, airline/hotel direct, partner merchants | Either more categories, or use the merchant directory plus MCC lists as the primary key and keep categories as display only |
| 10 | Event bonuses | "500 points on 5 transactions", recurring-payment setup bonuses, first-transaction welcome | Keep out of spend rates (importer already does); store as `event_bonus` for the ledger and a reminders feature |

### 1.3 Where the 35 stand

Generated from `docs/card-catalogue-gap-2026-11-07/build-report.json`. All 35 validate against the universal schema and none collides with a live card. The importer's database-free transform accepts 30; five have no published reward rate and are skipped on purpose.

| Slug | Name | Joining / annual ₹ | Earn + exclusion rules | Caps | Importable | Open questions | Main blocker |
|---|---|---|---|---|---|---|---|
| `au-ananta` | AU Ananta Credit Card | 2,000 / 2,000 | 3 + 0 | 1 | yes | 5 |  |
| `au-laksya` | AU Laksya Credit Card | 1,000 / 1,000 | 3 + 0 | 1 | yes | 4 |  |
| `au-prathama` | AU Prathama Credit Card | 100 / 100 | 2 + 0 | 0 | yes | 3 |  |
| `au-tejas` | AU Tejas Credit Card | 500 / 500 | 1 + 0 | 0 | yes | 4 |  |
| `au-traverse-nri` | AU Traverse Credit Card for NRIs | 4,999 / 4,999 | 0 + 0 | 0 | no | 4 | No reward rate published on the page; lounge and welcome only |
| `axis-bank-kwik` | Kwik Axis Bank Credit Card | 0 / 0 | 1 + 10 | 0 | yes | 3 | EDGE point value not read |
| `axis-bank-scapia-credit-card` | Scapia Axis Bank Credit Card | 0 / 0 | 3 + 9 | 0 | yes | 4 |  |
| `axis-bank-shoppers-stop` | Axis Bank Shoppers Stop Credit Card | 500 / 500 | 3 + 9 | 0 | yes | 5 | Network and point value not stated |
| `axis-bank-supermoney-rupay` | Axis Bank super.money RuPay Credit Card | 0 / 0 | 2 + 13 | 1 | yes | 3 | 3% cap depends on other cashback; effective date conflict |
| `bandhan-flare` | Bandhan Bank Flare Credit Card | 2,499 / 2,499 | 2 + 0 | 0 | yes | 4 |  |
| `bandhan-ignite` | Bandhan Bank Ignite Credit Card | 0 / 999 | 3 + 0 | 0 | yes | 4 |  |
| `bandhan-lumina` | Bandhan Bank Lumina Credit Card | 9,999 / 9,999 | 2 + 0 | 0 | yes | 5 | Fuel waiver cap ₹500 (MITC) vs ₹1,000 (page) |
| `bandhan-sparks` | Bandhan Bank Sparks Credit Card | 0 / 499 | 2 + 0 | 0 | yes | 4 |  |
| `bobcard-scapia-credit-card` | BOBCARD Scapia Credit Card | 0 / 0 | 3 + 10 | 0 | yes | 4 |  |
| `cheq-au-credit-card` | CheQ AU Credit Card | 0 / 0 | 4 + 9 | 1 | yes | 5 |  |
| `csb-bank-jupiter-edge-plus-rupay` | Jupiter Edge+ CSB Bank RuPay Credit Card | 999 / 0 | 0 + 0 | 0 | no | 3 | Jewels value and caps not in the MITC |
| `eternal-sbi-card` | Eternal SBI Card | 499 / 499 | 6 + 1 | 2 | yes | 5 |  |
| `federal-bank-scapia-credit-card` | Scapia Federal Bank Credit Card | ? / ? | 3 + 1 | 0 | yes | 3 | Fees not stated ("prevailing rate") |
| `google-pay-flex-axis-bank` | Google Pay Flex Axis Bank Credit Card | 0 / 0 | 5 + 8 | 1 | yes | 6 | Rates depend on Google One and prior-cycle spend |
| `icici-1838-reserve` | 1838 Reserve ICICI Bank Credit Card | 175,000 / 175,000 | 2 + 4 | 3 | yes | 5 |  |
| `icici-times-black` | Times Black ICICI Bank Credit Card | 20,000 / 20,000 | 2 + 3 | 1 | yes | 5 |  |
| `indian-overseas-bank-rupay-platinum` | IOB RuPay Platinum Credit Card | 0 / 250 | 0 + 0 | 0 | no | 4 | Schedule says variant is "proposed to be launched"; no earn rates found |
| `indian-overseas-bank-rupay-select` | IOB RuPay Select Credit Card | 0 / 500 | 0 + 0 | 0 | no | 4 | Schedule says variant is "proposed to be launched"; no earn rates found |
| `indusind-bank-cred-rupay` | CRED IndusInd Bank RuPay Credit Card | ? / ? | 3 + 6 | 2 | yes | 5 | Issuer fees not read; redemption values carried over |
| `paytm-au-credit-card` | Paytm AU Credit Card | 0 / 0 | 6 + 8 | 1 | yes | 4 |  |
| `rbl-bank-shoppers-stop-black` | RBL Bank Shoppers Stop Black Credit Card | 10,000 / 10,000 | 2 + 11 | 2 | yes | 5 |  |
| `rbl-bank-shoppers-stop-gold` | RBL Bank Shoppers Stop Gold Credit Card | 1,000 / 1,000 | 2 + 11 | 2 | yes | 5 |  |
| `rbl-bank-shoppers-stop-platinum` | RBL Bank Shoppers Stop Platinum Credit Card | 5,000 / 5,000 | 2 + 11 | 2 | yes | 5 |  |
| `sbm-bank-india-onecard-metal` | OneCard Metal Credit Card (SBM Bank India variant) | 0 / 0 | 0 + 0 | 0 | no | 5 | MITC (Sep 2025) has no earn structure |
| `sbm-paisabazaar-paisa-plus` | SBM Paisabazaar Paisa Plus Credit Card | 0 / 499 | 3 + 9 | 2 | yes | 5 | Annual fee conflict: KFS ₹499 vs rewards SOP 0 |
| `slice-small-finance-bank-upi-credit-card` | slice UPI Credit Card | 0 / 0 | 1 + 13 | 0 | yes | 5 |  |
| `stable-money-suryoday-rupay-platinum` | Stable Money Suryoday RuPay Platinum Credit Card | 0 / 0 | 1 + 11 | 1 | yes | 3 |  |
| `suryoday-mobikwik-first-rupay-platinum` | MobiKwik First Suryoday SFB RuPay Platinum Credit Card | 0 / 0 | 0 + 0 | 0 | yes | 4 | Cashback rules document not read |
| `suryoday-stable-money-rupay-select` | Stable Money Suryoday RuPay Select Credit Card | 0 / 0 | 1 + 11 | 1 | yes | 3 |  |
| `yes-bank-pop-club-rupay` | YES BANK POP-CLUB RuPay Credit Card | 0 / 399 | 2 + 0 | 0 | yes | 4 | YES documents timed out; POPcoin value unknown |
Reproduce: `node docs/card-catalogue-gap-2026-11-07/build.mjs` validates and rebuilds every draft; `node api/scripts/import_card_pipeline.js --transform-only --input docs/card-catalogue-gap-2026-11-07/drafts-all.json` runs the importer's mapping with no database.

## 2. What data the app needs (by feature), and what we hold today

"Now" means a current or already-specified feature needs it (spec Parts 0, A, B, C). "Next" is the follow-on in `card-rewards-later-phases.md`. "Later" is new here.

| Group | Fields | Feature it powers | When | State in catalogue today |
|---|---|---|---|---|
| Identity and lifecycle | issuer (legal name, display name, slug, **sender IDs**, domains, aliases); product name and **aliases / SMS naming variants**; co-brand partner; network variants; lifecycle (`announced/active/legacy/discontinued`) with dates; application mode | Card detection, add-card picker, recommendations (never suggest a card that is not on sale) | Now | Name, issuer, network (47 `unknown`), no sender IDs, no aliases, no lifecycle |
| Fees | joining, annual/renewal, waiver (threshold, period, excluded categories), add-on, replacement; forex and DCC **per network variant**; interest by customer type; late fee as slabs or a formula with minimum and maximum; cash advance; over-limit; fuel surcharge and waiver (min/max transaction, cap); category surcharges with thresholds (rent, wallet, utility, education, gaming, fuel, transport); EMI fees; redemption fee; payment-return fee | Fee-waiver tracker, true-cost comparison, late-fee warnings, travel-card pick | Now | Fees and forex yes; late fee, surcharges and fuel partial; effective dates missing |
| Earning | base rate (block, unit, rounding, minimum transaction); accelerators by MCC / merchant / platform / rail / network / **user state**; exclusion MCC lists; caps (bucket, period, metric, unit, parent or **dependent**, behaviour after cap); **value per point by channel**; expiry; redemption options and fees; transfer partners | Ranking, ledger, estimates | Now | Largely present; conditions ignored by the engine; point value by channel absent |
| Progress and benefits | milestones (period, unit, claim window); welcome and renewal gifts with triggers; lounge (count, period, unlock rule, guests, programme, domestic or international); golf, spa, movie quotas; insurance covers with amounts | Unlock progress, benefit reminders, "use it or lose it" | Now / Next | Milestones all anchored to card anniversary (importer bug); 238 of 641 caps linked to nothing (spec §3) |
| **Offers** (new entity) | merchant or category, discount type (instant discount, cashback, points boost), percent, cap, minimum transaction, quota and period, validity dates, card and network scope, payment mode, source | "Which card at this merchant today", deal alerts | Later | Not modelled; partner offers are in prose |
| Eligibility and application | age, income, employment, residency, relationship (FD, NRE, salary account), invite-only, documents, processing time, joining-offer cohort | "Which card should I get" | Later | Guideline fields exist; mostly null |
| Billing facts | statement day, due-date offset, grace days, minimum-due formula | Due-date reminders, interest-free days | Next | Partial |
| Detection data | see section 3 | Card detection, add-card flow | Now | Almost none |
| Provenance on every field | source URL, document and version, effective date, fetched-on, extracted-by, verified-by, confidence, change history | Trust, review, devaluation alerts | Now | Per-card only; per-field missing |

### 2.1 Critical criteria a rule must carry before it can be ranked

A rule is "rankable" only when all of these are known; otherwise it is stored but shown as information (the importer already does this):

1. the exact **unit** (points per ₹ block, or cashback percent) and the **₹ value** of that unit for the channel the user will use;
2. which spends qualify (MCC list or merchant list, minimum transaction, rail, network variant);
3. every **cap** that can bind, with period and what happens after it;
4. the **user attributes** the rate depends on, and whether we know them;
5. an effective date and the document it came from.

## 3. Detecting which card a transaction belongs to

### 3.1 What the digits can and cannot tell us

- **Last four digits** identify one physical card for one issuer. They say nothing about the product.
- **First six to eight digits (BIN)** give issuer, network, credit or debit and sometimes tier, but banks share ranges across products, so they narrow a list; they rarely name one product.
- **SMS never carries the BIN.** In the owner's 11,468 institutional messages, 2,287 mention a card, and one shows a visible card-number prefix pattern.
- `card_product.bin_ranges` exists in the schema but is filled for only 23 of 392 researched cards, by a language model with no check, and nothing in the app or API reads it. Do not rely on it.

### 3.2 Measured on the owner's real SMS (counts only; no message text left the Mac)

| Measure | Result |
|---|---|
| Transactional credit-card alerts (after the existing promo and debit filters) | 1,678 |
| Carry a masked suffix | 1,467 (87%); every suffix found was 4 digits (1,715 of 1,717 captures) |
| Product named in the text and matched by `discoverCardsInMessage` against the 376-card catalogue | 456 (27%) |
| Physical cards found (sender brand + suffix) | 28; 19 have at least one message that names the product |
| If a card's product name is applied to **all** its alerts | 1,359 alerts = **81%** of all card alerts (92.6% of those with a suffix) |
| Cards whose messages name two different products | 6 of 28, so conflicts must be surfaced, not silently resolved |

Reading the code (`api/src/card_discovery.js`): discovery already drops an unnamed placeholder when a named card shares its issuer and suffix, so the propagation gain is partly there for suggestions. The gaps are below.

### 3.3 Proposed layered resolution

| Layer | Signal | Data it needs |
|---|---|---|
| L1 | Sender header gives the issuer | An issuer registry of sender IDs (DLT headers) and aliases. Today the matcher needs every issuer token in the text or sender, so `IDFCFB`, `INDUSB`, `AUBANK`, `AMEXIN`, `SCBANK` cannot match "Idfc First Bank", "Indusind", "Au Small Finance Bank", "American Express India" or "Standard Chartered". This is from reading the code, not measured per issuer. |
| L2 | Product name in the text | Per-product aliases and the exact wording banks use in SMS; family-word disambiguation. A product missing from the catalogue can only ever be a placeholder, so catalogue breadth directly limits detection. |
| L3 | Suffix gives the physical card | Identity is (issuer, instrument type, suffix). American Express uses a 5-digit suffix: `extractLast4` returns nothing for it (tested on made-up strings; no Amex in this owner's data). |
| L4 | Propagate within one physical card | Apply a product named in any alert to every alert with the same issuer and suffix; flag conflicts. |
| L5 | One-time user confirmation | The add-card flow shows cards filtered by issuer and network, pre-selected from the evidence above, and asks which network was issued. |
| L6 (optional) | On-device scan of the physical card | Reads the BIN to narrow issuer, network and tier, then discards the number. Never store a full card number. |

### 3.4 Proposals, in order

1. **Issuer registry** with sender IDs and aliases, used by discovery (data plus a small code change).
2. **Clean issuer names** in the live feed: `Sbi` (77) and `State Bank Of India` (1), `Kotak` (15) and `Kotak Mahindra Bank` (24), two Ujjivan names, and slug-style `Hdfc`, `Pnb`, `Hsbc`. These split pickers and can create two placeholders for one bank.
3. **Per-product SMS aliases** in the catalogue, tested against a golden set built from real alerts.
4. **Propagation** with a conflict flag in the spend pipeline (check what the server does today with `user_cards.last4`).
5. **5-digit suffix** for American Express (needs a decision on the column and validation).
6. **Add-card picker** filtered by issuer and network.

Not recommended: BIN from SMS (absent), asking users to type a full card number.

## 4. Extraction plan for all cards on sale today

### 4.1 Universe: use the issuers' own fee tables

Listing pages are unreliable to scrape (SBI Card's page exposes 6 featured cards until tabs are clicked; sites use carousels and firewalls). The regulated **MITC / KFS / schedule of charges** lists every product with its fee, so it is the universe source.

Worked example, verified: AU Small Finance Bank's KFS v1.9 (2 Nov 2026) names **25 products** plus the SwipeUp Xcite series. The live catalogue has **8**. That is **17 missing**, of which 7 are in the 35 researched here; the other 10 are Xcite, Xcite ACE, Xcite Ultra, AU NOMO, Business Cashback, InstaPay, AU KOSMO, AU CA, AU CS and AU Zaggle. The same method applies to the ICICI and Axis MITCs and the RBL schedule, which were extracted but not yet diffed.

Total so far: 376 live + 35 drafted + 43 candidate names from the Nov 5 queue, plus whatever the full-table pass finds for the ~35 other issuers. Absent from the live feed entirely: Federal, CSB, SBM, IOB, Suryoday, slice, Bandhan, IDBI, Union Bank, Bank of India, Indian Bank, Central Bank, South Indian Bank, Karnataka Bank, Karur Vysya.

### 4.2 Pipeline

| Stage | What happens | Automation | Gate |
|---|---|---|---|
| S0 Discover | Parse each issuer's MITC / KFS fee table; add network-level lists and aggregator names as hints only | Script + `pdftotext`, page image for tables | Every product has issuer, name, source document and date |
| S1 Identity | Canonical slug, aliases, partner, lifecycle, networks and variants | Rules + review | No duplicate slug; alias collisions reviewed |
| S2 Fetch | Real browser for pages, direct PDF download, text extraction, store file hash and date | Browser automation | Document readable; hash stored |
| S3 Extract | Fill the universal schema from the documents with quotes; two-model cross-check as in CardPipeline | LLM, cached | Every non-null value cites a document |
| S4 Validate | Deterministic checks: schema, fee sanity, cap ≥ 0, forex 0-4%, rates reconcile with a worked example in the document | Script | No unexplained conflicts |
| S5 Transform | `--transform-only`; read the coverage report | Script | No new unmapped tokens without a decision |
| S6 Review | Reviewer sees value, source quote and conflicts side by side in the admin console | Human | Approved per card |
| S7 Publish | Existing `publish_card_pipeline.js` dry run, then publish | Human-approved | Audit log row |
| S8 Monitor | Weekly hash check of every source document; diff and alert on change | Existing scraper plus source table | Subject to the ToS review in `scraper/CANDIDATE_SOURCES.md` |
| S9 Learn | User corrections and statement mismatches feed back as review items | Existing correction flow | Reviewed before any rule changes |

Hand research in this session took roughly 6 to 10 tool calls per card and needed a human for every judgement call. For the remaining cards the target is S0 to S5 automated and about 10 minutes of human review per card (an estimate, not a measurement).

### 4.3 Order of work

1. Import the 30 importable drafts as `draft` and review them (decision below).
2. Resolve the open questions on the 5 skipped cards and the 10 AU cards not yet researched.
3. Run S0 on ICICI, Axis, RBL, SBI Card, HDFC, Kotak, IDFC FIRST, IndusInd, YES, Standard Chartered, HSBC, American Express, Federal, BOBCARD (most live cards first).
4. Land the schema additions in section 1.2 (value per channel, `user_state`, dependent cap, offers, lifecycle, per-field provenance).
5. Build S8 monitoring.

## 5. Acceptance criteria

- Every published card has joining and annual fee, forex, at least one earn rule with a stated ₹ value per unit, every binding cap, and a source document and date per field.
- No published card has an unresolved conflict or `network = unknown` unless the issuer genuinely issues a linked pair.
- Detection: at least 80% of card alerts resolved to a product on a held-out slice of the owner's SMS (81% is the measured ceiling from naming alone), with conflicts shown to the user.

## 6. Decisions needed

1. Import the 30 importable drafts into the production database as `draft` (they stay hidden from the public feed; nothing is published). The 5 skipped need more research first.
2. Approve the schema additions in section 1.2 (value per channel, `user_state`, dependent cap, offers, lifecycle).
3. Approve automated crawling of issuer documents (S2, S8), which needs the per-source ToS review.
4. Whether to build detection proposals 1 to 6 before or after the current release.
5. Fix the issuer names in production data.
