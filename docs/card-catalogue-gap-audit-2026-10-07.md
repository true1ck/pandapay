# Card catalogue gap audit

**Audit date:** 2026-10-07
**Environment checked:** PandaPay production catalogue and repository seed/fallback data
**Purpose:** Record missing card products and the evidence needed before publishing them.

## Executive summary

The production catalogue currently returns **377 published card rows**. It is not an exhaustive list of every Indian card product.

The most important confirmed gaps are:

1. **slice UPI Credit Card**
2. **Stable Money Suryoday RuPay Secured Credit Cards**
3. **OneCard Metal Credit Card**
4. **Scapia Federal Bank Credit Card**

The repository has a draft seed row named `Slice Super Card`, but it is not published and the current official product is now called **slice UPI credit card**. It should be represented as one active product with legacy aliases, not as a second active card.

## Confirmed production gaps

These products/families were not found in the live catalogue during the audit. Matching was checked against card name, slug, issuer name, and common aliases.

### 1. slice UPI Credit Card

| Field | Value |
|---|---|
| Canonical issuer | slice Small Finance Bank Ltd |
| Canonical product | slice UPI credit card |
| Legacy/search aliases | Slice Super Card, slice credit card, Slice UPI card |
| Product type | Credit card; UPI-enabled usage |
| Network | Verify from the issued-card record; do not infer it from the brand name |
| Fees | Official page advertises no joining and annual charges; terms must remain source-dated |
| Rewards | Up to 3% advertised; MITC defines eligible-spend rules and exclusions |
| Status | Missing from production catalogue |

The local seed contains `slice-super` as a **draft** card. That draft is not enough for app users because the production catalogue only exposes published rows.

Important terms to model include rewards exclusions for fuel, insurance, rent, education, taxes, government services, wallet loads, EMIs, international transactions, and excluded MCCs. These must be stored as rule data, not hardcoded into the UI.

Sources:

- https://slice.bank.in/credit-card
- https://slice.bank.in/cc-mitc/
- https://slice.bank.in/rates-and-pricing/

### 2. Stable Money Suryoday RuPay secured cards

Stable Money is the distribution brand; **Suryoday Small Finance Bank is the issuer**. The official Suryoday card page currently lists both products below, and neither was found in the live PandaPay catalogue.

| Canonical issuer | Product | Network | Type | Key evidence |
|---|---|---|---|---|
| Suryoday Small Finance Bank | Stable Money RuPay Select Credit Card | RuPay | FD-backed secured credit card | 0.5% cashback advertised; lounge and RuPay benefits |
| Suryoday Small Finance Bank | Stable Money RuPay Platinum Credit Card | RuPay | FD-backed secured credit card | 0.5% cashback advertised; lounge and RuPay benefits |

Required aliases:

- Stable Money Credit Card
- Stable Money Suryoday Credit Card
- Stable Money RuPay Select
- Stable Money RuPay Platinum
- Suryoday Stable Money Credit Card

The exact annual fee, lounge quota, cashback eligibility, FD-to-limit ratio, and exclusions must be taken from the applicable KFS/MITC version. The issuer page shows documents effective from **2026-10-05**, so this product must be stored with an effective date and document version rather than treated as timeless data.

Sources:

- https://stablemoney.in/credit-card
- https://suryoday.bank.in/personal/cards/credit-cards/secured-credit-card/
- https://suryoday.bank.in/assets/pdf/kfs-platinum-15112025.pdf

### 3. OneCard Metal Credit Card

The live catalogue has no OneCard issuer/product row. Current comparison research lists **OneCard Metal Credit Card** as a covered Indian product. It should be added only after validating the current issuing-bank partner, network variant, fees, reward caps, and applicable MITC.

Source for discovery, not final legal terms:

- https://www.perkpilot.in/banks/onecard
- https://www.perkpilot.in/cards/onecard/onecard-metal-credit-card

### 4. Scapia Federal Bank Credit Card

The live catalogue has no Federal Bank issuer row and no Scapia product row. Scapia Federal Bank Credit Card is a high-priority missing product, but the issuer's current official terms must be used for publication.

Source for discovery, not final legal terms:

- https://www.perkpilot.in/low-fee-credit-cards
- https://stablemoney.in/credit-card/federal-bank-scapia-credit-card

## Candidate gaps requiring issuer verification

Independent comparison data identifies one product each under **Jupiter** and **CRED**. No matching Jupiter or CRED product was found in the live catalogue. These are candidates, not yet publication-ready rows, because the exact current issuing bank, network, product name, and official terms need confirmation.

| Candidate family | Current audit result | Next verification |
|---|---|---|
| Jupiter | No matching live row | Confirm current issuer, card name, network, and official MITC |
| CRED | No matching live row | Confirm current issuer, card name, network, and official MITC |
| Indian Overseas Bank | Not represented in the live issuer list | Check whether an active credit-card product exists today |
| SBM Bank India | Not represented in the live issuer list | Check current active products and official terms |

CreditInd currently reports Slice, Jupiter, CRED, and Kiwi as separate covered families. Kiwi is **not** a complete gap in PandaPay: the live catalogue already contains PNB Kiwi and YES Bank Klick RuPay Kiwi rows.

Source for discovery only:

- https://creditind.com/credit-cards.html

## Products that should not be blindly added

### Legacy Citibank products

Some comparison sites still list Citibank PremierMiles and Prestige products. These should not be added as active cards without checking their current servicing/issuer status after the India portfolio migration. If retained for historical SMS matching, mark them `legacy` and prevent them from appearing as new-card recommendations.

### Slice Super Card as a separate active product

The repository seed name is useful as an OCR/SMS alias, but the current official product is the slice UPI credit card. Publishing both would create duplicate recommendations and could attach transactions to the wrong card.

## Catalogue quality findings

- Production contains **47 rows with `network = unknown`**. These should remain usable for identification but should not be used for network-specific reward calculations until verified.
- The offline bundled catalogue contains only **9 fallback cards**. If the catalogue API is unavailable, users may see a much smaller list than the production catalogue.
- The catalogue needs explicit `active`, `legacy`, and `discontinued` status handling.
- Every reward, cap, exclusion, fee waiver, lounge, and milestone rule needs `source_url`, `verified_at`, `effective_from`, and `effective_to` fields.
- A card should become visible to users only after human verification of the exact issuer document. Scraped comparison data is discovery input, not publication authority.

## Recommended implementation order

1. Add and verify the two Stable Money Suryoday products.
2. Add the current slice UPI Credit Card with legacy aliases, then publish it through the normal review gate.
3. Add OneCard Metal and Scapia only after official issuer/partner documents are attached.
4. Investigate Jupiter and CRED as separate candidate products.
5. Add catalogue tests for aliases, network variants, legacy filtering, and duplicate prevention.
6. Expand the fallback catalogue or show a clear offline state so users are not misled into thinking the nine fallback cards are the complete catalogue.

## Audit conclusion

PandaPay's catalogue is substantial but not complete. Slice and Stable Money are genuine gaps, and the current production count should not be described as “all Indian cards.” The safe approach is a reviewed, source-dated catalogue with aliases and lifecycle status—not a large unverified list copied from comparison websites.
