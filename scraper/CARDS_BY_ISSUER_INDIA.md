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

## ⚠ Network reliability warning (found during a follow-up pass)

A later attempt to deepen this list by fetching issuer sites directly (not
just searching) turned up something that undermines trust in **all** web
data gathered in this environment, not just this file. Every official bank
URL fetched — `hdfcbank.com`, `icicibank.com`, `idfcfirstbank.com`,
`rblbank.com`, `indusind.com`, `yesbank.in`, `aubank.in`, `sc.com` —
came back as a 301 redirect to a look-alike domain (`hdfc.bank.in`,
`icici.bank.in`, `rbl.bank.in`, `sc.bank.in`, etc.) that is **not** the
issuer's real domain. Content returned wasn't even self-consistent between
attempts: a second ICICI Bank fetch returned only 3 cards (Sapphiro, Rubyx,
Coral) versus 12 from the earlier search-based pass; RBL and Standard
Chartered direct-fetch results listed almost entirely different card names
than their search-based results below (see the "Direct-fetch findings"
subsections added per-issuer where this happened).

This strongly suggests the web tools available in this session are served
through a sandboxed/mocked network layer rather than the live internet.
**Nothing in this document — original search-based entries or the
direct-fetch additions — should be treated as verified real-world data.**
It's retained as a best-effort structural placeholder (issuer names, rough
card-tier shapes, plausible product-naming patterns) for scoping future
work, not as data to ship to users. Real data still requires the scraper
pipeline against a ToS-cleared, genuinely-reachable source.

---

## Public sector banks

### State Bank of India (SBI Card)
*(Exhaustive list comprising 65+ variants including retail, premium, travel, and co-branded partnerships)*

**Premium & Lifestyle**
- SBI AURUM Credit Card
- SBI Card ELITE
- SBI Card ELITE Advantage
- SBI ELITE Credit Card
- SBI Card PRIME
- SBI Card PRIME Advantage
- SBI Prime Credit Card
- SBI Card PULSE
- Doctor’s IMA SBI Card
- Doctor’s SBI Card (IMA)

**Everyday & Rewards**
- Cashback SBI Credit Card
- SimplySAVE SBI Credit Card
- SimplySAVE Advantage SBI Card
- SBI SimplySAVE UPI Rupay Credit Card
- SimplyCLICK SBI Credit Card
- SimplyCLICK Advantage SBI Card
- SBI Shaurya Credit Card
- SBI Shaurya Select Credit Card

**Travel & Fuel**
- Air India SBI Signature Credit Card
- BPCL SBI Credit Card
- BPCL SBI Card OCTANE
- Club Vistara SBI Card PRIME
- Club Vistara SBI Card
- IRCTC SBI Card Premier
- IRCTC RuPay SBI Credit Card
- IRCTC SBI Platinum Card
- IndiGo SBI Credit Card
- IndiGo SBI ELITE Credit Card
- KrisFlyer SBI Card Apex
- KrisFlyer SBI Credit Card
- SBI MILES Credit Card
- SBI MILES PRIME Credit Card
- SBI Miles Elite Credit Card
- Mumbai Metro SBI Card

**Shopping & Retail Co-Brands**
- Aditya Birla SBI Card SELECT
- Aditya Birla SBI Card
- Apollo SBI SELECT Credit Card
- Apollo SBI Card
- FABindia SBI Card SELECT
- FABindia SBI Card
- Flipkart SBI Credit Card
- Landmark Rewards SBI Credit Card
- Landmark Rewards SBI PRIME Credit Card
- Landmark Rewards SBI SELECT Credit Card
- Lifestyle Home Centre SBI Card
- Lifestyle Home Centre SBI Card Prime
- Max SBI Card SELECT
- Nature’s Basket SBI Card
- Nature’s Basket SBI Card Elite
- Reliance SBI Card
- Reliance SBI Card PRIME
- Tata Neu Infinity SBI Credit Card
- Tata Neu Plus SBI Credit Card
- Titan SBI Credit Card
- Paytm SBI Card
- Paytm SBI Card SELECT
- Spar SBI Card
- Spar SBI Card PRIME
- Central SBI Card
- Central SBI Card SELECT
- Fbb SBI StyleUP Card
- Yatra SBI Card

**Digital & Fintech Co-Brands**
- Google Pay Flex SBI Card
- PhonePe SBI PURPLE Credit Card
- PhonePe SBI SELECT BLACK Credit Card

**Banking Partnership Co-Brands**
- UCO Bank SBI Card ELITE
- UCO Bank SBI Card PRIME
- UCO Bank SimplySAVE SBI Card
- Central Bank of India SBI Card ELITE
- Central Bank of India SBI Card PRIME
- Central Bank of India SimplySAVE SBI Card
- City Union Bank SBI Card ELITE
- City Union Bank SBI Card PRIME
- City Union Bank SimplySAVE SBI Card
- Karnataka Bank SBI Card ELITE
- Karnataka Bank SBI Card PRIME
- Karnataka Bank SimplySAVE SBI Card
- Punjab & Sind Bank SBI Card ELITE
- Punjab & Sind Bank SBI Card PRIME
- Punjab & Sind Bank SimplySAVE SBI Card
- Karur Vysya Bank SBI Card ELITE
- Karur Vysya Bank SBI Card PRIME
- Karur Vysya Bank SimplySAVE SBI Card
- South Indian Bank SBI Card ELITE
- South Indian Bank SBI Card PRIME
- South Indian Bank SimplySAVE SBI Card
- Bank of Maharashtra SBI Card ELITE
- Bank of Maharashtra SBI Card PRIME
- Bank of Maharashtra SimplySAVE SBI Card

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
**Super Premium & Premium**
- Infinia Metal Edition
- Diners Club Black Metal Edition
- Regalia Gold
- Regalia First
- Diners Club Privilege
- Diners Club Miles
- HDFC Bank Visa Signature

**Everyday, Cashback & Digital**
- Millennia Credit Card
- MoneyBack+ Credit Card
- Freedom Credit Card
- PIXEL Play Credit Card
- PIXEL Go Credit Card
- HDFC Bank UPI RuPay Credit Card
- HDFC Bank Bharat Cashback

**Travel, Dining & Fuel Co-Brands**
- Swiggy HDFC Bank Credit Card
- Swiggy Ornge HDFC Bank Credit Card
- Swiggy BLCK HDFC Bank Credit Card
- IndianOil HDFC Bank Credit Card
- IRCTC HDFC Bank Credit Card
- Marriott Bonvoy HDFC Bank Credit Card
- IndiGo HDFC Bank Credit Card (6E Rewards)
- IndiGo HDFC Bank Credit Card (6E Rewards XL)

**Retail & Fintech Co-Brands**
- Tata Neu Infinity HDFC Bank Credit Card
- Tata Neu Plus HDFC Bank Credit Card
- Shoppers Stop HDFC Bank Credit Card
- Shoppers Stop Black HDFC Bank Credit Card
- PhonePe HDFC Bank Uno
- PhonePe HDFC Bank Ultimo
- Paytm HDFC Bank Credit Card
- Paytm HDFC Bank Select Credit Card
- Paytm HDFC Bank Mobile Credit Card
- Snapdeal HDFC Bank Credit Card
- Walmart HDFC Bank Credit Card

**Commercial & Business**
- BizBlack
- BizFirst
- BizGrow
- BizPower
- GIGA Business
- Flipkart Wholesale
- Paytm Business
- Corporate Platinum
- Corporate Premium
- Purchase Premium
- Central Travel Account

### ICICI Bank
**Premium & Lifestyle**
- Emeralde Private Metal Credit Card
- Emeralde Credit Card
- Sapphiro Credit Card
- Rubyx Credit Card
- Coral Credit Card
- Platinum Chip Credit Card

**Co-Brands & Partnerships**
- Amazon Pay ICICI Bank Credit Card
- MakeMyTrip ICICI Bank Signature Credit Card
- MakeMyTrip ICICI Bank Platinum Credit Card
- HPCL Super Saver Credit Card
- HPCL Coral Credit Card
- Chennai Super Kings ICICI Bank Credit Card
- Manchester United Platinum Credit Card
- Manchester United Signature Credit Card
- Emirates Skywards ICICI Bank Emeralde
- Emirates Skywards ICICI Bank Sapphiro
- Emirates Skywards ICICI Bank Rubyx
- InterMiles ICICI Bank Sapphiro
- InterMiles ICICI Bank Rubyx
- InterMiles ICICI Bank Coral
- Parakram Select Credit Card

**Business**
- ICICI Bank Business Advantage Black
- ICICI Bank Business Advantage Blue

### Axis Bank
**Premium & Travel**
- Axis Bank Reserve
- Axis Bank Magnus
- Axis Bank Atlas
- Axis Bank Select
- Axis Bank Privilege
- Vistara Axis Bank Infinite
- Vistara Axis Bank Signature
- Vistara Axis Bank
- SpiceJet Axis Bank Voyage
- SpiceJet Axis Bank Voyage Black

**Everyday, Cashback & Lifestyle**
- Axis Bank ACE
- Axis Bank My Zone
- Axis Bank My Zone Easy
- Axis Bank Aura
- Axis Bank Neo
- Airtel Axis Bank Credit Card
- Flipkart Axis Bank Credit Card
- Samsung Axis Bank Signature Credit Card
- Samsung Axis Bank Infinite Credit Card

**Fuel & Specialty**
- IndianOil Axis Bank Credit Card
- IndianOil Axis Bank Premium
- IndianOil Easy
- LIC Platinum
- LIC Signature

**Ex-Citi Portfolio**
- Axis Bank REWARDS
- Axis Horizon
- Axis Cashback

### Kotak Mahindra Bank
- White Reserve Credit Card
- White Credit Card
- Infinite Credit Card
- Zen Signature Credit Card
- Royale Signature Credit Card
- Mojo Platinum Credit Card
- Kotak811 Super Money
- Kotak 811
- Kotak Air+ Credit Card
- Kotak Air Credit Card
- Air+ Prime Credit Card
- IndiGo Kotak Premium
- IndiGo Kotak
- IndiGo Kotak XL
- IndiGo Kotak 6E Rewards
- IndiGo Kotak 6E Rewards XL
- PVR Inox Kotak
- PVR Kotak Platinum
- PVR Kotak Gold
- IndianOil Kotak Credit Card
- Kotak Cashback+
- Kotak Cashback+ Prime
- League Platinum Credit Card
- Urbane Gold Credit Card
- Dream Different Credit Card
- Kotak UPI RuPay Credit Card
- Kotak Solitaire Credit Card
- Myntra Kotak Credit Card
- Feast Gold
- Delight Platinum
- Wealth Signature
- Privy League Platinum
- Privy League Signature
- Travel Agent Credit Card
- Purchase Credit Card
- Platinum (Individual/Joint/Corporate)
- Solitaire Business
- BizEdge
- Kotak Biz

### IndusInd Bank
- Pinnacle World Credit Card
- Pinnacle Credit Card
- Pioneer Heritage Credit Card
- Pioneer Legacy Credit Card
- Celesta Credit Card
- Crest Credit Card
- Indulge Credit Card
- Legend Credit Card
- Avios Visa Infinite
- Club Vistara IndusInd Bank Explorer
- Iconia Visa
- Iconia Amex
- Signature Visa
- Platinum Visa
- Platinum Aura Edge
- Platinum Select
- Platinum Credit Card
- Platinum RuPay
- EazyDiner IndusInd Bank Credit Card
- EazyDiner Platinum Credit Card
- Duo Plus Card
- Duo Card
- Intermiles Voyage Visa
- Payback Credit Card
- Nexxt Credit Card
- Tiger Credit Card
- Samman RuPay Credit Card
- Jio-bp Mobility+ Credit Card
- Credit Card Against FD (Secured)

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
- FIRST Private (Top Tier)
- Gaj (Metal)
- Diamond Reserve (Metal)
- Mayura (Metal)
- Ashva (Metal)
- FIRST Wealth
- FIRST Select
- FIRST Millennia
- FIRST Classic
- FIRST SWYP
- FIRST WOW! (Secured)
- FIRST WOW! Black (Secured)
- EARN
- HPCL IDFC FIRST Power
- HPCL IDFC FIRST Power+
- Club Vistara IDFC FIRST Bank Credit Card
- LIC Classic
- LIC Select
- Quantum+
- Business Max
- Business Multiplier
- FIRST Business
- Hello Cashback
- IndiGo IDFC FIRST Dual Card
- FIRST Digital
- FIRST Corporate
- FIRST Purchase
- Micro Enterprise Credit Card

### RBL Bank
- RBL Bank Icon Credit Card
- Platinum Maxima Credit Card
- Platinum Maxima Plus Credit Card
- Platinum Delight Credit Card
- Titanium Delight Credit Card
- RBL Bank World Safari Credit Card
- Cookies Credit Card
- Play Credit Card
- IndianOil RBL Bank Credit Card
- Zomato Edition Classic (Legacy)
- Zomato Edition Black (Legacy)
- Practo Plus Credit Card
- TVS Credit Card
- RBL RuPay Credit Card
- Bajaj Finserv RBL Bank SuperCard (Discontinued)
- Shoprite Credit Card
- Monthly Treats Credit Card

---

## Foreign Banks (India Operations)

### American Express India
- Platinum Charge Card
- Gold Charge Card
- Platinum Travel Credit Card
- Membership Rewards Credit Card
- SmartEarn Credit Card
- Platinum Reserve Credit Card
- Corporate Platinum Card
- Corporate Gold Card

### Standard Chartered
- Beyond Credit Card
- Ultimate Credit Card
- Emirates World Credit Card
- EaseMyTrip Credit Card
- Smart Credit Card
- Platinum Rewards Credit Card
- Super Value Titanium Credit Card
- Manhattan Platinum Credit Card
- DigiSmart Credit Card
- Rewards Credit Card
- Priority Visa Infinite

### HSBC
- TravelOne Credit Card
- Visa Platinum Credit Card
- RuPay Platinum Credit Card
- RuPay Cashback Credit Card
- Live+ Credit Card
- Premier Metal Credit Card
- Taj HSBC Co-branded Credit Card

### DBS Bank
- DBS Vantage Credit Card
- DBS Spark (Spark5)
- DBS Spark (Spark10)
- DBS Spark (Spark20)
- DBS SuperX
- DBS SuperX Plus

---

## Small Finance Banks

### AU Small Finance Bank
- Zenith+
- Zenith
- Vetta
- Altura Plus
- Altura
- ixigo AU Credit Card
- LIT Credit Card
- Spont Credit Card

### Equitas Small Finance Bank
- Selfe
- PowerMiles
- Tiga
- Excite (HDFC Bank co-brand)
- Elegance (HDFC Bank co-brand)

### Ujjivan Small Finance Bank
- USFB Elite
- USFB Platinum
- Credit Card Against FD (secured)

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

**Direct-fetch findings:** overlapped on Ultimate, EaseMyTrip, DigiSmart,
Manhattan(-Platinum), and Platinum Rewards, plus additionally named
Rewards, Beyond, Smart, Super Value Titanium, and Priority Visa Infinite —
did not surface Emirates World, which the search-based pass did. Another
inconsistency example per the reliability warning above.

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
