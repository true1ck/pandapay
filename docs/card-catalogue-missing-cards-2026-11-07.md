# Missing cards work queue — 2026-11-07

> **Update (same day):** the 9 October and 26 November cards below were researched against current issuer documents. All 35 are validated drafts in `docs/card-catalogue-gap-2026-11-07/drafts-all.json`; 30 pass the importer's mapping and 5 are held for missing reward data. Status per card: `card-data-requirements-and-extraction-plan-2026-11-07.md` §1.3. The 43 candidate names further down are still unresearched, and AU Bank's own KFS shows 10 AU cards missing beyond the ones drafted (§4.1 of the plan).

Generated from the live `GET /catalogue` (376 published cards), CardPipeline `data/checklist.json`, and the `catalogue-gaps` batches of 2026-10-17 and 2026-11-05. Nothing here is published; every row below is a draft, a proposal, or just a name.

## Where the other cards are

| Bucket | Count | State |
|---|---|---|
| Live in the app (published) | 376 | Verified, source-hashed, in `GET /catalogue` |
| On the 392-row master list but excluded on purpose | 16 | Duplicates of another row, discontinued, or no numeric reward/fee terms the issuer publishes (list below) |
| October gap batch (Stable Money x2, slice, OneCard SBM, Federal Scapia, Jupiter CSB, CRED IndusInd, IOB x2) | 9 | Imported as drafts on 2026-11-05 or earlier; none published (the Stable Money Select draft was corrected to ₹0 annual fee on 2026-11-05) |
| November gap batch (new products with partial source JSON) | 26 | 18 saved as draft products, 8 held as proposals because the fee is unresolved |
| Candidate names found in issuer fee schedules, not yet researched | 43 | A name and a source URL only |

So the catalogue is not missing 400+ cards. The researched universe was 392 products; what is genuinely absent is about **78** more, and none of them can be published until each has real reward rules and fees from the issuer document.

## Excluded from the 392-row list (not "missing")

| Row | Card | Reason |
|---|---|---|
| 4 | SBI ELITE Credit Card | Duplicate alias of the canonical SBI Card ELITE record; excluded to guarantee one publish row per product slug. |
| 7 | SBI Prime Credit Card | Duplicate alias of the canonical SBI Card PRIME record; excluded to guarantee one publish row per product slug. |
| 22 | Club Vistara SBI Card PRIME | discontinued or not found |
| 34 | Mumbai Metro SBI Card | verified discontinued-product review |
| 70 | Central Bank of India SBI Card PRIME | discontinued or not found |
| 71 | Central Bank of India SimplySAVE SBI Card | discontinued or not found |
| 75 | Karnataka Bank SBI Card ELITE | discontinued or not found |
| 84 | South Indian Bank SBI Card ELITE | discontinued or not found |
| 98 | BOBCARD Conclave | discontinued or not found |
| 162 | Corporate Platinum | Current official Corporate MITC does not publish fixed numeric membership fees; fees are negotiated or communicated during application, so numeric joining and annual fees cannot be safely fabricated. |
| 196 | Vistara Axis Bank | Duplicate alias of the canonical Axis Bank Vistara Infinite record; excluded to guarantee one publish row per product slug. |
| 278 | Payback Credit Card | verified discontinued-product review |
| 283 | Credit Card Against FD (Secured) | No source-supported usable reward logic, numeric fees, or resolved network is available for safe publication. |
| 335 | Play Credit Card | Current official Play Credit Card terms mention reward points for RuPay variants but do not publish a source-supported numeric earn rate required by the publication gate. |
| 342 | Bajaj Finserv RBL Bank SuperCard (Discontinued) | This is a generic legacy SuperCard family row rather than one fee-bearing product; official terms publish variant-specific fees, so one numeric fee pair cannot safely represent the family. |
| 392 | Credit Card Against FD (secured) | No source-supported usable reward logic is available for safe publication. |

## October gap batch (imported as drafts, not published)

| Card | Issuer | Note |
|---|---|---|
| Stable Money Suryoday RuPay Select Credit Card | Suryoday Small Finance Bank | FD-backed secured credit card |
| Stable Money Suryoday RuPay Platinum Credit Card | Suryoday Small Finance Bank | FD-backed secured credit card |
| slice UPI Credit Card | slice Small Finance Bank Ltd | UPI credit card |
| OneCard Metal Credit Card (SBM Bank India variant) | SBM Bank India | OneCard issuer variant verification |
| Scapia Federal Bank Credit Card | Federal Bank | Travel credit card |
| Jupiter Edge+ CSB Bank RuPay Credit Card | CSB Bank | Candidate product verification |
| CRED IndusInd Bank RuPay Credit Card | IndusInd Bank | Candidate product verification |
| IOB RuPay Platinum Credit Card | Indian Overseas Bank | Candidate issuer product verification |
| IOB RuPay Select Credit Card | Indian Overseas Bank | Candidate issuer product verification |

## November gap batch (partial source JSON)

| Card | Slug | Network | Joining | Annual | Reward rules | Blocker |
|---|---|---|---|---|---|---|
| YES BANK POP-CLUB RuPay Credit Card | `yes-bank-pop-club-rupay` | rupay | ₹0 | ₹399 | 2 | rules partial; caps/exclusions unreviewed |
| Eternal SBI Card | `eternal-sbi-card` | unknown | ₹499 | ₹499 | 0 | no reward rules; network unknown |
| CheQ AU Credit Card | `cheq-au-credit-card` | unknown | unknown | unknown | 0 | fees unresolved; network unknown |
| Scapia Axis Bank Credit Card | `axis-bank-scapia-credit-card` | unknown | ₹0 | ₹0 | 0 | no reward rules; network unknown |
| BOBCARD Scapia Credit Card | `bobcard-scapia-credit-card` | unknown | ₹0 | ₹0 | 0 | no reward rules; network unknown |
| MobiKwik First Suryoday SFB RuPay Platinum Credit Card | `suryoday-mobikwik-first-rupay-platinum` | rupay | ₹0 | ₹0 | 0 | no reward rules |
| SBM Paisabazaar Paisa Plus Credit Card | `sbm-paisabazaar-paisa-plus` | unknown | ₹0 | unknown | 0 | fees unresolved; network unknown |
| Google Pay Flex Axis Bank Credit Card | `google-pay-flex-axis-bank` | rupay | ₹0 | ₹0 | 0 | no reward rules |
| Axis Bank super.money RuPay Credit Card | `axis-bank-supermoney-rupay` | rupay | ₹0 | ₹0 | 0 | no reward rules |
| Kwik Axis Bank Credit Card | `axis-bank-kwik` | rupay | ₹0 | ₹0 | 0 | no reward rules |
| Axis Bank Shoppers Stop Credit Card | `axis-bank-shoppers-stop` | unknown | ₹500 | unknown | 0 | fees unresolved; network unknown |
| 1838 Reserve ICICI Bank Credit Card | `icici-1838-reserve` | visa | ₹175,000 | ₹175,000 | 0 | no reward rules |
| Times Black ICICI Bank Credit Card | `icici-times-black` | visa | ₹20,000 | ₹20,000 | 0 | no reward rules |
| AU Ananta Credit Card | `au-ananta` | unknown | ₹2,000 | ₹2,000 | 0 | no reward rules; network unknown |
| AU Laksya Credit Card | `au-laksya` | unknown | ₹1,000 | ₹1,000 | 0 | no reward rules; network unknown |
| AU Tejas Credit Card | `au-tejas` | unknown | ₹500 | ₹500 | 0 | no reward rules; network unknown |
| AU Prathama Credit Card | `au-prathama` | unknown | ₹100 | ₹100 | 0 | no reward rules; network unknown |
| Paytm AU Credit Card | `paytm-au-credit-card` | unknown | ₹0 | ₹0 | 0 | no reward rules; network unknown |
| AU Traverse Credit Card for NRIs | `au-traverse-nri` | unknown | unknown | ₹4,999 | 0 | fees unresolved; network unknown |
| RBL Bank Shoppers Stop Gold Credit Card | `rbl-bank-shoppers-stop-gold` | visa | ₹1,000 | ₹1,000 | 2 | rules partial; caps/exclusions unreviewed |
| RBL Bank Shoppers Stop Platinum Credit Card | `rbl-bank-shoppers-stop-platinum` | visa | ₹5,000 | ₹5,000 | 2 | rules partial; caps/exclusions unreviewed |
| RBL Bank Shoppers Stop Black Credit Card | `rbl-bank-shoppers-stop-black` | visa | ₹10,000 | ₹10,000 | 2 | rules partial; caps/exclusions unreviewed |
| Bandhan Bank Sparks Credit Card | `bandhan-sparks` | unknown | unknown | unknown | 0 | fees unresolved; network unknown |
| Bandhan Bank Ignite Credit Card | `bandhan-ignite` | unknown | unknown | unknown | 0 | fees unresolved; network unknown |
| Bandhan Bank Flare Credit Card | `bandhan-flare` | unknown | unknown | unknown | 0 | fees unresolved; network unknown |
| Bandhan Bank Lumina Credit Card | `bandhan-lumina` | unknown | unknown | unknown | 0 | fees unresolved; network unknown |

## Candidate names not yet researched

Source is an issuer schedule of charges, which does not prove the product is still sold. Each needs a current-availability check first.

| Issuer | Candidate | Source |
|---|---|---|
| au | AU NOMO | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU Xcite | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU Xcite ACE | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU Xcite Ultra | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU InstaPay RuPay | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU Kosmo | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU Zaggle | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU CA Metal | https://www.au.bank.in/personal-banking/credit-cards |
| au | AU CS | https://www.au.bank.in/personal-banking/credit-cards |
| axis | IndiGo Axis Bank Credit Card | https://www.axis.bank.in/cards/credit-card/indigo-axis-bank-credit-card |
| axis | IndiGo Axis Bank Premium Credit Card | https://www.axis.bank.in/cards/credit-card/indigo-axis-bank-premium-credit-card |
| yes | YES BANK ANQ Phi | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK ANQ Pi | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK UNI | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK FREO | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK FREO RuPay | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK FinBooster | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK FinBooster RuPay | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK Paisasave RuPay | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| yes | YES BANK RIO / Zagg | https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards |
| sbm-bank-india | SBM MobiKwik First | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| sbm-bank-india | SBM ZET | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| sbm-bank-india | SBM Kredit.Pe | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| sbm-bank-india | SBM novio | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| sbm-bank-india | SBM Magnet | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| sbm-bank-india | SBM Niyo Global | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| sbm-bank-india | SBM Paisabazaar Step Up | https://www.sbm.bank.in/personal-banking/cards/secured-credit-card |
| rbl | RBL Bank Lumiere | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank Nova | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank iGlobe | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank World Safari Lite | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank World Safari Plus | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank SalarySe UP | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank IndianOil XTRA | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank BankBazaar SaveMax | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank BankBazaar SaveMax Pro | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank Paisabazaar Duet Plus | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank Popcorn | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank Movies & More | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank IRCTC | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| rbl | RBL Bank LazyPay | https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf |
| karur-vysya-bank | KVB Visa Platinum | https://www.kvb.bank.in/docs/retail-credit-card-mitc.pdf |
| karur-vysya-bank | KVB Visa Signature | https://www.kvb.bank.in/docs/retail-credit-card-mitc.pdf |

## Issuers with no cards in the live feed

Live feed has 25 issuer names. Several are one issuer written two ways, which splits the picker: `Sbi` (77) vs `State Bank Of India` (1), `Kotak` (15) vs `Kotak Mahindra Bank` (24), `Ujjivan Small Finance Bank` (1) vs `Ujjivan Sfb` (1). Names are also title-cased from slugs (`Hdfc`, `Pnb`, `Hsbc`, `Idfc First Bank`), not the real display names. Absent entirely: Federal Bank, CSB Bank, SBM Bank India, Indian Overseas Bank, Suryoday SFB, slice SFB, Bandhan Bank.

## Gate before anything is published

1. Fees, network, reward rules, caps and exclusions come from the issuer MITC / KFS, with `source_url` and effective date, never from a comparison site.
2. Run `node api/scripts/import_card_pipeline.js --transform-only` (no database) and read the coverage report.
3. Import as `draft` only, then human review, then `publish_card_pipeline.js --dry-run`, then publish.
