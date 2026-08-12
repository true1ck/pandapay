# Credit card issuers in India — reference list

This is a compiled reference list of banks/NBFCs known to issue credit cards
in India, for scoping future scraping/data-coverage work. It is **not** an
official RBI registry and is **not** the scraping-clearance list — see
`CANDIDATE_SOURCES.md` for the actual vetted, ToS-review-gated shortlist of
sources the scraper is allowed to touch. Nothing here implies any of these
issuers are enabled for scraping; adding a source still requires the same
robots.txt + human ToS review process documented in `CANDIDATE_SOURCES.md`
and recorded via `db/scripts/review_source.py`.

Issuer participation shifts over time (portfolio sales, mergers, new NBFC
entrants) — treat this as a snapshot, not a guaranteed-current list.

## Public sector banks

- State Bank of India (SBI Card)
- Bank of Baroda
- Punjab National Bank
- Canara Bank
- Union Bank of India
- Bank of India
- Central Bank of India
- Indian Bank
- Indian Overseas Bank
- UCO Bank
- Punjab & Sind Bank

## Private sector banks

- HDFC Bank
- ICICI Bank
- Axis Bank
- Kotak Mahindra Bank
- IndusInd Bank
- Yes Bank
- IDFC FIRST Bank
- RBL Bank
- Federal Bank
- South Indian Bank
- IDBI Bank
- Bandhan Bank
- CSB Bank
- DCB Bank
- Tamilnad Mercantile Bank
- Karnataka Bank (co-branded)
- City Union Bank

## Small finance banks

- AU Small Finance Bank
- Equitas Small Finance Bank
- Ujjivan Small Finance Bank

## Foreign banks (India operations)

- American Express (Amex)
- Standard Chartered
- HSBC
- Citibank — retail/cards portfolio sold to Axis Bank in 2023; legacy Citi
  cards are now serviced by Axis
- DBS Bank
- Deutsche Bank

## NBFCs / fintech co-branded issuers

- SBI Card (standalone NBFC, majority SBI-owned)
- OneCard (FPL Technologies, with Federal Bank / SBM Bank)
- Slice (now a bank via NESFB merger)
- Bajaj Finserv (co-branded with RBL / DBS)
- LazyPay / PayU (co-branded)

## Currently in `CANDIDATE_SOURCES.md`

Of the above, these 12 already have a candidate scraping source row (all
`tos_reviewed = false`, `is_enabled = false` until a human clears them):

HDFC Bank, ICICI Bank, SBI Card, Axis Bank, Kotak Mahindra Bank, Yes Bank,
IDFC FIRST Bank, IndusInd Bank, AU Small Finance Bank, Standard Chartered,
RBL Bank, American Express.

Everyone else in this list would need a new `CANDIDATE_SOURCES.md` row
(base URL + robots.txt check) before it could even enter the ToS-review
queue.
