# Transaction tags: Android emulator test plan

Prepared 20 October 2026. Use a dedicated development test account and the **dev** APK. The dev app connects to this computer at `10.0.2.2:4000` (API) and `10.0.2.2:3210` (Auth). Production configuration continues to use the hosted services.

## Setup

1. Apply the repository migrations, including the private-category/subcategory migrations and `20261020200000_transaction_tags.sql`, to the local product database. The tag migration is additive; it creates no sample financial transactions and changes no existing category values.
2. Start the current API and auth service with `scripts/start_local_backend.sh`. If an older local service is already running, restart that development process before testing: a new APK cannot make an old API expose new tag routes.
3. Build with `scripts/build_app.sh dev apk --debug`. Install `app/build/app/outputs/flutter-apk/app-dev-debug.apk` using `adb install -r`, which preserves app data. Open PandaPay Dev and sign into the test account. Do not clear app storage or uninstall another app to run this plan.
4. Use a second emulator/device signed into the same account for synchronization cases; use another account for isolation cases.
5. Record the existing wallet balances, card cap/milestone/points progress, spending total, and split values before tagging. Those financial values must not change after tag-only operations.

## Deterministic fixture

Use a clean month/custom range with the following six **cash** transactions so reward calculations cannot complicate the expected sums. All amounts are INR. Use existing categories or their closest equivalent. Create tags from the picker or Settings → Manage tags.

| Row | Date | Merchant | Category | Amount | Tags |
| --- | --- | --- | --- | ---: | --- |
| A | Oct 2 | TAG QA Cafe | Dining | 500 | Thailand trip, Office |
| B | Oct 3 | TAG QA Taxi | Travel | 1,000 | Thailand trip |
| C | Oct 4 | TAG QA Fuel | Fuel | 300 | Office |
| D | Oct 5 | TAG QA Shop | Shopping | 250 | None |
| E | Sep 15 | TAG QA Hotel | Travel | 2,000 | Thailand trip |
| F | Oct 6 | TAG QA Salary | Income (entry kind) | 10,000 | Office |

October spending = **₹2,050 / 4 spend transactions**. Thailand trip = **₹1,500 / 2**. Office spending = **₹800 / 2**. Trip OR Office = **₹1,800 / 3**, not ₹2,300. Untagged spending = **₹250 / 1**. September–October trip spending = **₹3,500**, with monthly bars ₹2,000 and ₹1,500. Income F can appear in Activity but must not inflate spending/tag budgets.

## Data currently seeded in the emulator

On 20 October 2026, eight clearly labeled rows were added to the emulator's **local development test account** through the local API. They are cash entries with `DEMO TAG ·` merchant names and the note `DEMO TAG DATA · local emulator seed · safe to remove`; no hosted data was changed.

| Merchant | Date | Category / kind | Amount | Demo tags |
| --- | --- | --- | ---: | --- |
| DEMO TAG · Bangkok cafe | Oct 2 | Dining / spend | ₹500 | Demo · Thailand trip, Demo · Office |
| DEMO TAG · Bangkok taxi | Oct 3 | Travel / spend | ₹1,000 | Demo · Thailand trip |
| DEMO TAG · Office fuel | Oct 4 | Fuel / spend | ₹300 | Demo · Office |
| DEMO TAG · Untagged online shop | Oct 5 | Online Shopping / spend | ₹250 | None |
| DEMO TAG · Chiang Mai hotel | Sep 15 | Travel / spend | ₹2,000 | Demo · Thailand trip |
| DEMO TAG · Home groceries | Oct 6 | Groceries / spend | ₹850 | Demo · Home |
| DEMO TAG · Home subscription | Oct 9 | Bills & Utilities / spend | ₹199 | Demo · Home |
| DEMO TAG · Salary example | Oct 7 | Other / income | ₹12,000 | Demo · Office |

The October demo expenses total **₹3,099 / 6**; Home is **₹1,049 / 2**; Thailand trip is **₹1,500 / 2** in October; Office spend is **₹800 / 2**. Selecting Office and Thailand trip together gives **₹1,800 / 3** because the café is shared by both tags. The trip becomes **₹3,500** over September–October. The salary appears as money in, not spending. The account had existing transactions before the seed, so whole-account Untagged results also include older rows; the demo shop itself is **₹250 / 1**.

The emulator is currently open to Spending with **Demo · Office** and **Demo · Thailand trip** selected; the visible result is 3 transactions and ₹1,800.

## UI and persistence

| ID | Steps | Expected result |
| --- | --- | --- |
| T01 | Quick Add: create Thailand trip inline; select it and Office; change category/subcategory and payment method | Selected tags remain selected; categories still save as before |
| T02 | Save A; open Activity → A | Two named tag chips are present; amount/category/date/source unchanged |
| T03 | Edit A: remove Office, save, reopen; add it back | Removal persists; totals update; card state not reapplied |
| T04 | Transaction detail: use Add/Edit tags without editing amount | Only tag metadata changes; no financial duplicate or split reset |
| T05 | Tap the Thailand trip chip | Spending opens filtered to that tag; visible scope is clear |
| T06 | Cancel picker; clear picker and Apply; change category alone | Cancel preserves assignments; explicit empty selection removes tags; category change retains tags |
| T07 | Settings: rename Thailand trip to Thailand holiday; change color | ID/history retained; forms, detail chips and filters show updated name/color |
| T08 | Archive tag, toggle Show archived, restore | Hidden from new-tag choices, retained in historical reports/filtering, restored without recreation |
| T09 | Merge two tags used on A, and one on B | Target contains unique A/B assignments; source archived; spend counted once |
| T10 | Activity: select A/B, Add Office, then bulk remove Office from B | Other tags retained; only selected rows change; count and labels refresh |
| T11 | Search tag names; enter blank, duplicate case/spacing, >60 characters | No empty/duplicate active names; length validation shown |

## Filters and charts

| ID | Steps | Expected result |
| --- | --- | --- |
| F01 | October: select Thailand trip; Show results | Preview and page both ₹1,500 / 2; pie has Dining ₹500 + Travel ₹1,000 |
| F02 | Select both trip and Office | ₹1,800 / 3; overlapping A counted once |
| F03 | Select trip + Dining + TAG QA Cafe + Cash | ₹500 / 1 in preview, headline, pie, category, merchant and payment breakdown |
| F04 | Change merchant to TAG QA Fuel while trip selected | Explicit zero results; no stale ₹1,500 values |
| F05 | Choose Untagged | Named tag selections clear; ₹250 / 1; categorized D still counts as untagged |
| F06 | Reset all filters | Original ₹2,050 total restored, all dimensions cleared |
| F07 | Select trip; change range to September–October; change breakdown tabs | Tag selection survives; ₹3,500 total; bars and pie agree; empty month bars remain zero |
| F08 | Tags breakdown; expand trip; tap Dining | Tag total is shown first; expansion lists Dining and Travel totals/counts; selecting Dining opens Activity scoped to trip + Dining + the selected date range, and shows spending only; overlapping tag totals are explicitly non-additive |
| F09 | Filter parent category with a selected subcategory | Parent includes child; child filter excludes siblings; no label-based mismatch |
| F10 | Rename a tag while a report is open on a second device; resume/refresh | Filter follows stable ID and updated label |
| F11 | Add older transactions beyond the first page | Filtered sums include complete requested history; never only first 50 rows |

## Offline, retry, synchronization and accounting

| ID | Steps | Expected result |
| --- | --- | --- |
| S01 | Airplane mode: create a tag, tag an existing transaction, force-stop and reopen | Metadata/assignments remain visible; changes show pending sync |
| S02 | Offline Quick Add with tags; reconnect after restart | One financial transaction and one set of assignments; local outbox ID resolves to canonical ID |
| S03 | Remove a tag offline; view an older cached transaction response | Removed tag does not reappear from embedded stale data |
| S04 | Reconnect and retry sync repeatedly | Same mutation IDs replay safely; no duplicate tags/links/transactions |
| S05 | Device A adds Office; device B adds trip to same transaction | Both assignments survive synchronization; different links do not overwrite each other |
| S06 | Same link edited on two devices with differing timestamps; sync older last | Newer link intent wins server-side; eventual snapshots agree |
| S07 | A new offline transaction cannot sync yet; change tag on another saved transaction | Failed dependent link remains queued; independent changes continue |
| S08 | Create same normalized tag name on two devices offline | Conflict is surfaced/preserved; rename local tag and retry; no silent deletion or discarded intent |
| S09 | Sign out; sign into different account; restart offline | No prior-account tags or assignments are exposed; no old-account writes use new identity |
| S10 | Record current split/receipt/note/card-state values; tag/rename/archive/merge | Split, receipt, note, balances, points, caps and milestones retain original values |
| S11 | Import same payment through SMS, Gmail, manual input; resolve duplicate | Surviving transaction retains explicit tags; total and tag total include payment once |
| S12 | Use old client transaction payload with no tags | Transaction continues saving/reading; no tags required |
| S13 | Tag monthly budget: set trip limit ₹2,000 for October | Spent ₹1,500; remaining ₹500; income F excluded; unrelated budgets unchanged |

## Import and export

| ID | Steps | Expected result |
| --- | --- | --- |
| I01 | Import CSV with Category, Subcategory, Tags columns | Fields parsed separately; tag/label headers no longer become subcategory values |
| I02 | Import review: set default tag for entire import; apply another to selected rows | Source tags retained; selected/default tags union by normalized name |
| I03 | Preview errors, retry same batch, reopen completed import | No duplicate financial rows or links; invalid tag names blocked before submit |
| I04 | Export CSV and JSON; use a tag name containing commas or semicolons | CSV properly quoted; tags encoded as JSON lists; JSON preserves metadata |
| I05 | Import transaction export into a test account | Tag names restored and reused by normalized name; categories/subcategories remain distinct |
| I06 | Existing imports made before this feature | No automatic reinterpretation of their stored categories/subcategories |

Full-account JSON export retains IDs, colors and archived metadata. The existing transaction-import workflow restores **tag names on imported transactions**; it is not an account-clone/identity restore endpoint. Verify any dedicated full-account restore separately before claiming it preserves every original tag ID/color/archive state.

## Layout and failure handling

Test 320px width, large accessibility text, long names, keyboard open, many tags, scroll-to-save, empty lists, loading, API unavailable, 401 recovery, storage failure, and repeated button taps. No overflow or trapped bottom-sheet controls; errors must retain entered data. Keep production data out of these fixtures.

## Automation and release gate

Executed locally during implementation:

- 112 Flutter regressions passed across the affected entry/edit/detail, Activity, import, spending and budgets suites. A further pending-merge regression was added and passed in the final focused run (42 tests).
- Full API suite: 468 passed, with the optional database test skipped in that default run; the real Postgres tag suite was then run explicitly and passed all 3 checks, including client-mutation ID resolution.
- The live local HTTP smoke script `api/scripts/verify_transaction_tags.js` passed tag definitions/assignments, transaction reads, tag-filtered reports, budgets, and CSV/JSON exports. Its temporary account and synthetic data were deleted afterwards.
- Dev APK built and installed using `adb install -r`; existing sign-in/data survived. Launch succeeded. Static analysis reports no errors or warnings, with informational lint/deprecation items still present.
- Emulator UI smoke check: opened an existing transaction, confirmed its Add tags action, and opened the tag picker. The full manual matrix below still needs execution.
- These are automated checks plus a basic emulator launch check; the entire manual matrix above is not marked passed.

- Flutter tests: `flutter test --no-pub test/data/transaction_tags_repository_test.dart test/data/spending_selection_test.dart test/features/insights/spend_trends_screen_test.dart`, plus transaction detail/edit/Quick Add/Activity/import/budget regression suites.
- API: `node --test test/transaction_tags.test.js test/spend_reports.test.js test/statement_import.test.js`.
- Real local Postgres tag checks: set `PANDAPAY_TAGS_TEST_DATABASE_URL` to the local migrated database and run `node --test test/transaction_tags.test.js`. Fixtures are inside a rolled-back transaction.
- Build the dev APK successfully. Record manual emulator results for the matrix above; an APK build or widget test is not evidence that every manual case passed.
- Deploy the additive database migration before the API, then deliver the app. Existing hosted services and the Play internal release need a separate deployment/update; a local APK alone does not update testers' installed release.

Recurring default-tag rules, automatic trip inference, and natural-language tag resolution in a voice assistant are follow-up automation. This implementation supports explicit tags and an ID-scoped assistant summary API; it does not guess contextual tags from messages.
