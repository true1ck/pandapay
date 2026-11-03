# SMS golden report

Engine: `rule engine 2.0.0 + rules/sms/v2 (complete pipeline)`

Cases: 115 (115 fully passed), scenarios: 15 (15 fully passed), messages: 115, weight: 115.0

Stages: interpreter=available, instruments=available, linker=available, projector=available, categories=available

## Metrics

| Metric | Value | n | Gate | Result |
| --- | --- | --- | --- | --- |
| captureRecall | 100.00% | 88 | >= 0.99 | pass |
| ignorePrecision | 100.00% | 27 | >= 0.995 | pass |
| eventKind | 100.00% | 87 | >= 0.97 | pass |
| amountRole | 100.00% | 80 | >= 0.99 | pass |
| instrument | 100.00% | 80 | >= 0.98 | pass |
| doubleCounts | 0 | 15 | <= 0.0 | pass |
| pairsLinked | 100.00% | 8 | >= 0.95 | pass |
| category | 100.00% | 1 | >= 0.9 | pass |
| askRate | 1.14% | 88 | <= 0.05 | pass |
| scenarioTotals | 100.00% | 15 | >= 1.0 | pass |
| eventKindByAmount | 100.00% | 450339.5 |  |  |
| amountRoleByAmount | 100.00% | 450339.5 |  |  |
| instrumentByAmount | 100.00% | 445840.5 |  |  |
| scenarioEvents | 100.00% | 14 |  |  |
| scenarioInstruments | 100.00% | 15 |  |  |

Gate profile `m1`: PASS

Baseline `../sms_golden/reports/latest.json`: no regressions

## By family

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| reward_points | 18 | 18 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| debit | 11 | 11 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| limit | 9 | 9 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| mandate_autopay | 8 | 8 | 100.00% | 100.00% | 100.00% | 100.00% | 12.50% |
| credit | 7 | 7 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| refund_reversal | 7 | 7 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| card_payment | 6 | 6 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| card_spend | 6 | 6 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| other | 6 | 6 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| wallet | 6 | 6 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| ipo_asba_hold | 5 | 5 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| otp_security | 4 | 4 | no_data | no_data | no_data | no_data | no_data |
| bill_statement | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| delivery_service | 3 | 3 | no_data | no_data | no_data | no_data | no_data |
| failed_declined | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| investment | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| salary_income | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| balance | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| loan_emi | 2 | 2 | no_data | no_data | no_data | no_data | no_data |
| promotion | 2 | 2 | no_data | no_data | no_data | no_data | no_data |
| insurance | 1 | 1 | no_data | no_data | no_data | no_data | no_data |

## By brand

| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HDFCBK | 67 | 67 | 100.00% | 100.00% | 100.00% | 100.00% | 1.79% |
| ICICIT | 11 | 11 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AXISBK | 5 | 5 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| SBICRD | 4 | 4 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AMAZON | 3 | 3 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| PHONPE | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| PYTM | 2 | 2 | no_data | no_data | no_data | no_data | no_data |
| SBIINB | 2 | 2 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| AMEXIN | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| BFDLPS | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| CANBNK | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| ICICIB | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| IPAYTM | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| JIOINF | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| JIOPAY | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| KOTAKB | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| KOTAKN | 1 | 1 | 100.00% | 100.00% | no_data | no_data | 0.00% |
| KOTSEC | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| PBAZAR | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| SBIBNK | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | 0.00% |
| SBIUPI | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| SWIGGY | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| TNBPAY | 1 | 1 | 100.00% | 100.00% | 100.00% | no_data | 0.00% |
| VICARE | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
| VIINFO | 1 | 1 | no_data | no_data | no_data | no_data | no_data |
