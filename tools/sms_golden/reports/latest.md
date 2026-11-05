# SMS golden report

Engine: `rule engine 2.3.0 + rules/sms/v2 (complete pipeline)`

Cases: 274 (274 fully passed), scenarios: 42 (42 fully passed), messages: 274, weight: 274.0

Stages: interpreter=available, instruments=available, linker=available, projector=available, categories=available

## Metrics

| Metric | Value | n | Gate | Result |
| --- | --- | --- | --- | --- |
| captureRecall | 100.00% | 238 | >= 0.99 | pass |
| ignorePrecision | 100.00% | 36 | >= 0.995 | pass |
| eventKind | 100.00% | 237 | >= 0.97 | pass |
| amountRole | 100.00% | 230 | >= 0.99 | pass |
| instrument | 100.00% | 170 | >= 0.98 | pass |
| doubleCounts | 0 | 42 | <= 0.0 | pass |
| pairsLinked | 100.00% | 22 | >= 0.95 | pass |
| category | 100.00% | 1 | >= 0.9 | pass |
| askRate | 0.42% | 238 | <= 0.05 | pass |
| scenarioTotals | 100.00% | 42 | >= 1.0 | pass |
| eventKindByAmount | 100.00% | 2486676.2 |  |  |
| amountRoleByAmount | 100.00% | 2486676.2 |  |  |
| instrumentByAmount | 100.00% | 2413943.7 |  |  |
| scenarioEvents | 100.00% | 35 |  |  |
| scenarioInstruments | 100.00% | 21 |  |  |

Gate profile `m1`: PASS

## By family

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| refund_reversal | 30 | 30 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| card_spend | 29 | 29 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| debit | 29 | 29 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| other | 25 | 25 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| credit | 23 | 23 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| reward_points | 21 | 21 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| mandate_autopay | 16 | 16 | 100.00% | 100.00% | 100.00% | 100.00% | 6.25% |
| limit | 13 | 13 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| loan_emi | 12 | 12 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| card_payment | 11 | 11 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| salary_income | 11 | 11 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| wallet | 10 | 10 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| bill_statement | 9 | 9 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| investment | 8 | 8 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
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
| HDFCBK | 104 | 104 | 100.00% | 100.00% | 100.00% | 100.00% | 1.11% |
| ICICIT | 22 | 22 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AXISBK | 15 | 15 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| SBICRD | 13 | 13 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| KOTAKB | 10 | 10 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| ICICIB | 8 | 8 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
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
| IRCTCI | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| LICIND | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| ONECRD | 2 | 2 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
