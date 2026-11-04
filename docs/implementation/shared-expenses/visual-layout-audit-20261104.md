# Planned-image versus implemented-layout verification

Verified 4 November 2026. Result: **visual acceptance NOT MET**. Current Bamboo token/font compliance and functional route tests do not establish conformity to the planned composition. This finding supersedes any implication in the earlier theme audit that the screens visually match the approved samples.

## Comparison sources

- Planned hub: [Friends / Groups / Activity sample](../../design/prototypes/splits-tabs-2026-11-04/pandapay-splits-tabs.png).
- Planned connected contexts: [Insights / selected group / Payments sample](../../design/prototypes/splits-tabs-2026-11-04/pandapay-insights-group-payments.png).
- The [original generation brief](../../design/prototypes/splits-tabs-2026-11-04/PROMPTS.md) specifies hierarchy and placement, not only a palette.
- Recorded native build 8126: `artifacts/shared-expenses-emulator-20261104/groups-persisted.png`, `activity-final.xml`, `context-live.xml`, `totals-live.xml`, `subscriptions.png`, and `insights.png`. These are recorded verification artifacts, not a claim of a fresh device capture during this comparison.
- Current source: `shared_components.dart`, `shared_expenses_screen.dart`, `shared_group_screen.dart`, presentation DTOs and runtime callback wiring. No UI, account data or device was changed during this audit.

## Exact mismatches and required corrections

| Area | Planned composition | Current implementation | Required correction / dependency |
| --- | --- | --- | --- |
| Hub title row | One compact Back/title row, search and filter icons at the right. | Back/title only; search is permanently expanded in the page. | Restore compact toolbar controls and explicit search/filter interaction. Do not add a nonfunctional filter icon. |
| Tab distribution | Three short hub labels distributed across the available width with a thin underline/divider. | SharedTabbedFrame always uses a start-aligned scrollable TabBar, leaving space on the right. | Distribute short hub/context tabs across width; retain horizontal scrolling for long Payments labels and large-text overflow as necessary. Reuse the existing tab family. |
| Friends / Groups summary | Compact slate card; net amount is the dominant lime figure; two smaller owed/owing values beneath a divider. | White panel; three similarly weighted vertical rows, net last. | Restore the intended hierarchy and slate/lime treatment. Gross directions must remain visible when net is zero. No netting or financial calculation changes. |
| Add friend / Create group | Small secondary action directly above the list. | Large outlined Create group button after search and Show settled; Add friend is not wired. | Use the planned secondary-action position/weight. Complete real friend/member flow before exposing it. |
| Context rows | Compact icon/avatar, title/subtitle, trailing balance with direction; optional expandable breakdown. | Large mostly text-only panel; generic layout; complete friend cross-context breakdown is not available. | Restore row composition, density and icons/avatars using existing tokens. Supply authorized breakdown data; never infer it from a page total or private notes. |
| Settled disclosure | Quiet disclosure after the active list, with contextual Friends/Groups copy and count when known. | Large outlined Show settled control before the list. | Restore bottom disclosure position, compact style and correct show/hide state. A count needs complete authorized coverage; never infer the full count from a page. |
| Bottom entry area | Fixed slate Add expense primary action and subordinate Scan bill text action where specified. | Footer is omitted because the production route supplies no Add expense callback; Scan bill is absent. | Finish existing Quick Add/detail orchestration, then wire the real actions in the planned footer. Do not add a fake success action or duplicate global editor to imitate the image. |
| Activity header | Recent changes heading with a compact net strip. | Reuses the full Friends/Groups summary and expanded search header. | Give Activity its planned composition while retaining the same underlying ledger/report scope. |
| Activity rows | Today/Yesterday grouping, actor avatar, action, context and optional financial/pending detail. | Generic cards with description/context, raw ISO timestamp and an extra View update action. | Implement day grouping and readable localized time; compact avatar/event rows; safe row-level navigation and authoritative pending state. Keep reported payment distinct from confirmed settlement. |
| Group title/subheader | Group name, settings, compact member count and optional settle-up date. | Group name/tabs only; runtime supplies no member/settings actions or date controls. | Connect current group/member/settings owners and optional date contract; preserve history/permissions. No new duplicate dashboard. |
| Group balance section | Compact slate balance panel and small Settle up action. | Runtime does not supply group summary or settlement callback, so this section is absent. | Add coherent authorized group balance read and real settlement flow; keep source/settlement gates explicit. |
| Group expense list | Month heading and compact icon/expense rows, Bill / Your share / You paid in a concise hierarchy. | Generic larger cards in presenter; current expense page is UUID-keyset ordered, with no month grouping. New QA group is empty. | Implement compatible chronological paging/grouping and compact presenters. Preserve full bill/funding metadata before labeling shared-only values as full bill or full payment. |
| Insights entry | Existing two-column insight grid, new Splits tile, existing main dock retained. | Correct entry/navigation ownership; existing app tile sizing differs from the generated sample. | Preserve existing root UI as requested; do not redesign the entire Insights grid solely to copy illustrative image proportions. |
| Payments / Subscriptions | One Payments header and third tab using original subscription content. | Correct structure and original body reuse. Existing list/add-control sizing differs from the sample. | Keep existing subscription UI/data ownership. Sample service values, confirmed charges and forecast examples must not replace actual AutoPay/unknown-charge states. Any visual refinement must respect the original reuse decision. |

## Boundaries that remain correct

- Keep Insights in Home / Wallet / Scan / Insights / You. No Splits replacement dock or second Account destination.
- Hub and selected context each have one visible tab level. Secondary pages use Back.
- Use the real Bamboo Ink theme: Outfit through BambooFonts.heading/ui, IBM Plex Sans/tabular monetary values through BambooFonts.money and existing MoneyText, AppBackground, AppSpace and AppRadius.
- Fictional reference names/amounts are not device data. Empty real groups can remain empty while using the same layout hierarchy. Missing data cannot justify fabricated people, balances, bills or payment confirmations.
- Large text and accessibility may require wrapping or horizontal scrolling; compare hierarchy/placement at equal logical viewport and text scale, not raw PNG pixel dimensions.

## Correction and acceptance sequence

1. Correct the existing hub frame, summary, toolbar, row composition and settled disclosure against the first sheet. No new screen or data-model rewrite for layout.
2. Implement Activity's distinct header/row grouping, including safe event data and navigation.
3. Complete source/editor/member/settlement dependencies before wiring their planned actions and group metadata. Keep these visual/functionality gaps explicitly open.
4. Capture the implemented Friends, Groups, Activity and group states at the same logical phone size with actual Bamboo fonts, using clearly labeled test fixtures in isolated tests where populated visual states are required. Keep production screens on authenticated real data.
5. Compare side by side to both original sheets. Verify narrow screens, large text, keyboard, hidden amounts and no extra app dock. Functional tests and theme-token checks are separate gates; neither is visual approval.

The samples remain the intended design reference. This audit does not replace them with the current layout or mark a partial screen complete.
