# Transaction tags: proposed implementation

Status: the explicit-tag core is implemented locally on 20 October 2026: transaction forms/details, Activity bulk controls, spending filters/breakdowns, Settings, imports/exports, local durable synchronization, and tag budgets. The ID-scoped assistant summary API accepts tag filters. The tag migration and the required category migrations have been applied to the local development database; the dev API was restarted and the dev APK built and installed on the emulator. Hosted database/API and Play release deployment are still separate.

See [the emulator test plan](transaction-tags-emulator-test-plan.md) for exact fixtures and expected totals. Recurring default-tag rules, automatic contextual classification, and natural-language tag-name resolution remain follow-up automation. Full account JSON exports preserve tag metadata, while the existing transaction-import path restores tag names rather than cloning account identities.

## Product model

Keep three independent concepts:

- Category: what the purchase was for, such as Dining, Fuel, or Travel.
- Subcategory: a narrower kind within one category, such as Dining → Office lunch.
- Tags: context shared across categories, such as Thailand trip, Office, or Reimbursable.

A transaction has one category, an optional subcategory, and zero or more tags. Tags are optional and private to the account. A Dining purchase can carry both Office and Reimbursable. A Thailand trip tag can contain Dining, Travel, Shopping, and Fuel transactions without changing their reward classification.

## Existing foundations and gaps

- `app/lib/app/category_picker.dart` creates categories/subcategories. Quick Add exposes subcategory selection.
- `app/lib/data/user_categories_repository.dart` stores private categories locally and queues synchronization.
- `transactions.user_category_id` is a single custom classification slot. Migration `20261020150000_user_subcategories.sql` introduces parent links; `20261020153000_normalize_transaction_category_parent.sql` preserves the public reporting/reward parent.
- Transaction models expose custom category and subcategory labels; the detail page renders their combined category label.
- `spend_trends_screen.dart` currently filters payment method, category labels, merchant, and card. There is no independent transaction tag selection in that filter model.
- CSV parsing currently treats tag/label headers as subcategory aliases. Separate these fields for future imports; do not silently reinterpret existing user classifications.

## Pages and behavior

| Page / entry point | Change | Status |
| --- | --- | --- |
| Quick Add / Add transaction | Optional Tags field; searchable picker; create inline; retain selection when category changes | Implemented |
| Edit transaction | Load/add/remove tags; queue offline changes; tag-only saves leave financial state alone | Implemented |
| Transaction detail | Display tag chips and Add tags; tapping a chip opens spending filtered to that tag | Implemented |
| Spending filters | Multi-tag OR selection plus explicit untagged; category/subcategory by stable IDs | Implemented |
| Spending summary | Apply one filtered dataset to totals, donut, monthly bars, and breakdowns | Implemented |
| Spending tag view | Tags breakdown with counts/drill-down and an overlap warning | Implemented |
| Activity / transaction lists | Tag filter and bulk add/remove; show tag indicators | Implemented |
| Settings | Create, rename, color, archive/restore, merge, and show usage/sync state | Implemented |
| CSV import review | Assign tags by row or import; parse tag columns separately from subcategories | Implemented |
| SMS / Gmail imports | Preserve explicit assignments when duplicate rows are merged into a canonical transaction | Implemented |
| Export / transaction import | CSV and JSON export tags; transaction import restores tag names. Full-account identity restore is separate follow-up. | Implemented with restore limitation |
| Home category tiles | Existing horizontal category cards continue to lead to category spending; tag-filtered reports are reachable through spending | Existing integration retained |
| Insights / assistant | Summary endpoint accepts tag IDs; natural-language tag-name resolution remains follow-up | Partially implemented |
| Budgets | Tag-scoped budgets, including normal spend/remaining calculations | Implemented |
| Recurring expenses | Optional explicit default tags for future occurrences; avoid silently applying one-off trip tags | Follow-up |
| Splits / reimbursements | Tags belong to the transaction; split ownership/share behavior is retained | Existing integration retained |

## Filtering and reporting contract

- Date AND payment method AND category/subcategory AND merchant AND card AND tags.
- Multiple choices within one group use OR by default. Multiple tags mean match any selected tag. An explicit Match all option can be added without ambiguity.
- Untagged means no assigned tags, not no category. Make it mutually exclusive with individual tag choices.
- Parent-category filters include children; tag filters work across all categories.
- Sheet preview count/amount and applied page results use the same query and predicate. Reset clears all dimensions. Preserve filters while changing dates and drill-down views.
- Apply the filter before aggregation and pagination. Do not calculate report totals from only the first loaded transaction page.
- Monthly comparisons include empty months and use consistent date boundaries/timezones. The category donut stays available for all date ranges.
- A transaction is counted once in any selected report, even when it matches multiple tags. Use EXISTS or deduplicate transaction IDs before sums; never sum a raw many-to-many join.
- Distinct tag rows can overlap. Their row totals must not be added to infer total spending.
- Use the application's existing spend eligibility, ignored/refund/transfer, rewards, and split accounting rules consistently. Tags change scope, not transaction amounts or reward eligibility.

## Storage, API, and synchronization

Add account-owned `transaction_tags` (id, profile_id, name, normalized_name, color, archived_at, timestamps) and `transaction_tag_links` (profile_id, transaction_id, tag_id, timestamps). Enforce unique links, account ownership, case-insensitive active-name uniqueness, and indexes for profile/tag/transaction lookup. Enforce ownership on both sides of each link in server validation and database constraints/policies.

Extend transaction reads/writes and local models with tag IDs and display metadata. Add tag management, assignment, and bounded bulk assignment APIs; extend transaction listing, spend reports, spending summaries, CSV export, and full export with a shared filter contract. Check old-client compatibility before making any field required.

Add account-namespaced SQLite tables, local tag/link writes, queue operations, server sync pull/push, tombstones, and dependent-create ordering. Use stable client-generated UUIDs and idempotent per-tag add/remove operations; define same-link conflict resolution so editing different tags on two devices does not overwrite the whole tag set. Update pending transaction IDs/references when canonical server IDs are resolved.

Tag-only edits must not reapply card spend/rewards state. Invalidate/recompute all affected spending caches after assignment, merge, archive, sync, or canonical transaction reconciliation. Renaming a tag keeps its ID and history. Archiving hides it from default pickers but retains historical assignments and reporting. Removing an assignment does not delete a transaction.

## Imports, automation, and migration

Keep original categories/subcategories unchanged. Start existing transactions with no tags. Review legacy tag/label import handling and document that earlier imports may have stored those values as subcategories; offer an explicit reviewed conversion rather than automatic migration.

For SMS/Gmail/manual duplicates, attach tags to the surviving canonical transaction and union explicit assignments when records merge. Preserve user choices when automatic classification changes. Reimports and retries cannot create duplicate tags, links, transactions, or amounts.

Start with manual and bulk tagging. Later introduce opt-in rules with preview, such as a selected merchant/date range → Thailand trip. Do not infer Office or a trip from arbitrary message text without a user-approved rule.

## Delivery order and acceptance

1. Confirm UX wording (Tags), picker behavior, archive/merge semantics, and reporting query contract.
2. Implement storage/API/local queue foundation and backwards compatibility.
3. Wire Quick Add, edit/detail, Settings, list selection, and import review.
4. Wire shared spending filters and every chart/summary/breakdown; add tag drill-down.
5. Finish export/restore, canonical dedup preservation, and multi-device sync.
6. Validate UI and end-to-end accounting on a test account before rollout; follow-up budgets/rules/assistant capabilities only after the core flow works.

Acceptance scenario: create Thailand trip and Office; assign multiple categories and one overlapping transaction; filter by trip, then Dining, then merchant, then date/card/payment. Preview, total, donut, bars, and rows must agree. Selecting two overlapping tags counts their shared transaction once. Confirm untagged and zero-result states, parent/child filtering, full-history pagination, offline creation/edit/reconnect/restart, two-device independent tag edits, SMS+Gmail+manual dedup, rename/archive/merge, account isolation, import/export round-trip, and preservation of rewards/splits accounting.
