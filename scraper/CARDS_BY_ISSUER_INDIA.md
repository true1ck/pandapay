# Credit cards by issuer — India (compiled reference)

Scoped to the 12 issuers already tracked in `CANDIDATE_SOURCES.md`. This is
compiled from public comparison/aggregator sites (CardInsider, PaisaBazaar,
Stablemoney, PerkPilot, Forbes Advisor India, etc.), **not** from any
scraped or ToS-cleared source in this repo, and is **not verified against
each issuer's own site**. Portfolios change often (new launches, sunsets,
fee revisions) — treat this as a starting point for scoping data coverage,
not as data PandaPay should ship to users as-is. The real path to accurate,
current, sourced data is enabling the matching row in `CANDIDATE_SOURCES.md`
via `db/scripts/review_source.py` once ToS is reviewed, then letting the
scraper populate `card_products` from the issuer's own pages.

Card counts per issuer are approximate and reported by aggregators, not
counted first-hand.

## HDFC Bank (~30+ cards)

- Infinia (invite-only, top-tier)
- Diners Club Black
- Regalia Gold
- Regalia First
- Diners Club Privilege
- Diners Club Miles
- Millennia
- MoneyBack+
- Freedom
- Pixel Go
- Pixel Play
- Tata Neu Infinity HDFC Bank Credit Card
- Tata Neu Plus HDFC Bank Credit Card
- Shoppers Stop HDFC Bank Credit Card
- Shoppers Stop Black HDFC Bank Credit Card
- Paytm HDFC Bank Credit Card (variants)

## ICICI Bank (~15+ cards)

- Emeralde Private Metal
- Emeralde
- Sapphiro
- Rubyx
- Coral
- Platinum
- Amazon Pay ICICI Bank Credit Card
- HPCL Super Saver
- Chennai Super Kings ICICI Bank Credit Card
- Emirates Skywards ICICI Bank (variants)
- InterMiles ICICI Bank (variants)
- Parakram (variants)

## SBI Card (25+ mainstream cards; aggregators cite 65+ counting variants)

- SBI Card ELITE
- SBI Card PRIME
- SimplySave
- SimplyClick
- Cashback SBI Card
- BPCL SBI Card Octane
- Air India SBI Signature
- IRCTC SBI Card
- Etc. — see sbicard.com for the full current catalog

## Axis Bank (~18 cards)

- Magnus (super-premium)
- Reserve
- ACE (flat-rate cashback)
- MyZone
- Rewards
- Neo (RuPay, lifetime-free)
- LIC Platinum (lifetime-free)
- LIC Signature (lifetime-free)
- Flipkart Axis Bank Credit Card
- Samsung Axis Bank Signature Credit Card
- Vistara Axis Bank (co-brand)
- SpiceJet Axis Bank (co-brand)

## Kotak Mahindra Bank

- White Reserve
- Royale Signature
- Zen Signature
- Kotak 811 (entry-level)
- Myntra Kotak Credit Card
- IndiGo Kotak 6E Rewards XL
- IndiGo Kotak 6E Rewards
- IndianOil Kotak Credit Card

## Yes Bank

- Yes Private
- Yes Private Prime
- Marquee
- YES Premia
- YES First Preferred
- YES First Exclusive
- Wellness / Wellness Plus
- Klick RuPay (with Kiwi, lifetime-free, fully digital)
- BYOC (Build Your Own Card)
- EMI Credit Card

## IDFC FIRST Bank (~13 cards)

- FIRST Private (top tier)
- Gaj (invite-only, ₹12,500)
- Mayura (₹5,999)
- Ashva (₹2,999)
- Wealth (lifetime-free)
- Select (lifetime-free)
- Classic (lifetime-free)
- Millennia (lifetime-free)
- Power+ / HPCL Power (fuel)
- Click (lifetime-free)
- SWYP (youth-focused)
- LIC Classic / LIC Select (co-branded)
- WOW! / WOW! Black (FD-backed)
- EARN (FD-backed)

## IndusInd Bank (~20 cards)

- Pinnacle World
- Pioneer Heritage
- Pioneer Legacy
- Celesta
- Crest
- Indulge
- Legend (lifetime-free)
- Avios Visa Infinite (Qatar Airways / British Airways)
- Club Vistara IndusInd Bank Explorer
- Iconia Visa / Iconia Amex
- Signature Visa
- Platinum Aura Edge
- Platinum Select
- Platinum
- EazyDiner IndusInd Bank Credit Card
- Duo Plus
- Intermiles Voyage Visa
- Payback
- Nexxt

## AU Small Finance Bank (7 cards)

- Zenith+ (₹4,999) — premium travel
- Vetta (₹2,999) — travel & dining
- Altura Plus (₹499)
- Altura (₹199, RuPay/UPI-linked, lifetime-free tier)
- ixigo (lifetime-free, travel co-brand)
- LIT (lifetime-free, fully customizable feature packs)
- Spont (invite-only)

## Standard Chartered (6 cards)

- Ultimate (₹5,000)
- Emirates World
- Manhattan Platinum (₹999)
- EaseMyTrip
- DigiSmart
- Platinum Rewards (lifetime-free)

## RBL Bank (40+ cards including fintech co-brands)

- Platinum Maxima
- Platinum Delight
- Titanium Delight
- IndianOil RBL Bank Credit Card (co-brand)
- Zomato co-brand
- Practo co-brand
- TVS Credit co-brand
- Numerous additional fintech co-branded cards (partner-issued programs)

## American Express India (4 mainstream consumer cards + corporate variants)

- Platinum Charge (invite-only / highest tier)
- Gold Charge (no preset spending limit)
- Platinum Travel Credit Card
- Membership Rewards Credit Card
- Note: Amex India has periodically paused new consumer card applications; Platinum Charge/Gold Charge are typically invite-led.

---

Not yet covered here (present in `CREDIT_CARD_ISSUERS_INDIA.md` but with no
`CANDIDATE_SOURCES.md` row): all public-sector banks, most other private
banks (Federal, South Indian, IDBI, Bandhan, DCB, etc.), small finance banks
other than AU, HSBC, DBS, Citi-legacy-via-Axis, and NBFC/fintech co-branded
issuers (OneCard, Slice, Bajaj Finserv, LazyPay/PayU). Add a source row and
run it through ToS review before expecting data coverage for those.
