# PandaPay invite-only access, Bamboo referrals, spins and subscription credits

Verified implementation handoff — 21 October 2026

Status: planning and source verification complete; feature implementation and production verification remain outstanding. Audited checkout: master, HEAD d95aa29, with unrelated local activity/payments edits present. This document supersedes the earlier chat plan where they differ.

Companion documents:

- [Test specification and online release gates](referral-only-test-plan-2026-10-21.md)
- [Luna implementation handoff](referral-only-luna-handoff-2026-10-21.md)

## 1. Outcome and boundaries

After closed testing, a new user needs a valid invitation to activate a PandaPay account. The inviter can see that a friend joined and the friend's Bamboo progress. Three consecutive days of eligible app use qualify the referral. Both people receive one spin. Each person's server-selected result is added to a separate subscription-credit balance. A later redemption uses a supported subscription benefit and never spends the same credit twice.

The existing app can continue to offer login/recovery to existing users. An invite cannot enroll somebody in a Google Play closed-testing group, grant TestFlight access, prove that somebody installed the app, or modify their store account balance.

No production database, domain association, installed release, store-console setup or live subscription product was inspected for this verification. Existing automated tests do not establish that this new feature works online. The companion release gates define the evidence required to make that claim.

## 2. Corrections to the earlier plan

| Earlier statement or omission | Verified correction | Consequence |
|---|---|---|
| Referral rewards were planned without an access gate | Invite-only product activation also needs server enforcement | Implement membership checks and guarded profile creation before enabling invite-only mode |
| Reuse the current streak for three days of app use | Current /home-summary streak groups transactions by occurred_at; historical imports can supply several days at once | Build an engagement streak for Bamboo; retain a distinct name for transaction-logging history |
| Current streak already means valid positive spend | The SQL filters active spend rows, but not positive amounts or future transaction dates | Do not treat this query as reward qualification evidence |
| Both stores effectively require the same credit implementation | Google expressly permits earned/awarded points to be exchanged for digital goods/services; Apple needs its own supported offer design | Keep platform redemption adapters separate; see section 4 |
| Google prohibits one-time referral credits because subscriptions need recurring value | The cited rule concerns selling subscriptions whose benefit is effectively a one-off item; it does not itself prohibit free referral rewards | Remove that inference |
| A free spinner is necessarily allowed, or necessarily forbidden | Available policies do not settle the exact proposed promotion's classification | Keep a configurable spinner; launch random rewards only after reviewing the actual rules and markets |
| One referral per referee is already guaranteed | UNIQUE(referrer_id, referee_id) allows different inviters to claim the same referee; NULL referees also do not establish attribution | Add a global referee uniqueness invariant for the new program |
| Revoking writes in the migration is sufficient | setup_app_role.sql grants writes on all public tables and execution on all public/pandapay functions after migrations | Use a restricted promotions schema and fix grants in every runner |
| Current UI “earned” means a funded credit | The UI uses a qualified flag and the current program amount; no credit ledger exists | New totals must come from committed ledger entries |
| A referral link automatically survives a fresh iPhone install | Universal Links handle installed-app routing; this does not establish deferred attribution after App Store installation | Provide a return-to-invitation/manual-code path |
| Turning off one is_active flag handles all situations | Admissions, new reward enrollment, fulfillment and redemption have different effects | Give each control a defined, separately tested meaning |

## 3. Current implementation: verified evidence

Paths below are relative to the repository root; line numbers refer to the audited checkout.

| Component | What exists | Gap or implication |
|---|---|---|
| db/supabase/migrations/0026_referrals.sql:18 | Program config, per-profile code, pending/signed_up/qualified referral rows | Fresh-install seed advertises INR 100 each and first ranked payment. These are legacy seed values, not verified production settings or approved new economics |
| api/src/index.js:7293 | GET /referrals; lazy code creation and list query | No attribution, milestone, spin or credit mutation flow found; code generation uses Math.random |
| app/lib/features/referrals/invite_friends_screen.dart:73 | Shares https://pandapay.app/i/CODE | No matching invitation route/native association in the checked sources; external hosting was not inspected |
| app/lib/data/user_cards_repository.dart:729 | Legacy ReferralInfo/Referral DTOs and GET client | No progress, reward-entitlement or ledger model |
| app/lib/features/auth/login_screen.dart:183 | Email OTP, saved session, POST /profile, purpose-specific consents | No invite-code handoff. Saved authentication can precede failed product bootstrap, so routing must support pending activation |
| api/src/index.js:253 | POST /profile upserts a profile from the JWT subject | Creates a product profile without invitation; email/phone in its body are client-supplied, unsuitable as verified identity evidence |
| api/src/auth.js:33 | JWT signature/issuer/audience/expiry checking and requireAuth | requireAuth currently tests only req.userId; membership and guest exclusion must be added at the private product boundary |
| auth/src/routes/authRoutes.js | Multiple identity/session creation paths and separate recovery paths | Do not depend on the client is_signup flag to enforce invitations. Existing identity/security remediation is a launch prerequisite |
| auth/src/routes/userRoutes.js:29 | Authenticated /users/me | Does not currently return the full verified-contact/session contract required for trusted product bootstrap |
| api/src/index.js:7619 | Read-time transaction-date streak | No Bamboo level or persisted referral qualification |
| app/lib/features/home/home_screen.dart:665 | Home summary and streak pill | Must display the selected engagement definition consistently with the referral screen |
| app/lib/app/providers.dart:823 | Onboarding completion is currently driven by a local preference/settings sync | Add a server-owned completion contract before using onboarding as inviter/activity eligibility |
| app/android/app/src/main/AndroidManifest.xml:79 | Generic Flutter deep linking disabled; custom assistant URL handled natively | Add invitation handling without breaking the assistant channel or delivering a link twice |
| app/ios/Runner/Runner.entitlements | Empty Runner entitlement dictionary | Add and verify Associated Domains in the actual signed target |
| app/android/app/build.gradle.kts:61 | dev, staging, prod application IDs | Domain verification must use the correct package and signing certificate for each channel |
| db/supabase/migrations/0004_user_domain.sql:145 | Card points ledger | Distinct from the new subscription credits |
| app/lib/features/insights/subscriptions_screen.dart | User-card recurring-charge insights | This is not PandaPay paid-subscription checkout; no app-level purchase SDK/checkout found |
| db/setup_app_role.sql | Broad runtime grants, including default public-table privileges | Financial tables/functions need an explicit ownership and privilege model |
| .github/workflows/build-and-test.yml | API/auth tests, Flutter checks, compose smoke job | Add database-backed feature tests and signed-device/link/billing evidence; unit tests alone are insufficient |
| .github/workflows/deploy-prod.yml | Successful master build can trigger backend migration/deploy | A later merge is potentially a deployment; feature flags must default safely and migrations must be compatible |

Search scope included active app, product API, auth, product migrations, console and test directories. Old architecture documents mentioning a different wallet or referral field are not evidence of an active end-to-end implementation. The code graph was used for navigation and cross-checked against current source; its incomplete traversal is not proof of absence.

## 4. Verified platform constraints and research

Checked against primary sources on 21 October 2026. These are platform facts plus explicitly identified engineering choices, not a store approval or legal classification of the campaign.

| Topic | Supported conclusion and design implication | Primary source |
|---|---|---|
| Android earned rewards | Earned/awarded points can unlock digital goods/services without Play Billing; selling points changes the policy treatment. This supports investigating reward-funded access, not arbitrary modification of a Play renewal charge | [Google Payments FAQ](https://support.google.com/googleplay/android-developer/answer/10281818?hl=en) |
| Android subscription discounts | Developer-determined offers support configured eligibility and discounted phases. Choose an existing store offer at checkout; do not pass an arbitrary wallet deduction as the store price | [Understanding subscriptions](https://support.google.com/googleplay/android-developer/answer/12154973?hl=en) |
| Android promo codes | Subscription promo codes grant trials, with eligibility limitations; they are not general cash-balance redemption | [Play promo codes](https://developer.android.com/google/play/billing/promo) |
| iOS offer codes | Configured offer codes can provide free/discounted periods for selected new, existing or expired subscribers. Offer-level eligibility and repeat-use limits constrain repeated referrals | [Apple offer codes](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-subscription-offer-codes) |
| iOS paid access and review | Digital unlocks generally use IAP subject to the applicable exceptions; paid benefits must not depend on referral tasks. Supply review access. TestFlight distribution must not compensate testers. Use synthetic beta rewards | [Apple App Review Guidelines, 2.1, 2.2, 3.1](https://developer.apple.com/app-store/review/guidelines/) |
| Chance-based promotions | Google sets conditions for gamified loyalty and chance outcomes; that exception includes qualifying-transaction conditions, so it cannot automatically be applied to this free referral design. Apple sections 5.3 cover contests/sweepstakes. Review the actual promotion; do not assume a paid-spin/gambling model | [Google rewards policy](https://support.google.com/googleplay/android-developer/answer/9877032?hl=en), [Apple guidelines](https://developer.apple.com/app-store/review/guidelines/) |
| Android installation | Play Install Referrer exposes referral information for Play installations. It is a source of attribution input, not proof of a unique person | [Install Referrer](https://developer.android.com/google/play/installreferrer) |
| Android links | Verified App Links require the native filter and hosted Digital Asset Links association | [Verify App Links](https://developer.android.com/training/app-links/verify-applinks) |
| iOS links | Universal Links require a website/app association and app-side handling. Keep a fresh-install fallback | [Supporting Universal Links](https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app) |
| Firebase | Firebase Dynamic Links shut down in August 2025; do not add it to this implementation | [Firebase shutdown FAQ](https://firebase.google.com/support/dynamic-links-faq) |
| India credit scope | RBI defines closed-system instruments for the issuer's own goods/services without withdrawal/third-party settlement. That definition alone does not classify this promotional design. Validate the actual credit terms before introducing cash, top-ups or third-party spending | [RBI PPI directions, section 2.1](https://www.rbi.org.in/Scripts/NotificationUser.aspx?Id=12156&Mode=0) |

Recommendation: build credits for PandaPay benefits only, with no purchase/top-up, withdrawal, transfer, UPI spending or card-bill payment. Keep the current card Wallet intact and label the new page “Subscription credits.” Naming alone does not determine regulation.

## 5. Product contract for implementation

The following defaults make the plan executable in staging. They are recommendations; unapproved commercial values must remain disabled in production.

| Rule | Proposed v1 behavior |
|---|---|
| Access | Valid invitation required for first product activation after enablement; existing activated profiles remain admitted |
| Who can invite | Existing active members, including grandfathered testers; new members after required onboarding is complete; explicit operator block overrides |
| New-user eligibility | First PandaPay product activation, with a real verified auth identity; an already activated product account cannot become a new referee |
| Attribution | One inviter per account for life of the retained attribution; first successful activation wins, not first anonymous click |
| Chain of referrals | A invites B, B invites C is permitted; A earns only for B, never for C. There are no downline earnings |
| Milestone | Bamboo = eligible foreground app activity on three consecutive campaign calendar dates |
| Eligible activity | Successful foreground Home/account-data load or an eligible interactive card/transaction action; server issues the action receipt; app submits a check-in |
| Calendar | Asia/Kolkata for this India campaign, frozen in its version; client device timezone/date changes do not alter it |
| Window | Proposed: complete a run within 30 elapsed days after activation; exact deadline returned by server |
| Missed date | Current run resets; user may start another run before the deadline |
| Sign-up day | Counts after the first eligible core action, not for OTP verification alone |
| Historical import | Can count as one action on the day of interaction; imported transaction dates cannot manufacture past activity days |
| Background capture | Automatic SMS/email ingestion, background sync, push delivery and passive notification display do not count as app use |
| Offline | Show pending state; an expired/no server receipt cannot backdate a day. Explain that the reward streak needs an online check-in |
| Qualification | Once completed, remains complete even if the user later misses a day or edits transaction history |
| Reward | Exactly one entitlement for the inviter and one for the referee per eligible qualified attribution |
| Spin | Each person spins independently; outcome selected and persisted by the server; client animation reveals that result |
| Money language | INR-denominated promotional subscription credit, not withdrawable cash; show terms before reward enrollment |
| Expiry | Pilot credits and spin entitlements have no expiry unless a separately approved, clearly disclosed campaign version specifies it |
| Privacy | Friend-selected display name/alias or “Friend”; no full email, phone, transaction data or bank details on inviter view |
| Notifications | Eventual server notification plus reliable in-app status; notifications are not required to receive the reward |

Do not silently replace the requested random spinner with a fixed reward. Support weighted_random and fixed campaign modes; fixed can use the same reveal UI. For the requested wheel, the inactive `bamboo-spin-v1-2026-10` configuration uses a 10,000-weight distribution per participant: ₹0 (10%), ₹5 (25%), ₹10 (25%), ₹25 (20%), ₹50 (10%), ₹75 (5%), ₹100 (3%), ₹150 (1%), ₹200 (0.5%), ₹300 (0.3%), ₹500 (0.2%). Thus 98% of outcomes are ₹0–₹100 and the top prize is 1 in 500. The expected value is ₹24.90 per person / ₹49.80 per qualified pair; maximum reserved liability is ₹1,000 per pair. These are versioned, configurable test defaults—not an activation or production approval. The migration intentionally leaves admissions, enrollment, fulfillment, redemption, and budget disabled.

Example test fixture only: INR 10 at 70%, INR 20 at 25%, INR 50 at 5%. Expected award is INR 14.50 per person / INR 29 per qualified pair. Maximum reserved liability is INR 100 per enrolled pair. These figures are not approved production rewards and must not appear in production seed data or marketing by default.

Three consecutive dates do not mean waiting 72 hours. For example, use just before midnight on date 1, on date 2, and just after midnight on date 3 qualifies under this rule. If a minimum elapsed duration is desired, version that as an additional rule before launch.

## 6. Architecture decision: gate product activation in the product database

Use the current separation deliberately: auth proves identity; the product database owns membership, attribution, milestones and credits. A valid OTP session can exist while product activation is pending. The user cannot enter private product features until activation succeeds.

This is invite-only access to PandaPay. It does not promise that the auth service will never create a pending identity row before invitation validation. Forbidding even that row requires a separate auth-level admission protocol across two databases and is unnecessary for the stated app-access requirement.

Activation sequence:

1. Capture an invitation URL/code locally and validate its format/availability for display. Anonymous validation is a preview, never an authorization grant.
2. Complete normal OTP verification. Keep a durable pending-activation state if the product API is unavailable.
3. Product API validates the current auth session through a trusted auth-service contract. Require a real subject, active account/session, guest=false, and at least one verified channel. Obtain canonical identity fields and verification flags server-to-server; ignore client contact claims for eligibility.
4. In one product-DB transaction, lock the subject's activation, check membership, validate the inviter, create profile/membership, establish immutable attribution, enroll in a versioned campaign, reserve reward liability if offered, and enqueue the joined event.
5. Commit before replying. Repeated activation for the same subject returns the existing membership/referral without changing inviter or reserving again.
6. App clears the pending code only after confirmed activation; it then completes required setup and enters Home.

Record required product/referral terms acceptance atomically during activation, with its actual version. Reconcile the existing subsequent POST /consents calls so retries do not create inconsistent/double enrollment consent; optional marketing/crowdsource choices remain independent. Add an authenticated, idempotent onboarding-completion endpoint that checks the required setup/terms contract and stores completion server-side. Current local preference completion alone cannot authorize new members to issue invitations or earn activity days. Do not require SMS permission, notifications or an optional card-add step to complete the reward mission.

The auth call happens before the product transaction, with a bounded timeout; it must not hold a database lock while waiting on network I/O. A database outage leaves the verified auth session pending, so the user retries activation instead of being asked to reuse a consumed OTP.

Close the database-side alternative path too: revoke ordinary runtime INSERT on public.profiles and execute first-profile creation through the restricted bootstrap routine. Split the existing upsert into guarded creation and allowed owner-field updates, because an INSERT ... ON CONFLICT still requires INSERT permission. Replace legacy GET /referrals code minting with the same trusted idempotent code routine used by v2. Re-running role setup must not restore ordinary profile/referral writes.

### Private API boundary

Introduce explicit guards:

- requireVerifiedSession for bootstrap/access and sensitive reward mutations; retains and checks guest/session/account state.
- requireProductMember for private user data, transaction/sync paths, check-ins, invitations and reward reads/writes.
- Existing requireAdmin for operator functions, with its own deliberate account/session requirements.

Inventory every authenticated product route. Exempt health/readiness, intentional public catalogue/discovery, access status and activation as appropriate. Handle secret-authenticated ingestion separately: it can write only for an admitted active profile and must never create membership. Anonymous analytics cannot qualify activity or grant credit. A missing membership must not be treated as an active member because a JWT is valid.

The current token guard/session behavior and documented auth findings need remediation before this boundary can be trusted. Refer to [the existing security review summary](security-review-summary-2026-10-20.md); section 13 defines the relevant prerequisite work.

## 7. Proposed data model and invariants

Use a dedicated promotions schema for new reward data/functions, owned by a NOLOGIN owner. The normal API role gets deliberate read permissions; a restricted reward-service role executes only the required write routines. Neither role is superuser/BYPASSRLS. Fix public legacy-table grants and default function execution as well. This keeps the new schema outside the existing blanket public grants.

| Object | Essential data and constraints |
|---|---|
| promotions.access_settings | Singleton admission_mode=open/invite_only/paused_new; active campaign version; effective timestamp; revision and operator audit |
| promotions.memberships | profile_id primary key; active/suspended; admission_source=legacy/invite/operator/open; activated_at; no client writes |
| public.referral_codes extension | Preserve existing unique code; add active/revoked state and issuance audit. Generate future codes with crypto.randomInt/randomBytes, bounded collision retry; no user-editable owner/code |
| promotions.campaign_versions | Immutable rules, eligibility window, timezone, per-role prize buckets/weights, caps, terms version, optional expiry. New versions for changes; never change enrolled rules in place |
| promotions.referral_attributions | ID; inviter/referee; code at enrollment; joined_at; campaign version; reward_eligible/reason; deadline; qualified_at; disqualified_at/reason. Global UNIQUE(referee_id) for retained non-null identities; inviter != referee |
| promotions.engagement_days | profile_id, local_date, server_activity_at, source action, receipt ID. UNIQUE(profile_id, local_date) and unique receipt ID; dates derived by server under the frozen calendar |
| promotions.reward_entitlements | attribution, beneficiary, beneficiary_role, immutable campaign version, ready/claimed/held/revoked/expired, timestamps. UNIQUE(attribution_id, beneficiary_role); validate beneficiary equals the relevant party |
| promotions.reward_spins | UNIQUE(entitlement_id), outcome bucket, amount_paise, distribution version/hash, draw metadata, committed_at. Immutable result |
| promotions.credit_accounts | Opaque account ID, owner, currency=INR, available_paise, reserved_paise, version/state. Balances nonnegative and reconciled to ledger |
| promotions.credit_ledger | Append-only signed integer-paise events: award, reserve, release, redeem, expiry, reversal, adjustment. Explicit available/reserved deltas; source reference; unique business idempotency key; actor/reason. No app UPDATE/DELETE |
| promotions.credit_redemptions | Owner, immutable quote/benefit/platform terms, reserved credit, pending/external_pending/committed/released/failed; stable redemption ID and unique store transaction bindings |
| promotions.campaign_budgets | Version/campaign budget, issued liability, outstanding reserved liability; locked counter enforcing issued+reserved <= total |
| promotions.reward_reservations | Per enrolled attribution and role, maximum award liability, state and release/consumption references; unique attribution+role |
| promotions.eligibility_claims | Campaign-scoped keyed fingerprints of trusted verified channels, key version and approved retention deadline; unique claim prevents the same verified contact receiving another new-user award within that policy |
| promotions.reward_outbox | Durable joined/qualified/award/redemption events, unique event key, attempt/retry/lease state; no raw contacts or transaction bodies |

Primary invariants:

1. A user cannot acquire private product membership by directly upserting profiles or replaying sync.
2. A referee has one immutable inviter; later login, reinstall, another code and another device cannot change it.
3. Two beneficiaries produce two entitlements, never one transferable/shared spin.
4. A spin result and its award ledger event commit together, or neither does.
5. The award idempotency key is based on entitlement ID, not a client-generated request ID alone.
6. Award amount, weights, beneficiary and qualification status never come from client claims.
7. Available/reserved balance changes lock the account and append a matching ledger event in the same transaction.
8. Campaign version, amount precision and terms remain reproducible after a configuration change.
9. Campaign budgets reserve the maximum two-sided liability at reward enrollment; already-promised rewards cannot fail later merely because new enrollment consumed the budget.
10. A deleted account must not cascade-delete financial history. Define pseudonymization and lawful retention with the account-deletion workflow; retain only required records and erase friend-visible labels.

Use PostgreSQL bigint for paise. Use decimal-string minor units in the JSON API (for example amountPaise="1000") and BigInt for Node arithmetic. Flutter parses to bounded integer paise and Money.fromPaise. Validate ranges explicitly; do not convert via floating-point rupees.

Eligibility fingerprints come only from the trusted auth response, with a dedicated HMAC key and documented normalization/rotation. A typed-but-unverified phone is not a verified identity. Do not equate different devices/UUIDs/emails with distinct humans, or reject a household solely for shared IP/device. Device/IP velocity, referral patterns and verified-channel reuse are abuse signals; bounded budgets and audited holds contain residual risk. Fingerprints remain personal-data-related records: agree their retention/erasure policy, and never claim permanent human uniqueness or keep them indefinitely by accident.

Enforce membership and participant RLS, and safe owner/role behavior. Revoke PUBLIC execute/default privileges on new privileged functions; pin definer search_path and schema-qualify references. A client-read projection for the inviter must expose only joined date, alias, milestone count/status and the inviter's own reward. The referee gets a separate projection of their own invitation and reward.

### Campaign enrollment and limits

On activation, take campaign budget/cap locks in a fixed documented order, then enroll and reserve both maximum awards atomically. Define caps as counts of reward enrollments, qualified referrals or issued value explicitly; do not mix those meanings. Proposed pilot cap is configurable reward-enrollments-per-inviter, so pending rewards cannot exceed it.

If an advertised preview becomes unavailable before activation commits, return offer_changed with the new terms and create no profile/membership yet. The user can explicitly continue with invite access but no reward using the new preview revision. Record reward_eligible=false and a reason; never silently withdraw an offered benefit after activation.

When the qualification deadline passes without success, a worker releases the unused reward reservations. Successful enrollment terms remain honored after new enrollment is paused. Issued credit is tracked as campaign liability; it does not imply a cash payment.

## 8. API contracts

Names below are proposed contracts. Keep existing GET /referrals and POST /profile compatibility until the supported old app versions are retired.

| Endpoint | Identity/access | Contract |
|---|---|---|
| GET /access-policy | Public | Access mode, minimum client capability, public campaign terms/version, safe invitation fallback instructions; never a user directory |
| POST /invitations/validate | Public, rate limited | Code preview + short-lived signed preview revision; generic invalid/unavailable response; no raw inviter contact. No profile, referral or reward creation |
| GET /access | Verified session | active/requires_invite/activation_pending/suspended; server-owned next action |
| POST /profile | Verified session | Existing update path; first activation additionally accepts invitationCode, preview revision, referral terms version and explicit access-only acceptance. Subject always comes from verified session |
| POST /onboarding/complete | Active member | Idempotently confirm the required setup/terms state on the server; optional tracking permissions and skipped optional steps do not block completion |
| POST /referrals/code | Active member | Idempotently get/create own code, independent of reward campaign enrollment availability |
| GET /referrals/v2?year=2026&cursor=... | Active member | Stable cursor page of safe friend progress, separate join-year and award-year totals, own ready rewards, terms and freshness timestamp |
| GET /referrals/mine | Active member | Referee's own inviter alias, enrollment/deadline/Bamboo progress and own entitlement; no inviter's other referrals |
| POST /engagement/check-ins | Active member | Validate signed action receipt, record one campaign day and evaluate qualification atomically; no client date/count/level override |
| GET /rewards | Active member | Own ready/claimed/held entitlements, persisted spin results and credit references |
| POST /rewards/:id/spin | Verified session + active member | Commit/return one authoritative result for caller's entitlement; repeats return the same result |
| GET /subscription-credits | Active member | Available, reserved, currency, capability/expiry flags and last confirmation time |
| GET /subscription-credits/ledger?cursor=... | Active member | Own immutable history, keyset pagination; credit/redeem/refund states distinct |
| POST /subscription-credits/quotes | Verified session + member | Supported platform benefit, required credit, actual store offer/renewal terms, quote expiry; unavailable benefits produce no debit |
| POST /subscription-credits/redemptions | Verified session + member | Reserve credits once against quote, return redemption ID and platform instructions |
| GET /subscription-credits/redemptions/:id | Active member | Canonical pending/final state, recovery from interrupted UI |
| Store notification/verification handlers | Authenticated provider events | Verify external transaction, platform, app, environment, offer and account binding; finalize once |
| Admin campaign/hold/adjustment endpoints | Product admin + audit | Create new version, pause a defined operation, adjudicate fraud, release holds, append reasoned adjustment; never edit a spin result |

Suggested activation response preserves profile and adds activation/referral fields:

~~~json
{
  "profile": { "id": "subject-uuid" },
  "activation": { "state": "active", "source": "invite" },
  "referral": {
    "id": "attribution-uuid",
    "rewardEligible": true,
    "campaignVersion": "india-pilot-v1",
    "deadlineAt": "2026-11-20T06:00:00Z",
    "milestone": { "kind": "bamboo", "requiredDays": 3, "calendarZone": "Asia/Kolkata" }
  }
}
~~~

Suggested spin response:

~~~json
{
  "entitlementId": "entitlement-uuid",
  "spinId": "spin-uuid",
  "outcomeId": "credit-10",
  "amountPaise": "1000",
  "currency": "INR",
  "ledgerEntryId": "ledger-uuid",
  "state": "credited",
  "replayed": false
}
~~~

Persist the substantive result; replay may change only replayed/freshness metadata. Use structured errors: invitation_required, invitation_unavailable, offer_changed, activation_pending, session_invalid, reward_not_ready, reward_held, feature_paused, quote_expired and insufficient_credit. Foreign reward IDs return a non-disclosing 404. Timeouts return a recoverable unknown state, never a made-up loss/win.

## 9. Engagement and qualification algorithm

1. An admitted foreground app requests a supported core action. After it succeeds, the server returns an engagementReceipt alongside normal data. The receipt binds subject, random receipt ID, allowed action, server activity timestamp and expiry; sign with a dedicated rotated key/issuer/audience. Proposed receipt lifetime: five minutes.
2. The foreground lifecycle submits the receipt once. No check-in is sent by background SMS/email/sync jobs. Server proof establishes a real authenticated API action; it cannot prove a unique human or reliably prove foreground against a modified client. Rate limits, limits on reward liability and abuse review address that limitation.
3. Verify receipt ownership, signature, purpose, expiry and timestamp bounds. Derive date from its signed server activity timestamp in the campaign's frozen timezone. A valid receipt crossing midnight counts for the date on which the action actually occurred.
4. Insert engagement_days ON CONFLICT DO NOTHING. Multiple devices/actions/retries on a date still produce one day. Do not use anonymous analytics or transaction occurred_at.
5. Under the attribution lock, recalculate from persisted dates whose server activity timestamps are on/after joined_at and before deadlineAt. Recalculation must handle valid receipts arriving out of order across midnight. A next-day action increments; a missed date starts at one. A run that ended yesterday remains displayed until today finishes. At midnight after the missed day, display zero until a new action starts a run.
6. Once any valid three-day run is established, conditionally set qualified_at and create exactly two role-bound entitlements using existing budget reservations. Insert outbox events in that transaction. Require the completing activity timestamp to precede the deadline.
7. Qualification is permanent under the normal rules. A fraud decision is a separate audited disqualification/hold, not a recalculation of past app use from edited financial data.

Live state can be evaluated synchronously on check-in; no cron is required to grant an earned reward. A durable worker reconciles incomplete processing, expires unqualified enrollments and delivers outbox notifications. Wait until deadlineAt plus the maximum receipt lifetime before releasing an unqualified enrollment's reservation: a valid pre-deadline action receipt may still be submitted within that grace interval. After expiry/grace, no client-supplied earlier date can reopen eligibility. Install this worker explicitly in local/staging/production compose/deploy with retry/backoff, leases, heartbeat and alerting. Do not rely on the currently skipped pg_cron migration.

V1 uses one India engagement calendar across this campaign. Supporting campaigns with different calendars requires a calendar identifier in the daily-event uniqueness key before enabling them; do not reinterpret existing dates under another timezone.

## 10. Spin transaction and budget accounting

The animation never determines value. For each spin request:

1. Authenticate, check membership and lock the requested entitlement. Check ownership inside the trusted write routine.
2. Return the existing committed spin if present. A duplicate with another request ID still returns this same result.
3. Reject non-ready/held/revoked entitlements; load the immutable distribution version reserved at enrollment.
4. Generate an unbiased integer using Node crypto.randomInt(totalWeight). Validate positive integer weights, unique bucket IDs, exact supported sum/range and approved nonnegative paise amounts. Select using cumulative half-open intervals.
5. Insert spin, append award ledger entry with unique key award:entitlementId, update the credit account, mark entitlement claimed and settle that role's maximum budget reservation against the actual award. Commit all changes together.
6. Return only after commit. Insert an award outbox event transactionally. If the HTTP response is lost, the app fetches/retries the same entitlement; it never creates another spin.

Use the shared lock order for overlapping rows: campaign budget, inviter quota, attribution, entitlement in sorted ID order, then credit account in sorted ID order, then redemption/ledger records. A routine may skip classes it does not use; it must not acquire an earlier class later. Activation can take a subject-specific advisory lock before this order; other routines must not acquire that advisory lock after domain locks. Read immutable IDs before locks when needed, then recheck mutable state under lock. Lease outbox work in a separate committed transaction before doing domain work. Test real concurrent transactions and bounded retry for deadlock/serialization failures. A retry after rollback may draw again internally, but the client must never observe any uncommitted outcome. Do not run network callbacks or push delivery inside the award transaction.

## 11. Credits and future subscription redemption

The credit service is independent of existing bank-card rewards and recurring-charge insights. Introduce a platform adapter returning explicit capabilities. There is no universal “subtract arbitrary INR from the next Apple/Google renewal” API established by this research.

Start with a small set of configured benefits/discount tiers; preserve unused credit as a remainder. A quote freezes credit cost, supported store product/offer, expected discounted period, expiry and post-offer renewal terms. If a platform cannot redeem a particular balance/benefit, show that state before reserving or spending credits. Never consume a credit merely because a store sheet was displayed.

Android options to prototype: fully reward-funded access using earned credits, or an eligible Play subscription offer for a paid checkout. iOS prototype: configured offer codes that match recipient eligibility, or a reviewed supported offer flow. Repeated rewards and active subscribers require explicit testing; offer codes cannot be assumed to stack forever. Do not use a renewal-extension compensation endpoint as an unlimited referral-credit mechanism.

Two-stage accounting:

1. Lock the account and quote, ensure available balance and eligibility, append reserve deltas, and create a redemption record. Return its stable ID.
2. For a benefit granted entirely by PandaPay under the chosen supported design, debit reserved credit and create the access entitlement in one database transaction.
3. For a store-mediated benefit, perform the external operation outside locks; use an idempotent provider/account association and durable reconciliation. Finalize only after trusted verification identifies the intended product/offer and account. Failed/cancelled requests release credit only when the benefit can no longer be redeemed.
4. A store offer token/code is not necessarily a secret bound to a PandaPay user. Document the platform's limitations. A code that is already issued and might still redeem must remain externally pending until redemption, revocation or expiry is established; an app timeout alone cannot refund it. Code-only redemption without reliable account binding stays disabled.
5. Duplicate/out-of-order webhooks, app restarts and delayed verification converge on one ledger debit and one benefit. A late full-price purchase must not silently consume credits reserved for a discount that was never applied.
6. Define refund/revocation and account-switch handling per platform before enablement. Refunds do not automatically replenish referral credits unless the quoted benefit's rule explicitly does so.

Balances and ledger:

~~~text
award INR 20       available +2000, reserved    +0
reserve INR 10     available -1000, reserved +1000
confirm benefit   available    +0, reserved -1000

OR, if definitively cancelled before benefit could be granted:
release reserve   available +1000, reserved -1000
~~~

Material product choices still needed: subscription price, benefit tiers/conversion, supported platforms and eligibility, campaign amounts/odds/caps, campaign budget, and promotion terms. Code and tests can be implemented with explicit staging fixtures; these values cannot be inferred from the old INR 100 seed.

The requested exact-rupee subscription reduction remains a desired product outcome, not a verified cross-platform capability. P7 must prove that behavior for each supported checkout, or return an explicit benefit-tier proposal for the product owner to choose; never silently describe a limited trial/discount tier as an arbitrary cash deduction.

The user intends future subscription use. Build and test the credit balance now, but enable live earning only with an explicitly stated usable benefit or approved future-use terms. If subscription redemption launches later, do not invent an expiry that elapses before redemption is available or advertise an already usable checkout discount.

## 12. App and link implementation

### Invitation entry and authentication

- Use https://pandapay.app/i/CODE, validate the exact host/path/code, and support a manual code field. No arbitrary redirect URL from a parameter.
- Native links and Play Install Referrer fill a durable local pending invitation; explicit manual choice can replace an unclaimed local candidate. Show the inviter/terms before activation; final server claim wins. Do not silently switch attribution when another link arrives during OTP.
- Instantiate one early link listener, handle both initial and warm links, and coalesce repeats. Preserve the Android assistant native channel; select exactly one owner for invitation link delivery. On iOS validate the actual lifecycle/plugin combination used by the installed Flutter version before choosing a dependency version.
- Host /.well-known/assetlinks.json and /.well-known/apple-app-site-association on the real domain with correct MIME/status, package IDs, Team ID, bundle ID, paths and production signing identities. Use the Play App Signing certificate, not merely the local upload key. Keep staging associations distinct.
- Android fresh Play installs can read the encoded referral value; sideloads and unavailable referrer data fall back to code entry. iOS fresh installs use the invitation webpage, an explicit copy/paste action, or reopening the invitation after install. Do not read clipboard silently or claim universal automatic deferred attribution.
- URL click/share/install telemetry must not create a named referral row. Show “Joined” only after activation commits; an installed app alone provides no verified person-to-referrer relationship.
- Router state separates authenticated_pending_activation from active_member. A saved token cannot bypass the gate. Restart, OTP resend, recovery and bootstrap retry preserve the correct step and subject. Clear local per-user reward state when switching accounts.
- Start private sync only after membership confirmation; a pending subject must not upload an old subject's queued records. Existing members can retain subject-scoped cached reads while offline, with stale confirmation shown; offline state cannot provision membership, qualify a new day, spin or redeem.
- Existing members recover/login normally and ignore incoming codes for re-attribution. An auth-only legacy identity without a product profile follows the invitation gate unless a trusted explicit grandfathering allowlist is provided.

### Referral and credit pages

- Refactor v2 API/domain models into dedicated referral/credit repositories rather than extending the large user_cards_repository indefinitely. Keep v1 parsing for old clients during transition.
- Referral screen: own code/share link; explanation and rules; Joined, Bamboo 0/3–2/3, Milestone complete, Your spin ready, Credits added, Expired, Access only, and Under review states.
- Progress may reset before qualification; explain the next action/deadline. State reflects server data with last confirmed timestamp; do not optimistically award a day or credits.
- Add join-year filters and separate awarded-this-year totals using campaign-zone half-open year ranges. A December join and January award belongs to different relevant totals; never multiply current reward price by historical qualified count.
- Allow each user to see/claim only their own spin. Reduced-motion users can reveal directly; screen readers announce committed amount/status. On a lost response, show “Checking your reward” and fetch its committed state.
- Subscription credits page shows available/reserved/used credits, ledger, expiry if applicable, benefit availability and no-cashout terms. Keep card Wallet and bank-card points distinct.
- Refresh on foreground, check-in completion, spin and redemption; optional push invalidates queries but does not carry authoritative balances. Cache reads per subject; all credit mutations require online confirmation.

## 13. Ordered implementation packages

Each package is a reviewable change with its own tests. New code paths default disabled until the relevant package and test gates are complete. No package is permission to deploy or edit production during this planning task.

| Package | Concrete work and likely files | Completion evidence |
|---|---|---|
| P0 — identity and current test baseline | Stabilize the six existing auth/onboarding test failures. Close the documented contact-linking and legacy signup proof gaps; atomic OTP consumption, canonical encrypted-phone lookup/identity uniqueness, guest exclusion, safe OTP logging and cross-service session revocation. Use versioned auth migrations if lookup/constraints change; update both bootstrap and deploy paths. Add trusted current-session/verified-identity response to auth routes, with no contact values in logs | Regression cases in companion spec pass against real DB where required; supported login/recovery remains usable; no claim that the eight reproduced findings were fixed solely because old unit tests pass |
| P1 — schema/privileges and compatibility | New uniquely sortable migrations for promotions schema, memberships/backfill, campaign/attribution/budgets, engagement, rewards/ledger and outbox. Fix db/setup_app_role.sql plus local/prod runners so grants persist. Extend api/src/config.js/api/src/db.js with restricted write connection and strict config validation | Empty DB + upgraded fixture both migrate; rerunning migrations and role setup preserves least privilege; all flags disabled; old client contracts still work |
| P2 — admission and attribution | New api/src/product_access.js, api/src/referrals.js and narrow HTTP route registration; auth identity client; guarded /profile and requireProductMember. app/lib/data/auth_api.dart, login screen, router/providers; add pending-invitation and activation repositories/screens | Direct HTTP bypass tests fail; activation/retry produces one immutable attribution and budget reservation; legacy members work |
| P3 — website/native invitations | Deploy-owned invitation landing/association assets in a clearly identified web/deploy directory; Android manifest/MainActivity, iOS entitlements/URL lifecycle and chosen link transport; Install Referrer integration and local fallback | Production-signed Play/internal-track and TestFlight/device link matrix recorded; no assistant regression; domain owner and association files verified |
| P4 — Bamboo engagement | New api/src/engagement.js and shared receipt/check-in service; appropriate core-action responses; app foreground lifecycle; dedicated Bamboo provider/UI | Three server dates qualify once; same-day, missed day, timezone, imports, background jobs and forged receipts behave as specified |
| P5 — entitlements/spins/credit balance | New api/src/referral_rewards.js and api/src/subscription_credits.js, restricted DB routines, dedicated Flutter repositories, reward page and credit-history page | Concurrency/lost-response/fault tests prove one result and one award per entitlement; budget and ledger reconcile |
| P6 — operators/worker | api/src/rewards_worker.js with outbox/reconciliation/expiry; compose service and deploy/health integration; admin endpoints and console controls; campaign audit/hold tools | Restarts retry leased work; dead-letter/failure alert actionable; operations pauses have defined effects and retained earned rights |
| P7 — subscription benefit integration | Platform capability spike first; configure actual store products/offers; implement credit quote/reserve/verification/redemption adapter, entitlement source and store notifications | Sandbox tests for new/active/lapsed users, repeated rewards, account switch, refunds and late events pass; no unsupported exact-rupee or automatic-renewal deduction claim |
| P8 — pilot/release | Add feature DB integration job, contract/E2E tests, live rollout runbook and evidence pack; signed-app tester pilot with synthetic credits; real three-date soak | Companion go-live checklist complete for the exact API/schema/mobile versions; only then enable selected operations |

Dependency order: P0 and P1 before P2/P4/P5; P2 before P3 end-to-end; P4 before qualification grants; P5/P6 before enabling live rewards; P7 before advertising usable subscription redemption; P8 before broad enablement. P3 association hosting preparation can proceed while backend packages are under review.

Add a dedicated referral/reward notification category and preference mapping to the existing database/API/app notification contract. Use per-beneficiary deduplication keys from the outbox. The existing foreground NotificationTriggerRunner is not the qualification authority or a substitute for the worker when the app is closed.

Do not broaden this implementation into unrelated UI cleanup. Preserve the dirty activity/payments files and existing untracked artifacts seen at audit time.

## 14. Migration and rollout protocol

1. Capture the current target release SHA, app versions, product/auth migration ledgers and actual database roles with read-only queries. The older local drift report is dated evidence, not the current production state.
2. Back up both databases and verify the relevant restore procedure before a release migration. Use a disposable DB for rehearsal and retain its result. Do not run reset/clean-volume commands against the user's existing database.
3. Audit legacy referral rows/codes: duplicate referees across inviters, self-links, orphaned/null identities, invalid states and claimed-but-unfunded values. Check product/auth identity consistency before grandfathering, because there is no cross-database FK. Preserve evidence; quarantine guest/orphan/deleted identities and conflicts for operator review. Never auto-create credits from a legacy qualified flag.
4. Apply additive schema/permission changes first; backfill valid existing product accounts as legacy members. Preserve unresolved profile data without granting it access; legitimate returning users can prove their current identity and recover grandfathered access through the trusted flow. New code can still run in open mode with new rewards disabled. Verify role setup after migration, including both fresh and repeated deployment paths.
5. Deploy compatible backend and worker, then the new apps and domain associations. Existing users remain admitted. Require the necessary client capability/minimum version before enabling invite-only admission so old signup clients get an actionable update path.
6. Use synthetic campaign versions for local, staging, Android test and TestFlight testing. Test rewards must not become redeemable production credit on account migration.
7. After closed testing and the device/soak gates, enable invite-only access independently of monetary rewards. Enable a bounded real campaign only with approved rules, budget, benefit terms and operational readiness.
8. Monitor activation completion/failure, unattributed new profiles, qualification latency, ready/claimed counts, outbox age and budget/balance reconciliation. Every unexplained duplicate award or ledger drift blocks expansion.
9. Roll back by pausing new admissions/enrollment or fulfillment/redemption as needed, retaining audit and balances. Do not drop financial tables or erase awards. A fulfillment pause shows a recoverable hold; it does not silently cancel an earned entitlement.

Operational controls must distinguish: admission_mode, campaign_enrollment_open, award_fulfillment_paused and credit_redemption_paused. Routine new-enrollment pause honors existing enrolled rules; emergency holds require a reason and visible status.

## 15. Verification performed during this planning task

| Check on 21 October 2026 | Result | Limit |
|---|---|---|
| Active source/schema/route/native/CI review | Completed for the areas listed in section 3 | No live DB or hosted-domain validation |
| API npm test | 470 tests: 469 passed, 1 skipped, 0 failed; syntax checks passed | The skipped real-DB transaction-tags case was not exercised; no new referral flow exists |
| Auth npm test | 38 passed, 0 failed | Existing suites miss the reproduced security conditions |
| Focused Flutter auth/onboarding/router tests | 31 passed, 6 failed | See companion baseline table; failures must be diagnosed before release |
| Existing synthetic security probes rerun against current source | Eight audit conditions still reproduced, with mocked DB/providers and no network | These are findings, not passes for security; original probe report date is hardcoded 20 October. This run did not overwrite that report |
| Toolchain used | Flutter 3.44.8 / Dart 3.12.2; local Node 24.15.0 | CI currently uses Node 22; final release checks must run the configured CI runtime too |
| New app/schema implementation | Not performed | This handoff is the requested plan; the test matrix is a specification, not a passing test report |

The final online acceptance criterion is a witnessed Android/iOS referral journey backed by matching database records: one attribution, three eligible dates, two entitlements, one immutable result/award per claimed entitlement, and a correctly reconciled supported redemption. The plan supplies the work and tests needed to establish that evidence; it cannot guarantee an unimplemented release.
