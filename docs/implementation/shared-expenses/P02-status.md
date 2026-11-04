# P02 handoff: exact domain foundation

Updated 4 November 2026. Owner/writer: root integrator. Packet: **implementing**. Foundation sub-increment: **delivered/tested, awaiting independent review**. Dependency baseline: `sms-v2/integration` @ `bf6bec9b`; test-portability prerequisite commit `9e23201d`. Contract: `1.0.0-foundation`. No app integration or financial persistence is enabled.

Implementation commits: **`2d6163e1`** (Node/contracts/shared fixtures) → **`40d5cd5b`** (matching Dart consumer and JavaScript-target verification). Review both commits together for parity; there is no deployed API dependency because no route is enabled.

## Implemented behavior and owned files

| Behavior | Node | Dart | Shared evidence |
| --- | --- | --- | --- |
| Exact equal/exact/percentage/shares allocation, largest remainders, persisted tie order, 50 beneficiaries and caps | `api/src/shared_expenses/domain.js`, `validation.js` | `packages/pandapay_domain/lib/src/shared_expenses/domain.dart`, `validation.dart` | `contracts/shared_expenses/v1/domain_vectors.json` |
| Up to eight payer contributions, payer-only members, sorted zero-sum positions and deterministic obligation edges | Same domain modules | Same domain modules | You-paid, friend-paid, multiple-payer and paid-for-others fixtures |
| Residual owned source plus recognized personal share, no invented bank movement | `personalCost` | `sharedPersonalCost` | Full/partial sharing, no own source, zero own share, aggregate bound |
| Typed source integer → exact wire string; no floating currency math | `sourceIntToSharedMinor` | `sourceIntToSharedMinor`, checked `sharedMoneyFromMinor` | Shared integer-boundary fixtures plus rejection tests |
| Closed account-owned identity shapes, pending hash/local alias, canonical UUID/version pairs | `api/src/shared_expenses/source_reference.js` | `packages/pandapay_domain/lib/src/shared_expenses/source_reference.dart` | `contracts/shared_expenses/v1/source_reference_vectors.json` |
| Isolated public import and meaningful failure/property tests | `api/test/shared_expenses_domain.test.js`, `shared_expenses_source_reference.test.js` | `packages/pandapay_domain/lib/shared_expenses.dart`, `test/shared_expenses_test.dart` | Both runtimes consume the same 23 expected-result vectors |
| JavaScript-target exactness | Existing Node runtime executes compiled output | Dart2JS compilation of the same 23 vectors and exact Money upper bound | `scripts/check_shared_expenses_web.py`; compiled arithmetic only, not browser UI |

Inputs remain unchanged. Closed schemas reject unknown properties, malformed/oversized/negative/fractional amounts, duplicate members, invalid sums/weights/order/currencies and source alias misuse. Errors contain stable codes/field paths, not private payloads. Pure allocation is bounded O(n log n), positions/edges bounded by membership; no per-paisa loop, network or database scan.

## Test-driven evidence

1. Node allocation tests failed with `MODULE_NOT_FOUND` before creating the module; source-reference tests likewise failed before implementation. Dart test compiled with missing `shared_expenses.dart` errors before creation.
2. Source-integer adapter vectors/rejection tests were added afterward and failed in both runtimes on the absent function, then passed after implementation. No failing result was recorded as a pass.
3. Focused final suites: **36 Node tests passed; 32 Dart tests passed**. Each runtime additionally checks 500 randomized bounded allocations with multiple payers, reconstructing every obligation into the exact member balance. Persisted tie order survives display reordering. Node repeated rounding fixture checks 100 identical expenses.
4. Final full `pandapay_domain` suite: **1,036 passed**, zero failures. Scoped new-code analyzer: **no issues**. Final API `npm test` (including syntax checks): **1,445 passed, nine skipped**, zero failures. Separate SMS v2 API suite: **102 passed, 34 skipped**, zero failures. Skipped database tests do not establish storage correctness.
5. Dart2JS compile/run: **all 23 common vectors passed** on Node, including checked Money at `9007199254740991` and rejection of the next integer. This checks the JavaScript calculation target, not real browser/app UI or production throughput.
6. Updated HTML validated for 113 inventoried screens, links, unchanged navigation/tab/font contracts, search/filters, print restoration, reduced motion and widths 320/360/430/768/1024/1440. No browser runtime errors. This is documentation verification, not Flutter screen verification.

### Repeatable commands

From repository root:

```powershell
node --test api/test/shared_expenses_domain.test.js api/test/shared_expenses_source_reference.test.js
python scripts/check_shared_expenses_web.py --dart <path-to-dart-executable>
```

From `api`:

```powershell
npm test
node --test test/sms_v2/*.test.js
```

From `packages/pandapay_domain`, use the current checked-in package dependencies:

```powershell
dart test
dart analyze lib/shared_expenses.dart lib/src/shared_expenses test/shared_expenses_test.dart
```

On this sandbox the direct SDK executable was `C:\flutter\flutter\bin\cache\dart-sdk\bin\dart.exe`; process-scoped `APPDATA`/`LOCALAPPDATA` pointed to the existing repository-local `.flutter-direct-appdata3`, and `PUB_CACHE` to the existing `.pub-cache`. `dart pub get --offline` refreshed stale package metadata without changing dependency versions. API `npm ci` used the existing lockfile, disabled install scripts and a task-local npm cache. No lockfile changes resulted.

### Baseline regression fixes, kept separate

Initial full Dart run: 1,025 passed and four failed to load/build fixture bundles. The instrument/linker golden loaders and common rules helper checked `senders/` against Windows `senders\...`, misclassifying sender entries as rules. Normalize the relative separator exactly as `tools/sms_rules_cli/lib/rules_source.dart` already does. The existing API SMS v2 frontmatter assertion also assumed LF in a CRLF checkout; normalize line endings before its unchanged semantic assertion. Commit `9e23201d` changes three Dart test helpers and one Node test only. No production parser/rule/fact changes.

The intermediate full Dart run then passed 1,032 tests; the SMS v2 API run passed 102 and skipped 34. Final counts include the four additional source-integer adapter tests per runtime. Initial raw logs and final logs are retained under the thread visualization directory; this handoff summarizes them so it remains usable without private chat history.

## Scenario coverage boundary

Domain assertions support the **calculation portions** of M01–M11, M14 and V14. The identity-shape portions of V01/V02 are exercised; confirmed foreign reference shape is covered, but V12 funding/valuation admission is not. C01/C02/C04/C05/C11/C13 expected examples are represented where named in fixture IDs. This does **not** complete any full UI/API/DB scenario: consent, source ownership/version/remap, bank/reward reporting, persistence, source eligibility and notifications still require their owning packets.

## Review and next owner

### Subsequent journal increment, 4 November 2026

- Added `api/src/shared_expenses/journal.js` and matching Dart `src/shared_expenses/journal.dart`, [scoped journal contract](../../contracts/shared-expenses-v1/journal.md) and shared `journal_vectors.json`. Tests were written and failed before implementation in both runtimes.
- Confirmed-payment deltas are separate from expense revision deltas. Partial settlement, explicit overpayment credit, decrease/void after settlement, refund counterparties, payment reversal and circular obligations preserve original payment effects. Settlement allocation is bounded and follows persisted selected obligation order.
- Root focused suites: **18 Node journal tests and 18 Dart journal tests passed**; combined existing/new Node domain/source/journal: **54 passed**. Dart2JS common expected-result fixtures increased from 23 to **36**, all passed, plus Money bounds. Scoped new Dart journal analyzer: no issues.
- Independent P04/P05 agent review found a gross-overflow gap in a zero-net circular graph and a future frozen-edge compatibility risk. Added failing Node/Dart reproductions, then checked context gross as well as pair/member net limits. SQL persists `pair_v1` and frozen prior edges; corrections subtract stored edges. Pure v1 matching must not silently change in future versions.
- Full domain run under concurrent Flutter/Docker work hit two existing SMS timing benchmarks. Those timing failures are not a green full-suite claim; isolate/recheck under controlled scheduling before recording the next full regression result. Functional journal checks passed. No SMS production source changed in this increment.

The journal helpers remain pure. Authenticated SQL commands and local immutable operation queues are separate P01/P03/P05 implementations undergoing integration; source funding, UI entry/report integration and release/device acceptance remain incomplete.

Root self-review: correctness and conservation, readability, isolation from existing financial/source modules, strict input/error privacy and bounded processing checked. Independent reviewers are currently unavailable due to agent usage limits; no independent approval is claimed. Next reviewer leases only these foundation paths and checks the public contract and expected results before P03/P06 consumes them.

Remaining P02: accepted journal/revision recognition, partial/overpayment and settlement allocation, exact refund/correction/reversal behavior, recognition-period fixtures and DB-backed property/race reconciliation with P01/P03/P09. These functions preview one snapshot; they do not constitute that journal. General multi-currency settlement/gifts/write-offs remain unsupported.

No Flutter UI was wired, no device was installed/tested, no PostgreSQL migration was applied, no source cutover happened and no deployment/push occurred in this increment. Existing split storage, pending edits, rewards and source histories were not rewritten. Continue with [P00 gates](P00-status.md) and [the implementation register](README.md).
