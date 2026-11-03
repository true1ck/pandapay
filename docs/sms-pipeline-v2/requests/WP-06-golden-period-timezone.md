# WP-06 golden reporting period correction

The November scenarios label their expected totals as an Indian calendar month, but their original UTC-midnight bounds exclude printed date-only 1 November transactions. The engine correctly parses IST midnight as 31 October 18:30 UTC. Once the ledger stage was wired, cheque_debit, points_earned_on_card_spend and salary_credit failed only for this reason.

Resolution for integration review: express the intended November IST period as `[2026-10-31T18:30:00Z, 2026-11-30T18:30:00Z)` in the scenarios. Expected monetary values and event classifications are unchanged. The projector still compares exact instants and uses half-open periods. No engine, contract or timestamp is changed to make a fixture pass.
