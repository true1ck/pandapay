# PandaPay split expansion: screenshot coverage review

Date: 4 November 2026. Scope: investigation only; no app implementation or replacement of the current plan.

**Status after the subsequent plan revision (4 November):** the main [Markdown plan](shared-expenses-product-ux-accounting-spec.md) and [HTML review](shared-expenses-product-ux-accounting-spec.html#tab-design) now include the tab samples, Bamboo font/component contract and core lifecycle/activity requirements below. Navigation has been aligned to Insights → Splits and Payments → Subscriptions. This document retains the original coverage findings as historical evidence; “Missing” describes the plan before that revision, not the current approved scope or implemented app behavior.

**Current source rebaseline:** plans now target `sms-v2/integration` @ `bf6bec9b`; see the [old-vs-new branch review](shared-expenses-sms-v2-branch-review.md). The original screenshot analysis remains historical. Reuse current source review/ledger/foreign screens and event identities; no old draft contracts are implicitly activated.

## Finding

The plan covers the core expense, payer/share accounting, settlement and reuse principles. It does **not yet specify every feature visible in these four screenshots**. Several important group/friend lifecycle and activity-feed requirements are missing or only implied. The HTML is an integration investigation, not a complete interaction specification for all these states.

The latest HTML and the older Markdown also disagree about the primary entry point. The HTML contains the agreed **Insights → Splits** placement and **Payments → Subscriptions** move. The Markdown still proposes a permanent hub in You in its final decision 8 and section 9.5. Its accounting rules remain useful evidence, but its old navigation must not drive implementation.

This review records gaps and recommended decisions. It does not silently treat the recommendations below as already included or implemented.

## Evidence and interpretation

- Screenshot 1: Groups list with overall net, per-group and per-person positions, non-group expenses, settled groups, search/filter/create controls, Scan and Add expense.
- Screenshot 2: A group with settings, member count, optional settle-up date, balance, settlement/charts/balances/totals shortcuts and a dated group timeline.
- Screenshot 3: Recent activity with actors, expense names, group context, payment/creation/update events, personal financial effects and timestamps.
- Screenshot 4: Friends list with net per friend, cross-group breakdowns, settled/no-expenses states, search/filter/add-friend controls, Scan and Add expense.
- Current HTML: [integration review](shared-expenses-product-ux-accounting-spec.html), especially [prototype placement](shared-expenses-product-ux-accounting-spec.html#prototype), [redirects](shared-expenses-product-ux-accounting-spec.html#redirects), [amounts](shared-expenses-product-ux-accounting-spec.html#amounts), and [edge cases](shared-expenses-product-ux-accounting-spec.html#safety).
- Older Markdown: [accounting, entry and UI specification](shared-expenses-product-ux-accounting-spec.md), particularly sections 4.5, 7–9, 11–14. Its navigation is superseded by the latest HTML/user decision.
- Current source spot-checks: [legacy split sheet/summary](../../app/lib/features/activity/transaction_detail_screen.dart), [legacy split data model](../../app/lib/data/user_cards_repository.dart), [transaction-scoped split routes](../../api/src/transaction_splits.js), [Insights tiles](../../app/lib/features/insights/insights_hub_screen.dart), and [router](../../app/lib/app/router.dart).

Coverage labels:

- **Covered**: explicitly described at the relevant functional level in the plan. This does not mean implemented or visually complete.
- **Partial**: domain/related behavior exists in the plan, but this exact surface, interaction or state still needs a contract.
- **Missing**: no explicit equivalent was found. Existing merchant search, document filters or generic group records do not establish this feature.
- **Adapt**: carry the useful function into PandaPay's existing owners; do not copy the reference navigation/layout literally.
- **Unverified**: the screenshot does not establish the hidden behavior. Do not infer it from an icon or an expense title.

## Screenshot 1: Groups list

| Visible feature | Coverage today | Evidence / gap and PandaPay treatment |
| --- | --- | --- |
| Overall “you are owed” amount | Partial | Markdown 9.5 specifies gross owed/owing beside net; HTML safety warns about zero net. Add an explicit summary contract to the Splits page: You are owed, You owe, Net, currency, pending/sync context. |
| Group rows with name and image/icon | Partial | Groups are domain records and dashboard filters/expansions in the plan. Specify compact row content, fallback icon, long names, tap target and loading/empty states. |
| Per-group owed/owing amount | Partial | Ledger math is explicit in Markdown 4.1/4.5. Group row labels and whether the header is a net or gross number still need specification. |
| Expanded people below a group | Partial | Obligation provenance and friend/group drill-down are planned. Specify collapsed/expanded presentation and the exact edges included. Default collapsed to avoid clutter. |
| Mixed receivable and payable people inside one group | Covered in accounting; UI partial | Markdown 4.5 explicitly preserves pair/group obligations. A group net must not hide that one person owes you while you owe another. |
| “Non-group expenses” bucket | Missing | No explicit direct-expense context, privacy boundary or dashboard bucket is defined. Support an expense without requiring the user to create a group; do not treat all friends as members of one public group. |
| “Settled up” group row | Partial | Markdown 4.5 defines true settlement, but the UI state and outstanding-credit/pending/dispute exclusions are not designed. |
| Previously settled groups with show/re-hide | Missing | Add a reversible, per-user visibility preference. Hiding must preserve history, balances and membership; a new obligation should make the context visible again. |
| Search icon | Missing for this surface | Existing Activity/merchant search is different. Specify search over authorized group names and shared expense descriptions, with a clear scope and paginated results. |
| Filter icon | Missing for this surface | Spending sharing filters are planned; Splits list filters are not. Specify All / You owe / Owed to you / Settled, plus separate needs-review or pending attention. |
| Create group and the additional lower group CTA | Partial | Group records/contextual creation are implied, but no group creation flow exists in the interaction spec. One canonical group form; avoid repeated persistent CTAs. The lower CTA is partly obscured in the image. |
| Scan | Covered / Adapt | Reuse existing Quick Add → Scan Bill with selected group/payer context. Scan receipt is different from merchant UPI Scan & Pay. |
| Add expense | Covered / Adapt | Existing Quick Add and the expanded allocation sheet own creation. An existing source opens View split instead of creating a second expense. |
| Friends / Groups / Activity / Account bottom bar | Adapt | Keep PandaPay Home / Wallet / Scan / Insights / You. Friends and Groups belong inside Insights → Splits; no second Account destination. |

## Screenshot 2: Group context

| Visible feature | Coverage today | Evidence / gap and PandaPay treatment |
| --- | --- | --- |
| Group name, visual identity and Back | Partial | Generic group expansion exists in the HTML. Specify one reusable selected-group view within Splits, preserving list/filter/scroll state on Back. No separate group dashboard clone. |
| Settings gear | Missing as a UI contract | Financial authorization exists in Markdown 12.4, but settings controls are not defined. Specify name/icon, notification mute, member permissions, history-preserving archive/leave behavior and permission/error states. Gear contents cannot be inferred from the screenshot. |
| “4 people” member control | Partial | Stable members, invites and verified claims are planned. Add roster/add/remove/invite status and explain historical versus current membership. A member count is not a payer or beneficiary count. |
| Optional “Add settle up date” | Missing | General reminders are not a group settle-up deadline. Add an optional date/reminder preference; define timezone, who may edit it and reminder recipients. It must never change issuer due dates or schedule an automatic payment. |
| Person-specific “owes you” summary | Covered in accounting; UI partial | Markdown 4.5 supports exact pair/group positions. Show amount and direction in text; the actual settlement receiver comes from eligible obligations, not a group net alone. |
| Settle up action | Covered | Reuse the focused settlement sheet; sender, receiver, currency, current payable and editable amount. Keep partial payment, overpayment credit and unconfirmed UPI states. |
| Charts shortcut with diamond badge | Partial / Unverified | Existing Spending charts can be reused with a group filter. A dedicated chart's metrics, contents or access rules are not established by the screenshot or current plan. Do not introduce a second report engine or infer a premium requirement. |
| Balances shortcut | Partial | Journal and pair/group provenance are planned, but an explicit balances sheet is not. Show who owes whom, pending versus accepted amounts, credits and settlement allocations. |
| Totals shortcut | Partial | Calculation rules exist; the exact group summary is missing. Specify Group expense total, Your share, You paid, Settlements paid/received and Current outstanding, with period/currency labels. |
| Chronological expense timeline with month/date grouping | Partial | Combined Activity pagination exists in Markdown 9.2; a group-scoped timeline and its row types are not explicitly specified. Reuse row presenters and query/projection infrastructure. |
| Category icons and expense descriptions | Partial / Adapt | Existing category ownership is preserved. Reuse it, but keep group-visible category separate from the user's private override/tags. No new Split category. |
| “You were not involved” rows | Partial | Markdown permits zero shares and payer-only participation; it does not define this display rule. See the participation rules below. |
| Settlement between two other people in the group | Partial | Ledger events support settlement; group-feed visibility and personal-feed exclusion are unspecified. An authorized group event can be shown without creating a personal payment or expense. |
| Contextual Add expense and Scan | Covered / Adapt | Open the same entry owner with group preselected. Validate current membership on save/reconnect. Do not recreate the group or create a second manual form. |
| Additional clipped shortcut to the right | Unverified | Its label/content cannot be read; do not invent an associated feature. |

## Screenshot 3: Recent activity

| Visible feature | Coverage today | Evidence / gap and PandaPay treatment |
| --- | --- | --- |
| Search on recent activity | Partial | Markdown 9.2 addresses combined feed search/pagination. Explicitly define shared-event search scope; do not claim current bank Activity already contains an audit feed. |
| Actor name and small avatar | Partial | Stable identities and audited financial changes are planned. The activity presenter, avatar fallback and former/deleted-member label are not. |
| Added / updated / paid actions | Partial | Immutable revisions/settlements are planned, but a user-facing event taxonomy and copy are missing. Define expense added, edited, voided, payment reported/confirmed/reversed and membership changes. |
| Expense description and group context | Partial | Linked expense/detail routing is planned. Specify actor + verb + expense + optional group; non-group events need a clear direct-context label. |
| “You get back”, “You owe”, “You received” | Partial | Amount vocabulary/settlement accounting exists. Event copy must distinguish the event's personal effect from the current outstanding balance and from actual bank verification. |
| “You do not owe anything” | Partial | A zero payable may still mean the user paid and is owed, or had no participation. Specify distinct copy instead of treating every zero as settled. |
| Exact date/time and relative timestamps | Partial | Reporting timestamps/timezones exist, but event ordering, local relative dates and original-versus-edited timestamps need an explicit UX rule. |
| Updated expense history | Partial | Markdown 12.4 retains before/after audit. Specify whether an event displays the amount at that revision; do not silently rewrite old event copy to current values. |
| Event tap to source details | Covered at routing level | Exact authorized record routing is planned. Reuse the shared detail presenter; original private bank evidence stays private. |
| Two entries titled “Settle all balances” | Unverified | These are visible item titles, not proof of a bulk-settlement control. Do not count them as confirmation that bulk settlement exists. Advanced netting is deferred in Markdown 4.5/13. |
| A received-payment row | Covered in accounting; feed partial | A repayment is separate from consumption and earned income. Distinguish Reported received, Confirmed by receiver and Provider verified, according to available evidence. |
| Scan/Add expense floating actions | Adapt | Reuse one primary Add expense with Scan Bill as a secondary entry. Reserve safe-area clearance; do not overlay a second floating action on another CTA or list content. |

The reference shows financial events and editing history. PandaPay needs a distinction between a **current economic expense row** and an **audit event about that expense**. Both can be visible in appropriate views without counting the same money twice.

## Screenshot 4: Friends list

| Visible feature | Coverage today | Evidence / gap and PandaPay treatment |
| --- | --- | --- |
| Add friends | Partial | Stable pending people, contacts-optional entry and invitation claim rules exist. Specify the picker/manual contact/invite flow and distinguish adding a person from sending a message or accepting historical debt. |
| Friend search | Missing for this surface | Define name search over authorized people; do not treat merchant search as an implementation. Contacts permission must remain optional. |
| Friend photo or geometric fallback | Missing | Specify existing avatar/fallback reuse, optional photo and accessible name. Identity is never inferred from a displayed name or image. |
| Net owed/owing per friend | Covered in accounting; HTML detail partial | Markdown 4.5 and 9.5 explicitly aggregate friend positions with group drill-down. Add exact UI copy, currency and gross detail to the HTML/interaction spec. |
| Same friend owes in a group while user owes outside it | Covered in accounting; UI partial | No silent cross-group offset is explicitly required. Keep both underlying positions inspectable even if their informational net is small. |
| Expanded group/non-group breakdown | Partial | Group drill-down is mentioned, but non-group scope, collapsed rows and “more” disclosure are missing. |
| “Settled up” friend | Partial | A true settlement policy exists. It must not mean merely zero combined net when obligations remain in different groups. |
| “No expenses” friend | Missing | Distinguish no shared history from historical expenses now settled, pending invitations, outstanding credit and incomplete sync. |
| Previously settled friends show/re-hide | Missing | Add the same reversible preference as groups. Hiding a person does not delete the identity, source links or shared history. |
| Friend tap, Add expense and settlement context | Partial / Covered | Contextual entry and settlement are described; define one reusable person view with group sections. Do not create separate forms or a new personal Account page. |
| Overall net/filter and shared Scan/Add actions | Same gaps/reuse as Groups | Friends and Groups are different projections over the same obligations, not independent ledgers or duplicate expenses. |

## Verified calculation example from the screenshots

All numbers below were checked using decimal arithmetic. These are the displayed screenshot positions, not live PandaPay balances.

| Reconciliation | Calculation | Result |
| --- | --- | --- |
| Overall from group nets | 14,081.81 − 36.28 − 12,488.31 | ₹1,557.22 owed to you, net |
| Himanshu across contexts | 14,081.81 − 13,933.81 | ₹148.00 owed to you, net |
| Priyansh across contexts | 607.50 + 157.15 | ₹764.65 owed to you |
| Vani across contexts | 838.00 − 90.00 | ₹748.00 owed to you, net |
| Overall from friend nets | 148.00 + 764.65 + 748.00 − 103.43 | ₹1,557.22 owed to you, net |
| Visible pair/context receivables before cross-context offsets | 14,081.81 + 157.15 + 838.00 + 607.50 | ₹15,684.46 |
| Visible pair/context payables before cross-context offsets | 13,933.81 + 103.43 + 90.00 | ₹14,127.24 |

The last two amounts reconcile to the same ₹1,557.22 net. Summing only positive friend nets produces ₹1,660.65, which is a **different, cross-context-netted measure**, not the gross scope-preserving receivable. Summing positive group nets is another different measure. The app must name the aggregation basis and not alternate between these values under the same label.

For this example the recommended summary is **You are owed ₹15,684.46 · You owe ₹14,127.24 · Net ₹1,557.22**, based on the displayed obligations and the initial no-cross-group-offset policy. This does not authorize paying only a friend's cross-group net or silently closing unrelated group obligations.

Required reconciliation invariants:

1. For one user, currency, recognized scope and snapshot: the sum of group/direct-context net positions equals the sum of friend net positions and the overall net. Friends and Groups must not be added together.
2. Within a group, display the user's pairwise obligations; do not confuse them with the zero sum of all group members' journal balances.
3. Group expense total counts each accepted economic expense once, even with several payers/tags/revisions. Personal share and actual contribution remain different metrics.
4. Settlements and audit updates change obligations/history, not the original consumption total or purchase-reward denominator.
5. Do not sum different currencies without an explicitly supported frozen-rate conversion. Pending/unaccepted claims and incomplete offline coverage are separately labeled.
6. Hidden settled contexts remain part of retained history. Search results, pagination and visible rows must not accidentally become the sole source of global balances.

## Rules that must be explicit before implementation

### Participation and visibility

- **You paid = 0 and Your share = 0:** an authorized group expense may show “Not included in this split”. It contributes zero to the user's spending, rewards, funding and obligations. It need not clutter the default personal Activity feed; offer a scoped group “All activity” view.
- **You paid > 0 and Your share = 0:** show “You paid for others”, not “Not involved”. The user can be owed money despite a zero personal cost.
- **You paid = 0 and Your share > 0:** show “Paid by Rahul · Your share ₹X”. Do not create an own bank debit.
- A settlement between two other people has zero personal movement and consumption. Visibility follows group authorization; private funding evidence remains hidden.
- A group member count includes authorized members, not necessarily everyone included in each expense. Historical participants remain addressable after leave/removal.

### Lifecycle and state

- Group creation: name, optional image/type only if useful, member selection, pending invite state, optional date and one Save group. Creating the group creates no expense or debt.
- Direct/non-group expense: keep a stable private context and expense-level participant authorization. A list bucket must not expose every direct expense to all friends.
- Member add/remove/leave: define who can act, future versus historical access and handling of queued drafts. Removing a member must not erase accepted obligations or silently reallocate old shares.
- Group settings/archive: reuse a sheet or the selected-group view. Archiving/hiding is different from voiding an expense or deleting source evidence. Unresolved obligations require an explicit state, not disappearing history.
- Distinguish No expenses, Settled, Net zero with obligations, Pending payment, Pending invite/review, Credit owed back, Disputed and Snapshot incomplete.
- Settled groups/friends are collapsed by default with Show settled / Hide settled. Reopen visibility when recognized new activity needs action. A presentation preference never mutates ledger data.
- Optional settle-up date uses the user's timezone and notification preferences, quiet hours and reminder caps. It does not initiate UPI or alter issuer dues.

### Activity versus reports

- Use stable event IDs and server/local cursors for actor/action/time/revision records; retain a recoverable local pending state and deduplicate retries.
- An audit event's amount refers to that event/revision and uses explicit labels. Current outstanding lives in the detail/balance view; an old event must not appear to quote today's balance without explanation.
- Keep event time, expense occurrence date and settlement confirmation time distinct. Spending uses the agreed expense-date/correction policy, not the edit notification time.
- Expense edit/void and settlement report/confirm/reversal remain inspectable without appending another consumption fact.
- Reuse current Activity row/query infrastructure where suitable, but extend its typed model. An audit event is not a bank transaction and is not automatically a suitable item for every personal Activity filter.
- If bulk settlement is added later, present exact sender/receiver/currency/scope allocations and authorization before confirmation. It must be an explicit settlement/offset operation, never a fake expense named “Settle all balances”.

### Uncluttered PandaPay placement

Recommended refinement for the next plan revision:

```text
Existing bottom navigation: Home · Wallet · Scan · Insights · You

Insights
├─ Spending → existing reports; optional group/person filter
├─ Splits → one feature page
│  ├─ Summary: You owe · You are owed · Net
│  ├─ Friends / Groups view switch
│  ├─ Search, filters and Show settled
│  ├─ Selected person/group: same reusable contextual view
│  │  ├─ Expense list + scoped activity
│  │  ├─ Balances / Totals disclosures
│  │  ├─ Members / settings / optional date
│  │  └─ Settle up → shared settlement sheet
│  ├─ Recent changes disclosure → scoped event feed
│  └─ Add expense / Scan Bill → existing Quick Add owner
└─ Payments
   ├─ Bills & commitments
   ├─ Due dates
   └─ Subscriptions → current content and existing service detail
```

This is one new feature destination with contextual sections/sheets, not four replacement bottom-navigation pages. Friends, Groups and activity views read the same underlying identities, expenses and journal. Use one context presenter with Back preserving selection, filters and scroll. If mobile presentation needs a full-height context view, it must reuse that presenter rather than clone an independent dashboard.

Charts should open the existing Spending owner with a group/person filter and a clearly named basis. Group-wide totals that include others' expenses require their own authorized aggregate; do not relabel a personal report as the whole group's spending. A new group analytics engine, premium gate and automatic debt simplification are not required by these images.

Follow [Bamboo Ink guidance](mobile-ui-guidelines.md): paper/glass, slate primary actions, lime only on slate, semantic text labels, existing type/spacing/radius tokens and accessible touch targets. Keep one primary Add action. Do not reproduce the overlapping floating controls or the reference app's bottom bar. Keep amounts readable with paisa and large text; collapse long breakdowns rather than truncate financial values.

## Recommended plan work, in order

| Priority | Required change | Acceptance before implementation |
| --- | --- | --- |
| P0 | Align Markdown and HTML navigation | Both say Insights → Splits, Payments → Subscriptions; every source/deep-link/back path agrees. |
| P0 | Specify group/direct contexts and friend aggregation | Same currency/snapshot yields matching group, friend and overall nets; private direct expenses have correct authorization. |
| P0 | Define balances, totals and participation states | Exact formulas, no cross-group silent offsets, no fake own charges, no “settled” based only on net zero. |
| P0 | Specify group/member lifecycle and settled visibility | No lost history/obligations; hide/show/archive and leave/remove have distinct effects. |
| P0 | Define shared audit events and Activity integration | No duplicate expenses or spending/rewards from edits, notifications or settlement records. |
| P1 | Design search/filter/roster/settings/date sheets | Explicit permissions, offline/conflict/empty/error states and one reusable creation owner. |
| P1 | Add contextual balances/totals and group-filtered reports | One authorized scope, clear amount basis, original payment/detail links and preserved Back state. |
| Later, explicit scope | Advanced charts, bulk netting/offset, optional personalization | Separate agreed behavior and testable contracts; do not infer them from a badge or title. |

Companion designs still needed: Friends/Groups list variants, selected group/person context, non-group view, group/member settings, settled/no-expenses/net-zero states, balances/totals sheet, date/reminder sheet and shared audit-event rows. These supplement the existing editor/detail/settlement designs; they do not justify duplicate manual forms or another app navigation bar.

## Validation and limits

- Compared all four supplied images with the current HTML, the older Markdown's relevant accounting/UX sections and the current source owners listed above.
- Verified the screenshot balance examples with exact decimal arithmetic.
- Confirmed the legacy `TransactionSplit` stores amount/note/card/category metadata, and the inspected split routes operate on an owned transaction. Those pieces alone do not implement stable friends, group membership, a social activity feed or shared settlements.
- No app install, sign-in, financial mutation, external publication or live payment verification was performed. No existing plan or application file was changed for this investigation; this review is the new artifact.
- Screenshots do not reveal the search/filter menu contents, settings options, charts/totals contents, member-management permissions or the clipped extra shortcut. Recommendations for those controls are proposed requirements, not claims about the reference app's hidden behavior.
