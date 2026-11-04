# P04 handoff: isolated Bamboo split presentation shell

Updated 4 November 2026. Writer: `/root/split_ui_shell`. Baseline `sms-v2/integration` @ `2608053b`, internal calculation/source contract `1.0.0-foundation`. Packet status **implementing**; isolated presentation sub-increment **ready for review**, with 16 focused Flutter tests passing and scoped static analysis clean. No root routes or real repositories wired by this writer. Independent review and emulator/production evidence remain pending.

## Owned paths and delivered boundary

- `app/lib/features/shared_expenses/ui/shared_presentation.dart`: typed presentation-only DTOs, explicit ready/loading/error/revoked states, separate gross owed/owing/net, context and participation states, immutable pages capped at 100 rows and explicit load-more/incomplete flags.
- `shared_components.dart`: one header/top-tab frame, shared Bamboo panels/actions/notices, lazy bounded list presenters, amount hiding including accessibility semantics, existing `MoneyText` and actual `BambooFonts.money`, heading and UI tokens.
- `shared_expenses_screen.dart`: Friends / Groups / Activity top tabs, overall summary, independent search state, reversible settled visibility, callbacks for existing add/navigation flows, cached/offline/incomplete/error/retry/pagination states. No app-level dock or duplicated form.
- `shared_group_screen.dart`: Expenses / Balances / Totals top tabs, separate bill total / You paid / Your share, explicit payer-only versus not-involved copy, callbacks to existing detail/editor/settings/member flows. No second simultaneous tab level or payment inference.
- `app/test/features/shared_expenses/ui/shared_expenses_screen_test.dart`: behavior tests started before implementation, covering tab hierarchy, gross/net-zero difference, hidden settled/new active records, callbacks, search preservation, offline/incomplete/loading/error/pagination/revocation, hidden monetary semantics, exact amount labels, narrow/large text and page limits.

The authenticated repository adapter remains responsible for source eligibility, consent, accepted/provisional projection, exact amounts, currency, account fences, server search and timezone/date labels. Presentation never sums the loaded page into a total or treats a zero net/payment launch as settled. Callers must key the feature subtree by authenticated account to dispose per-account search/scroll state, supply only authorized DTO fields and suppress disallowed callbacks.

Root retains router/providers/global design/Subscriptions extraction and all API/domain/storage files. No global files, manifests, lockfiles, existing screen UI or financial data were changed by this writer. No commits or Git staging performed.

## Verification log

- RED: first sandbox Flutter run could not access the SDK lockfile and was not test evidence. Retried through approved existing SDK access; focused Flutter test then failed compilation on the not-yet-created presentation/screens as expected.
- After implementation, focused Flutter compilation reached current branch's existing `sms_v2/sync/attestation.dart` import and failed because app package metadata did not contain `firebase_app_check`. Current `app/pubspec.yaml` and lockfile already declare the dependency; root notified to refresh its owned app metadata/dependencies. No dependency versions changed here. Scoped sandbox analyzer also could not read existing AppData Pub cache dependencies, so its unresolved-package output is not a valid code verdict.
- Root refreshed app metadata from the existing lockfile without version changes. Focused suite then passed 13 cases; a large-text test initially selected the wrong (horizontal/preloaded) Scrollable and was corrected to target the active Expenses vertical list.
- Added defensive assertions for nonzero balances with stale settled metadata, maximum exact money under 320-point/2× text layout, full accessible monetary values and activity callback behavior. Accessibility tests enable the semantics tree and assert full value preservation through Flutter's merged row nodes, with handles explicitly disposed before the framework's end-of-test checks.
- **Final focused suite: 16 passed, zero failures. Final scoped analyzer: no issues.** Command from `app`: direct SDK `dart.exe C:\flutter\flutter\bin\cache\flutter_tools.snapshot test --no-pub --concurrency=1 test/features/shared_expenses/ui/shared_expenses_screen_test.dart --reporter expanded`; `dart analyze lib/features/shared_expenses/ui test/features/shared_expenses/ui`. Existing process-scoped `APPDATA`/`LOCALAPPDATA` pointed to repository `.flutter-direct-appdata3`, `PUB_CACHE` to repository `.pub-cache`; SDK/package-cache access was required by the tool sandbox. Focused test log: `.flutter-direct-appdata3/p04-focused-tests.log` (local artifact, not source).
- No full-app regression suite, device/emulator runtime, actual-font screenshot or route/backend integration claim is made from these isolated widget tests. Root must run combined affected suites after real adapters/routes integrate.

## Root integration next steps

### Root integration increment

The existing Payments destination now has **Bills & commitments / Due dates / Subscriptions**. `PaymentsInsightScreen` embeds the original `SubscriptionsScreen(showChrome:false)` body and Add action beneath the single Payments header; the standalone body retains its default chrome for existing widget/direct consumers. No recurring model, service ID, amount, mandate or transaction record changed. The old `/insights/subscriptions` route redirects to Payments with `tab=subscriptions`, preserving other query parameters. The duplicate Insights Subscriptions tile was removed as agreed; Payments retains its annual headline. Visited tab bodies stay alive so cadence selection/provider/scroll state survives tab changes and detail navigation.

Root added four meaningful UI tests (single header, original standalone behavior, body-only embed and retained cadence selection) and an actual-router old-link regression. Combined existing Subscriptions/grouped-insight/main navigation + new Payments + Bamboo shell tests: **50 passed, zero failures**. Scoped changed route/screen/test analyzer: **no issues**. This is widget/router evidence; the Splits shell still awaits real repository/routes, and no emulator flow has run.

1. Focused shell tests/analyzer are green. Review these files and run the combined affected tests after root adapters/routes change; keep dependency manifests/lockfiles unchanged unless separately assigned.
2. Adapt real repository DTOs into these presentation models. Route Insights tile to this one screen, group/person selection to the reused context owner; preserve the current dock and navigation state. Root owns account-state disposal and selection/route persistence.
3. Extract current subscription list body into Payments' Subscriptions top tab with one header and preserved old links/IDs/filter/scroll. This isolated writer deliberately did not touch those root-owned existing screens.
4. Extend fixtures for recipient consent, individual balance drill-down, permissions and complete group lifecycle after P00/P03/P05 contracts are available. Do not enable new financial writes from shell tests.

Sources used: `docs/design/mobile-ui-guidelines.md`, actual `app_theme.dart`, `widgets.dart`, existing `GroupedInsightScreen` and product/production plans. A separately installed Bamboo skill was absent; implementation uses the app's canonical Bamboo Ink source directly.

## Root runtime integration, 4 November 2026

Insights now conditionally exposes the single Splits tile under independent `PANDAPAY_SHARED_EXPENSES_ENABLED` (default false). Actual authenticated runtime adapters back the hub and selected-context routes. Existing main navigation, transaction detail and Quick Add remain intact. P05's immutable local queue and account owner are reused; no second local database or fabricated runtime demo data is wired into the app.

Each top tab has scoped search and bounded Next/Previous page history. The displayed page owns its cursor; selecting another context cannot overwrite it through a global cursor map. Group amounts distinguish Shared total / Your shared contribution / Your share because full bill metadata is still a P06 persistence gate. The partial-sharing display must not call a shared contribution the full bank payment; a new failing UI contract test was added before those labels. Payer captions use known contribution data, without exposing implementation details. All-time accepted totals are supplied by the server projection, independent of loaded pages. Pending local work and incomplete/offline data have separate notices.

Root widget/API-client checks reproduce and verify: retained group search/selected tab across paging, context-parameter replacement, automatic removal of visible revoked content, in-flight aggregate/cache fencing, and recovery draining query/cache publication. The earlier combined runtime/HTTP/presenter/router/Insights suite passed **44 tests**; subsequent runtime-focused suite passed **nine tests**. Presenter fixtures used by tests remain labeled test data; production routes use authenticated providers only.

All entry/review/member/settlement callbacks are not complete; null actions are not presented as successful features. Source funding and the feature rollout remain off. Actual rendered fonts/device navigation and the full integrated financial flow still require emulator acceptance after implementation. No emulator install, reset, production change or push has occurred.

Latest combined presenter/runtime/router regression after shared-only label changes: **32 passed** (17 Bamboo presenter tests, nine runtime/client interaction cases and six existing/router cases). Log: `.flutter-direct-appdata3/shared-ui-final.log`. Keep multi-request read snapshot/sequence consistency and complete pending-review visibility in the next integration gate; these read adapters do not yet establish a coherent report-wide financial snapshot or complete review UI.
