# SMS v2 security audit, November 2026 (Lane O)

Scope: `app/lib/features/sms_v2/**`, `app/lib/app/local_sms_rig_*.dart`, `app/lib/data/api_request_headers_client.dart`, the SMS v2 parts of `app/ios/**` and `app/android/**`, `api/src/sms_v2/**`, `api/src/legacy_version_gate.js`, `api/src/legacy_entry_kind.js`, `db/supabase/migrations/*sms_v2*`, `console/lib/features/sms_rules/`.

Method: OWASP Mobile Top 10 (2024) and OWASP API Top 10 (2023) walk-through, manual code review, targeted probes (the regex lint was exercised with catastrophic patterns and timed), `npm audit`, and secret greps. The `owasp-mobile-security-checker` scanners report "0 files" on this tree, so the M1 check was done by grep. Local only: no deploy, no production access, no push.

Severity: HIGH = an authenticated caller or a modified phone can cause material cost, integrity or privacy damage today. MEDIUM = needs a precondition or limited blast radius. LOW = hardening.

## Summary

| ID | Sev | Area | Finding | Status |
| --- | --- | --- | --- | --- |
| LO-01 | HIGH | API4 resource use | `facts:batch` side arrays are uncapped and unmetered | Fixed |
| LO-03 | HIGH | M4 / API injection | Regex lint lets exponential backtracking through; unsigned AI rules reach the phone engine unlinted | Fixed |
| LO-04 | HIGH | API6 / shared learning | One account can auto-pause any staged rule | Fixed |
| LO-02 | MEDIUM | API4 | Failed or oversized bodies spend no rate budget | Fixed |
| LO-06 | MEDIUM | M5 | Release APK allows cleartext to `localhost` and `10.0.2.2` | Fixed |
| LO-07 | MEDIUM | M6 privacy | Consenting phones can store free text in `corrected` | Fixed |
| LO-08 | MEDIUM | API4 | `rule-stats` accepts unbounded version strings, rule ids, rows, counters | Fixed |
| LO-09 | MEDIUM | M10 keys | Rule signing key lives in the public API process and signs per request | Fixed (Lane U) |
| LO-10 | MEDIUM | M3 / API2 | App Check tokens are bearer tokens not bound to account or device id; monitor mode admits unattested scripts | Binding fixed; limited-use replay protection built, off by default; monitor admission unchanged (Lane U) |
| LO-11 | MEDIUM | M9 | Raw SMS bodies and facts sit in plaintext SQLite in the backup-eligible iOS Documents directory | Fixed (fresh-start Phase 3: `d4c9e42`, `a451693`, `ab0753e`, `984f9e4`) |
| LO-12 | LOW | M5 | No certificate pinning | Open |
| LO-13 | LOW | M10 | Leaked rule key can only be revoked by an app release | Mitigated: release-free runbook (Lane U); removal from the app still needs a release |
| LO-14 | LOW | M4 | Signed-bundle patterns are not re-linted on the phone; stacked polynomial quantifiers and the lack of a match timeout remain | Open |
| LO-15 | LOW | API2 | Debug App Check tokens are valid to the server if registered in the production Firebase project | Fixed best effort (Lane U); a separate Firebase project remains the dependable control |
| LO-16 | INFO | API5 | Legacy version gate trusts the `X-App-Version` header | Accepted |
| LO-17 | INFO | API4 | `legacy_entry_kind` recurses without a depth bound (own-data DoS only) | Accepted |

No open HIGH finding. LO-11 was the only open MEDIUM finding without a fix and is now Fixed.

## Fixed findings

### LO-01 HIGH: `facts:batch` side arrays are uncapped and unmetered

Evidence (before): `api/src/sms_v2/facts_route.js` capped and charged only `items` (`const units = Array.isArray(body.items) ? Math.max(1, body.items.length) : 1`). `contracts/sms/v2/api/facts_batch.request.schema.json` has `maxItems: 500` on `items` only; `instruments`, `events` and `ledger` have none. A body of 8 MiB inflated could carry tens of thousands of events or ledger rows, each driving SQL writes and `transactions` projection, while counting as one unit. That skips the 20,000 items a day limit that WP-13 sets to bound cost.

Fix: every list is capped at 500 (`413 request.facts_batch.items_too_many`, the same cap the phone uses per kind) and the budget is charged for the largest list, so honest batches cost exactly what they did before.

Tests: `api/test/sms_v2/security_audit.test.js` (LO-01).

### LO-03 HIGH: regex denial of service

Evidence (before): `lintPattern` in `api/src/sms_v2/rules_admin_route.js` and `lintRegexDialect` in `packages/pandapay_domain/lib/src/sms_v2/engine/lint.dart` rejected only `(a+)+` style nesting. `^(a|aa)+$` passed both; timed in V8 at 243 ms for 34 characters and doubling per character. The phone engine (`compiled_bundle.dart`) compiles whatever pattern it is given and has no timeout (Dart regex cannot be interrupted). Two paths feed it patterns without a human lint gate on the phone: AI-drafted provisional rules (`ProvisionalStore.overlay`, delivered by sync and not covered by the bundle signature) and any admin-authored rule that passed the weaker lint.

Fix: both linters now refuse an unbounded quantifier after a group whose alternatives can start with the same text (`(a|aa)+`, `(\w|\d)+`, `(a|)+`), including through nested groups. Disjoint branches such as `(?:x|y)*` and `(?:\s|,)*` remain allowed, because the existing engine test and real rules rely on them. `ProvisionalStore` now runs `lintRegexDialect` on every private rule before it can reach the matcher. Signed shared bundles are deliberately not re-linted on the phone, so a stricter lint can never brick an installed bundle (LO-14).

Coordination note for the rules lane: `lintRegexDialect` is also called by `bundle_lint.dart`, so a rule with ambiguous alternation under `*` or `+` now fails `build` and publish. Rewrite as a character class or a bounded count.

Tests: `api/test/sms_v2/security_audit.test.js` (LO-03), `packages/pandapay_domain/test/sms_v2/engine/lint_alternation_test.dart`, `app/test/features/sms_v2/storage/provisional_store_test.dart`.

### LO-04 HIGH: one account can auto-pause any staged rule

Evidence (before): `evaluateAutoPause` in `api/src/sms_v2/rule_stats.js` paused a version on the testers, 5% and 25% cohorts once `hits >= 50` and the correction rate exceeded the threshold, with no minimum number of contributing devices. `sms_v2_record_rule_stats` (`20261110120000_sms_v2_rules.sql`) accepts any rule id and unbounded counters from any signed-in profile. One account could post `hits=1e6, corrected=1e6` for a rule id and pause it for every user in the staged cohort, which is also a way to hold back a legitimate fix.

Fix: auto-pause requires `AUTO_PAUSE_MIN_DEVICES = 3` distinct reporting profiles (the rollup's `devices` column). Counters are bounded by LO-08. Residual: three colluding accounts could still do it; the pause is logged, audited, and reversible by publishing a new version.

Tests: `security_audit.test.js` (LO-04); existing auto-pause tests unchanged.

### LO-02 MEDIUM: failed parses spend no budget

Evidence (before): `facts_route.js` returned 400 or 413 for unparseable, over-count or bad-gzip bodies before calling `checkRate`, so a script could force an 8 MiB inflate and JSON parse repeatedly, free of the 60 requests a minute limit.

Fix: those paths now charge one unit and answer 429 when the budget is gone. Tests: `security_audit.test.js` (LO-02). A body over 1 MiB as sent is still refused in `readRawBody` before any inflate and costs no CPU.

### LO-06 MEDIUM: release APK allows cleartext to loopback hosts

Evidence (before): `app/android/app/src/main/res/xml/network_security_config.xml` had `cleartextTrafficPermitted="true"` for `localhost` and `10.0.2.2` in every build type. Fix: the main config denies cleartext everywhere; the development hosts moved to `app/android/app/src/debug/res/xml/network_security_config.xml`, which replaces it in debug builds only. `flutter run --profile` against the emulator's `http://10.0.2.2` no longer works; use debug or a hosted `https` backend. Tests: `app/test/native/android_network_security_test.dart`.

### LO-07 MEDIUM: free text in shared corrections

Evidence (before): `submitCorrection` stored the whole `corrected` object (up to the 100 KiB body limit) for consenting users, and `listCases` shows it to every admin. A modified client could place raw message text there. The shipped phone sends only `category` and `_template`. Fix: only `category` and `merchantKey`, strings of at most 200 characters, are kept. Test: `security_audit.test.js` (LO-07).

### LO-08 MEDIUM: `rule-stats` can bloat shared tables

Evidence (before): the contract allows any `appVersion` string, any `ruleId`, any number of rows and any counter size; `appVersion` is part of the key of `sms_v2_rule_stats_daily`, which is never trimmed. Fix in the handler: `appVersion` matches `^[0-9A-Za-z.+_-]{1,40}$`, rule ids match the contract id pattern with at most 128 characters, at most 500 rows, counters at most 1,000,000 per day. Test: `security_audit.test.js` (LO-08).

## Open findings

(LO-09, LO-10, LO-11 and LO-15 below are kept for their history; see the summary table for current status.)

### LO-09 MEDIUM: signing key in the public API process (fixed, Lane U)

Before: `bundleForServing` re-signed the stored bundle on each request, so `SMS_RULES_SIGNING_KEY` sat in the public API. Now minting stores the signed copy in `sms_v2_bundles.served_body` (migration `20261114100000`, read through `pandapay.sms_v2_latest_served_bundle`). The hourly job `run_sms_v2_rule_jobs.js` re-signs it before the 7-day expiry (default when less than 72 hours remain) and when the key id changes. `rules_route.js` and `index.js` no longer load a signer; the route serves the stored copy only if it is signed, matches the row's version and is unexpired, otherwise `503 bundle_unavailable` (fail closed, no re-signing, no older bundle). The public process logs an error at start-up in production if the key is in its environment. The job refuses to sign a body whose content hash differs from the mint-time hash. Tests: `api/test/sms_v2/lane_u_signing.test.js`. Runbooks: `signing-keys.md`, `bundle-release.md`.

### LO-10 MEDIUM: attestation is transferable and optional in monitor mode (binding fixed, Lane U)

Before: the verifier checked signature, issuer, audience, expiry and app id, but a token was not tied to a profile or `X-Sms-Device-Id`. Now the first (profile, installation digest) to present a token owns it (`sms_v2_attestation_bindings`, migration `20261114110000`, durable `db` mode in production, per-process `memory` elsewhere). Another profile or installation presenting it is unattested: half limits and no shared learning in monitor mode, `403` in enforce. The rate counters were already keyed by profile and installation digest, so the same pair now governs both the budget and the token. Limited-use replay protection (Firebase `verifyAppCheckToken`, `alreadyConsumed`) is implemented behind `SMS_V2_APPCHECK_REPLAY_PROTECTION=on`, default off, needs `google-auth-library` and credentials, and needs the app to send `getLimitedUseToken()` tokens (`DeviceAttestation.limitedUseHeaders()` is added; the sync client is not wired to it yet, so the switch stays off). Monitor mode still admits callers without a token at half limits, by design. The client-metrics receipt rows belong to another lane and were not touched. Tests: `api/test/sms_v2/lane_u_attestation.test.js`, `app/test/features/sms_v2/sync/attestation_test.dart`.

### LO-11 MEDIUM: plaintext SMS store on the phone (Fixed, fresh-start Phase 3)

Before: `app/lib/data/local/app_database.dart:538` opened `pandapay.sqlite` in the Documents directory with no encryption, and `sms_intake_repository.dart` kept raw bodies in `sms_captured_messages` (kept for re-interpretation) next to the v2 fact payloads. Android had `allowBackup="false"`. On iOS the file was covered by the default data-protection class but eligible for device backups; only the native spool (`IncomingSmsSpool.swift:91`) set `isExcludedFromBackup`.

Fix, in the fresh-start Phase 3 commits (merged as `6870ca9`):

- `d4c9e42 feat(storage): encrypt the local database with SQLCipher`. `sqlite3_flutter_libs` is replaced by `sqlcipher_flutter_libs`; the install key from `LocalDatabaseKeyCustody` keys the database, the read-worker isolate and the recovery connection. A lost or mismatched key resets the unreadable file, and a locked key store exits without touching the spool. Tests: `database_key_test.dart`, `encrypted_database_host_test.dart`, `integration_test/encrypted_database_test.dart`.
- `a451693 feat(security): encrypt receipt files at rest` (files start with the `PPRC` marker).
- `ab0753e feat(security): encrypt SMS text in the iOS spool` (spool bodies start with `v1:`), plus `2b61951` so the spool imports SQLCipher and the iOS app builds.
- `984f9e4 feat(storage): one backup-excluded root for account files`, which closes the backup-eligibility half.

Remaining proof is the on-device check in plan Task 7.3 (database header is not `SQLite format 3`, receipts start with `PPRC`, spool bodies start with `v1:`, backup-exclude attribute present). That needs a release build on a phone and was not run here.

### LO-12 LOW: no certificate pinning

Neither platform pins. Trust is the system store; the local rig CA is unreachable in release (see the proof below). Add a `<pin-set>` to the Android config and an iOS pin when the production domain is fixed.

### LO-13 LOW: key revocation needs an app release (mitigated, Lane U)

`rule_keys.dart` is a compile-time map, so a leaked key stays trusted by installed apps until a release removes it. A release-free recovery now exists as a runbook (`runbooks/signing-keys.md`, "Revoking a leaked rule key without an app release"): ship a spare public key one release ahead, then switch the maintenance environment to the spare and run the hourly job once, which re-signs every served bundle. The leaked key remains usable only by someone who can deliver a forged bundle to a phone. A phone-side ratchet (refuse bundles signed by a lower-ranked key once a higher one was seen) would close that gap but needs new persisted state in the bundle store and a release, so it is a follow-up. The phone never uses an older bundle (`bundle_store.dart:28` rejects a lower version), which limits replay.

### LO-14 LOW: engine regex limits

The engine enforces 2,000 characters through the bundle schema and the new alternation rule through the publish lint only. Stacked polynomial quantifiers such as `.*.*.*.*x` and the absence of any match timeout are not mitigated. Mitigation if needed: cap unbounded quantifiers per pattern in the lint, and truncate the matched body to a fixed length (SMS bodies are short).

### LO-15 LOW: debug App Check provider (fixed best effort, Lane U)

`attestation.dart` selects the debug provider for debug and rig builds only. The server now rejects, when `NODE_ENV=production`, tokens carrying a provider claim that names a debug provider, or whose subject is listed in `SMS_V2_DEBUG_APP_IDS`, unless `SMS_V2_ALLOW_DEBUG_APP_CHECK=true`. Firebase documents no stable debug claim, so keep development registrations in a separate project or under dedicated app ids listed in `SMS_V2_DEBUG_APP_IDS`. Tests: `lane_u_attestation.test.js` (LO-15).

## Accepted and informational

- LO-16: `legacy_version_gate.js` reads `X-App-Version`, which a client can spoof. It is an upgrade nudge, not an access control. The worker-path exemptions (`/ai/jobs/lease`, heartbeat, result, retry, fail) are exact patterns and are authenticated elsewhere.
- LO-17: `legacy_entry_kind.js` recurses over response JSON. Deeply nested user-controlled JSON could only fail that user's own response, and v2 routes are registered before this filter.

## Areas reviewed with no finding

- Secrets (M1): no keys, tokens, PEMs or passwords in the in-scope tree. `template_worker.js` reads the AI key from the environment. The rig CA PEM added to a test is a throwaway public certificate.
- Dependencies (M2): `npm audit --omit=dev` found 0 vulnerabilities; `jsonwebtoken` is 9.x, `firebase_app_check` is pinned at 0.4.8.
- Authentication and IDOR (M3, API1, API5): every phone-facing query in `storage.js`, `corrections_route.js` and `ai_templates.js` filters by `profile_id`, and the v2 tables use forced RLS with `profile_id = pandapay.uid()` (`20261111120000_sms_v2_core.sql`). Rule, bundle, tester, stats and template tables are admin-only or `pandapay_admin_api`-only with `admin_has_permission` guards; `sms_v2_rate_counters` has forced RLS and no policy and is reached only through a `SECURITY DEFINER` function; `sms_v2_release_metrics` is revoked from `PUBLIC` and `app_user`. Correction cases give the phone owner read, insert and a `request_hash`-only update. Admin routes are served by the private admin API, and the public app denies `/admin` paths (`public_admin_boundary.js`).
- Signature, expiry and rollback on the phone (M10): Ed25519 over canonical JSON, key id from a compile-time list, installs refuse a lower version, an expired bundle and an equal version with different content. Unsigned downloads are refused, and only the explicit empty version-0 baseline loads unsigned. Hostile payload shapes return null instead of throwing (new test). Stale bundles keep working and mark freshness stale.
- Attestation enforcement: all seven phone-facing routes (`facts:batch`, `categories:batch`, `sync`, `rules`, `rule-stats`, `corrections`, `unknown-templates`) call `verifyAttestation` and `checkRate`. `enforce` fails closed, including when the project number is missing or an unknown `SMS_V2_ATTESTATION_MODE` is set (the server will not start).
- Logging (M6, M8): the v2 server and phone log error codes only; no message text, hashes or identifiers. The Dart tree has no `print` or `debugPrint`.
- Local rig in release (M8): proved by tests, see below.
- Debug and test-only native code: the synthetic inbox and history bridge compile only under `DEBUG && targetEnvironment(simulator)`, and the probe code only under `PANDAPAY_DEVICE_IMPORT_PROBE`. The Debug build configuration uses `DeviceTesting.entitlements`; Release and Profile use `Runner.entitlements` with the production App Attest environment.
- Redacted-template privacy (M6): templates are queued only with current consent (`template_upload.dart` `_canShare`), withdrawal deletes the queue, origins and AI results in one savepoint, the phone re-redacts with a per-upload salt and refuses digits runs, URLs, emails and domains, and the server re-checks the same patterns (`ai_templates.js`, `corrections_route.js`, stricter `\d` ban) and the consent row inside the transaction. Raw message text never leaves the phone: facts forbid `evidence` and `instrument.raw` in the contract. Corrections send only categorical values.
- Rate limits and quotas: the Postgres counter function takes a per-account advisory lock, so profile and device budgets are atomic; device ids are client-chosen but the profile budget always applies.

## Local rig is unreachable in release builds (proof)

`app/test/app/local_sms_rig_release_gate_test.dart`:

1. The whole permission matrix: for every combination of debug, opt-in, web, CA, key and five environment names, `LocalSmsRigBuild.permits(isRelease: true, ...)` is false.
2. Wiring: `enabled` passes `kReleaseMode`, `kDebugMode` and `kIsWeb` to the matrix, `controlsEnabled` is `kDebugMode || enabled`, `localSmsRigHttpClient()` returns null unless the flag is on, and the rig rule key joins the verifier's trust map only inside `if (LocalSmsRigBuild.enabled)`. `smsV2RuleKeys` has no rig key.
3. No other path: no file outside the rig build and runtime provider reads the rig defines; no file overrides certificate validation (`badCertificateCallback`) and only the rig client sets a custom trust store.
4. The rig transport accepts only private IPv4 `https` origins, rejects any other origin, userinfo, `http` and redirects.
5. A test run without rig defines has no local trust and no controls.

Because `kReleaseMode` is a compile-time constant, a release build also tree-shakes the rig branch. The defines are never required by CI release builds, and `PANDAPAY_ENV` must be exactly `dev`.

## Re-check, November 2026 (fresh-start Phase 6 and Task 7.1)

Run from `fresh/phase6-hardening` (on `sms-v2/integration` at `2b61951`). The `owasp-mobile-security-checker` scanners wrote to a scratch copy of `app/` (they write their JSON next to the project, so nothing was added to the repository). Unlike the first pass, which saw "0 files", this run scanned the whole app tree (438 Dart files).

| Scanner | Result | Disposition |
|---|---|---|
| M1 hardcoded secrets | 0 findings in 444 files | Clean |
| M2 dependencies (`check_dependencies.py`) | Did not run: needs PyYAML, which is not installed (no global installs were made) | Replaced by the checks below |
| M5 network | 4 HIGH, 2 MEDIUM | No new finding, see below |
| M9 storage | 5 MEDIUM | No new finding, see below |

**M2 replacement checks (all done, no fix needed for the app):**

- `osv-scanner` is not installed. The 229 hosted packages in `app/pubspec.lock` were queried against the OSV.dev batch API (ecosystem `Pub`), the same database osv-scanner uses: 0 known vulnerabilities.
- `cd api && npm audit --omit=dev`: 0 vulnerabilities (also 0 including dev dependencies).
- `cd auth && npm audit --omit=dev`: 1 HIGH before (`follow-redirects` 1.16.1, GHSA-mrwp-f3q8-3g9p, reached through `twilio` and `axios`), 0 after. Fixed by `npm audit fix`, which moved `follow-redirects` to 1.16.2 in `auth/package-lock.json` only. `auth` tests: 377 pass.
- `dart pub outdated` shows many newer majors (go_router 14 to 18, Riverpod 2 to 3, firebase 4 to 5, flutter_local_notifications 18 to 22, others). None is tied to a known vulnerability, and the plan forbids major bumps of Riverpod and go_router, so none were taken. `sqlcipher_flutter_libs` 0.6.8 is the version in use; its latest published release is `0.7.0+eol`, i.e. the package is end of life upstream. Plan a replacement as a post-release item (check upstream's recommended successor first); there is no advisory against 0.6.8.

**M5 network findings (no change in risk):**

- `lib/app/env.dart:60,66,80`: the `http://10.0.2.2` strings are the dev-only defaults. `Env.assertReleaseConfigured` throws at start-up in a release build that still points at them, and LO-06 removed cleartext from the release network config. False positive for release.
- `lib/data/card_discovery_engine.dart:153`: `'http://'` is a spam marker in a keyword list, not a request. False positive.
- No certificate pinning (2 MEDIUM from the scanner): this is LO-12, still Open and still LOW in our rating, because the production domain is fixed late in the cutover.

**M9 storage findings (no change in risk):**

- `portable_attachments.dart:73`, `portable_http_repository.dart:104`, `canonical_ndjson.dart:86` write the user's own backup export to a staging folder, and `private_temporary_workspace.dart:32` writes a marker file. These are user-started exports into a private, marked temporary workspace that is cleaned up and swept by age; the final archive is the user's to share. Not a storage regression.
- `features/scan/card_scanner.dart:138` writes resized card photos for OCR into the same private workspace and calls `workspace.cleanup()` in its `finally`. Not a storage regression.
- The earlier SMS database finding (LO-11) is no longer detectable by this scanner's patterns because the store is now encrypted; the scanner's remaining hits are file-write heuristics only.

**Result:** no new HIGH or CRITICAL finding. One HIGH dependency advisory (auth, `follow-redirects`) was found and fixed. No open HIGH finding.

**M7 note (manual):** release builds are now obfuscated (`--obfuscate --split-debug-info`), see `docs/release/symbolication.md`. That file also records a gap: in-app error reports from an obfuscated build carry no code locations.
