# SMS golden report

Engine: `rule engine 2.2.0 + rules/sms/v2 (complete pipeline)`

Cases: 254 (254 fully passed), scenarios: 33 (33 fully passed), messages: 254, weight: 254.0

Stages: interpreter=available, instruments=available, linker=available, projector=available, categories=available

## Metrics

| Metric | Value | n | Gate | Result |
| --- | --- | --- | --- | --- |
| captureRecall | 100.00% | 221 | >= 0.99 | pass |
| ignorePrecision | 100.00% | 33 | >= 0.995 | pass |
| eventKind | 100.00% | 220 | >= 0.97 | pass |
| amountRole | 100.00% | 213 | >= 0.99 | pass |
| instrument | 100.00% | 153 | >= 0.98 | pass |
| doubleCounts | 0 | 33 | <= 0.0 | pass |
| pairsLinked | 100.00% | 18 | >= 0.95 | pass |
| category | 100.00% | 1 | >= 0.9 | pass |
| askRate | 0.45% | 221 | <= 0.05 | pass |
| scenarioTotals | 100.00% | 33 | >= 1.0 | pass |
| eventKindByAmount | 100.00% | 2419310.7 |  |  |
| amountRoleByAmount | 100.00% | 2419310.7 |  |  |
| instrumentByAmount | 100.00% | 2346578.2 |  |  |
| scenarioEvents | 100.00% | 27 |  |  |
| scenarioInstruments | 100.00% | 21 |  |  |

Gate profile `m1`: PASS

## By family

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| refund_reversal | 30 | 30 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| card_spend | 26 | 26 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| credit | 23 | 23 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| other | 23 | 23 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| reward_points | 21 | 21 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| debit | 18 | 18 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| mandate_autopay | 16 | 16 | 100.00% | 100.00% | 100.00% | 100.00% | 6.25% |
| limit | 13 | 13 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| card_payment | 11 | 11 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| salary_income | 11 | 11 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| wallet | 10 | 10 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| bill_statement | 9 | 9 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| investment | 8 | 8 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| loan_emi | 8 | 8 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| insurance | 5 | 5 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| ipo_asba_hold | 5 | 5 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| delivery_service | 4 | 4 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| failed_declined | 4 | 4 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| otp_security | 4 | 4 | no_data | no_data | no_data | no_data | no_data |
| promotion | 3 | 3 | no_data | no_data | no_data | no_data | no_data |
| balance | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |

## By brand

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HDFCBK | 98 | 98 | 100.00% | 100.00% | 100.00% | 100.00% | 1.18% |
| ICICIT | 22 | 22 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AXISBK | 12 | 12 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| SBICRD | 10 | 10 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| KOTAKB | 8 | 8 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| EXSHOP | 5 | 5 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| IDFCFB | 5 | 5 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| SBIINB | 5 | 5 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AMAZON | 4 | 4 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| BOBSMS | 4 | 4 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| UCOBNK | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| BESCOM | 3 | 3 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| BOBCRD | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| INDUSB | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| JIOPAY | 3 | 3 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| PHONPE | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AMEXIN | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| CANBNK | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| CITIBK | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| EXWAL | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AIRTEL | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| ICICIB | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| IRCTCI | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| LICIND | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| ONECRD | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
