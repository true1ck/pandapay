# Splits layout correction and verification — 4 November 2026

Owner: root. Branch: `sms-v2/integration`. Verified code checkpoint: **`2c443370`** (local only). Scope: existing presentation and its regression tests. This corrects the layout gaps identified in [the original visual audit](visual-layout-audit-20261104.md); it does not complete P04/P06 or the financial release.

## Implemented

- Full-width Friends / Groups / Activity and Expenses / Balances / Totals tabs at normal text size. Narrow/large-text layouts retain scrollable tabs. Existing main navigation and Payments tabs are unchanged.
- Compact Search/Filter toolbar. Search expands on demand, preserves each tab's query while switching, clears the real server query when closed, and retains the existing debounce/paging ownership. The filter controls settled visibility for the selected Friends/Groups tab; Activity has no nonfunctional filter.
- Slate summary: dominant lime informational net, then the two gross directions beneath the divider. Opposite obligations remain visible at net zero. Large text stacks the gross figures; hidden amounts retain private accessibility semantics.
- Avatar/group-icon rows with trailing directional amounts. Mixed obligations show the informational net plus both gross directions. No automatic cross-context settlement or fabricated group breakdown.
- Small Add friend/Create group controls above the list when real callbacks exist. Quiet, reversible settled disclosure follows the active rows; no fabricated full-account count.
- Activity has Recent changes, a compact net strip, local Today/Yesterday/date headings, readable times and row-level navigation. Generic event icons are used because the current feed does not provide an authoritative actor avatar. Reported payments remain awaiting confirmation.
- Compact group expense rows with an icon and distinct total, own funding and own share. Shared-only runtime values retain Shared total/Your shared contribution labels. Expense calendar dates are not shifted across time zones. Row taps reuse existing callbacks, with no extra View expense/View update buttons.
- Connected primary Add expense actions use slate/lime. Runtime actions remain conditional on their real owner; no duplicate editor, placeholder success or synthetic device expenses were added.

Bamboo source: `docs/design/mobile-ui-guidelines.md`, `app_theme.dart`, `widgets.dart`. Outfit is used through BambooFonts.heading/ui; IBM Plex Sans/tabular money through BambooFonts.money and MoneyText. No separate installed Bamboo SKILL.md is available.

## Visual evidence and limits

Compared both original image sheets with [actual Flutter layout renders](../../design/prototypes/splits-tabs-2026-11-04/implemented/README.md), at 430 × 940 logical pixels. Actual cached fonts, Material icons and AppTheme.light() were loaded; system-font fallback was disabled. These four renders contain fictional fixture data and conditional callbacks, not native financial-flow proof. No fixture data was inserted into the signed-in app.

The first render lacked the test icon font; it was corrected and all four images rerendered before saving the public copies. The final comparison restored hub hierarchy, full-width tabs, toolbar placement, row composition, settled controls and Activity composition. Group financial rows were reduced after visual inspection to preserve all three measures without large stacked panels.

**Visual acceptance remains partial.** Full sample parity depends on existing entry/save integration, Scan bill, friend/member flows, group settings/settle-up date, coherent authorized group summary, chronological expense paging/month grouping, complete friend cross-context breakdown, authoritative actor/pending metadata and real settlement actions. These gaps remain open; the original samples remain the target. Existing Insights tile sizing and original Subscriptions body are intentionally retained as required.

## Automated evidence

- TDD red: five missing interaction/hierarchy cases reproduced on the prior layout. A further mixed-obligation net case was reproduced before its fix.
- Final UI/runtime suite: 30 passed. Separate isolated actual-font layout renderer: one passed.
- Final exact-source shared/router/Insights/Payments/Subscriptions regression: **127 passed**; recorded in `layout-regression-final.log`.
- Changed UI/tests analyzer: no issues found. Formatting and `git diff --check` passed. Updated HTML checks passed for all 113 inventoried screens, CSP/runtime, filters, print state and responsive widths 320/360/430/768/1024/1440.
- Existing full-app limitations remain: the prior full suite was not green, with four unrelated SMS screenshot references/differences still unresolved. No golden reference or tolerance was changed.

Logs and private native evidence live under `artifacts/shared-expenses-emulator-20261104/` and are not committed. Public fictional renders alone are saved under the design prototypes folder.

## Final Android verification

- Serial: **emulator-5554**. Package: **app.pandapay.pandapay.dev2**. Installed: **1.0.16-dev / 8128**.
- Backend recorded before both update-installs: API **http://10.0.2.2:4001**, auth **http://10.0.2.2:3210**. Both local ready endpoints returned 200.
- Updated with `adb install -r`; no uninstall, app-data clear or automated authentication. Existing signed-in Home was visibly verified after the final install.
- Exercised Home → Insights → Splits; Friends/Groups/Activity; expanding search and searching QA, clearing the query; settled filter apply/Done; Activity → existing QA group → Expenses/Balances/Totals; Back restoring Activity; Back to Insights; Payments → Subscriptions with the original AutoPay/unknown-charge body.
- The existing QA group remained present. There are no accepted shared expense/settlement device flows in this verification; financial gates remain disabled.
- Consistent local SQLite snapshots after normal force-stop: quick_check **ok**, **24 before / 24 after** financial entity records, identical namespace/entity/id/amount_paise tuples, and **one before / one after** byte-identical legacy split document row. These are scoped local preservation checks, not a guarantee for all server fields/accounts.
- A cold restart then retained the signed-in Home and the same QA group; the app was left on the final Groups tab.
- firstInstallTime remained **2026-11-01 00:21:28**; lastUpdateTime is **2026-11-04 16:28:37**. Native XML/PNGs and `layout-data-preservation.json` record the evidence.

## Next owner boundary

Continue P01 source admission/guards and P06 existing Quick Add/detail orchestration, including immutable full bill/full payer metadata, before enabling finance or exposing their footer actions. Then integrate member/review/settlement flows and coherent report snapshots. No backend migration, API/ledger/source calculation change, push or production deployment was made in this presentation increment.
