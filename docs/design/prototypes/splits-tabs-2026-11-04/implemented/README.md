# Rendered Flutter layout fixtures

Rendered 4 November 2026 from the existing Splits widgets at 430 × 940 logical pixels (2× PNG scale), using the app's actual cached Outfit and IBM Plex Sans fonts, Material icons and AppTheme.light(). These are isolated Flutter fixtures with fictional data, not signed-in emulator screens or evidence of implemented financial flows.

- [Friends](friends.png): informational net and both gross obligations; avatar rows and settled disclosure.
- [Groups](groups.png): compact context rows, zero-net obligations remain outstanding.
- [Activity](activity.png): compact net strip, readable local day/time, row navigation.
- [Selected group](group.png): compact financial rows preserve total, personal funding and share.

The fixture supplies Add expense/Add friend callbacks and an authorized group summary to demonstrate their conditional placement. The real route must obtain its data and wire the existing entry owner before these controls appear. Scan bill, settlement, member/settings and settle-up date integrations remain open. The fixture's complete-bill data can use Bill total/You paid; the current runtime correctly uses Shared total/Your shared contribution until full bill metadata is available.

Reference samples remain the parent folder's original two image sheets. Existing Insights tile sizing and Subscriptions body are deliberately preserved. The implementation review and device evidence are in docs/implementation/shared-expenses/layout-correction-20261104.md.
