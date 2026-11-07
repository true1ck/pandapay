# Published to production on 7 Nov 2026

The owner asked for the ready cards to be published. 34 drafts passed the completeness checks in REVIEW.md. A further screen held back 5 whose key facts rest on inference or conflict, so **29 were published**. No person has read these documents card by card; the verified stamp on each carries the owner admin id because the publish step sets it.

Run: dry run (29 would publish, 0 failed), then the real run (29 published, 0 failed). Public feed went from 376 to 405 cards; the 33 other drafts stay hidden. Feed fields and null patterns match the older cards, and the only new database values are free-text variant labels and one unused network tier.

## Published (29)

| Card | Slug |
|---|---|
| Scapia Axis Bank Credit Card | `axis-bank-scapia-credit-card` |
| Bandhan Bank Flare Credit Card | `bandhan-flare` |
| Bandhan Bank Lumina Credit Card | `bandhan-lumina` |
| BOBCARD Scapia Credit Card | `bobcard-scapia-credit-card` |
| CheQ AU Credit Card | `cheq-au-credit-card` |
| Eternal SBI Card | `eternal-sbi-card` |
| Scapia Federal Bank Credit Card | `federal-bank-scapia-credit-card` |
| Google Pay Flex Axis Bank Credit Card | `google-pay-flex-axis-bank` |
| IOB RuPay Platinum Credit Card | `indian-overseas-bank-rupay-platinum` |
| IOB RuPay Select Credit Card | `indian-overseas-bank-rupay-select` |
| CRED IndusInd Bank RuPay Credit Card | `indusind-bank-cred-rupay` |
| Paytm AU Credit Card | `paytm-au-credit-card` |
| RBL Bank IndianOil XTRA Credit Card | `rbl-bank-indianoil-xtra` |
| RBL Bank IRCTC Credit Card | `rbl-bank-irctc` |
| RBL Bank Paisabazaar Duet Plus Credit Card | `rbl-bank-paisabazaar-duet-plus` |
| RBL Bank SalarySe UP Credit Card | `rbl-bank-salaryse-up` |
| RBL Bank Shoppers Stop Black Credit Card | `rbl-bank-shoppers-stop-black` |
| RBL Bank Shoppers Stop Gold Credit Card | `rbl-bank-shoppers-stop-gold` |
| RBL Bank Shoppers Stop Platinum Credit Card | `rbl-bank-shoppers-stop-platinum` |
| RBL Bank World Safari Plus Credit Card | `rbl-bank-world-safari-plus` |
| SBM Kredit.Pe Credit Card | `sbm-kredit-pe` |
| SBM MobiKwik First Credit Card | `sbm-mobikwik-first` |
| SBM Niyo Global Credit Card | `sbm-niyo-global` |
| SBM Paisabazaar Paisa Plus Credit Card | `sbm-paisabazaar-paisa-plus` |
| SBM Paisabazaar Step Up Credit Card | `sbm-paisabazaar-step-up` |
| slice UPI Credit Card | `slice-small-finance-bank-upi-credit-card` |
| Stable Money Suryoday RuPay Platinum Credit Card | `stable-money-suryoday-rupay-platinum` |
| Stable Money Suryoday RuPay Select Credit Card | `suryoday-stable-money-rupay-select` |
| YES BANK Paisabazaar PaisaSave RuPay Credit Card | `yes-bank-paisasave-rupay` |

## Ready on the checks but held back (5)

| Card | Why |
|---|---|
| AU Ananta Credit Card | no network in any issuer document (DB has none stored) |
| Times Black ICICI Bank Credit Card | core reward unit (2 and 2.5 points per Rs100) is inferred |
| Kwik Axis Bank Credit Card | point value comes from a conversion example, not a Kwik rate |
| Jupiter Edge+ CSB Bank RuPay Credit Card | earn rule is UPI-on-Jupiter-app only, page headline says otherwise |
| Axis Bank super.money RuPay Credit Card | in-force T&C version uncertain (effective dates conflict) |

To take a published card down, set its status back to draft through the admin card status endpoint; each change is audited.
