# SMS golden report

Engine: `server: parseSmsAgainstPatterns`

Cases: 82 (16 fully passed), scenarios: 15 (not evaluated, a stage is not available), messages: 82, weight: 82.0

Stages: interpreter=available, instruments=not_available, linker=not_available, projector=not_available, categories=not_available

## Metrics

| Metric | Value | n | Gate | Result |
| --- | --- | --- | --- | --- |
| captureRecall | 62.16% | 74 |  |  |
| ignorePrecision | 22.22% | 36 |  |  |
| eventKind | 20.95% | 74 |  |  |
| amountRole | 63.64% | 66 |  |  |
| instrument | 46.21% | 66 |  |  |
| doubleCounts | not_available |  |  |  |
| pairsLinked | not_available |  |  |  |
| category | not_available |  |  |  |
| askRate | 0.00% | 74 |  |  |
| scenarioTotals | not_available |  |  |  |
| eventKindByAmount | 14.89% | 450204.5 |  |  |
| amountRoleByAmount | 88.28% | 450204.5 |  |  |
| instrumentByAmount | 67.76% | 445705.5 |  |  |
| scenarioEvents | not_available |  |  |  |
| scenarioInstruments | not_available |  |  |  |

## By family

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| debit | 11 | 11 | 90.91% | 45.45% | 90.91% | 54.55% | 0.00% |
| mandate_autopay | 8 | 8 | 25.00% | 18.75% | 25.00% | 10.00% | 0.00% |
| reward_points | 8 | 8 | 60.00% | 10.00% | 40.00% | 50.00% | 0.00% |
| refund_reversal | 7 | 7 | 71.43% | 0.00% | 100.00% | 83.33% | 0.00% |
| card_payment | 6 | 6 | 100.00% | 0.00% | 100.00% | 40.00% | 0.00% |
| card_spend | 6 | 6 | 100.00% | 80.00% | 80.00% | 90.00% | 0.00% |
| credit | 6 | 6 | 66.67% | 0.00% | 100.00% | 40.00% | 0.00% |
| ipo_asba_hold | 5 | 5 | 40.00% | 10.00% | 40.00% | 20.00% | 0.00% |
| wallet | 5 | 5 | 60.00% | 30.00% | 50.00% | 50.00% | 0.00% |
| bill_statement | 3 | 3 | 33.33% | 0.00% | 0.00% | 0.00% | 0.00% |
| failed_declined | 3 | 3 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| investment | 3 | 3 | 66.67% | 66.67% | 100.00% | 100.00% | 0.00% |
| salary_income | 3 | 3 | 100.00% | 16.67% | 100.00% | 100.00% | 0.00% |
| balance | 2 | 2 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| limit | 2 | 2 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| other | 2 | 2 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| otp_security | 2 | 2 | no_data | no_data | no_data | no_data | no_data |

## By brand

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HDFCBK | 56 | 56 | 62.00% | 18.00% | 67.44% | 53.41% | 0.00% |
| ICICIT | 7 | 7 | 85.71% | 35.71% | 57.14% | 28.57% | 0.00% |
| AXISBK | 4 | 4 | 75.00% | 25.00% | 75.00% | 25.00% | 0.00% |
| AMAZON | 2 | 2 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| AMEXIN | 1 | 1 | 100.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| CANBNK | 1 | 1 | 100.00% | 0.00% | 100.00% | 100.00% | 0.00% |
| ICICIB | 1 | 1 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| IPAYTM | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| KOTAKB | 1 | 1 | 100.00% | 100.00% | 100.00% | 0.00% | 0.00% |
| KOTAKN | 1 | 1 | 0.00% | 0.00% | no_data | no_data | 0.00% |
| PYTM | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| SBIBNK | 1 | 1 | 100.00% | 0.00% | 100.00% | 100.00% | 0.00% |
| SBICRD | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| SBIINB | 1 | 1 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| TNBPAY | 1 | 1 | 0.00% | 0.00% | 0.00% | no_data | 0.00% |
| VICARE | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| ZOMATO | 1 | 1 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |

## Failures (66)

- case `probe:amazon_pay_balance_spend`: financial message was ignored; kind: no movement fact produced; amount: no movement fact produced
- case `probe:amazon_pay_cashback`: financial message was ignored; kind: no movement fact produced; amount: no movement fact produced
- case `probe:cc_payment_amex`: kind: attrs.direction: expected credit, got null; instrument: instrument.maskDigits: expected 10005, got 2026
- case `probe:cc_payment_axis`: kind: attrs.direction: expected credit, got null
- case `probe:axis_multiline`: instrument: instrument.maskDigits: expected 123456, got null
- case `corpus:card_bill_payment`: kind: attrs.direction: expected debit, got null; instrument: instrument: expected an object, got null
- case `corpus:card_statement`: financial message was ignored; kind: no bill_due fact produced; amount: no bill_due fact produced
- case `corpus:ambiguous_suffix_two_banks_second`: kind: attrs.direction: expected credit, got null
- case `corpus:autopay_failed`: financial message was ignored; kind: no attempt fact produced
- case `probe:cc_bill_bank_side`: kind: attrs.direction: expected debit, got null; instrument: instrument.kind: expected bank_account, got credit_card
- case `local:21`: financial message was ignored; kind: no attempt fact produced; instrument: no attempt fact produced
- case `probe:upcoming_autopay`: financial message was ignored; kind: no attempt fact produced; amount: no attempt fact produced
- case `corpus:refund_with_offer`: kind: attrs.direction: expected credit, got null
- case `probe:ipo_asba_block`: financial message was ignored; kind: no hold fact produced; amount: no hold fact produced
- case `local:04`: kind: attrs.purpose: expected salary, got null
- case `corpus:salary_income`: kind: attrs.purpose: expected salary, got null
- case `local:18`: financial message was ignored; kind: no attempt fact produced; instrument: no attempt fact produced
- case `probe:spend_avl_lmt_hdfc`: kind: no balance_snapshot fact produced; amount: no balance_snapshot fact produced; instrument: no balance_snapshot fact produced
- case `corpus:atm_withdrawal`: kind: attrs.direction: expected debit, got null
- case `probe:salary_neft`: kind: attrs.purpose: expected salary, got null
- case `probe:limit_enhanced`: financial message was ignored; kind: no limit_change fact produced; amount: no limit_change fact produced
- case `probe:self_transfer_imps`: kind: attrs.direction: expected debit, got null
- case `corpus:send_debit_with_balance`: instrument: instrument.maskDigits: expected 1234, got null; instrument: instrument.maskDigits: expected 1234, got null
- case `local:19`: financial message was ignored; kind: no attempt fact produced; instrument: no attempt fact produced
- case `local:10`: financial message was ignored; kind: no bill_due fact produced; amount: no bill_due fact produced
- case `probe:ipo_allotment_debit`: kind: attrs.purpose: expected investment, got purchase
- case `probe:mandate_registered`: financial message was ignored; kind: no mandate fact produced; amount: no mandate fact produced
- case `probe:reward_points_redeemed`: kind: no reward fact produced; amount: no reward fact produced; instrument: no reward fact produced
- case `local:12`: financial message was ignored; kind: no balance_snapshot fact produced; amount: no balance_snapshot fact produced
- case `local:09`: kind: attrs.direction: expected credit, got null
- case `corpus:autopay_mandate`: financial message was ignored; kind: no mandate fact produced; amount: no mandate fact produced
- case `probe:netflix_upi_autopay_debit`: instrument: instrument.maskDigits: expected 1234, got null; instrument: instrument.maskDigits: expected 1234, got null
- case `local:00`: kind: no balance_snapshot fact produced; amount: no balance_snapshot fact produced
- case `probe:cheque_cleared`: financial message was ignored; kind: no movement fact produced; amount: no movement fact produced
- case `local:20`: financial message was ignored; kind: no attempt fact produced; instrument: no attempt fact produced
- case `corpus:autopay_scheduled`: financial message was ignored; kind: no attempt fact produced; amount: no attempt fact produced
- case `corpus:outstanding_reminder`: financial message was ignored; kind: no bill_due fact produced; amount: no bill_due fact produced
- case `local:16`: kind: attrs.direction: expected credit, got null
- case `probe:cashback_on_card`: kind: attrs.direction: expected credit, got null
- case `local:14`: kind: attrs.direction: expected credit, got null
- case `local:17`: kind: attrs.direction: expected credit, got null
- case `local:22`: financial message was ignored; kind: no attempt fact produced
- case `corpus:ambiguous_suffix_two_banks`: kind: attrs.purpose: expected transfer, got purchase
- case `local:05`: kind: attrs.direction: expected debit, got null
- case `corpus:reversed_credit`: kind: attrs.direction: expected credit, got null
- case `local:13`: kind: attrs.direction: expected credit, got null
- case `probe:ipo_unblock`: financial message was ignored; kind: no hold fact produced; amount: no hold fact produced
- case `probe:refund_on_card`: kind: attrs.direction: expected credit, got null
- case `probe:cc_bill_card_side`: kind: attrs.direction: expected credit, got null
- case `corpus:mandate_cancelled`: financial message was ignored; kind: no mandate fact produced; instrument: no mandate fact produced
- case `probe:paytm_wallet_load_bank`: kind: attrs.purpose: expected wallet_topup, got purchase; instrument: instrument.maskDigits: expected 1234, got null
- case `local:15`: kind: attrs.direction: expected credit, got null
- case `local:08`: financial message was ignored; kind: no attempt fact produced; amount: no attempt fact produced
- case `corpus:declined_attempt`: financial message was ignored; kind: no attempt fact produced; amount: no attempt fact produced
- case `probe:spend_avl_limit_icici`: kind: no balance_snapshot fact produced; amount: no balance_snapshot fact produced; instrument: no balance_snapshot fact produced
- case `probe:ipo_mandate_executed`: kind: attrs.purpose: expected investment, got purchase; instrument: instrument.maskDigits: expected 1234, got null
- case `probe:reward_points_earned`: kind: no reward fact produced; amount: no reward fact produced; instrument: no reward fact produced
- case `probe:ipo_upi_mandate_block`: financial message was ignored; kind: no hold fact produced; amount: no hold fact produced
- case `probe:spotify_card_si`: kind: no balance_snapshot fact produced; amount: no balance_snapshot fact produced; instrument: no balance_snapshot fact produced
- case `probe:cc_bill_via_cred`: kind: attrs.direction: expected debit, got null; instrument: instrument.maskDigits: expected 1234, got null
- case `probe:kotak_sent`: instrument: instrument.maskDigits: expected 1234, got null
- case `corpus:kotak_settlement`: financial message was ignored; kind: no attempt fact produced
- case `probe:sbi_upi_p2p`: kind: attrs.purpose: expected p2p, got purchase
- case `corpus:balance_only`: financial message was ignored; kind: no balance_snapshot fact produced; amount: no balance_snapshot fact produced
- case `corpus:bill_with_offer`: financial message was ignored; kind: no bill_due fact produced; amount: no bill_due fact produced
- case `probe:zomato_money_spend`: financial message was ignored; kind: no movement fact produced; amount: no movement fact produced
