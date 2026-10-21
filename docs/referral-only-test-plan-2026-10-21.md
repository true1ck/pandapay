# PandaPay referral feature: test specification and release evidence

Prepared 21 October 2026 for the [implementation plan](referral-only-implementation-plan-2026-10-21.md).

Status: the new-feature cases below are required tests to implement, not tests that already pass. The baseline section records checks actually run during planning. A green unit suite is insufficient to claim the referral/credit flow works online.

## 1. Current baseline

| Command/check | Actual result on audited working tree |
|---|---|
| API: npm test | 470 tests: 469 pass, 1 skip, 0 fail; includes configured syntax checks |
| Auth: npm test | 38 pass, 0 fail |
| App: flutter test --concurrency=1 --reporter expanded test/features/auth test/features/onboarding test/app/router_onboarding_test.dart | 31 pass, 6 fail |
| Existing synthetic actual-source security probes | Eight documented conditions still reproduce with mocks; no live requests or database access. reproduced=true means a finding, not a security pass |

Focused Flutter failures to diagnose before changing signup:

| File | Failing test |
|---|---|
| app/test/features/auth/consent_checkboxes_test.dart | a successful sign-up writes one POST /consents call per purpose — observed pumpAndSettle timeout |
| app/test/features/auth/account_recovery_autofill_test.dart | verified email shows masked phone without activating a session |
| app/test/features/auth/account_recovery_autofill_test.dart | phone recovery shows masked email and replaces it only after a new code |
| app/test/features/auth/account_recovery_autofill_test.dart | failed linked-contact lookup retries without consuming the OTP again |
| app/test/features/auth/account_recovery_autofill_test.dart | second check returns to sign-in without activating recovery tokens |
| app/test/features/auth/emergency_card_nav_test.dart | the auth screen does not expose a guest or emergency bypass — expected account button was absent |

Do not skip these tests or replace behavioral assertions with unconditional success. Diagnose network/plugin/provider setup, animation pumping and actual product changes separately. The four recovery failures need their full individual error output when triaged; this plan does not assert a common cause. Preserve supported login, recovery, consent and onboarding behavior while fixing the test harness or code as warranted.

Local toolchain was Flutter 3.44.8, Dart 3.12.2 and Node 24.15.0. Repeat release CI with its configured Node 22 as well. No full Flutter suite, signed-app device run, new-feature DB integration or production probe was completed during this planning task.

## 2. Test layers and proposed files

| Layer | Proposed suite | Responsibility |
|---|---|---|
| Node unit | api/test/referral_rules.test.js | Invitation normalization, immutable rules, date runs, eligibility, boundaries, state transitions |
| Node unit | api/test/reward_distribution.test.js | Cumulative intervals, invalid configs, integer money, deterministic bucket tests |
| Node HTTP contract | api/test/product_access.test.js; api/test/referrals.test.js; api/test/subscription_credits.test.js | Real route handlers with controlled service failures, subject checks and stable response/error contracts |
| Auth regression | auth/test/verified_identity.test.js plus dedicated linking/session/OTP suites | Current identity, verification, linking, revocation and single-use proof contract |
| SQL integration | db/tests/[unique-version]_referral_permissions_test.sql | Actual roles/RLS/function ownership, constraints and grants after every migration/setup runner |
| Real-DB Node integration | api/test-db/referral_activation.test.js; referral_concurrency.test.js; referral_reconciliation.test.js; credit_redemption.test.js | Transactions, locks, unique keys, partial failures and reconciliation against disposable PostgreSQL |
| Flutter repository/unit | app/test/data/referrals_repository_test.dart; subscription_credits_repository_test.dart; pending_invitation_test.dart | DTO parsing, paise, auth retries, stable operation IDs, local subject scoping |
| Flutter widget/router | app/test/features/referrals/; app/test/features/subscription_credits/; app/test/app/router_referral_access_test.dart | Every state, navigation, errors, accessibility, reduced motion and account switching |
| End-to-end | app/integration_test/referral_journey_test.dart plus scripts/referral_smoke_test.[chosen runtime] | Real auth/API/DB flow, exact counts/balances, no mocked financial persistence |
| Native/device | Recorded Android/iPhone link and lifecycle matrix | Signed associations, install transitions, cold/warm launch, real OTP, process kill |
| Store sandbox | Platform-specific purchase/offer tests | Supported benefit, purchase verification, account binding, repeat eligibility, lifecycle and reconciliation |

Names are proposed and may be adapted to established repository conventions. Database integration must be an explicit CI job; an unset connection URL must fail that job rather than turn every new test into a skip.

Use a dedicated compose project and isolated, marked test databases. Test scripts must refuse an unmarked/non-test target and must not reuse a developer's default database URL. Do not start local test stacks in a way that rewrites existing volumes or points services at production. Test seeds/cleanup are restricted to that disposable environment.

## 3. Fixture and clock contract

Use synthetic accounts A (inviter), B (referee), C (unrelated/second inviter), D (second referee), plus legacy_member, pending_identity, suspended_member, server_guest and anonymous.

Seed real OTP/auth identities in the integration environment using its supported test-only provider. At least one end-to-end suite must verify the real JWT issuance and bootstrap flow, rather than signing arbitrary access tokens inside every test. Include expired/revoked tokens, not just missing tokens.

Campaign fixture:

~~~text
calendarZone: Asia/Kolkata
requiredConsecutiveDays: 3
qualificationWindow: 30 elapsed days
receiptLifetime: 5 minutes
credit/spin expiry: none
prizes: 1000 paise / 70 weights; 2000 / 25; 5000 / 5
budget per reward-eligible pair: reserve maximum 10000 paise
~~~

Date fixture:

~~~text
B activation: 2026-10-21T04:30:00Z = 21 Oct 10:00 IST
day 1 action: 2026-10-21T04:35:00Z
day 2 action: 2026-10-22T04:35:00Z
day 3 action: 2026-10-23T04:35:00Z
deadline:     2026-11-20T04:30:00Z
expiry sweep must respect the additional valid-receipt grace interval
~~~

Inject a clock and RNG into unit tests. For DB/E2E, seed dated server facts through a test fixture connection or run a test-only service clock; the production configuration must refuse a test clock/RNG. No public date/forced-prize/debug endpoint, client timestamp or HTTP header can override production time/outcomes. Verify that negative test requests trying these controls are denied or ignored without effect.

For spinner tests, stub the draw rather than relying on statistical sampling. With totalWeight=100, draws 0–69 select 1000, 70–94 select 2000, 95–99 select 5000. Test every interval boundary. A frequency smoke check may supplement these assertions; it is not proof of an unbiased RNG.

For the interactive wheel's `bamboo-spin-v1-2026-10` defaults, totalWeight is 10,000. Assert weights for ₹0 = 1,000; ₹5 = 2,500; ₹10 = 2,500; ₹25 = 2,000; ₹50 = 1,000; ₹75 = 500; ₹100 = 300; ₹150 = 100; ₹200 = 50; ₹300 = 30; ₹500 = 20. Therefore ₹0–₹100 totals 9,800 (98%), amounts above ₹100 total 200 (2%), and ₹500 is 0.2%. Assert exact interval boundaries with a stub RNG, including the first and last draw for each bucket. A ₹0 spin must persist exactly once, release the full reservation, create no zero-delta wallet ledger row, send a completion event, and leave available credit unchanged. The maximum liability is ₹1,000 per pair; expected value is ₹49.80 per pair. The campaign seed remains inactive and unfunded.

## 4. Identity, access and attribution cases

| ID | Scenario | Required observation |
|---|---|---|
| A01 | Anonymous or malformed/expired token calls a private route | 401; no profile, membership, referral, day or ledger event |
| A02 | Valid pending identity calls /profile in invite_only mode without code | invitation_required; no product profile/membership; authentication may remain pending |
| A03 | Pending identity directly calls card, transaction, sync, check-in, referral or credit routes | Membership denial for every private route; no partial writes |
| A04 | Server guest JWT, including a validly signed one, attempts activation/private calls | Denied; no activation or financial writes |
| A05 | /auth/signup, alternative sign-in route or client is_signup=false is used | No route can grant product access without verified identity plus membership/invitation |
| A06 | Valid code, verified identity and correct terms | One profile/membership/attribution; correct inviter, version/deadline; two maximum-liability reservations |
| A07 | Same activation submitted repeatedly, concurrently or after lost response | Same attribution; no duplicate budget reservation, consents or joined event |
| A08 | B submits A's code and C's code concurrently | One globally unique referee attribution; winner remains immutable; loser returns existing result/conflict without second reward enrollment |
| A09 | Existing activated account or reinstalled B submits another code | No re-attribution, new-user bonus or duplicated membership; normal sign-in works |
| A10 | Invalid, revoked, inactive, self or unsupported-format code | Safe failure and no rows; format is normalized only by documented rules |
| A11 | A is suspended, unapproved to invite, or new onboarding is incomplete | Code cannot grant new access under inviter-eligibility rules; legacy grandfathering is deliberate |
| A12 | Existing member logs in/recovers when new admissions are paused | Existing access/recovery remains usable; no referral required |
| A13 | Auth-only old identity without a product profile | Requires invitation unless explicitly present in trusted grandfathering list |
| A14 | Campaign/preview changes or budget/cap fills between preview and activation | offer_changed before profile creation; explicit updated acceptance can join access-only; no silent loss of offered reward |
| A15 | Two new users compete for the last reward budget/cap slot | Exactly the reserved capacity enrolls; budget never exceeded; other gets explicit updated terms |
| A16 | Campaign enrollment paused after B already enrolled | B's frozen terms remain fulfillable; A cannot silently acquire newly promised rewards |
| A17 | A invites B, then B invites C after onboarding | A/B qualify only for B's mission; B/C qualify only for C's mission; no downline credit |
| A18 | Identity service timeout, DB timeout, failure before commit or committed response loss | Correct pending/retry state; no OTP re-consumption required for bootstrap retry; no partial attribution |
| A19 | Profile request contains another subject/contact/verified flag | Subject and verified identity come from trusted session/auth service; body cannot change ownership/eligibility |
| A20 | Required terms absent/wrong version; optional marketing/crowdsource declined | Required terms block enrollment as specified; optional consent choices never block reward eligibility |
| A21 | Logout-all, account disablement/deletion or device-session revocation | Sensitive operations denied within documented revocation bound; no known-invalid-session grace for spin/redemption |
| A22 | Contact linking/lookup/OTP verification regression suite | Existing account control cannot be established from an unrelated contact proof; identity uniqueness and OTP consumption hold under concurrent requests |
| A23 | New auth ID reuses an already rewarded verified channel within campaign retention | Eligibility claim prevents a second new-user award; access/recovery behavior remains explicit; no raw contact stored in campaign records |
| A24 | Shared household/IP/device, changed email, fingerprint key rotation and lawful erasure | No unsupported unique-human claim or automatic household ban; rotation preserves intended reuse checks; retention/erasure follows approved rules |

A01–A05/A21 are table-driven across the actual private route registry. Do not assume protecting the visible signup screen or only the new /rewards routes protects transactions/sync and bootstrap.

## 5. Native link, installation and pending-state cases

| ID | Scenario | Required observation |
|---|---|---|
| L01 | Android prod app installed, cold/warm invitation tap | Exactly one validated candidate reaches signup; no raw URI/duplicate route push |
| L02 | Android install from the actual Play test track after referral landing | Correct referrer payload when available; later authenticated attribution matches it |
| L03 | Android sideload/no referrer service/empty or malformed payload | Manual/return-link fallback; no guessed inviter |
| L04 | Production Play signing certificate differs from upload/debug key | Hosted asset association matches the installed signed package; verify native link status |
| L05 | iPhone installed, cold/warm Universal Link, app suspended/terminated | Correct invitation and one listener; actual signed Associated Domains entitlement works |
| L06 | iPhone fresh install through App Store/TestFlight | Explicit code/reopen-link path succeeds; no claim that URL parameters automatically survived installation |
| L07 | Code copied manually with user action | Accepted after validation; no silent clipboard polling or sensitive content logging |
| L08 | New link arrives during OTP; process is killed; OTP resent | Existing selected invitation remains visible unless user explicitly replaces it; no accidental late overwrite |
| L09 | Candidate on device, then existing A logs in instead of new B | A is not re-attributed; no reward earned for A; pending candidate handling avoids applying A's choice to another account silently |
| L10 | Staging app and prod app installed together | Correct distinct package/domain association; staging rewards never enter production |
| L11 | Assistant spending link, normal launcher and unknown/malicious URI | Assistant still works; invitation handler rejects unapproved hosts/paths and open redirects |
| L12 | Domain file missing/wrong content type/redirect/CDN cache delay | Diagnose and record failure; fallback code remains usable; release link gate stays red |
| L13 | Person clicks/share-preview crawler opens URL, never activates | No named joined referral or install milestone is created |
| L14 | New user has a valid invite but lacks closed-testing enrollment | Store availability is handled clearly; invitation cannot replace tester enrollment |

Record actual package/bundle IDs, certificate fingerprint, domain verification status, OS/app version, build channel and a short screen recording. Android v1 source package is app.pandapay.pandapay; verify the release configuration rather than guessing iOS Team ID or signing fingerprints.

## 6. Bamboo activity cases

| ID | Scenario | Required observation |
|---|---|---|
| E01 | B performs valid foreground actions on the three fixture dates | Day counts 1, 2, 3; qualified_at set once; A/B each receive one entitlement |
| E02 | Many actions/check-ins on one date, two devices and retries | One daily row; no second day or duplicated qualification |
| E03 | Days 1, 2, 4, 5, 6 | Day 4 restarts at 1; day 6 qualifies once |
| E04 | Latest action yesterday/two days ago | Current run remains yesterday's value while today is available; expires when a whole date is missed |
| E05 | Sign-up/OTP only, before required setup/core action | Joined, but 0/3 activity; no automatic day from authentication |
| E06 | Import 90 days of transactions in one foreground action | At most one activity day; existing transaction streak does not qualify referral |
| E07 | Automatic SMS/email import, background sync or push delivery | No engagement receipt/check-in day from background workflow |
| E08 | Historical/future transaction timestamps, zero spends, refunds, transaction deletion | Cannot create historical/future activity; normal later transaction changes do not revoke completed engagement |
| E09 | Phone clock/timezone changes and client date/count/level fields | Campaign calendar and server activity timestamp determine outcome |
| E10 | 23:59:59 / 00:00:00 IST, month/year/leap-day boundary | Correct distinct calendar dates; no UTC 05:30 split; year totals use correct ranges |
| E11 | Receipt issued just before midnight, submitted just after midnight | Counts the signed server action date; next real action on next date can count separately |
| E12 | Valid receipts arrive out of order across midnight | Recalculation from daily facts converges on the same run and one qualification |
| E13 | Receipt forged, wrong subject/purpose/key, expired or far future | Rejected without activity/qualification; no decoding-only trust |
| E14 | Receipt replayed same date, next date and for another user | Never earns an additional day |
| E15 | Offline pending interaction with no valid receipt | No optimistic confirmed day; reconnect cannot backdate an unproved session |
| E16 | Completing action just before deadline, receipt submitted within valid grace | Qualifies even if processing crosses deadline; expiry worker cannot release its reservation early |
| E17 | Action exactly at/after deadline or submission after receipt expiry | Does not qualify; consistent half-open boundary and eventual reservation release |
| E18 | Third-day requests concurrent, with worker/retry/process failure | One qualified transition, exactly two entitlements and one event per beneficiary; rollback/retry consistent |
| E19 | User misses dates after already qualified | Earned qualification/entitlements remain; current run can differ from permanent milestone |
| E20 | Campaign version edited/new version starts | Existing enrollment's rules/calendar/distribution stay unchanged |
| E21 | No optional card, SMS, notification or marketing permission | Supported core-use path still allows the same mission on Android and iOS |

Rate limiting and authenticated receipts do not prove a unique human. Test automation/abuse detection separately and report its limits; do not label the streak bot-proof.

## 7. Entitlement, spinner and financial concurrency cases

| ID | Scenario | Required observation |
|---|---|---|
| R01 | A/B open rewards before qualification | No ready spin; Joined/progress visible |
| R02 | Qualified pair | Two role-bound entitlements; each account sees only its own claimable reward |
| R03 | A/C tries B's entitlement or client swaps beneficiary | Non-disclosing denial; no state/balance change |
| R04 | 20 concurrent spin requests for one entitlement, using same and different request IDs | One spin ID, one amount, one ledger award, one budget settlement; every successful reply refers to that result |
| R05 | Commit succeeds, HTTP response is lost; app killed/reinstalled | Fetch/retry recovers same result and balance without a second draw/credit |
| R06 | Fault before each write/commit, DB disconnect or rollback | No partial spin/ledger/balance/claim state; retry succeeds once |
| R07 | Campaign config changes or enrollment is paused while a spin is pending | Frozen distribution honored; new enrollment toggle cannot reroll/cancel a committed result |
| R08 | Client sends amount, probability, random seed, forced bucket or ready=true | None can select value or bypass readiness |
| R09 | Invalid empty/negative/fractional weights, unsupported amount, overflow or mismatched version/hash | Config rejected before enabling campaign; no runtime partial award |
| R10 | Every cumulative bucket boundary for fixture distribution | Exact expected bucket with no gap/overlap; Node crypto RNG used in production |
| R11 | One user claims, the other waits indefinitely | Balances/results independent; outstanding maximum reservation retained under no-expiry terms |
| R12 | Emergency fulfillment hold/unhold | No new result while held; explicit status; committed result/ledger immutable; recovery does not double award |
| R13 | Qualified friend deleted, suspended or under fraud review | Defined hold/reversal policy with audit; no cascade deletion or negative available balance |
| R14 | Unqualified referral expires with worker retry | Reservation released once, attribution remains historical; no spin created |
| R15 | Mixed activation/spin/expiry/redemption load | No over-budget enrollment, negative balance, unbounded lock wait or deadlock retry loop |

Account/ledger tests:

| ID | Scenario | Required observation |
|---|---|---|
| W01 | Several awards, reserve/redeem/release and reload | Exact integer-paise arithmetic; available/reserved match ledger-derived deltas |
| W02 | Fractional rupees/sub-paise input, JSON BigInt edge, huge amounts | Invalid mutation values rejected; DTO precision preserved via decimal-string paise |
| W03 | Concurrent redemptions exceed available balance | Only affordable operations reserve; totals never negative |
| W04 | App_user writes tables/functions or sync payload includes promotion entities | No award, ledger edit, balance edit or membership grant possible |
| W05 | Rerun setup_app_role plus fresh/upgrade migration runners | Restrictions remain; PUBLIC/inherited privileges cannot restore forbidden writes/execute |
| W05b | Direct profile INSERT/upsert, legacy code mint and profile/sync alternative paths | Ordinary runtime role cannot create membership indirectly; supported profile update and old GET response remain compatible through trusted routines |
| W06 | User/account deleted; retention job runs | Friend labels removed, required audit pseudonymized/retained by policy, no accidental financial-history cascade |
| W07 | Fraud reversal after partial/full redemption | Only supported unspent reversal applied; unresolved spent value recorded for review, not fabricated negative credit/cash debt |
| W08 | Year filters, pagination, same timestamp/ties, December join/January award | Stable pages, no missing/duplicate referral; joined and awarded totals use their distinct dates |
| W09 | Credit screen offline, account switched, stale push received | Cached state labeled and subject-scoped; no mutation from push/cache and no old user's balance leaked |

## 8. Subscription redemption tests

These gates remain pending until the actual product/offer design exists. A mocked payment response does not prove the store permits or supports it.

| ID | Scenario | Required observation |
|---|---|---|
| S01 | No supported benefit/product/platform capability | Clear unavailable state; zero credit reserved/spent |
| S02 | New, current, expired/lapsed subscriber and repeated referral rewards | Actual store eligibility matches displayed benefit; no assumption of unlimited code reuse/stacking |
| S03 | Expired quote, changed terms/price, wrong platform/region | Refresh quote before debit; no unexpected charge |
| S04 | Reserve, cancel before external grant, confirmed failure | Exactly one reserve/release pair; available restored only when benefit cannot still redeem |
| S05 | Successful internal reward-funded entitlement under supported design | Debit and access grant commit once; remaining credit preserved |
| S06 | Successful store offer/purchase | Verified product, offer, environment and account; one debit and benefit; store renewal terms correct |
| S07 | Store sheet shown, user cancels or pays normal full price | No false discount-credit debit; pending operation reconciles correctly |
| S08 | Lost response/process kill while external outcome unknown | Stable redemption ID recovers; reserve not prematurely released |
| S09 | Offer code issued, app times out, code redeemed later/outside app | Remains pending until a safe final outcome; no spend twice or refund-plus-benefit |
| S10 | Code/purchase cannot be reliably tied to the PandaPay beneficiary | Adapter disabled for this design; no claim of account-bound redemption |
| S11 | Duplicate/out-of-order/delayed provider notifications and store API failures | Idempotent eventual final state; old event cannot undo newer state incorrectly |
| S12 | Spoofed webhook/receipt, sandbox token on prod, wrong bundle/package or reused purchase across accounts | Rejected; no access or debit |
| S13 | User switches PandaPay/store account mid-flow; purchase restored on another device | Documented account ownership honored; no transfer/double spend |
| S14 | Refund/revocation, cancellation versus expiry, grace period and renewal | Access and credit follow the agreed rule; cancellation alone not mistaken for immediate expiry |
| S15 | Paid subscriber skips referral/engagement tasks | Already purchased benefits remain available; referral mission is optional |

For iOS TestFlight/device and Android Play license-testing runs, use synthetic non-production awards and store sandbox/test products. Do not compensate people for TestFlight participation with redeemable rewards. A production paid-subscription test, if later authorized, needs an explicit account, amount and refund plan.

## 9. Notification, operations and migration cases

| ID | Scenario | Required observation |
|---|---|---|
| O01 | Notification provider down during qualification/spin | Financial transaction commits correctly; outbox retries; app reads canonical reward without waiting for push |
| O02 | Worker crashes before/after dispatch/lease expiration | Replay deduplicates per-beneficiary notification; no award duplication |
| O03 | Two worker instances and backlog/dead-letter | Bounded lease/retry, useful heartbeat/age alerts, no silently abandoned event |
| O04 | New admission paused / new reward enrollment paused / fulfillment paused / redemption paused | Each documented effect tested separately; existing login and balances survive |
| O05 | Campaign budget exhausted, cap hit or abuse flag raised | Deterministic enrollment/hold state, honest UI, auditable reason; no promise silently broken |
| O06 | Blank DB, legacy-only DB, current-upgrade DB and rerun | All required tables/functions available; old profiles grandfathered; migration ledger correct |
| O07 | Duplicate/conflicting legacy referral or qualified-but-unfunded record | Quarantined/preserved, no automatic money/credit creation and no guessed winner |
| O08 | Deploy/restart midway through transition; old app version connects | Compatible response or actionable required upgrade; no old-client gate bypass |
| O09 | Auth migration needed for P0 | Fresh and existing auth DB both upgraded by an explicit versioned runner; modifying init.sql alone is insufficient |
| O10 | Feature rollback after legitimate awards | Pause/forward correction preserves immutable awards, balances and evidence; no destructive schema rollback |
| O11 | Admin edits campaign version/adjusts credit/holds account | Authorization and reasoned audit; no direct spin result edit; ordinary member denied |
| O12 | Reconciliation mismatch deliberately seeded in disposable DB | Alert/fail gate; do not auto-rewrite historical ledger to make counters match |
| O13 | Logs, metrics and analytics observed during all failure paths | No OTP, auth token, full contact/message, raw financial data or reward-secret material in telemetry |
| O14 | Restore rehearsal for both product and auth databases | Membership/attribution/ledger/session ownership recover coherently; worker can reconcile without re-awarding |

## 10. State assertions after the happy path

The smoke test checks values and durable rows, not only HTTP status codes:

1. A's code resolves to A. B's authenticated activation creates exactly one attribution to A and one active membership. C cannot read or change it.
2. Day 1 and day 2 show 1/3 and 2/3 with no ready entitlement or credit.
3. Day 3 yields exactly two entitlements, one per role; no credit exists until each claim occurs.
4. Force the test RNG to return the INR 10 bucket for A and INR 20 bucket for B. A receives 1000 paise; B receives 2000 paise. They have different entitlement IDs, their own spin/ledger IDs, and no access to the other's claim.
5. Retrying both claims changes neither balance nor spin ID. Reloading/restarting preserves them.
6. Budget changes from 10000 reserved paise for this pair to zero reserved and 3000 issued paise after both fixture spins. No other pair's reservation changes.
7. A uses a supported 1000-paise benefit: available moves 1000 -> 0, reserved 0 -> 1000 -> 0 after verified success. Exactly one benefit is granted. B stays at 2000 available.
8. An alternate cancellation test reserves/releases once and grants no benefit. Do not execute success and cancellation for the same finalized redemption as if both were possible outcomes.
9. In-app history and year totals match the ledger and the referral dates. Outbox notifications can lag without changing any result.

Reconciliation invariants to implement as actual DB-backed assertions after DDL is finalized:

~~~text
each qualified, reward-eligible attribution has exactly 2 entitlements
each entitlement has at most 1 spin
each committed spin has exactly 1 award event keyed by that entitlement
each award amount equals the committed spin amount and belongs to its beneficiary
account.available == sum(ledger.available_delta)
account.reserved == sum(ledger.reserved_delta)
account.available >= 0 and account.reserved >= 0
campaign.issued + campaign.reserved <= campaign.total_budget
reservation settlement/release has exactly 1 final business operation
each committed redemption has exactly 1 matching debit and verified benefit
no inviter can view a friend's contacts, spending or private ledger
~~~

## 11. CI and release gates

All gates are required for the capability being enabled. Leave an unimplemented capability disabled; do not label it tested.

| Gate | Evidence required |
|---|---|
| G0: baseline/identity | Existing focused tests repaired; full app/console/domain checks run for affected release; relevant identity regression conditions no longer reproduce |
| G1: migration/roles | Empty+upgrade tests, real role/RLS tests after role setup, verified auth schema upgrade path where needed |
| G2: backend contracts | Admission, qualification, spins and credits unit/HTTP cases pass under configured CI Node runtime |
| G3: real persistence | Disposable PostgreSQL concurrency, failure injection, worker and reconciliation cases pass without skips; E2E uses actual auth/API/DB |
| G4: app behavior | Widgets/router/repositories and Android/iOS integration flow pass; stale/offline/account-switch states covered |
| G5: native distribution | Actual signed-track/device L01–L14 evidence, association files and manual-code fallback |
| G6: time soak | At least one real three-date Android/iPhone paired journey; test clock results supplement rather than replace this |
| G7: redemption | Supported platform/benefit sandbox tests and accounting pass before marketing usable subscription credits; economic/terms decision recorded |
| G8: operations | Worker installed/healthy, dashboards/alerts, configured caps/budget, backup/restore and pause/rollback rehearsal |
| G9: release record | Exact API/auth SHAs, schema versions, app version/build/signing channel, campaign version/terms and test evidence attached |

Use Android-to-Android, Android-to-iPhone, iPhone-to-Android and iPhone-to-iPhone inviter/referee combinations. Share one campaign backend; verify no platform combination changes attribution or the mission. Include at least one new install and one existing member/recovery journey.

Suggested pilot observations: activation completion rate, valid-code denial rate, un-attributed activations, check-in and qualification processing latency, spin request/result count versus unique awards, balance/budget discrepancies, external-pending redemption age, worker heartbeat/outbox backlog and crash-free onboarding. Reconciliation discrepancies must be zero before expansion; latency targets should be set from the actual deployed infrastructure and then tested, not asserted from this plan.

## 12. Completion report format for the implementer

For each package in the main plan, record changed files, migration IDs, executed commands/results, test IDs covered, skipped/blocked cases, device/store evidence and enabled flags. Separate “implemented,” “tested in disposable environment,” “tested on signed devices,” and “verified online.”

Do not write “everything works” when only mocks or unit tests were run. The user should receive the exact remaining limitation and the capability that stays disabled until its gate passes.
