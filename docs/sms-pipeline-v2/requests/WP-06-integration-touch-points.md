# WP-06 integration touch points

The owner asked this session to resume the overall plan and complete the implementation. This session is performing local orchestration as well as WP-06. The following integration edits are explicit and reviewed here, rather than unrecorded expansions of a package:

- `tools/sms_rules_cli/lib/golden/adapters.dart`: wire the ledger and category stages as requested by WP-00/WP-07 handoffs.
- `tools/sms_golden/scenarios/*.json`: correct IST month boundaries; see WP-06-golden-period-timezone.md. Expected totals are unchanged.
- `app/lib/app/providers.dart`: WP-06's allowed guarded totals/subscriptions/bills/card-usage call sites are in this shared file. No capture routing, upload, timer or AI logic is changed (WP-14 still owns that work).
- `app/lib/features/sms_v2/ledger/providers.dart`: reporting-only composition. WP-14 can re-export it from its provider folder without duplicating calculations.
- `app/lib/features/activity/{edit_transaction_screen,needs_review_screen}.dart`: the new enum values would otherwise appear as new choices in the old `TxnEntryKind.values` dropdowns even with the flag off. Keep the legacy four choices and include an unknown/refund value only when it is the current row's value. This is compatibility for WP-06's model change, not new v1 interpretation behavior.

Reports switch to the new source only when the build flag is on and this account has v2 facts or events. Until then legacy history keeps its established source. This readiness check affects reporting, not capture routing, and prevents a blank ledger during the pre-replay upgrade interval. A regression test exercises this transition.

No frozen schema or interface changes are authorised by this note. No Gmail, IMAP, email-ingestion or card-discovery engine file is edited.
