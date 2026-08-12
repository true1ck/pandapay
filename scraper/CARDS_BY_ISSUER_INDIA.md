# Credit cards by issuer — India (compiled reference)

Covers every issuer listed in `CREDIT_CARD_ISSUERS_INDIA.md`. Compiled from
public comparison/aggregator sites (CardInsider, PaisaBazaar, Stablemoney,
PerkPilot, Forbes Advisor India, BankBazaar, etc.) via web search, **not**
from any scraped or ToS-cleared source in this repo, and **not verified
against each issuer's own site**.

**This is not, and cannot be, a guaranteed-complete list.** There is no
single authoritative registry of every credit card product in India — RBI
publishes issuer-level statistics (cards outstanding), not a card-level
catalog. Aggregator sites each cover a subset, sometimes disagree with each
other on counts for the same issuer, and go stale as products launch, get
renamed, or get discontinued. Web search returns summarized snippets, not
full page content, so even this "deepened" pass can miss variants a snippet
didn't surface. Treat every list below as a lower bound, not a ceiling.

The only way to get an actually-complete, current, sourced catalog is the
scraper pipeline this repo already has designed for it: enable a source in
`CANDIDATE_SOURCES.md` (12 issuers already have candidate rows) via
`db/scripts/review_source.py` after a human ToS review, and let the scraper
pull `card_products` straight from the issuer's own pages.

---

## Public sector banks

### State Bank of India (SBI Card)
25+ mainstream cards; aggregators cite 65+ counting co-branded variants.
- SBI Card ELITE, SBI Card PRIME
- SimplySave, SimplyClick
- Cashback SBI Card
- BPCL SBI Card Octane
- Air India SBI Signature
- IRCTC SBI Card
- Numerous co-branded variants issued jointly with regional/PSU banks (see
  "co-branded via SBI Card" note under each of those banks below)

### Bank of Baroda (via BOBCARD Ltd.)
- BOBCARD Eterna
- BOBCARD Premier
- BOBCARD IRCTC
- BOBCARD Snapdeal (co-brand)
- BOBCARD Defence Personnel Card
- BOBCARD Corporate

### Punjab National Bank
- PNB RuPay Platinum
- PNB RuPay Millennial
- PNB RuPay Select
- PNB SALARY RuPay Select
- PNB LUXURA RuPay Metal
- PNB Kiwi Credit Card (fintech co-brand, lifetime-free)
- PNB Patanjali RuPay Select (co-brand)
- PNB EMT RuPay Platinum (EaseMyTrip co-brand)

### Canara Bank
- Canara Visa Classic / MasterCard Standard Global
- Canara Visa Platinum
- Canara RuPay Platinum
- Canara MasterCard World
- Canara Visa Signature Travel
- Canara Visa Signature Business
- Canara RuPay Select
- Canara Select Platinum
- Canara Travel Card

### Union Bank of India
- Union Bank RuPay Select
- Union Bank RuPay Platinum
- Visa Signature / Visa Gold / Visa Platinum
- Divaā Credit Card (women-focused)
- Union JCB Wellness Card
- PM SVANidhi RuPay Credit Card (street vendors)

### Bank of India
- BOI RuPay Select
- BOI Celestia RuPay Ekaa
- BOI Navy Classic (Indian Navy personnel)
- BOI Visa Platinum International
- BOI RuPay Swadhan Platinum

### Indian Bank
- Indian Bank Bharat Credit Card (own-issued, free, low limit)
- Otherwise reported to lean on co-branded SBI Card partnership products (not
  independently confirmed in this pass)

### Central Bank of India
- Central Bank of India Prime Card (co-branded with SBI Card)
- Central Bank of India Aspire Credit Card (FD-backed, against Cent Aspire
  term deposit)

### Indian Overseas Bank
- IOB Gold (Visa)
- IOB Classic (Visa)
- IOB RuPay Classic
- IOB RuPay Select

### UCO Bank
- UCO Bank credit cards issued in partnership with SBI Card; aggregators
  cite ~3 variants, plus sector-specific cards for artisans, fishermen,
  handloom weavers, auto-rickshaw owners, and SHGs. Exact current retail
  variant names weren't resolved in this pass — check uco.bank.in directly.

### Punjab & Sind Bank
- PSB SBI Card ELITE (co-brand)
- PSB SBI Card PRIME (co-brand)
- PSB SimplySAVE SBI Card (co-brand)
- RuPay Kisan Credit Card (farmer-focused, distinct product line)

---

## Private sector banks

### HDFC Bank
~30+ cards.
- Infinia (invite-only, top-tier)
- Diners Club Black
- Regalia Gold, Regalia First
- Diners Club Privilege, Diners Club Miles
- Millennia, MoneyBack+, Freedom
- Pixel Go, Pixel Play
- Tata Neu Infinity, Tata Neu Plus (co-brand)
- Shoppers Stop, Shoppers Stop Black (co-brand)
- Paytm HDFC Bank Credit Card (co-brand, multiple variants)

### ICICI Bank
~15+ cards.
- Emeralde Private Metal, Emeralde
- Sapphiro, Rubyx, Coral, Platinum
- Amazon Pay ICICI Bank Credit Card
- HPCL Super Saver
- Chennai Super Kings ICICI Bank Credit Card
- Emirates Skywards ICICI Bank (variants)
- InterMiles ICICI Bank (variants)
- Parakram (variants)

### Axis Bank
~18 cards. (Includes the ex-Citibank lineup — see Citibank note below.)
- Magnus (super-premium), Reserve
- ACE (flat-rate cashback), MyZone, Rewards
- Neo (RuPay, lifetime-free)
- LIC Platinum, LIC Signature (lifetime-free)
- Flipkart Axis Bank Credit Card
- Samsung Axis Bank Signature Credit Card
- Vistara Axis Bank, SpiceJet Axis Bank (co-brands)
- Axis Bank REWARDS (ex-Citi Rewards, post-migration)
- Axis Horizon (ex-Citi PremierMiles, post-migration)
- Axis Cashback (ex-Citi Cashback, post-migration)
- INDIANOIL AXIS BANK PREMIUM (ex-IndianOil Citi, post-migration)

### Kotak Mahindra Bank
- White Reserve, Royale Signature, Zen Signature
- Kotak 811 (entry-level)
- Myntra Kotak Credit Card
- IndiGo Kotak 6E Rewards XL, IndiGo Kotak 6E Rewards
- IndianOil Kotak Credit Card

### IndusInd Bank
~20 cards. (Also acquired Deutsche Bank's India credit card book — see
Deutsche Bank note below.)
- Pinnacle World, Pioneer Heritage, Pioneer Legacy
- Celesta, Crest, Indulge
- Legend (lifetime-free)
- Avios Visa Infinite (Qatar Airways / British Airways)
- Club Vistara IndusInd Bank Explorer
- Iconia Visa, Iconia Amex
- Signature Visa
- Platinum Aura Edge, Platinum Select, Platinum
- EazyDiner IndusInd Bank Credit Card
- Duo Plus
- Intermiles Voyage Visa
- Payback, Nexxt

### Yes Bank
- Yes Private, Yes Private Prime
- Marquee
- YES Premia
- YES First Preferred, YES First Exclusive
- Wellness, Wellness Plus
- Klick RuPay (with Kiwi, lifetime-free, fully digital)
- BYOC (Build Your Own Card)
- EMI Credit Card

### IDFC FIRST Bank
~13 cards.
- FIRST Private (top tier)
- Gaj (invite-only, ₹12,500)
- Mayura (₹5,999), Ashva (₹2,999)
- Wealth, Select, Classic, Millennia, Click (lifetime-free)
- Power+ / HPCL Power (fuel)
- SWYP (youth-focused)
- LIC Classic, LIC Select (co-branded)
- WOW!, WOW! Black (FD-backed)
- EARN (FD-backed)

### RBL Bank
40+ cards including fintech co-brands.
- Platinum Maxima, Platinum Delight, Titanium Delight
- IndianOil RBL Bank Credit Card (co-brand)
- Zomato, Practo, TVS Credit (co-brands)
- (Bajaj Finserv RBL Bank SuperCard co-brand ended per 2024/2025 exit —
  see Bajaj Finserv note below)
- Numerous additional fintech co-branded programs

### Federal Bank
4 cards.
- Federal Celesta
- Federal Scapia
- Federal Signet
- Federal Visa Signature
- (Federal Bank Imperio also referenced by some aggregators)

### South Indian Bank
- South Indian Bank OneCard (fintech co-brand, lifetime-free)
- Co-branded SBI Card variants
- RuPay credit cards (UPI-linked)

### IDBI Bank
- Royale Signature (lifetime-free)
- Aspire Platinum (lifetime-free)
- Euphoria World
- Imperium Platinum (FD-backed/secured, Visa)
- Winnings

### Bandhan Bank
- One (₹299 annual fee)
- Plus (₹699 annual fee)
- Xclusive (₹2,999 annual fee)
- (Standard Chartered Bandhan Bank co-branded cards existed but are no
  longer accepting new applications)

### CSB Bank
- Edge+ CSB Bank RuPay Credit Card (with Jupiter)
- Edge CSB Bank RuPay Credit Card (with Jupiter)

### DCB Bank
All secured/FD-backed.
- DCB PayLess
- DCB Niyo
- DCB Novio (RuPay, FD-backed)

### Tamilnad Mercantile Bank (TMB)
- TMB Wings RuPay Credit Card
- TMB Phoenix RuPay Credit Card (business)
- TMB Platinum
- TMB Titanium
- TMB General Credit Card
- TMB India Card Credit Card

### Karnataka Bank
- Karnataka Bank SimplySAVE SBI Card (co-brand)
- Karnataka Bank SBI Card Prime / Platinum SBI Card (co-brand)

### City Union Bank
- City Union Bank SBI SimplySave (co-brand)
- City Union Bank SBI Prime Card (co-brand)
- Dhi CUB Visa Signature, Platinum, Master, RuPay
- CUB SalarySe Level Up Credit Card

---

## Small finance banks

### AU Small Finance Bank
7 cards.
- Zenith+ (₹4,999), Vetta (₹2,999)
- Altura Plus (₹499), Altura (₹199)
- ixigo (lifetime-free, travel co-brand)
- LIT (lifetime-free, customizable feature packs)
- Spont (invite-only)

### Equitas Small Finance Bank
- Selfe (digital-first)
- PowerMiles (premium travel)
- Tiga
- Excite (HDFC Bank co-brand)
- Elegance (HDFC Bank co-brand, higher limit tier)

### Ujjivan Small Finance Bank
- USFB Elite (BOBCARD co-brand)
- USFB Platinum (BOBCARD co-brand)
- Credit Card Against FD (secured)

---

## Foreign banks (India operations)

### American Express India
4 mainstream consumer cards + corporate variants.
- Platinum Charge (invite-only / highest tier)
- Gold Charge (no preset spending limit)
- Platinum Travel Credit Card
- Membership Rewards Credit Card
- Note: Amex India has periodically paused new consumer card applications.

### Standard Chartered
6 cards.
- Ultimate (₹5,000)
- Emirates World
- Manhattan Platinum (₹999)
- EaseMyTrip
- DigiSmart
- Platinum Rewards (lifetime-free)

### HSBC
5 mainstream cards + 1 invite-only.
- TravelOne (₹4,999)
- Visa Platinum (lifetime-free)
- RuPay Platinum (lifetime-free)
- RuPay Cashback (lifetime-free)
- Live+ (₹999, upgraded to Visa Infinite mid-2026)
- Premier Metal (₹20,000, invite-only, Premier banking tier)
- Taj co-branded card (luxury-hotel specialist, sits outside the main lineup)

### DBS Bank
- DBS Vantage (premium/travel)
- DBS Spark (Spark5 / Spark10 / Spark20 variants)
- DBS SuperX / DBS SuperX Plus (successor cards for migrated Bajaj Finserv
  DBS SuperCard holders — see Bajaj Finserv note below)

### Deutsche Bank
No longer an active issuer — its India credit card business was sold to
IndusInd Bank. Historical lineup (pre-sale) included Classic, Gold,
Platinum, Landmark, Miles & More, and Corporate cards; these are legacy
only and should not be treated as currently issued.

### Citibank
No longer issues cards directly in India — its full consumer credit card
book (9 legacy Citi cards) migrated to Axis Bank as of 15 July 2024, mapped
onto 7 new Axis variants (see Axis Bank section above: REWARDS, Horizon,
Cashback, INDIANOIL AXIS BANK PREMIUM, plus others). Don't list "Citibank"
as a live issuer in the catalog — attribute those cards to Axis Bank.

---

## NBFCs / fintech co-branded issuers

### SBI Card
Standalone NBFC, majority SBI-owned — see State Bank of India section above
for its own-brand catalog; also the co-branding partner behind many PSU/
regional bank cards listed elsewhere in this doc.

### OneCard (FPL Technologies)
- OneCard Metal (unsecured, plastic/metal card)
- OneCard Lite (FD-backed, via SBM Bank India; also branded "South Indian
  Bank OneCard" and similar bank-specific co-brands)

### Slice
- Slice Super Card / Slice UPI Credit Card (RuPay, lifetime-free, issued via
  Slice Small Finance Bank following its bank license/merger)

### Bajaj Finserv (co-branded — winding down)
Bajaj Finance exited the co-branded credit card space (RBI direction
restricting co-brand partners to sourcing-only roles):
- Bajaj Finserv RBL Bank SuperCard / Platinum Plus SuperCard — partnership
  ended
- Bajaj Finserv DBS Bank SuperCard — discontinued for new issuance since
  23 Nov 2024; existing holders migrated to DBS SuperX / SuperX Plus,
  effective 1 Aug 2026

### LazyPay / PayU
- LazyCard — credit line-backed card issued via SBM Bank India, with an
  FD-backed "Booster" variant

---

## Confidence notes / known gaps

- Several PSU banks (Indian Bank, UCO Bank especially) did not yield clear,
  current standalone product names in this pass — likely because their
  retail credit card offering leans heavily on co-branded SBI Card products
  rather than bank-specific branding. Needs direct confirmation from the
  issuer's own site.
- Counts cited (e.g. "18 cards", "40+ cards") are as reported by
  aggregators at search time, not independently verified or recounted.
- Co-brand and partnership status changes fast (Bajaj Finserv/RBL/DBS,
  Standard Chartered/Bandhan, Citi/Axis) — anything here should be treated
  as a snapshot, not current truth, by the time it's read.
