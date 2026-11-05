# Fresh-Start Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one clean PandaPay build to the owner and their friends: SMS v2 is the only pipeline, no legacy code or data, account data encrypted on the phone and wiped on sign-out, consent and privacy text that are true, and one merged `master` branch.

**Architecture:** Everyone starts fresh. Testers delete the old app and install the new one, and the production product database starts empty, so there is no migration, no compatibility period and no legacy routes. The phone is the only SMS parser. It uploads typed facts, never message text. All account data on the phone lives in one SQLCipher database plus encrypted receipt files under one backup-excluded folder, keyed by one install key held in the Keychain or Keystore. Sign-out revokes the session on the server, unregisters push, destroys the keys and deletes the files. Messages the phone can't read can be shared, only with the user's opt-in, as redacted layouts. A private worker asks Gemini to draft a rule for each layout, the sharing phone uses that draft for that one layout, and the owner approves it in the console before every phone gets it (Phase 6b).

**Tech Stack:** Flutter (Riverpod 2.6.1, go_router 14.x), `sqlite3` 2.x with `sqlcipher_flutter_libs`, `flutter_secure_storage` 11, Swift/CryptoKit (iOS SMS spool), Node 20 + Express 5 (`api/`, `auth/`), PostgreSQL migrations in `db/supabase/migrations/`, Novu + FCM for push.

## Decisions (locked 2026-11-05 with the owner)

| ID | Decision |
|---|---|
| D1 | **Fresh start.** No previous app version is kept. No legacy data migration, compatibility period or minimum-version cutoff planning. Testers delete the old app and install the new build. |
| D2 | **SMS v2 only.** The phone parses every SMS with the signed rule bundle and uploads typed facts only. Raw SMS text never reaches the server. Unrecognised messages become on-phone review items; their redacted template is uploaded only with `sms_shared_learning` consent. |
| D3 | **One install key, not per-account keys.** One account at a time per phone. SQLCipher encrypts the whole local database. The key lives in Keychain (`first_unlock_this_device`, not synchronizable) or Android Keystore. Sign-out destroys the key and deletes the files. |
| D4 | **Keep email import** (IMAP mailbox polling and email forwarding), the owner's decision on 2026-11-05. It stays server-side and is hardened: mailbox passwords encrypted in the API with AES-256-GCM, polling only from bank senders, email text deleted once parsed, and its own consent screen (Tasks 1.3 and 2.2). Gmail card discovery stays hidden as it is today. |
| D5 | **Remove server-escrowed account recovery** (`PANDAPAY_ACCOUNT_RECOVERY_ENABLED`, escrow routes and tables). It is switched off, and its key design (the server can decrypt) conflicts with the future user-held-key SMS backup. Keep the passphrase-encrypted file export/import if it is user-visible. *The owner kept email import and raised no objection to this; mention it to them once before deleting.* |
| D6 | **Keep login accounts, wipe all product data** at cutover. Revoke every session. Keep the pre-cutover encrypted backup for 30 days, then destroy it. |
| D7 | **Card rewards ships only if its own gates pass by release cut**, behind its flag. Otherwise it goes in the next release. |
| D8 | **One branch.** All work merges into `sms-v2/integration`, which is fast-forwarded into `master` and tagged. Superseded and merged branches and worktrees are deleted. |
| D9 | **AI learning stays, in the v2 form only** (owner, 2026-11-06). The old per-message Gemini pipeline (full SMS text uploaded, server redaction, Gemini deciding each transaction) stays deleted. The v2 template loop is switched on for the test phase: opt-in redacted layouts, Gemini drafts a rule, the owner approves it in the console. Gemini runs on a paid key, only on the private admin host. On-device AI drafting is out of scope for this release. |

## Global Constraints

- Riverpod stays 2.6.1 (codegen) and go_router stays 14.x. Do not upgrade packages because a skill's example assumes newer versions.
- `sqlite3` stays on 2.x. Replace `sqlite3_flutter_libs` with `sqlcipher_flutter_libs`; never ship both.
- No SMS body, sender+body pair or OTP leaves the phone. Server routes that accept raw SMS text are deleted, not disabled. (Email import is a separate, consented, server-side channel; its text is deleted once parsed.)
- Every account file lives under `Application Support/PandaPay/`. Nothing is stored in the Documents directory.
- Keychain items: `KeychainAccessibility.first_unlock_this_device`, `synchronizable: false`. Android: `AndroidOptions(resetOnError: false)`.
- Logs and error reports never contain SMS text, amounts linked to a person, tokens or keys.
- TDD for every code task: failing test, minimal code, passing test, commit. `flutter analyze` reports zero issues.
- No `git push`, deployment, production flag change or data deletion without the owner's explicit approval in chat.
- Gemini receives only redacted layouts that passed the server's redaction check (`redactionError` in `api/src/sms_v2/ai_templates.js`), never message text. It runs on a paid (billed) key only: on the unpaid tier Google may use inputs to improve its products and human reviewers may read them. `GEMINI_API_KEY` and `SMS_RULES_SIGNING_KEY` live only on the private admin host, never in the public API's environment.
- User-facing copy is plain language. The exact strings in this plan are the strings to ship.

## Current state (checked 2026-11-05)

- `origin/sms-v2/integration` (head `48df9ca`) contains all of `master` and `sms-v2/main`, plus the console/ops commits from `codex/ios-shortcuts-prototype` (patch-equivalent).
- The main checkout `/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs` (branch `codex/ios-shortcuts-prototype`) has **115 uncommitted changes**. Not in integration: `app/lib/features/auth/auth_feedback.dart`, `app/lib/features/sms_import/live_alert_status.dart`, a login screen rework (`login_screen.dart`, +592/−208 versus integration), iOS intake controller, import screen and shortcut link changes, `IncomingSmsSpool.swift`/`IncomingSmsIntent.swift` tweaks, and Android fastlane lanes.
- 113 local/remote branches are fully merged into integration.
- Not merged: 10 `card-rewards/*` branches (active in another session; no single branch contains all of them), `sms-v2/lane-x-receipt-review` (in progress, Kiwi receipt rule; same commit as `sms-v2/publish`), and probable superseded copies: `sms-v2/wp-10-ai-templates`, `sms-v2/wp-12-corrections`, `sms-v2/main-claude-backup`, `sms-v2/wp-03a-banks`, `sms-v2/wp-03b-wallets`, `origin/feature/card-queue-geofence`.
- SMS v2 is behind the compile flag `SMS_PIPELINE_V2` (`app/lib/features/sms_v2/flag.dart`, default false). The legacy raw-text upload (`/transactions/from-sms[/batch]`) is still live.
- Phone storage today: `pandapay.sqlite` is plaintext in Documents (security audit LO-11, open). Receipts are written unencrypted (`transaction_attachments_repository.dart:85`), even though `EncryptedReceiptFileStore` already exists. The iOS spool `handoff.sqlite` stores `body` in plaintext; it is backup-excluded and file-protected. Home widget data in the app group is never cleared.
- Auth: access tokens last 15 minutes and refresh tokens rotate with reuse detection, but the refresh TTL defaults to `180d` (`auth/src/config.js:90`). `POST /auth/logout` exists and the app never calls it. There is no push unregistration.
- **Checked 2026-11-06 on `sms-v2/integration` (`398ece5`):** the old AI pipeline is deleted (`d50a81d`, `800a57f`, `766a4a9`). The v2 template loop is wired end to end in code: phone upload (`template_upload.dart`), server intake (`/sms/v2/unknown-templates`), Gemini worker (`api/src/sms_v2/template_worker.js`), private rule back to the phone (`provisional_store.dart`), and the console Templates and Metrics tabs. But nothing runs the worker or the hourly rule job (`run_sms_v2_rule_jobs.js`): neither is in any compose file, and `api/.dockerignore` ships only `src/` and `sms_v2_assets/`, so `api/scripts/` isn't in the image at all. Served rule sets expire 7 days after signing (`BUNDLE_TTL_MS`), the public API then answers `503 bundle_unavailable`, and a new install keeps the empty shipped baseline (`app/assets/sms_rules/baseline_bundle.json`, 0 rules). The private `admin-api` service has no `SMS_RULES_SIGNING_KEY`, so console publishing can't sign. The test database had 0 layouts and 0 `sms_shared_learning` opt-ins. Layouts sent without a valid App Check token are stored as `held` and never drafted. Old-worker settings (`AI_WORKER_TOKEN`, `GEMINI_MODEL`, `GEMINI_REQUESTS_*` and others) are still in the deploy files, but nothing reads them.
- Existing building blocks to reuse: `LocalDatabaseKeyCustody` + `FlutterSecureKeyValueStore` (per-install DB key, correct Keychain options), `LocalReceiptKeyCustody` + `EncryptedReceiptFileStore` (AES-256-GCM), `localDeviceIdProvider` (install ID), `POST /consents` (append-only consent log), `app_status.min_supported_version` (version gate).

## File structure

New:
- `app/lib/data/local/storage_paths.dart`: one private root for all account files, plus backup exclusion and wipe.
- `app/lib/data/local/database_key.dart`: loads the install key and applies it with SQLCipher.
- `app/lib/data/secure_storage/install_guard.dart`: clears Keychain leftovers on the first launch after a reinstall.
- `app/lib/features/auth/account_sign_out.dart`: the ordered sign-out and wipe.
- `app/lib/features/consent/sms_access_disclosure.dart`: the standalone SMS disclosure and consent screen.
- `app/ios/Runner/SpoolCipher.swift`: encrypts spool message text at rest.
- `app/android/app/src/main/res/xml/data_extraction_rules.xml`: blocks cloud backup and device-to-device transfer.
- `api/src/notification_devices_route.js`: `DELETE /notification-devices`.
- `db/supabase/migrations/20261115000000_fresh_start_drop_legacy.sql`: drops legacy tables.
- `api/src/sms_v2/jobs/schedule.js`, `rule_jobs_main.js`, `template_worker_main.js`: job entry points that ship inside the API image (Phase 6b).
- `api/scripts/dry_run_sms_v2_templates.js`: dev-only check of AI drafts against stored layouts, writing nothing back.
- `deploy/tests/test_private_jobs.py`: keeps the rule job and AI worker on the private admin host.

Modified (main ones): `app_database.dart`, `token_store.dart`, `transaction_attachments_repository.dart`, `home_widget_service.dart`, `account_settings_screen.dart`, `push_notification_service.dart`, `auth_api.dart`, `IncomingSmsSpool.swift`, `AppDelegate.swift`, `AndroidManifest.xml`, `pubspec.yaml`, `api/src/index.js`, `api/src/notification_service.js`, `auth/src/config.js`, the Fastfile and CI release build commands.

Deleted: the legacy SMS client pipeline (Task 1.2 list), plaintext-to-encrypted DB conversion code, server-escrowed recovery (D5), legacy server SMS routes and workers (Task 2.1). Email import is kept and hardened (Tasks 1.3, 2.2).

---

## Phase 0: One codebase

### Task 0.1: Save the main checkout's uncommitted work

**Files:** everything listed by `git status` in `/Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs`.

- [ ] **Step 1: Ask the owner which session owns the checkout changes and whether any are abandoned.** Do not discard anything without their answer.
- [ ] **Step 2: Commit the wanted changes on a rescue branch from the checkout's HEAD**

```bash
cd /Users/chandresh_kerkar/Documents/PandaPath/pandapay-docs
git switch -c rescue/main-checkout-2026-11-05
git add -A
git commit -m "chore: save main-checkout work before fresh-start merge"
```

- [ ] **Step 3: Merge into integration in a separate worktree and resolve conflicts.** For legacy files deleted in Phase 1 (`local_sms_parser.dart`, `sms_import_store.dart`, the legacy parts of `providers.dart`), take integration's side. For the login screen, `auth_feedback.dart`, `live_alert_status.dart`, the iOS intake files and the Android fastlane lanes, keep the rescue side and adapt them to integration.

```bash
git worktree add ../pandapay-integration origin/sms-v2/integration -b sms-v2/integration
cd ../pandapay-integration
git merge --no-ff rescue/main-checkout-2026-11-05
```

- [ ] **Step 4: Run the full checks** (`cd app && flutter analyze && flutter test`; `cd api && npm test`; `cd auth && npm test`). Expected: all pass.
- [ ] **Step 5: Commit the merge.**

### Task 0.2: Verify and delete superseded branches

- [ ] **Step 1: For each commit below, check whether integration already contains the change.** A clean reverse-apply means the change is already there.

```bash
cd ../pandapay-integration
for sha in ddd5e13 58d00ed 9bd7088 02b2d0f c5d44f9 3ef60d6; do
  if git show $sha | git apply -R --check 2>/dev/null; then echo "$sha present"; else echo "$sha NOT present - inspect"; fi
done
```

`1b432e0` is a revert of a wallets merge. Skip it if `c5d44f9` is present.

- [ ] **Step 2: For each "NOT present" commit, show its diff to the owner and cherry-pick only what they want.**
- [ ] **Step 3: Delete the local branches** `sms-v2/wp-10-ai-templates sms-v2/wp-12-corrections sms-v2/main-claude-backup sms-v2/wp-03a-banks sms-v2/wp-03b-wallets` with `git branch -D`. Deleting `origin/feature/card-queue-geofence` is a push and needs owner approval.

### Task 0.3: Merge in-flight work

- [ ] **Step 1: Lane X.** When `sms-v2/lane-x-receipt-review` is finished and its tests pass, merge it into `sms-v2/integration`, then delete it and `sms-v2/publish` (same commit `1448435`).
- [ ] **Step 2: Card rewards (D7).** Ask the card-rewards session to consolidate `card-rewards/phase1`, `wp1`–`wp9` into one branch `card-rewards/release`, rebased on `sms-v2/integration`. Measured on 2026-11-05, `card-rewards/wp7-integration` is missing 22 commits of `phase1`, 37 of `wp2-loader`, 15 of `wp8` and 19 of `wp9`. Merge it behind its flag only when its tests pass on top of integration.

### Task 0.4: Remove merged branches and worktrees

- [ ] **Step 1: List the merged local branches**

```bash
git branch --merged sms-v2/integration | grep -v -E '^\*|master|sms-v2/integration'
```

- [ ] **Step 2: Remove their worktrees first** (`git worktree list`, then `git worktree remove <path>` for each clean worktree whose branch is merged; ask before removing any worktree with uncommitted changes). Then delete the branches with `git branch -d` (lowercase: git refuses unmerged ones).
- [ ] **Step 3: Prune remote merged branches only with owner approval** (`git push origin --delete <branch>`).

*(Task 0.5, the final fast-forward of `master`, is in Phase 8.)*

---

## Phase 1: SMS v2 is the only client pipeline

### Task 1.1: Remove the `SMS_PIPELINE_V2` flag

**Files:** delete `app/lib/features/sms_v2/flag.dart`; modify every file returned by `rg -n "kSmsPipelineV2" app/lib app/test`.

- [ ] **Step 1: Write a guard test that fails while the flag exists**

```dart
// app/test/release_guards_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('SMS v2 is unconditional', () {
    final offenders = _dartFiles('lib')
        .where((f) => f.readAsStringSync().contains('kSmsPipelineV2'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}
```

- [ ] **Step 2: Run it.** `cd app && flutter test test/release_guards_test.dart`. Expected: FAIL listing the flag users.
- [ ] **Step 3: Inline the v2 branch at every call site and delete `flag.dart`.**
- [ ] **Step 4: Run** `flutter test --no-pub` without `--dart-define=SMS_PIPELINE_V2=true`. Expected: all pass, including the guard.
- [ ] **Step 5: Commit** `refactor(sms): make SMS v2 the only pipeline`.

### Task 1.2: Delete the legacy client SMS pipeline

**Files (delete after a caller audit with `rg -n "<file stem>" app/lib`):** `app/lib/data/local_sms_parser.dart`, `indian_narration_sanitizer.dart`, `flashtext_merchant_extractor.dart`, `sms_fact_scoring.dart`, `app/lib/data/local/sms_auto_resolution_controller.dart`, `app/lib/features/activity/needs_review_screen.dart`, `app/lib/data/needs_review_repository.dart`, `app/lib/data/local/sms_rule_bundle_store.dart`, `app/lib/data/local/sms_rule_bundle.dart`, `app/lib/data/local/sms_learning_feedback.dart`, `app/lib/data/local/sms_facts_outbox.dart`, `app/lib/features/sms_import/sms_backup_import_screen.dart`, `app/lib/data/sms_backup_xml_parser.dart`, plus their tests. Modify `providers.dart` (legacy upload, AI timer, recipient replay and `reconcileSmsHistory` branches), `user_cards_repository.dart` (`logTransactionFromSms`, `logTransactionsFromSmsBatch`, `reconcileSmsHistory`), and `sms_import_store.dart` (legacy upload bookkeeping).

**Keep:** shared capture, source identity, `SmsSecurityPolicy` safety checks, intake bookkeeping that v2 reads, and the v2 review screens (WP-15). `LocalSmsParser.sensitive` callers switch to `SmsSecurityPolicy.sensitive`.

- [ ] **Step 1: Add guard tests to `app/test/release_guards_test.dart`**

```dart
  test('no client code can upload raw SMS text', () {
    const banned = [
      '/transactions/from-sms',
      '/transactions/reconcile-sms',
      '/transactions/sms-import-state',
      "'/sms/facts'",
      'logTransactionFromSms',
      'logTransactionsFromSmsBatch',
    ];
    final offenders = <String>[];
    for (final f in _dartFiles('lib')) {
      final text = f.readAsStringSync();
      for (final b in banned) {
        if (text.contains(b)) offenders.add('${f.path}: $b');
      }
    }
    expect(offenders, isEmpty);
  });
```

- [ ] **Step 2: Run it.** Expected: FAIL listing the legacy call sites.
- [ ] **Step 3: Delete the files and branches above.** Work inward from `providers.dart`: remove a call, run `flutter analyze`, follow the errors.
- [ ] **Step 4: Run** `flutter analyze && flutter test`. Expected: zero issues, all pass.
- [ ] **Step 5: Commit** `refactor(sms): delete legacy SMS parser, uploads and review`.

### Task 1.3: Consent screen for email import (kept feature, D4)

Email import sends email text to the server, so it needs its own disclosure and consent, separate from SMS and never bundled into the terms.

**Files:** create `app/lib/features/consent/email_import_disclosure.dart` and its widget test. Modify `app/lib/features/import/imap_connection_screen.dart` (show it before the connect form) and `app/lib/features/import/email_forwarding_screen.dart` (show it before the forwarding address is revealed). In `api/src/index.js`, add `'email_import'` to `CONSENT_PURPOSES`. Gmail card discovery stays hidden; do not unhide it in this release.

- [ ] **Step 1: Failing widget test.** "Continue" is disabled until the checkbox is ticked. Dismissing returns `false`. Tick plus Continue posts `POST /consents {purpose: 'email_import', granted: true, policyVersion: '2026-11-15', sourceScreen: <screen>}` and returns `true`.
- [ ] **Step 2: Run. Expected: FAIL.**
- [ ] **Step 3: Implement with exactly this copy:**

> **PandaPay reads your bank emails**
> - Connecting your mailbox lets PandaPay check it regularly for emails from your banks and cards and record those transactions. Forwarded emails are read the same way.
> - Only emails from bank and card senders are read. Other emails are not opened.
> - The email text is sent to PandaPay to read the transaction and deleted once it has been read. Emails PandaPay couldn't read are kept for up to 30 days so you can review them.
> - Your mailbox app password is stored encrypted and used only to read these emails. Disconnecting deletes it.
>
> ☐ I agree to PandaPay reading my bank emails as described.
> [Continue] [Not now]

- [ ] **Step 4: Run. Expected: PASS. Commit** `feat(consent): email import disclosure`.

### Task 1.4: Delete code that only existed for old installs

**Files:** delete `app/lib/data/secure_storage/encrypted_database_copy.dart`, `encrypted_database_migration.dart` and their tests. A fresh install has no plaintext database to convert. Remove the WP-16 legacy replay entry points (`rg -n "legacy" app/lib/features/sms_v2/migration`) while keeping the v2-only category refresh. Remove the SharedPreferences-to-secure-storage migration in `TokenStore.load()` (`token_store.dart`, the `legacyAccess`/`legacyRefresh` block). For D5, delete `app/lib/data/portable_backup/account_recovery_*.dart`, `automatic_recovery_scheduler.dart`, `app/lib/features/recovery/automatic_account_recovery.dart`, `account_data_recovery.dart`, `recovery_deferred_sms.dart` and `Env.accountDataRecoveryEnabled`, and keep the passphrase file export (`portable_crypto.dart`, `portable_backup.dart`, `portable_restore*.dart`) if the Data transfer screen uses it.

- [ ] **Step 1: Delete, then `flutter analyze` and follow errors.**
- [ ] **Step 2: `flutter test`. Expected: pass.**
- [ ] **Step 3: Commit** `refactor: remove legacy migration and escrowed recovery`.

---

## Phase 2: Server keeps only what the new app uses

### Task 2.1: Delete legacy SMS routes and workers

**Files:** `api/src/index.js`: delete `POST /transactions/from-sms`, `POST /transactions/from-sms/batch`, `POST /transactions/reconcile-sms`, `GET /transactions/sms-import-state`, the `parser_failures` writes and `redactSmsShape` use. Delete `api/src/sms_facts_route.js` (legacy `POST /sms/facts`), `sms_learning.js`, `sms_learning_feedback_route.js`, `sms_learning_worker_runner.js`, and the per-message AI path (`ai_queue_route.js`, `gemini_queue.js`, `gemini_worker.js`, `ai_provider_quota_route.js`). **First run** `rg -n "require\('\.\./(gemini|ai_)|require\('\./(gemini|ai_)" api/src/sms_v2`. Any module the v2 AI templates (`api/src/sms_v2/ai_templates.js`) import stays. **Keep** `api/src/sms_parser.js`, `importParsedMessage` and everything else the email path uses (`api/src/imap_poller.js`, `POST /inbound-emails/webhook`, `POST /inbound-emails/:id/create-transaction`). Before deleting any shared helper, run `rg -n "<helper>" api/src/imap_poller.js` and check the inbound-email handlers in `index.js`. If the email path writes `parser_failures`, keep that write and that table. Remove `worker:gemini` and `worker:sms-learning` from `api/package.json`, and their services from `deploy/docker-compose*.yml`.

- [ ] **Step 1: Write the guard test**

```js
// api/test/release_guards.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const src = path.join(__dirname, '..', 'src');
const files = fs.readdirSync(src, { recursive: true })
  .filter((f) => f.endsWith('.js'))
  .map((f) => path.join(src, f));

test('server has no route that accepts raw SMS text', () => {
  const banned = ["'/transactions/from-sms'", "'/transactions/from-sms/batch'",
    "'/transactions/reconcile-sms'", "'/transactions/sms-import-state'", "'/sms/facts'"];
  const hits = [];
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    for (const b of banned) if (text.includes(b)) hits.push(`${path.relative(src, f)}: ${b}`);
  }
  assert.deepEqual(hits, []);
});
```

- [ ] **Step 2: `cd api && node --test test/release_guards.test.js`. Expected: FAIL.**
- [ ] **Step 3: Delete the routes and files, and delete tests that only covered deleted code.**
- [ ] **Step 4: `npm test`. Expected: PASS.**
- [ ] **Step 5: Commit** `refactor(api): remove legacy SMS routes and workers`.

### Task 2.2: Harden email import on the server (kept feature, D4)

Checked on 2026-11-05:
- The forwarding webhook already requires `INBOUND_EMAIL_WEBHOOK_SECRET` with a constant-time compare.
- The mailbox poller skips messages it can't parse instead of storing them.
- `inbound_emails.body_text` is scrubbed by the maintenance job after `purge_after` (30 days).

Four gaps remain:
1. Mailbox passwords are encrypted with `pgp_sym_encrypt($3, $4)` (`index.js` `POST /imap-connections`), so the encryption key travels to PostgreSQL as a query parameter, where statement logging or `pg_stat_statements` can capture it.
2. `sender_filter` is optional, so a connection can poll the whole mailbox.
3. Email text that was parsed successfully still waits up to 30 days.
4. There is no consent record (handled in Task 1.3).

**Files:** create `api/src/imap_credentials.js` and `api/test/imap_credentials.test.js`. Modify `index.js` (`POST /imap-connections`, `POST /imap-connections/:id/test`, the inbound-email webhook), `api/src/imap_poller.js` (decrypt through the new module, require a sender filter), `api/src/config.js` (`imapEncryptionKey` must be 32 bytes, base64, with a key id), and add migration `db/supabase/migrations/20261115020000_imap_credentials_app_encryption.sql`.

- [ ] **Step 1: Failing tests**

```js
// api/test/imap_credentials.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { sealPassword, openPassword, normalizeSenderFilter } = require('../src/imap_credentials');

const key = { id: 'k1', bytes: crypto.randomBytes(32) };

test('password round-trips and is bound to its connection', () => {
  const sealed = sealPassword('app-pass-123', { profileId: 'p1', connectionId: 'c1' }, key);
  assert.equal(openPassword(sealed, { profileId: 'p1', connectionId: 'c1' }, new Map([['k1', key.bytes]])), 'app-pass-123');
  assert.throws(() => openPassword(sealed, { profileId: 'p2', connectionId: 'c1' }, new Map([['k1', key.bytes]])));
});

test('sealed value never contains the password', () => {
  const sealed = sealPassword('app-pass-123', { profileId: 'p1', connectionId: 'c1' }, key);
  assert.ok(!sealed.ciphertext.toString('latin1').includes('app-pass-123'));
  assert.equal(sealed.keyId, 'k1');
});

test('a sender filter is required and limited to bank sender domains', () => {
  assert.throws(() => normalizeSenderFilter(''), /sender_filter_required/);
  assert.throws(() => normalizeSenderFilter('*'), /sender_filter_required/);
  assert.deepEqual(normalizeSenderFilter(' alerts@hdfcbank.net, CreditCards@icicibank.com '),
    ['alerts@hdfcbank.net', 'creditcards@icicibank.com']);
});
```

- [ ] **Step 2: Run `node --test test/imap_credentials.test.js`. Expected: FAIL.**
- [ ] **Step 3: Implement**

```js
// api/src/imap_credentials.js
const crypto = require('node:crypto');

const aad = ({ profileId, connectionId }, keyId) =>
  Buffer.from(JSON.stringify(['pandapay-imap-v1', profileId, connectionId, keyId]));

/** AES-256-GCM in the API process; the key never reaches PostgreSQL. */
function sealPassword(password, binding, key) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key.bytes, nonce);
  cipher.setAAD(aad(binding, key.id));
  const body = Buffer.concat([cipher.update(password, 'utf8'), cipher.final()]);
  return { keyId: key.id, ciphertext: Buffer.concat([nonce, cipher.getAuthTag(), body]) };
}

function openPassword(sealed, binding, keysById) {
  const keyBytes = keysById.get(sealed.keyId);
  if (!keyBytes) throw new Error('imap_key_unavailable');
  const data = sealed.ciphertext;
  const decipher = crypto.createDecipheriv('aes-256-gcm', keyBytes, data.subarray(0, 12));
  decipher.setAAD(aad(binding, sealed.keyId));
  decipher.setAuthTag(data.subarray(12, 28));
  return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString('utf8');
}

const EMAIL = /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/;

/** Only explicit sender addresses; never the whole mailbox. */
function normalizeSenderFilter(raw) {
  const list = String(raw || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (list.length === 0 || list.some((s) => !EMAIL.test(s))) throw new Error('sender_filter_required');
  return list;
}

module.exports = { sealPassword, openPassword, normalizeSenderFilter };
```

Migration: `alter table imap_connections drop column app_password_encrypted, add column app_password_ciphertext bytea not null, add column app_password_key_id text not null, alter column sender_filter set not null;` The production product DB starts empty (Phase 8), so no re-encryption is needed. The connection id used in the AAD must exist before sealing: generate the UUID in the API and insert it explicitly. The default sender list comes from the bank sender addresses already used by the email parser patterns. The connect screen pre-fills it, and the user can only remove entries.

- [ ] **Step 4: Delete parsed email text right away.** In the inbound-email webhook and the poller, after a transaction is created (`UPDATE inbound_emails SET produced_txn_id = …`), also set `body_text = null` in the same statement. Write a failing PostgreSQL test first: a parsed forwarded email has `body_text IS NULL` and an unparsed one keeps its text until `purge_after`.
- [ ] **Step 5: Disconnect deletes the credential.** Check that a disconnect route exists (`rg -n "app.delete\('/imap-connections" api/src/index.js`). If it doesn't, add `DELETE /imap-connections/:id`, which deletes the row (the password goes with it), with a test. Account deletion already cascades through `profile_id … on delete cascade`.
- [ ] **Step 6: `npm test`. Expected: PASS. Commit** `feat(email): encrypt mailbox passwords in the API, require bank senders, delete parsed email text`.

### Task 2.3: Drop legacy tables

**Files:** create `db/supabase/migrations/20261115000000_fresh_start_drop_legacy.sql`; update `api/src/portable_backup/coverage.json` (its test compares coverage against migrations).

- [ ] **Step 1: On a scratch database built from migrations, list what depends on each candidate table** (views, functions, foreign keys):

```sql
select distinct c.relname as dependent, t.relname as table_name
from pg_depend d
join pg_rewrite r on r.oid = d.objid
join pg_class c on c.oid = r.ev_class
join pg_class t on t.oid = d.refobjid
where t.relname in ('parser_failures',
  'needs_review_items','sms_learning_feedback','sms_learning_feedback_events','sms_learning_examples',
  'sms_learning_settings','sms_learning_worker_runs','sms_learning_candidate_decisions',
  'sms_ai_learning_proposals','ai_jobs','ai_events','ai_quota_days',
  'ai_provider_capacity_checks','ai_provider_reservations')
  and c.relname <> t.relname;
```

Any `ai_*` table that `api/src/sms_v2` still reads (Task 2.1 audit) is removed from the drop list. `imap_connections`, `imap_worker`, `inbound_emails` and `forwarding_addresses` stay (email import is kept). Remove `parser_failures` and `needs_review_items` from the drop list too if the email path still writes them.

- [ ] **Step 2: Write the migration** (one `drop table if exists <name>;` per table without CASCADE; drop dependent views or functions explicitly first).
- [ ] **Step 3: Apply all migrations to an empty scratch database, then run `cd api && npm test` (including the PostgreSQL tests). Expected: PASS. Update `coverage.json` until its test passes.**
- [ ] **Step 4: Commit** `feat(db): drop legacy SMS and AI tables`.

---

## Phase 3: Phone storage security

### Task 3.1: One backup-excluded storage root

**Files:** create `app/lib/data/local/storage_paths.dart`, `app/test/data/local/storage_paths_test.dart`, `app/android/app/src/main/res/xml/data_extraction_rules.xml`. Modify `app/ios/Runner/AppDelegate.swift` (register the `pandapay/storage` channel where the file's other `FlutterMethodChannel(name:` channels are registered) and `AndroidManifest.xml`.

**Interfaces produced:** `StoragePaths.resolve()`, `.databasePath`, `.receiptsDir`, `.wipe()`.

- [ ] **Step 1: Failing test**

```dart
// app/test/data/local/storage_paths_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/storage_paths.dart';

void main() {
  late Directory support;
  late List<String> excluded;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('support');
    excluded = [];
  });
  tearDown(() => support.delete(recursive: true));

  Future<StoragePaths> make() => StoragePaths.create(
        supportDirectory: () async => support,
        excludeFromBackup: (path) async => excluded.add(path),
      );

  test('all account files live under Application Support/PandaPay', () async {
    final paths = await make();
    expect(paths.databasePath, '${support.path}/PandaPay/pandapay.sqlite');
    expect(paths.receiptsDir.path, '${support.path}/PandaPay/receipts');
    expect(excluded, ['${support.path}/PandaPay']);
  });

  test('wipe deletes everything and re-excludes the empty root', () async {
    final paths = await make();
    await File(paths.databasePath).writeAsString('x');
    await paths.receiptsDir.create(recursive: true);
    await paths.wipe();
    expect(File(paths.databasePath).existsSync(), isFalse);
    expect(paths.receiptsDir.existsSync(), isFalse);
    expect(Directory('${support.path}/PandaPay').existsSync(), isTrue);
    expect(excluded.length, 2);
  });
}
```

(The app package name is `pandapay`.)

- [ ] **Step 2: `flutter test test/data/local/storage_paths_test.dart`. Expected: FAIL (file missing).**
- [ ] **Step 3: Implement**

```dart
// app/lib/data/local/storage_paths.dart
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Every file that holds account data lives under one private root,
/// Application Support/PandaPay, never Documents. iOS excludes the root from
/// iCloud and computer backups; Android blocks backup and device transfer in
/// the manifest.
class StoragePaths {
  StoragePaths._(this.root, this._excludeFromBackup);

  final Directory root;
  final Future<void> Function(String path) _excludeFromBackup;

  static const _channel = MethodChannel('pandapay/storage');
  static Future<StoragePaths>? _shared;

  static Future<StoragePaths> resolve() => _shared ??= create(
        supportDirectory: getApplicationSupportDirectory,
        excludeFromBackup: (path) async {
          if (Platform.isIOS) {
            await _channel.invokeMethod<void>('excludeFromBackup', {'path': path});
          }
        },
      );

  static Future<StoragePaths> create({
    required Future<Directory> Function() supportDirectory,
    required Future<void> Function(String path) excludeFromBackup,
  }) async {
    final support = await supportDirectory();
    final root = Directory(p.join(support.path, 'PandaPay'));
    await root.create(recursive: true);
    await excludeFromBackup(root.path);
    return StoragePaths._(root, excludeFromBackup);
  }

  String get databasePath => p.join(root.path, 'pandapay.sqlite');
  Directory get receiptsDir => Directory(p.join(root.path, 'receipts'));

  /// Deletes every account file. Close database connections first.
  Future<void> wipe() async {
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
    await _excludeFromBackup(root.path);
  }
}
```

```swift
// AppDelegate.swift, next to the other channel registrations
let storageChannel = FlutterMethodChannel(name: "pandapay/storage", binaryMessenger: messenger)
storageChannel.setMethodCallHandler { call, result in
  guard call.method == "excludeFromBackup",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String else { result(FlutterMethodNotImplemented); return }
  do {
    var url = URL(fileURLWithPath: path, isDirectory: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    result(nil)
  } catch {
    result(FlutterError(code: "backup_exclusion_failed", message: nil, details: nil))
  }
}
```

```xml
<!-- app/android/app/src/main/res/xml/data_extraction_rules.xml -->
<?xml version="1.0" encoding="utf-8"?>
<!-- allowBackup="false" alone does not stop Android 12+ device-to-device transfer. -->
<data-extraction-rules>
    <cloud-backup>
        <exclude domain="root" path="." />
        <exclude domain="file" path="." />
        <exclude domain="database" path="." />
        <exclude domain="sharedpref" path="." />
        <exclude domain="external" path="." />
    </cloud-backup>
    <device-transfer>
        <exclude domain="root" path="." />
        <exclude domain="file" path="." />
        <exclude domain="database" path="." />
        <exclude domain="sharedpref" path="." />
        <exclude domain="external" path="." />
    </device-transfer>
</data-extraction-rules>
```

In `AndroidManifest.xml`, on `<application>`, keep `android:allowBackup="false"` and add `android:fullBackupContent="false"` and `android:dataExtractionRules="@xml/data_extraction_rules"`.

- [ ] **Step 4: Run the test. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(storage): one backup-excluded root for account files`.

### Task 3.2: SQLCipher with the install key

**Files:** `app/pubspec.yaml` (remove `sqlite3_flutter_libs`; add `sqlcipher_flutter_libs`, choosing the newest 0.6.x that resolves with `sqlite3: ^2.9.4`). Create `app/lib/data/local/database_key.dart` and `app/test/data/local/database_key_test.dart`. Modify `app_database.dart` (`open`, `openFile`, `withRecoveryDatabase`), `financial_read_worker.dart:209`, `sms_capture_worker.dart:146`, `sms_listener_service.dart:70`, `ios_sms_background.dart`, `main.dart`. Device test: `app/integration_test/encrypted_database_test.dart`.

**Interfaces produced:** `ensureSqlCipherLoaded()`, `applyCipherKey(Database, String keyHex)`, `DatabaseKeyLoader.loadHex({required bool databaseExists})`, `AppDatabase.openFile(String path, {required String keyHex})`.

- [ ] **Step 1: Failing tests** (host tests run against system SQLite, which has no SQLCipher, so the guard must refuse):

```dart
// app/test/data/local/database_key_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/database_key.dart';

void main() {
  test('rejects a key that is not 64 lowercase hex characters', () {
    final db = sqlite3.openInMemory();
    expect(() => applyCipherKey(db, 'abc'), throwsArgumentError);
    db.dispose();
  });

  test('refuses to run when SQLCipher is not linked', () {
    final db = sqlite3.openInMemory();
    expect(() => applyCipherKey(db, 'a' * 64), throwsStateError);
    db.dispose();
  });

  test('hex encoding of key bytes', () {
    expect(keyBytesToHex([0, 1, 255, 16]), '0001ff10');
  });
}
```

- [ ] **Step 2: Run. Expected: FAIL (file missing).**
- [ ] **Step 3: Implement**

```dart
// app/lib/data/local/database_key.dart
import 'dart:io';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../secure_storage/flutter_secure_key_value_store.dart';
import '../secure_storage/local_database_key_custody.dart';

final _hexKey = RegExp(r'^[0-9a-f]{64}$');

/// Call once in every isolate before the first sqlite3 use (main, workers,
/// background SMS entry points). iOS links SQLCipher statically; Android
/// must load libsqlcipher instead of the system libsqlite.
void ensureSqlCipherLoaded() {
  if (Platform.isAndroid) {
    open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
  }
}

String keyBytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Must run before any other statement on the connection.
void applyCipherKey(Database db, String keyHex) {
  if (!_hexKey.hasMatch(keyHex)) throw ArgumentError('Invalid database key');
  db.execute("PRAGMA key = \"x'$keyHex'\"");
  final rows = db.select('PRAGMA cipher_version');
  final version = rows.isEmpty ? null : rows.first.values.first as String?;
  if (version == null || version.isEmpty) {
    throw StateError('SQLCipher is not linked; refusing to open an unencrypted database');
  }
  // A wrong key fails here with SQLITE_NOTADB (26).
  db.select('SELECT count(*) FROM sqlite_master');
}

final class DatabaseKeyUnavailable implements Exception {
  const DatabaseKeyUnavailable(this.status);
  final LocalKeyStatus status;
  @override
  String toString() => 'DatabaseKeyUnavailable(${status.name})';
}

/// The single install key. Never derived from the account; destroyed on
/// sign-out by deleting secure storage.
class DatabaseKeyLoader {
  DatabaseKeyLoader({required this.installId, LocalDatabaseKeyCustody? custody})
      : _custody = custody ?? LocalDatabaseKeyCustody(FlutterSecureKeyValueStore());

  final String installId;
  final LocalDatabaseKeyCustody _custody;

  Future<String> loadHex({required bool databaseExists}) async {
    final result = await _custody.openKey(
      installId: installId,
      encryptedManifestExists: databaseExists,
    );
    final handle = result.handle;
    if (handle == null) throw DatabaseKeyUnavailable(result.status);
    try {
      return handle.withKeyBytes(keyBytesToHex);
    } finally {
      handle.dispose();
    }
  }
}
```

In `app_database.dart`:

```dart
static Future<AppDatabase> open() async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return AppDatabase._(sqlite3.openInMemory());
  }
  ensureSqlCipherLoaded();
  final paths = await StoragePaths.resolve();
  final installId = await DeviceIdentity().localDeviceId(); // same source as localDeviceIdProvider
  final exists = File(paths.databasePath).existsSync();
  String keyHex;
  try {
    keyHex = await DatabaseKeyLoader(installId: installId).loadHex(databaseExists: exists);
  } on DatabaseKeyUnavailable catch (e) {
    if (e.status == LocalKeyStatus.unavailable || e.status == LocalKeyStatus.busy) rethrow;
    // Key lost or bound to another install: the file can never be read again.
    // Server data re-syncs after sign-in; start empty.
    await paths.wipe();
    keyHex = await DatabaseKeyLoader(installId: installId).loadHex(databaseExists: false);
  }
  return openFile(paths.databasePath, keyHex: keyHex);
}

static AppDatabase openFile(String path, {required String keyHex}) {
  final absolute = p.normalize(File(path).absolute.path);
  if (_recoveryPaths.contains(absolute)) {
    throw StateError('Account recovery has exclusive local storage access');
  }
  final db = sqlite3.open(absolute);
  try {
    applyCipherKey(db, keyHex);
  } catch (_) {
    db.dispose();
    rethrow;
  }
  return AppDatabase._(db, filePath: absolute, keyHex: keyHex);
}
```

Store `keyHex` on the instance (private field, excluded from `toString`). Pass it in the isolate arguments of `financial_read_worker.dart` and `sms_capture_worker.dart` next to the path (`arguments[2]`), and call `ensureSqlCipherLoaded()` at the top of each worker entry point. `withRecoveryDatabase` calls `applyCipherKey(recovery, _keyHex!)` immediately after `sqlite3.open(location)`. `DatabaseKeyUnavailable(unavailable)` in a background SMS path means the phone has not been unlocked since boot: exit without processing. The native spool keeps the message.

iOS check: open `app/ios/Runner.xcodeproj/project.pbxproj` and remove any explicit `libsqlite3.tbd` link, because SQLCipher provides the SQLite API. The Swift spool keeps working: SQLCipher opens unkeyed databases normally.

- [ ] **Step 4: Run host tests. Expected: PASS.** Then write the device test:

```dart
// app/integration_test/encrypted_database_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/database_key.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('database file is unreadable without the key', (_) async {
    ensureSqlCipherLoaded();
    final dir = await Directory.systemTemp.createTemp('cipher');
    final path = '${dir.path}/t.sqlite';
    final key = 'ab' * 32;
    final db = sqlite3.open(path);
    applyCipherKey(db, key);
    db.execute('CREATE TABLE t(v TEXT)');
    db.execute("INSERT INTO t VALUES ('secret')");
    db.dispose();
    final header = File(path).readAsBytesSync().take(15).toList();
    expect(String.fromCharCodes(header), isNot('SQLite format 3'));
    final wrong = sqlite3.open(path);
    expect(() => applyCipherKey(wrong, 'cd' * 32), throwsA(isA<SqliteException>()));
    wrong.dispose();
  });
}
```

Run on the iOS simulator and an Android emulator: `flutter test integration_test/encrypted_database_test.dart -d <device>`. Expected: PASS on both.

- [ ] **Step 5: Commit** `feat(storage): encrypt the local database with SQLCipher`.

### Task 3.3: Clear Keychain leftovers after a reinstall

**Files:** create `app/lib/data/secure_storage/install_guard.dart` and `app/test/data/secure_storage/install_guard_test.dart`. Modify `app/lib/main.dart` (run before `TokenStore.load()`) and `ios_sms_background.dart` (run before opening the DB).

- [ ] **Step 1: Failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/secure_storage/install_guard.dart';

void main() {
  test('first launch clears secure storage once and sets the marker', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var clears = 0;
    final guard = InstallGuard(prefs: prefs, clearSecureStorage: () async => clears++);
    expect(await guard.run(), isTrue);
    expect(await guard.run(), isFalse);
    expect(clears, 1);
    expect(prefs.getBool(InstallGuard.markerKey), isTrue);
  });
}
```

- [ ] **Step 2: Run. Expected: FAIL.**
- [ ] **Step 3: Implement**

```dart
// app/lib/data/secure_storage/install_guard.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iOS keeps Keychain items after the app is deleted; SharedPreferences
/// (NSUserDefaults) do not survive. A missing marker therefore means a fresh
/// install, so remove every leftover token and key before anything reads them.
class InstallGuard {
  InstallGuard({required this.prefs, required this.clearSecureStorage});

  static const markerKey = 'pandapay.install_marker.v1';
  final SharedPreferences prefs;
  final Future<void> Function() clearSecureStorage;

  Future<bool> run() async {
    if (prefs.getBool(markerKey) == true) return false;
    await clearSecureStorage();
    await prefs.setBool(markerKey, true);
    return true;
  }

  /// Both option sets the app writes with, because an iOS delete query
  /// includes the accessibility class.
  static Future<void> clearAllSecureStorage() async {
    await const FlutterSecureStorage().deleteAll();
    await const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
        synchronizable: false,
      ),
    ).deleteAll();
  }
}
```

In `main.dart`, before `TokenStore.load()`: `await InstallGuard(prefs: await SharedPreferences.getInstance(), clearSecureStorage: InstallGuard.clearAllSecureStorage).run();`. Also move `TokenStore`'s own storage to the `first_unlock_this_device` options so background SMS work can refresh while the phone is locked.

- [ ] **Step 4: Run. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(security): clear Keychain leftovers after reinstall`.

### Task 3.4: Encrypt receipt files

**Files:** modify `app/lib/data/local/transaction_attachments_repository.dart` (root becomes `StoragePaths.receiptsDir`; `addFromPath` and `addFromBytes` write through `EncryptedReceiptFileStore.copyEncrypted`; viewing uses `decryptToPrivateWorkspace`, defined in `encrypted_receipt_file.dart:295`). Test: `app/test/data/local/transaction_attachments_repository_test.dart`.

- [ ] **Step 1: Failing test.** Add a receipt from bytes `[1,2,3]` with an in-memory `SecureKeyValueStore` fake. Assert that the stored file's first 4 bytes equal `EncryptedReceiptFileCodec.magic` (`PPRC`), that the file does not contain the plaintext, and that reading it back returns `[1,2,3]`.
- [ ] **Step 2: Run. Expected: FAIL (file is plaintext).**
- [ ] **Step 3: Implement.** Get the key with `LocalReceiptKeyCustody(FlutterSecureKeyValueStore()).openKey(installId: <install id>, accountNamespace: <cacheNamespace, e.g. user:<uuid>>, encryptedReceiptsExist: receiptsDir has files)`, then `handle.withSecretKey((key) => store.copyEncrypted(source: …, destination: …, key: key, accountNamespace: …, attachmentId: attachment.id, keyVersion: handle.version))`. For `addFromBytes`, write the bytes to a file in the private temporary workspace (`app/lib/data/portable_backup/private_temporary_workspace.dart`), encrypt from it, then delete it in `finally`. Delete decrypted viewer copies when the viewer closes.
- [ ] **Step 4: Run. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(security): encrypt receipt files at rest`.

### Task 3.5: Encrypt SMS text in the iOS spool

**Files:** create `app/ios/Runner/SpoolCipher.swift` (add to the Runner target in `project.pbxproj`). Modify `IncomingSmsSpool.swift` (seal `body` and `sender` on insert at the capture path around `capture(body:sender:…)`, open them when handing captures to Flutter, and call `SpoolCipher.destroyKey()` in the reset that runs `DELETE FROM` on every table). Add `case cipher, keyUnavailable` to `IncomingSmsError`. Tests: `app/test/native/incoming_sms_spool_test.swift` (run it the same way as the file's existing tests).

- [ ] **Step 1: Failing tests:** (a) after `capture`, the raw `captures.body` column starts with `v1:` and does not contain the message; (b) the handoff read returns the original text; (c) after reset, a new capture still works (a new key is created).
- [ ] **Step 2: Run. Expected: FAIL.**
- [ ] **Step 3: Implement**

```swift
// app/ios/Runner/SpoolCipher.swift
import CryptoKit
import Foundation
import Security

/// Encrypts SMS text at rest in the native spool. The key never leaves the
/// Keychain item, is usable after the first unlock (Shortcut captures run
/// while the phone is locked) and never syncs or moves to another device.
enum SpoolCipher {
  private static let service = "app.pandapay.spool"
  private static let account = "body-key.v1"

  static func seal(_ text: String) throws -> String {
    let box = try AES.GCM.seal(Data(text.utf8), using: try key(create: true))
    guard let combined = box.combined else { throw IncomingSmsError.cipher }
    return "v1:" + combined.base64EncodedString()
  }

  static func open(_ stored: String) throws -> String {
    guard stored.hasPrefix("v1:"),
          let data = Data(base64Encoded: String(stored.dropFirst(3))) else { throw IncomingSmsError.cipher }
    let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: try key(create: false))
    guard let text = String(data: plain, encoding: .utf8) else { throw IncomingSmsError.cipher }
    return text
  }

  static func destroyKey() {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                   kSecAttrService as String: service,
                   kSecAttrAccount as String: account] as CFDictionary)
  }

  private static func key(create: Bool) throws -> SymmetricKey {
    var item: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecAttrAccount as String: account,
                                      kSecReturnData as String: true] as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
    guard status == errSecItemNotFound, create else { throw IncomingSmsError.keyUnavailable }
    let fresh = SymmetricKey(size: .bits256)
    let raw = fresh.withUnsafeBytes { Data($0) }
    let added = SecItemAdd([kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account,
                            kSecValueData as String: raw,
                            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    if added == errSecDuplicateItem { return try key(create: false) }
    guard added == errSecSuccess else { throw IncomingSmsError.keyUnavailable }
    return fresh
  }
}
```

The dedupe fingerprints (`SHA256` at `IncomingSmsSpool.swift:327/362`) keep hashing the plaintext before sealing. Keep the size checks on the plaintext; the capacity check may count ciphertext bytes.

- [ ] **Step 4: Run. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(security): encrypt SMS text in the iOS spool`.

### Task 3.6: Clear home widget data

**Files:** modify `app/lib/features/home_widget/home_widget_service.dart` (add `static const allDataKeys = <String>[…every *Key constant…]` and `clearAll()`). Test: `app/test/features/home_widget/home_widget_service_test.dart`.

- [ ] **Step 1: Failing test.** Mock the `home_widget` method channel with `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`. Call `clearAll()` and assert one `saveWidgetData` call with `data == null` for every key in `allDataKeys`, followed by `updateWidget` calls.
- [ ] **Step 2: Run. Expected: FAIL.**
- [ ] **Step 3: Implement.** For each key that holds a file path, read it with `HomeWidget.getWidgetData<String>(key)` and delete the file. Then `HomeWidget.saveWidgetData<String>(key, null)` for every key, then `HomeWidget.updateWidget(...)` for each widget name used in `configure()`.
- [ ] **Step 4: Run. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(security): clear home widget data`.

---

## Phase 4: Sessions and server-backed data

### Task 4.1: `DELETE /notification-devices`

**Files:** create `api/src/notification_devices_route.js` and `api/test/notification_devices_route.test.js`. Modify `api/src/notification_service.js` (add `unregisterDevice`) and `api/src/index.js` (register the route next to `POST /notification-devices`).

- [ ] **Step 1: Confirm the Novu semantics** for `PUT /v1/subscribers/{id}/credentials` (replace or append `deviceTokens`) in the Novu API reference for the version in use. The code below assumes replace. If the API appends, use the documented call for removing a token instead.
- [ ] **Step 2: Failing test**

```js
// api/test/notification_devices_route.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerNotificationDeviceRoutes } = require('../src/notification_devices_route');

test('DELETE /notification-devices removes only this phone token', async () => {
  const calls = [];
  const app = express();
  app.use(express.json());
  registerNotificationDeviceRoutes(app, {
    requireAuth: (req, _res, next) => { req.userId = 'u1'; next(); },
    notificationService: { unregisterDevice: async (args) => { calls.push(args); } },
  });
  const server = app.listen(0);
  const { port } = server.address();
  const res = await fetch(`http://127.0.0.1:${port}/notification-devices`, {
    method: 'DELETE',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: 'x'.repeat(20) }),
  });
  server.close();
  assert.equal(res.status, 204);
  assert.deepEqual(calls, [{ subscriberId: 'u1', token: 'x'.repeat(20) }]);
});
```

- [ ] **Step 3: Run** `node --test test/notification_devices_route.test.js`. Expected: FAIL.
- [ ] **Step 4: Implement**

```js
// api/src/notification_devices_route.js
function registerNotificationDeviceRoutes(app, { requireAuth, notificationService }) {
  app.delete('/notification-devices', requireAuth, async (req, res) => {
    const { token } = req.body || {};
    if (typeof token !== 'string' || token.trim().length < 10 || token.length > 4096) {
      return res.status(400).json({ error: 'A valid FCM token is required' });
    }
    try {
      await notificationService.unregisterDevice({ subscriberId: req.userId, token: token.trim() });
      return res.status(204).end();
    } catch (_) {
      return res.status(502).json({ error: 'notification_provider_unavailable' });
    }
  });
}
module.exports = { registerNotificationDeviceRoutes };
```

```js
// notification_service.js: add and export
async function unregisterDevice({ subscriberId, token }) {
  if (!isConfigured()) return;
  const id = encodeURIComponent(subscriberId);
  const current = await request(`/v1/subscribers/${id}`, { method: 'GET' });
  if (current.status === 404) return;
  if (!current.ok) throw new Error('subscriber_lookup_failed');
  const body = await readJson(current);
  const fcm = (body?.data?.channels || []).find((c) => c.providerId === 'fcm');
  const remaining = (fcm?.credentials?.deviceTokens || []).filter((t) => t !== token);
  const update = await request(`/v1/subscribers/${id}/credentials`, {
    method: 'PUT',
    body: JSON.stringify({
      providerId: 'fcm',
      ...(config.notificationServiceFcmIntegrationIdentifier
        ? { integrationIdentifier: config.notificationServiceFcmIntegrationIdentifier }
        : {}),
      credentials: { deviceTokens: remaining },
    }),
  });
  if (!update.ok) throw new Error('credential_update_failed');
}
```

- [ ] **Step 5: Run. Expected: PASS. `npm test` passes. Commit** `feat(api): unregister a phone from push on sign-out`.

### Task 4.2: Sign-out that revokes, unregisters and wipes

**Files:** create `app/lib/features/auth/account_sign_out.dart` and `app/test/features/auth/account_sign_out_test.dart`. Modify `auth_api.dart` (add `logout`), `push_notification_service.dart` (add `unregister()`), `account_settings_screen.dart` (`_signOut` and the post-deletion sign-out use the orchestrator), and `providers.dart` (provider wiring).

**Interfaces produced:** `AccountSignOut.prepare() -> Future<SignOutReport>`, `AccountSignOut.run()`. `SignOutReport { int unsynced; int phoneOnlyReceipts; int phoneOnlyReviewItems; }`.

- [ ] **Step 1: Failing test (order and offline behaviour)**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';

void main() {
  AccountSignOut build(List<String> log, {bool offline = false}) => AccountSignOut(
        flushOutboxes: () async => log.add('flush'),
        report: () async => const SignOutReport(unsynced: 2, phoneOnlyReceipts: 1, phoneOnlyReviewItems: 3),
        unregisterPush: () async { log.add('push'); if (offline) throw Exception('offline'); },
        revokeSession: () async { log.add('revoke'); if (offline) throw Exception('offline'); },
        closeDatabases: () async => log.add('close'),
        destroyKeysAndTokens: () async => log.add('keys'),
        deleteFiles: () async => log.add('files'),
        clearWidgetsAndNotifications: () async => log.add('widgets'),
        clearPreferences: () async => log.add('prefs'),
        resetSession: () => log.add('reset'),
      );

  test('prepare uploads first, then reports what would be lost', () async {
    final log = <String>[];
    final report = await build(log).prepare();
    expect(log, ['flush']);
    expect(report.unsynced, 2);
  });

  test('run revokes on the server before destroying keys, then deletes files', () async {
    final log = <String>[];
    await build(log).run();
    expect(log, ['push', 'revoke', 'close', 'keys', 'files', 'widgets', 'prefs', 'reset']);
  });

  test('an offline sign-out still wipes the phone', () async {
    final log = <String>[];
    await build(log, offline: true).run();
    expect(log.last, 'reset');
    expect(log, containsAllInOrder(['keys', 'files']));
  });
}
```

- [ ] **Step 2: Run. Expected: FAIL.**
- [ ] **Step 3: Implement**

```dart
// app/lib/features/auth/account_sign_out.dart
class SignOutReport {
  const SignOutReport({required this.unsynced, required this.phoneOnlyReceipts, required this.phoneOnlyReviewItems});
  final int unsynced;
  final int phoneOnlyReceipts;
  final int phoneOnlyReviewItems;
  bool get losesSomething => unsynced + phoneOnlyReceipts + phoneOnlyReviewItems > 0;
}

/// Order matters: server calls need the refresh token; keys are destroyed
/// before files so a crash mid-wipe leaves only unreadable ciphertext.
class AccountSignOut {
  AccountSignOut({
    required this.flushOutboxes,
    required this.report,
    required this.unregisterPush,
    required this.revokeSession,
    required this.closeDatabases,
    required this.destroyKeysAndTokens,
    required this.deleteFiles,
    required this.clearWidgetsAndNotifications,
    required this.clearPreferences,
    required this.resetSession,
  });

  final Future<void> Function() flushOutboxes;
  final Future<SignOutReport> Function() report;
  final Future<void> Function() unregisterPush;
  final Future<void> Function() revokeSession;
  final Future<void> Function() closeDatabases;
  final Future<void> Function() destroyKeysAndTokens;
  final Future<void> Function() deleteFiles;
  final Future<void> Function() clearWidgetsAndNotifications;
  final Future<void> Function() clearPreferences;
  final void Function() resetSession;

  Future<SignOutReport> prepare({Duration timeout = const Duration(seconds: 20)}) async {
    try {
      await flushOutboxes().timeout(timeout);
    } catch (_) {
      // Offline or slow: report what is still pending.
    }
    return report();
  }

  Future<void> run() async {
    for (final step in [unregisterPush, revokeSession]) {
      try {
        await step().timeout(const Duration(seconds: 8));
      } catch (_) {
        // Best effort. The phone is wiped regardless.
      }
    }
    await closeDatabases();
    await destroyKeysAndTokens();
    await deleteFiles();
    await clearWidgetsAndNotifications();
    await clearPreferences();
    resetSession();
  }
}
```

Wiring in `providers.dart`:
- `flushOutboxes`: run the v2 facts upload, corrections sync, sync queue push and transaction outbox flush once.
- `report`: count rows in `transaction_outbox_entries`, `sync_pending_changes` and the v2 outbox table (`app/lib/features/sms_v2/storage/outbox_store.dart`), plus receipt files and open v2 review items.
- `unregisterPush`: `token = await FirebaseMessaging.instance.getToken()`, then `DELETE /notification-devices {token}`, then `FirebaseMessaging.instance.deleteToken()`. Deleting the token on the phone alone already stops delivery.
- `revokeSession`: `AuthApi.logout(refreshToken)`, which does `POST $authBaseUrl/auth/logout` with `Authorization: Bearer <access>` and body `{"refresh_token": "<refresh>"}`.
- `closeDatabases`: dispose every `AppDatabase` connection, including the worker isolates.
- `destroyKeysAndTokens`: `InstallGuard.clearAllSecureStorage()`.
- `deleteFiles`: `StoragePaths.wipe()`, plus the native spool reset over the existing intake channel (which now also destroys the spool key).
- `clearWidgetsAndNotifications`: `HomeWidgetService.clearAll()`, `FlutterLocalNotificationsPlugin().cancelAll()`, and end the import Live Activity through `SmsImportLiveActivityHost`.
- `clearPreferences`: remove every key except `InstallGuard.markerKey`.
- `resetSession`: `accessTokenProvider` becomes null and the router goes to login.

UI in `account_settings_screen.dart`: call `prepare()`. If `report.losesSomething`, show this dialog:
- Title: "Sign out of PandaPay?"
- Body: "{unsynced} changes haven't reached PandaPay yet, and {receipts} receipts and {review} messages to review are stored only on this phone. Signing out deletes them from this phone."
- Buttons: "Cancel" / "Sign out anyway". Omit any zero-count clause from the body.

Account deletion calls `run()` directly.

- [ ] **Step 4: Run tests. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(auth): sign-out revokes the session, unregisters push and wipes the phone`.

### Task 4.3: Shorter refresh lifetime

**Files:** `auth/src/config.js:90` (default `'90d'`), `auth/example.env`, and the production env (owner).

- [ ] **Step 1:** Change the default, run `cd auth && npm test` (expected: PASS), and commit `chore(auth): 90-day refresh token lifetime`.

### Task 4.4: Sync bills added or edited by hand

Today `local_commitments` is the only copy of hand-entered bills (`commitments_repository.dart:531`). The sign-out wipe would delete them.

**Files:** create migration `db/supabase/migrations/20261115010000_user_commitments.sql`. Modify the sync push allowlist and `pandapay.sync_pull` (find both with `rg -n "sync_pull|syncable|allowlist" api/src db/supabase/migrations`), `commitments_repository.dart` (record edits through `SyncQueue`, defined in `app/lib/data/local/sync_queue.dart`), and the sync pull applier.

- [ ] **Step 1: Failing API test:** pushing a `commitment` insert from device A, then pulling from device B with `since=0`, returns it, and the row is scoped to the profile by RLS.
- [ ] **Step 2: Migration**

```sql
create table if not exists user_commitments (
  id uuid primary key,
  profile_id uuid not null references profiles(id) on delete cascade,
  payload jsonb not null check (octet_length(payload::text) <= 16384),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table user_commitments enable row level security;
create policy user_commitments_owner on user_commitments
  using (profile_id = pandapay.current_profile_id())
  with check (profile_id = pandapay.current_profile_id());
```

Use the helper that the existing RLS policies use (`rg -n "create policy" db/supabase/migrations | head`). If it is not `pandapay.current_profile_id()`, use the existing one. Add the `commitment` entity to the push allowlist and the pull function the same way an existing entity (for example budgets) is added.

- [ ] **Step 3: Client.** Every create, update and delete in `CommitmentsRepository` also calls `SyncQueue` (inserts are not coalesced; updates coalesce per field). Pull applies `commitment` changes to `local_commitments`.
- [ ] **Step 4: Run API and Flutter tests. Expected: PASS. Commit** `feat(sync): sync hand-entered bills`.

### Task 4.5: UPI payment type survives a new phone

- [ ] **Step 1: Check whether v2 facts carry the payment rail for plain UPI and whether the server stores it.** Run `rg -n "rail|upi" app/lib/features/sms_v2/sync/facts_upload.dart api/src/sms_v2/storage.js`.
- [ ] **Step 2: If they don't, write a failing server test:** a v2 `movement` fact with rail `upi` produces a transaction whose `GET /transactions/:id` returns `payment_method: "upi"`. Implement it (add the column or reuse an existing one), make the test pass, and delete `_withLocalSmsEvidence` in `transaction_detail_screen.dart`.
- [ ] **Step 3: Commit** `fix(sms): store UPI payment type on the server`.

---

## Phase 5: Consent, privacy text and store compliance

### Task 5.1: Standalone SMS disclosure and per-account consent

Google Play requires an in-app disclosure that immediately precedes the permission request, cannot live only in the terms, and needs a tap or tick. India's DPDP Act needs specific, informed and unconditional consent. Consent is per account, so a second account on the same phone sees this screen before its history import.

**Files:** create `app/lib/features/consent/sms_access_disclosure.dart` and its widget test. Modify every `Permission.sms` request site (`find_cards_screen.dart:83,211`, `auto_sms_sync_screen.dart`, `sms_import_screen.dart`) and the iOS Shortcut setup screen (`ios_sms_import_screen.dart`). In `api/src/index.js`, add `'sms_reading'` to `CONSENT_PURPOSES`.

- [ ] **Step 1: Failing widget test.** "Continue" is disabled until the checkbox is ticked. Back or dismiss returns `false`. Tick plus Continue returns `true` and posts `POST /consents {purpose: 'sms_reading', granted: true, policyVersion: '2026-11-15', sourceScreen: <screen>}`.
- [ ] **Step 2: Run. Expected: FAIL.**
- [ ] **Step 3: Implement with exactly this copy:**

> **PandaPay reads your bank SMS on this phone**
> - PandaPay reads messages from banks, cards and wallets to record your transactions automatically, including in the background when a new message arrives.
> - Messages are read on this phone. Only the transaction details (amount, merchant, date, card or account ending, and type) are sent to PandaPay, so your spending shows on any phone you sign in to.
> - Personal messages and one-time passwords are skipped and never sent.
> - Messages already on this phone will be added to the account {masked phone or email}.
> - You can turn this off in Settings at any time.
>
> ☐ I agree to PandaPay reading my bank SMS as described.
> [Continue] [Not now]

On iOS, replace the first bullet with: "PandaPay records your transactions from the bank messages you share with it through the Shortcut." Only after `true`: request the Android runtime permission, or open the Shortcut setup on iOS. "Not now" leaves the app fully usable for manual entry. Never start a history import for an account without that account's `sms_reading` consent.

- [ ] **Step 4: Run. Expected: PASS. Commit** `feat(consent): standalone SMS disclosure before any SMS access`.

### Task 5.2: Template sharing opt-in names the AI provider

**Files:** the existing `sms_shared_learning` consent screen (`rg -n "sms_shared_learning" app/lib`).

- [ ] **Step 1: Update the widget test to expect this copy, run it (fail), update the screen, run it (pass), commit.** Default off. Copy:

> **Help PandaPay read new bank messages**
> When PandaPay can't read a message, it can send a copy with every amount, name, number and date removed, so a rule can be added for everyone. These copies may be processed by Google Gemini to suggest the rule. Nothing is sent unless you turn this on, and you can turn it off at any time.
> [Turn on] [Not now]

### Task 5.3: In-app privacy text that is true

**Files:** `transaction_detail_screen.dart` (the SMS evidence notes), `legal_screen.dart`, and any copy found by `rg -n -i "never leaves|stays on (this|your) (device|phone)|not uploaded" app/lib`.

- [ ] **Step 1:** Replace the three evidence notes with:
  - Message present: "The original SMS stays on this phone and is never sent to PandaPay."
  - Message missing: "The original SMS isn't on this phone. The details above came from it when it was first read."

  Remove the advice to attach a screenshot as a backup of the message.
- [ ] **Step 2:** Update widget tests, run them, commit `fix(copy): accurate SMS privacy text`.

### Task 5.4: Privacy policy, terms and age

**Files:** the legal pages served under `legalBaseUrl` (`rg -n "legal" api/src/index.js deploy/nginx` to find them), and the login consent checkboxes (`login_screen.dart`, `consent_checkboxes_test.dart`).

- [ ] **Step 1: Privacy policy sections** (plain language, owner and lawyer review the final text):
  1. Who we are, and the grievance officer's name and email (reply within 30 days).
  2. Data we collect: phone or email, transaction details derived from SMS on the phone, details you enter, statements you import, device and push identifiers, and privacy-safe error reports.
  3. What stays on your phone: SMS text, receipts and messages waiting for review.
  4. Why we use it, one purpose per item.
  5. Optional sharing of redacted templates, and Google Gemini as processor.
  5a. Optional email import: which emails are read (bank and card senders only), that the email text is sent to PandaPay and deleted once read (unread ones within 30 days), that the mailbox app password is stored encrypted and deleted on disconnect, and how to disconnect.
  6. Service providers: hosting, Novu/Firebase for notifications, error reporting.
  7. Security: encryption in transit, encrypted backups, encrypted storage on the phone.
  8. Retention: kept while the account exists; deleted within 30 days of account deletion; backups expire within 30 days.
  9. Your rights: access, correction, deletion and withdrawing consent, and how to exercise each.
  10. Breach notification commitment.
  11. 18+ only.
  12. Changes to the policy.
- [ ] **Step 2: Terms state 18+ only.** Add a required checkbox at sign-up: "I am 18 or older." (DPDP requires verifiable parental consent for anyone under 18.) Write the failing test first, then implement and commit.
- [ ] **Step 3: Set the policy version string used by `POST /consents` to the published policy date.**

### Task 5.5: Store and legal checklist (owner, not code)

- [ ] **Play Console:** SMS permission declaration under "SMS-based money management", with a short video of the disclosure followed by the permission prompt. Data safety form: Financial info (purchase history and other financial info: collected, linked to the user, used for app functionality); Messages: Emails (optional, when email import is connected, used for app functionality) and SMS (only redacted templates, optional, when sharing is on); device or other IDs; diagnostics.
- [ ] **App Store Connect privacy labels** match the same list. Confirm the Apple developer account is an **Organization** (guidelines 5.1.1(ix) and 3.2.1(viii) for money-management apps).
- [ ] **Confirm with the hosting provider** that the server's disks are encrypted at rest.
- [ ] **Name a grievance officer.**
- [ ] **Before public launch (not needed for the friends test):** an Indian fintech privacy lawyer reviews the policy, terms and consent screens.

---

## Phase 6: Release build hardening

### Task 6.1: Obfuscated release builds

**Files:** `app/android/fastlane/Fastfile`, `.github/workflows/build-and-test.yml`, and the iOS release build command (wherever `flutter build ipa` runs).

- [ ] **Step 1:** Add `--obfuscate --split-debug-info=build/debug-info` to every release `flutter build` and keep `build/debug-info` as a build artifact. Error reports need it for symbolication; see the `symbolize-android-stacktrace` skill.
- [ ] **Step 2:** Build once per platform and confirm the app starts. Commit `build: obfuscate release builds`.

### Task 6.2: Dependency audit

- [ ] **Step 1:** `cd app && dart pub outdated`, and run `osv-scanner --lockfile=pubspec.lock` (install with `brew install osv-scanner`). Run `cd api && npm audit --omit=dev` and `cd auth && npm audit --omit=dev`.
- [ ] **Step 2:** Fix every high or critical finding without major-version bumps of Riverpod or go_router. Commit.

---

## Phase 6b: Switch on the AI template loop and the scheduled rule jobs (D9, added 2026-11-06)

The loop already works in code (see "Current state", 2026-11-06). This phase makes it run in production, makes it visible in the console, improves the prompt, and removes the old worker's settings. Without Task 6b.2, every phone installed more than 7 days after the last signing gets no rules.

### Task 6b.1: Job entry points inside the API image

**Files:**
- Create: `api/src/sms_v2/jobs/schedule.js`, `api/src/sms_v2/jobs/rule_jobs_main.js`, `api/src/sms_v2/jobs/template_worker_main.js`
- Modify: `api/scripts/run_sms_v2_rule_jobs.js`, `api/scripts/run_sms_v2_templates.js` (both become thin wrappers so existing runbook commands keep working)
- Test: `api/test/sms_v2_job_schedule.test.js` (top level, so `npm test` runs it)

**Interfaces:**
- Produces: `nextRunDelayMs(now: Date, minute = 7): number`. `runRuleJobsLoop({ runOnce, now, sleep, log, stopped }): Promise<void>` runs once at start-up and then at minute 7 of every hour. It logs a failed run and tries again at the next slot, and never exits because of a failed run. `rule_jobs_main.js` exports `main(argv, env)`: `--loop` is the service mode, and without it the job runs once and exits non-zero on failure (today's CLI behaviour). `template_worker_main.js` exports `main()`, which is today's `run_sms_v2_templates.js` body, moved unchanged.

- [ ] **Step 1: Write the failing test** `api/test/sms_v2_job_schedule.test.js`:

```js
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { nextRunDelayMs, runRuleJobsLoop } = require('../src/sms_v2/jobs/schedule');

test('next run is minute 7 of this hour while it is still ahead', () => {
  assert.equal(nextRunDelayMs(new Date('2026-11-20T10:05:00Z')), 2 * 60_000);
});

test('next run is minute 7 of the next hour once it has passed', () => {
  assert.equal(nextRunDelayMs(new Date('2026-11-20T10:07:00Z')), 60 * 60_000);
  assert.equal(nextRunDelayMs(new Date('2026-11-20T10:30:00Z')), 37 * 60_000);
});

test('loop runs at start-up, survives a failed run and stops when asked', async () => {
  const outcomes = [new Error('db down'), { refreshed: [] }];
  const logs = [];
  let calls = 0;
  let stop = false;
  await runRuleJobsLoop({
    runOnce: async () => {
      const next = outcomes[calls++];
      if (next instanceof Error) throw next;
      stop = true;
      return next;
    },
    now: () => new Date('2026-11-20T10:30:00Z'),
    sleep: async () => {},
    log: (entry) => logs.push(entry),
    stopped: () => stop,
  });
  assert.equal(calls, 2);
  assert.deepEqual(logs.map((entry) => entry.status), ['failed', 'ok']);
  assert.ok(logs.every((entry) => entry.event === 'sms_v2_rule_jobs'));
});

test('job entry points ship in the image (src/), not only in scripts/', () => {
  assert.equal(typeof require('../src/sms_v2/jobs/rule_jobs_main').main, 'function');
  assert.equal(typeof require('../src/sms_v2/jobs/template_worker_main').main, 'function');
});
```

- [ ] **Step 2: Run** `cd api && node --test test/sms_v2_job_schedule.test.js`. Expected: FAIL, cannot find module `../src/sms_v2/jobs/schedule`.

- [ ] **Step 3: Write `api/src/sms_v2/jobs/schedule.js`:**

```js
'use strict';

const HOUR_MS = 3_600_000;

function nextRunDelayMs(now, minute = 7) {
  const next = new Date(now.getTime());
  next.setUTCMinutes(minute, 0, 0);
  if (next.getTime() <= now.getTime()) next.setTime(next.getTime() + HOUR_MS);
  return next.getTime() - now.getTime();
}

async function runRuleJobsLoop({ runOnce, now = () => new Date(), sleep, log, stopped }) {
  while (!stopped()) {
    try {
      await runOnce();
      log({ event: 'sms_v2_rule_jobs', status: 'ok' });
    } catch (error) {
      // Metadata only: never log bundle bodies, rules or keys.
      log({ event: 'sms_v2_rule_jobs', status: 'failed', code: error.code || error.name });
    }
    if (stopped()) break;
    await sleep(nextRunDelayMs(now()));
  }
}

module.exports = { nextRunDelayMs, runRuleJobsLoop };
```

- [ ] **Step 4: Write `api/src/sms_v2/jobs/rule_jobs_main.js`** (today's script body, split into settings and one run):

```js
'use strict';

const { setTimeout: delay } = require('node:timers/promises');
const { runRuleJobsLoop } = require('./schedule');

function configError(code) {
  return Object.assign(new Error(code), { code, exitCode: 2 });
}

function settings(argv, env) {
  const i = argv.indexOf('--admin-id');
  const adminId = (i >= 0 ? argv[i + 1] : undefined) || env.SMS_V2_JOB_ADMIN_ID;
  if (!adminId) throw configError('SMS_V2_JOB_ADMIN_ID_required');
  const hours = env.SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS;
  const refreshBeforeMs = hours === undefined ? undefined : Number(hours) * 3_600_000;
  if (refreshBeforeMs !== undefined && !(refreshBeforeMs >= 3_600_000 && refreshBeforeMs <= 120 * 3_600_000)) {
    throw configError('SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS_invalid');
  }
  const signer = require('../signer').signerFromEnv(env);
  if (!signer) throw configError('SMS_RULES_SIGNING_KEY_required');
  return { adminId, refreshBeforeMs, signer };
}

async function runOnce({ adminId, refreshBeforeMs, signer }) {
  const { openRuleAdminStore } = require('../admin_store');
  const { runRuleJobs } = require('../rule_stats');
  const { store, pool } = await openRuleAdminStore();
  try {
    return await runRuleJobs({ store, signer, adminId, refreshBeforeMs });
  } finally {
    await pool.end();
  }
}

async function main(argv = process.argv, env = process.env) {
  const config = settings(argv, env);
  if (!argv.includes('--loop')) {
    console.log(JSON.stringify(await runOnce(config)));
    return;
  }
  const controller = new AbortController();
  process.once('SIGTERM', () => controller.abort());
  process.once('SIGINT', () => controller.abort());
  await runRuleJobsLoop({
    runOnce: () => runOnce(config),
    sleep: (ms) => delay(ms, undefined, { signal: controller.signal }).catch(() => {}),
    log: (entry) => console.log(JSON.stringify(entry)),
    stopped: () => controller.signal.aborted,
  });
}

if (require.main === module) {
  main().catch((error) => {
    console.error('rule jobs failed:', error.code || error.message);
    process.exit(error.exitCode || 1);
  });
}

module.exports = { main, runOnce, settings };
```

- [ ] **Step 5: Move the body of `api/scripts/run_sms_v2_templates.js`** into `api/src/sms_v2/jobs/template_worker_main.js` unchanged. Change the requires to `../template_worker`, `../admin_store` and `../../admin/server`, export `main`, and run it only `if (require.main === module)`. Replace both scripts with wrappers:

```js
#!/usr/bin/env node
'use strict';
require('../src/sms_v2/jobs/rule_jobs_main').main().catch((error) => {
  console.error('rule jobs failed:', error.code || error.message);
  process.exit(error.exitCode || 1);
});
```

```js
#!/usr/bin/env node
'use strict';
require('../src/sms_v2/jobs/template_worker_main').main().catch((error) => {
  console.error('SMS v2 template worker stopped', error.code || error.name);
  process.exitCode = 1;
});
```

- [ ] **Step 6: Run** `cd api && node --test test/sms_v2_job_schedule.test.js test/sms_v2/template_worker.test.js && npm test`. Expected: PASS.
- [ ] **Step 7: Commit** `feat(sms-v2): job entry points that ship in the API image`.

### Task 6b.2: Run the rule job and the AI worker on the private admin host

**Files:**
- Modify: `deploy/admin/compose.private.yml` (two services, and the signing key on `admin-api`), `deploy/admin/RUNBOOK.md`, `.env.prod.example` (a "private admin host only" section), `docs/sms-pipeline-v2/runbooks/dark-deploy.md` and `signing-keys.md` (they say the jobs are not scheduled)
- Test: `deploy/tests/test_private_jobs.py`

**Interfaces:**
- Consumes: `src/sms_v2/jobs/rule_jobs_main.js --loop` and `src/sms_v2/jobs/template_worker_main.js` (Task 6b.1).

- [ ] **Step 1: Write the failing test** `deploy/tests/test_private_jobs.py`:

```python
"""The SMS v2 rule job and AI worker run only on the private admin host."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRIVATE = (ROOT / 'deploy/admin/compose.private.yml').read_text()
PUBLIC = (ROOT / 'docker-compose.prod.yml').read_text()


def service(source, name):
    match = re.search(
        rf'(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9_-]+:\n|^[a-z]|\Z)', source)
    return match.group(1) if match else None


class PrivateJobsTest(unittest.TestCase):
    def test_rule_jobs_run_hourly_on_the_private_host(self):
        body = service(PRIVATE, 'sms-v2-rule-jobs')
        self.assertIsNotNone(body)
        self.assertIn('src/sms_v2/jobs/rule_jobs_main.js', body)
        self.assertIn('--loop', body)
        self.assertIn('restart: unless-stopped', body)
        for key in ('SMS_RULES_SIGNING_KEY', 'SMS_RULES_KEY_ID', 'SMS_V2_JOB_ADMIN_ID'):
            self.assertIn(key, body)

    def test_template_worker_runs_on_the_private_host(self):
        body = service(PRIVATE, 'sms-v2-template-worker')
        self.assertIsNotNone(body)
        self.assertIn('src/sms_v2/jobs/template_worker_main.js', body)
        for key in ('GEMINI_API_KEY', 'SMS_V2_AI_MODEL', 'SMS_V2_AI_TPM', 'SMS_V2_JOB_ADMIN_ID',
                    'SMS_V2_AI_INPUT_USD_PER_MILLION', 'SMS_V2_AI_OUTPUT_USD_PER_MILLION'):
            self.assertIn(key, body)

    def test_admin_api_can_sign_published_rules(self):
        self.assertIn('SMS_RULES_SIGNING_KEY', service(PRIVATE, 'admin-api'))

    def test_public_compose_never_holds_the_signing_or_ai_keys(self):
        for key in ('SMS_RULES_SIGNING_KEY', 'GEMINI_'):
            self.assertNotIn(key, PUBLIC)


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run** `python3 -m unittest deploy/tests/test_private_jobs.py`. Expected: FAIL (no such services; `docker-compose.prod.yml:128-130` still has `GEMINI_*`; Task 6b.3 removes those, so this test passes only after both tasks).
- [ ] **Step 3: Add to `deploy/admin/compose.private.yml`** next to `admin-api` (same hardening as `admin-api`; the image's HTTP health check doesn't apply to these two services):

```yaml
  sms-v2-rule-jobs:
    profiles: [admin]
    build:
      context: ./api
    command: [node, src/sms_v2/jobs/rule_jobs_main.js, --loop]
    restart: unless-stopped
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    pids_limit: 64
    mem_limit: 256m
    cpus: 0.25
    networks: [admin_private]
    healthcheck:
      disable: true
    environment:
      NODE_ENV: production
      ADMIN_API_DATABASE_URL: '${ADMIN_API_DATABASE_URL:?}'
      SMS_V2_JOB_ADMIN_ID: '${SMS_V2_JOB_ADMIN_ID:?}'
      SMS_RULES_SIGNING_KEY: '${SMS_RULES_SIGNING_KEY:?}'
      SMS_RULES_KEY_ID: '${SMS_RULES_KEY_ID:?}'
      SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS: '${SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS:-72}'
      DB_SSL: 'true'
      DB_SSL_CA: '${DB_SSL_CA:-}'
  sms-v2-template-worker:
    profiles: [admin]
    build:
      context: ./api
    command: [node, src/sms_v2/jobs/template_worker_main.js]
    restart: unless-stopped
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    pids_limit: 64
    mem_limit: 256m
    cpus: 0.25
    networks: [admin_private]
    healthcheck:
      disable: true
    environment:
      NODE_ENV: production
      ADMIN_API_DATABASE_URL: '${ADMIN_API_DATABASE_URL:?}'
      SMS_V2_JOB_ADMIN_ID: '${SMS_V2_JOB_ADMIN_ID:?}'
      GEMINI_API_KEY: '${GEMINI_API_KEY:?}'
      SMS_V2_AI_MODEL: '${SMS_V2_AI_MODEL:?}'
      SMS_V2_AI_TPM: '${SMS_V2_AI_TPM:?}'
      SMS_V2_AI_RPM: '${SMS_V2_AI_RPM:-60}'
      SMS_V2_AI_MAX_OUTPUT_TOKENS: '${SMS_V2_AI_MAX_OUTPUT_TOKENS:-4096}'
      SMS_V2_AI_INPUT_USD_PER_MILLION: '${SMS_V2_AI_INPUT_USD_PER_MILLION:?}'
      SMS_V2_AI_OUTPUT_USD_PER_MILLION: '${SMS_V2_AI_OUTPUT_USD_PER_MILLION:?}'
      DB_SSL: 'true'
      DB_SSL_CA: '${DB_SSL_CA:-}'
```

  Add `SMS_RULES_SIGNING_KEY: '${SMS_RULES_SIGNING_KEY:?}'` and `SMS_RULES_KEY_ID: '${SMS_RULES_KEY_ID:?}'` to `admin-api`, which signs on publish, pause and rollback. Prices are required so the console's cost figures are never blank. `SMS_V2_JOB_ADMIN_ID` is an active owner's `admin_users.id` with `learning.publish`.
- [ ] **Step 4: Runbook and env example.** In `deploy/admin/RUNBOOK.md`, add: (a) allow outbound HTTPS from the `admin_private` network to `generativelanguage.googleapis.com` only for the template worker; (b) check after start with `docker compose -f docker-compose.prod.yml -f deploy/admin/compose.private.yml --profile admin logs sms-v2-rule-jobs`, expecting `{"event":"sms_v2_rule_jobs","status":"ok"}`; (c) recovery: fix, then `docker compose ... restart sms-v2-rule-jobs` (it runs at start-up). In `.env.prod.example`, add a "Private admin host only" section listing the variables above with empty values and the comment "Never set these on the public API host." Fix the "not scheduled" sentences in `dark-deploy.md` and `signing-keys.md`.
- [ ] **Step 5: Run** `docker compose -f docker-compose.prod.yml -f deploy/admin/compose.private.yml --profile admin config --quiet` with dummy values exported, and `python3 -m unittest deploy/tests/test_private_jobs.py` (after Task 6b.3). Expected: PASS.
- [ ] **Step 6: Commit** `feat(deploy): run the SMS rule job and AI worker on the private admin host`.

### Task 6b.3: Remove the old AI worker's settings

**Files:**
- Modify: `.env.prod.example:186-200`, `api/example.env:47-64`, `docker-compose.yml:119-122`, `docker-compose.prod.yml:128-130`, `deploy/deploy.sh:301-313`, `.github/workflows/deploy-prod.yml:151-175`, `.github/workflows/deploy-pushed-branch.yml:233-249`, `deploy/tests/test_deploy_security_order.py:154` (its fake env writes `AI_WORKER_TOKEN=` and `GEMINI_API_KEY=`)
- Test: `api/test/release_guards.test.js`

Nothing in `api/src`, `api/scripts` or `auth/src` reads these settings (checked 2026-11-06). `GEMINI_API_KEY` is still needed, but only on the private admin host (Task 6b.2), so the public deploy path stops sending it.

- [ ] **Step 1: Add the failing guard test** to `api/test/release_guards.test.js` (reuse its existing `fs`/`path` imports and repo-root constant if it has them):

```js
test('old per-message AI worker settings are gone, and the public deploy sends no Gemini key', () => {
  const root = path.resolve(__dirname, '../..');
  const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
  const stale = /\b(AI_WORKER_[A-Z_]+|AI_PROVIDER_TIMEOUT_MS|GEMINI_FALLBACK_[A-Z_]+|GEMINI_API_KEYS|GEMINI_MODEL|GEMINI_REQUESTS_PER_[A-Z]+|GEMINI_TOKENS_PER_MINUTE)\b/;
  for (const file of ['.env.prod.example', 'api/example.env', 'docker-compose.yml', 'docker-compose.prod.yml',
    'docker-compose.staging.yml', 'deploy/deploy.sh', '.github/workflows/deploy-prod.yml',
    '.github/workflows/deploy-pushed-branch.yml']) {
    assert.doesNotMatch(read(file), stale, file);
  }
  for (const file of ['docker-compose.prod.yml', 'deploy/deploy.sh', '.github/workflows/deploy-prod.yml',
    '.github/workflows/deploy-pushed-branch.yml']) {
    assert.doesNotMatch(read(file), /GEMINI_API_KEY/, file);
  }
});
```

- [ ] **Step 2: Run** `cd api && node --test test/release_guards.test.js`. Expected: FAIL naming `.env.prod.example`.
- [ ] **Step 3: Delete the listed lines.** In `.env.prod.example`, the old "SMS intelligence Gemini worker" block goes; `GEMINI_API_KEY` stays only in the private-host section from Task 6b.2. In `api/example.env`, replace the old block with the template worker's variables (`GEMINI_API_KEY`, `SMS_V2_AI_MODEL`, `SMS_V2_AI_TPM`, `SMS_V2_JOB_ADMIN_ID`) and a comment pointing to `api/src/sms_v2/jobs/template_worker_main.js`. Update the fake env in `test_deploy_security_order.py`. Remove the `GEMINI_API_KEY` repository secret from the deploy workflows (owner removes it from GitHub after merge).
- [ ] **Step 4: Run** `cd api && npm test` and `python3 -m unittest discover deploy/tests`. Expected: PASS.
- [ ] **Step 5: Commit** `chore(deploy): remove the old AI worker's settings`.

### Task 6b.4: Show the AI loop and rule signing in the console

**Files:**
- Modify: `api/src/admin/system_status.js` (`SERVICES`, `JOBS`), `console/lib/features/sms_rules/sms_rules_screen.dart` (Templates and Metrics tabs)
- Test: `api/test/admin_system_status.test.js`, the SMS rules screen test (`rg -l SmsRulesScreen console/test`)

The Metrics tab already shows AI calls, tokens and cost by day. The missing pieces are whether the two jobs are healthy, why a layout is held or failed, and how many layouts are held.

- [ ] **Step 1: Write failing tests:** system status lists services `sms-v2-rule-jobs` and `sms-v2-template-worker` (`runs: 'admin_only'`), and jobs `sms_v2_rule_signing` and `sms_v2_ai_drafts`. A rule-signing row with `last_status: 'expiring'` reports state `failed`. The Templates tab shows "Held: sent without a valid App Check token, so it was not sent to the AI" for a `held` row, and "Failed: draft_validation_failed" for a failed row with that `failure_code`. The Metrics tab shows "Layouts sent to the AI: 3 · Held: 2" for `templateSubmissions: {verified: 3, unverified: 2}`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** Add to `SERVICES`:

```js
  { key: 'sms-v2-rule-jobs', runs: 'admin_only', name: 'SMS rule job', purpose: 'Every hour: re-signs the SMS rule sets phones download (they expire after 7 days) and pauses rules with too many corrections.', health: 'job:sms_v2_rule_signing' },
  { key: 'sms-v2-template-worker', runs: 'admin_only', name: 'SMS AI drafts', purpose: 'Asks Gemini to draft a rule for each shared message layout.', health: 'job:sms_v2_ai_drafts' },
```

  Add to `JOBS`:

```js
  {
    key: 'sms_v2_rule_signing', name: 'SMS rule set signing', permission: 'operations.read', expectedEveryHours: 120,
    sql: `SELECT max(served_expires_at) - interval '7 days' AS last_run_at,
                 CASE WHEN min(served_expires_at) > now() + interval '48 hours' THEN 'fresh' ELSE 'expiring' END AS last_status,
                 max(served_expires_at) - interval '7 days' AS last_success_at
            FROM sms_v2_bundles WHERE status = 'active'`,
    ok: status => status === 'fresh',
  },
  {
    key: 'sms_v2_ai_drafts', name: 'SMS AI drafts', permission: 'operations.read', expectedEveryHours: 24,
    sql: `SELECT now() AS last_run_at,
                 CASE WHEN EXISTS (SELECT 1 FROM sms_v2_unknown_templates
                                    WHERE ai_status = 'queued' AND first_seen < now() - interval '1 hour')
                      THEN 'backlog' ELSE 'ok' END AS last_status,
                 (SELECT max(started_at) FROM sms_v2_template_attempts WHERE outcome = 'valid') AS last_success_at`,
    ok: status => status === 'ok',
  },
```

  If the admin database role can't read `sms_v2_bundles` or `sms_v2_template_attempts`, the job shows its query error. Fix that with a grant in a new migration, not by widening the permission. In the Templates tab subtitle, append the held and failed lines from Step 1. In the Metrics tab, under "AI usage by day", add the "Layouts sent to the AI … · Held …" line from `templateSubmissions`.
- [ ] **Step 4: Run** `cd api && node --test test/admin_system_status.test.js` and `cd console && flutter test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(console): health of the SMS rule job and AI drafts`.

### Task 6b.5: Prompt carries the India SMS rules, checked on the owner's layouts

**Files:**
- Modify: `api/src/sms_v2/template_worker.js` (`buildPrompt`)
- Create: `api/scripts/dry_run_sms_v2_templates.js` (dev only; `scripts/` is not shipped in the image)
- Test: `api/test/sms_v2/template_worker.test.js` (fixture `api/test/sms_v2/fixtures/template_draft.js`)

The prompt reads the fact schema at run time, so new fact types reach it automatically. It lacks the domain knowledge the deleted per-message prompt had (`git show d50a81d^:api/src/gemini_worker.js`, lines 53-90), and it never explains the placeholders. Below, that knowledge is rewritten in v2 fact vocabulary (`contracts/sms/v2/fact.schema.json`).

- [ ] **Step 1: Write the failing test:**

```js
test('prompt carries the India SMS rules and the placeholder legend', () => {
  const { template } = require('./fixtures/template_draft');
  const prompt = JSON.parse(buildPrompt(template));
  assert.ok(prompt.domainRules.some((rule) => rule.includes('bill_due')));
  assert.ok(prompt.domainRules.some((rule) => rule.includes('hold fact')));
  assert.ok(prompt.domainRules.some((rule) => rule.includes('never the movement amount')));
  assert.equal(prompt.placeholders['<AMT>'], 'an amount, with its currency marker');
  assert.equal(prompt.placeholders['#'], 'one digit');
});
```

- [ ] **Step 2: Run** `cd api && node --test test/sms_v2/template_worker.test.js`. Expected: FAIL (`prompt.domainRules` is undefined).
- [ ] **Step 3: Add to `template_worker.js`** and include `placeholders: SMS_PLACEHOLDERS, domainRules: SMS_DOMAIN_RULES` in the object `buildPrompt` serialises (after `instruction`):

```js
const SMS_PLACEHOLDERS = Object.freeze({
  "<AMT>": "an amount, with its currency marker",
  "<DATE>": "a date or date-time",
  "<MASK>": "a masked card or account number such as XX1234",
  "<VPA>": "a UPI ID",
  "<REF>": "a reference number of 6 or more digits",
  "<PHONE>": "a phone number",
  "<EMAIL>": "an email address",
  "<URL>": "a link",
  "<PARTY>": "a person's or payee's name",
  "<W>": "one or more words that were removed",
  "#": "one digit",
});

const SMS_DOMAIN_RULES = Object.freeze([
  "The pattern runs on the real message, where every placeholder is a real value. Never match placeholder text such as <AMT> literally; capture the value with a named group.",
  "Only a completed money movement is a movement fact. Pending, failed, declined, scheduled or cancelled payments are attempt facts.",
  "Salary, interest and dividend credits are movement facts with direction credit and purpose salary, interest or dividend.",
  "A broker or exchange payout to the user's bank, or a transfer between the user's own accounts, is a movement fact with purpose transfer.",
  "A SIP debit, mutual fund purchase or stock purchase is a movement fact with direction debit and purpose investment.",
  "A card statement, utility bill or Pay Later due notice is a bill_due fact. It is never a movement.",
  "A Pay Later purchase is a movement fact only when the message confirms it completed.",
  "An AutoPay or e-mandate registration, change, pause or cancellation is a mandate fact. Its amount is a ceiling, never a spend.",
  "An IPO or ASBA block, a UPI mandate block or a card pre-authorisation is a hold fact.",
  "An ATM cash withdrawal is a movement fact with direction debit and purpose atm.",
  "A refund, reversal or cashback is a movement fact with direction credit and purpose refund, reversal or cashback.",
  "A credit card bill payment is a movement fact with purpose card_payment.",
  "Telecom talktime or validity deductions, loan or Pay Later offers, credit-limit upgrade offers, OTPs, gambling or promotional messages and general service alerts are info facts with category otp, security, promotion or service. They never create a movement.",
  "An available-balance or balance-after amount is never the movement amount.",
  "If the layout holds more than one separate money movement, emit a fact for each printed amount; never keep one and drop the others.",
]);
```

- [ ] **Step 4: Run** the test file and `cd api && npm test`. Expected: PASS. Commit `feat(sms-v2): India SMS rules and placeholder legend in the AI prompt`.
- [ ] **Step 5: Write the dry-run script** `api/scripts/dry_run_sms_v2_templates.js`. It drafts rules for stored layouts and writes nothing to the database:

```js
#!/usr/bin/env node
'use strict';
// Dev only. Drafts rules for stored (already redacted) layouts and writes
// nothing back. The output file holds layouts and drafts, never message text.
const fs = require('node:fs');
const { openRuleAdminStore } = require('../src/sms_v2/admin_store');
const { workerConfig, buildPrompt, validateDraftSafely, createGeminiTemplateProvider } =
  require('../src/sms_v2/template_worker');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

async function main() {
  const out = arg('out');
  if (!out) throw new Error('--out <file outside the repository> is required');
  const limit = Number(arg('limit', '20'));
  const config = workerConfig();
  const provider = createGeminiTemplateProvider();
  const { pool } = await openRuleAdminStore();
  const results = [];
  try {
    const templates = (await pool.query(
      `SELECT template_hash, sender_brand, redacted_body FROM sms_v2_unknown_templates
        ORDER BY distinct_profiles DESC, seen_count DESC LIMIT $1`, [limit])).rows;
    for (const template of templates) {
      const examples = (await pool.query(
        "SELECT body FROM sms_v2_rules WHERE status='active' AND $1=ANY(senders) ORDER BY rule_id,version DESC LIMIT 5",
        [template.sender_brand])).rows.map((row) => row.body);
      let errors = [];
      let rule = null;
      for (let attempt = 1; attempt <= 2 && (attempt === 1 || errors.length); attempt++) {
        try {
          const response = await provider.generate({
            prompt: buildPrompt(template, examples, errors),
            model: config.model,
            maxOutputTokens: config.maxOutputTokens,
          });
          rule = typeof response.rule === 'string' ? JSON.parse(response.rule) : response.rule;
          errors = await validateDraftSafely(rule, template, config.model);
        } catch {
          errors = ['provider_or_json_invalid'];
        }
      }
      results.push({ senderBrand: template.sender_brand, redactedBody: template.redacted_body,
        valid: errors.length === 0, errors, rule });
      console.log(JSON.stringify({ sender: template.sender_brand, valid: errors.length === 0, errors }));
    }
  } finally {
    await pool.end();
  }
  fs.writeFileSync(out, JSON.stringify(results, null, 2));
  console.log(`${results.filter((r) => r.valid).length} of ${results.length} drafts valid. Review ${out}.`);
}

main().catch((error) => {
  console.error('dry run failed:', error.code || error.message);
  process.exit(1);
});
```

- [ ] **Step 6: Dry run on the owner's layouts (owner and implementer together).** On the rig build, the owner turns on Settings → Privacy & permissions → "Help PandaPay read new bank messages" and leaves the app open after a history import. The rig has no App Check, so layouts arrive as `held`; that is fine for this script, which reads every status. The cap is 50 layouts per account per day. Then run, with a paid key: `ADMIN_API_DATABASE_URL=<rig> GEMINI_API_KEY=… SMS_V2_AI_MODEL=… SMS_V2_AI_TPM=… node api/scripts/dry_run_sms_v2_templates.js --limit 50 --out <scratch dir>/ai-dry-run.json`. The owner reads each draft. Record in `docs/sms-pipeline-v2/handoff/WP-10.md`: layouts tried, drafts valid, drafts the owner would publish without edits, and the common failure codes. Suggested bar before friends opt in: at least 7 of 10 valid drafts need no edit. Otherwise adjust `SMS_DOMAIN_RULES` and run again.
- [ ] **Step 7: Commit** `chore(sms-v2): dry-run script for AI drafts` and the WP-10 note.

---

## Phase 7: Verification gates (all must pass before the cutover)

### Task 7.1: Automated

- [ ] `cd app && flutter analyze && flutter test`. Expected: zero issues, all pass, guard tests included.
- [ ] `cd api && npm test`, `cd auth && npm test`. Expected: pass, PostgreSQL tests included.
- [ ] `python3 -m unittest discover deploy/tests` and `docker compose -f docker-compose.prod.yml -f deploy/admin/compose.private.yml --profile admin config --quiet`. Expected: pass.
- [ ] The golden-set and accuracy commands in `docs/sms-pipeline-v2/test-and-release.md`. Expected: at or above its release thresholds.
- [ ] Re-run the OWASP mobile scanners (send their JSON to a temp folder, not `app/`). Mark LO-11 as Fixed in `docs/sms-pipeline-v2/security-audit-2026-11.md`.

### Task 7.2: Accuracy on the owner's real messages

- [ ] Import the owner's full history on Android and through the iPhone Shortcut on a fresh install. Compare monthly totals and categories with bank and card statements. Record the results in `docs/sms-pipeline-v2/handoff/WP-17.md`. Fix problems through the rule bundle (Lane A) or code (Lane B) until the thresholds in `test-and-release.md` are met.

### Task 7.3: Device acceptance (iPhone and Android, release builds)

| Check | How to verify | Expected |
|---|---|---|
| Consent comes first | Fresh install, open import | Disclosure before any permission prompt or Shortcut; "Not now" leaves the app usable |
| Locked-phone capture | Lock the phone, receive or share a bank SMS | Transaction appears after unlock; no crash |
| Database encrypted | iOS: `xcrun simctl get_app_container booted <bundle id> data`, then `head -c 15 "Library/Application Support/PandaPay/pandapay.sqlite"`. Android: `adb exec-out run-as <app id> head -c 15 files/PandaPay/pandapay.sqlite` | Not `SQLite format 3` |
| Receipts encrypted | Same container, `receipts/*` | Files start with `PPRC` |
| Spool encrypted | `sqlite3 …/PandaPaySmsIntake/handoff.sqlite "select substr(body,1,3) from captures"` | `v1:` |
| Backup excluded | `xattr -l "Library/Application Support/PandaPay"` | Shows `com.apple.metadata:com_apple_backup_excludeItem` |
| Sign-out | Sign out | `PandaPay/` folder empty, widget blank, `POST /notifications/test` to the old account reaches nothing, old refresh token gets 401 from `/auth/refresh` |
| Offline sign-out | Airplane mode, sign out | Phone is still wiped |
| Reinstall (iPhone) | Delete the app, reinstall | Opens on login, not the old account |
| New phone | Sign in on a second device | Home totals, this month's spending, category totals, hand-entered bills and the UPI label match |
| Second account | Sign out, sign in as another account | Sees the SMS disclosure for that account before any import |
| Account deletion | Delete the account | Product and auth rows are gone, including `imap_connections` and `inbound_emails` (confirm `ACCOUNT_LIFECYCLE_ENABLED` is on in production) |
| Email consent | Open mailbox connect or email forwarding | Email disclosure first; nothing connects without the tick |
| Mailbox password | After connecting, `select app_password_ciphertext, app_password_key_id from imap_connections` | Ciphertext only; the password and key never appear in PostgreSQL logs |
| Bank senders only | Connect a test mailbox containing a personal email and a bank email | Only the bank email is fetched |
| Parsed email text deleted | Forward a bank email that parses | Its `inbound_emails.body_text` is null |
| Disconnect | Disconnect the mailbox | The `imap_connections` row is gone |
| AI sharing is off by default | Fresh install, finish import | No row for the account in `sms_v2_template_submitters`; nothing sent to `/sms/v2/unknown-templates` |
| Layouts reach the AI | Release build (App Check works), turn on Settings → Privacy & permissions → "Help PandaPay read new bank messages", keep a message the app can't read | Console Templates tab shows the layout as `queued`, then `ready`, not `held`; Metrics shows it under "sent to the AI" |
| Private draft fixes the sender's phone | After `ready`, open the app (sync) | That message becomes a transaction on this phone only |
| Approved rule reaches everyone | Console: Create draft → golden check → publish to the testers cohort | A second phone with sharing off reads the same message after its next rule check (about 6 hours, or at next launch) |
| Turning sharing off | Turn the setting off | The phone's template queue is empty, and the account no longer counts toward that layout (`distinct_profiles` drops) |
| Rule sets stay fresh | System status, 8 days after the cutover | "SMS rule set signing" is ok; `GET /sms/v2/rules` answers 200, not `503 bundle_unavailable` |

---

## Phase 8: Production cutover (owner approves each step)

- [ ] **8.1 Fast-forward `master`** to the release commit on `sms-v2/integration`, then tag `release/fresh-start-1`. Pushing needs owner approval.
- [ ] **8.2 Take paired encrypted backups** of the product and auth databases (`db/backup/README.md`). Write down the destroy date (cutover + 30 days).
- [ ] **8.3 Turn on maintenance mode:** `update app_status set maintenance_mode = true`.
- [ ] **8.4 Start the product database empty:** build a new product database from migrations and point the API at it (preferred over truncating, because no legacy row can survive). Keep the auth database.
- [ ] **8.5 Revoke every session** in the auth database. Use the same statement as `POST /users/me/logout-all-devices` (`auth/src/routes/userRoutes.js:387`), without the user filter.
- [ ] **8.6 Block old builds:** `update app_status set min_supported_version = '<new build version>'`.
- [ ] **8.7 Deploy `api` and `auth`** from the tag. Remove the legacy worker services. Replace `IMAP_ENCRYPTION_KEY` with a new random 32-byte key and key id (the old key protected only data in the old database). Confirm `INBOUND_EMAIL_WEBHOOK_SECRET` is set.
- [ ] **8.8 Set up SMS v2 production trust:** rule-signing keys and App Check in enforce mode (LO-10), using `docs/sms-pipeline-v2/runbooks/`. The signing key goes only to the private admin host (`admin-api`, `sms-v2-rule-jobs`), never to the public API. Because the product database is new (8.4), load the rules with `node api/scripts/release_sms_v2_bundle.js --apply --admin-id <id>` (`bundle-release.md`) from an operator checkout. Enable the v2 server gates for the tester accounts.
- [ ] **8.8a Start the private admin profile** with the two new services (Task 6b.2). Confirm the rule job logs `"status":"ok"`, `GET /sms/v2/rules` answers 200 with an `expiresAt` about 7 days ahead, and System status shows "SMS rule set signing" ok.
- [ ] **8.8b Gemini on a paid key:** create the key in a Google Cloud project with billing turned on, and confirm in AI Studio that the project is on a paid tier. Set `GEMINI_API_KEY`, `SMS_V2_AI_MODEL`, `SMS_V2_AI_TPM` and the two `SMS_V2_AI_*_USD_PER_MILLION` prices (from Google's pricing page for that model) on the private admin host only. Allow its outbound HTTPS to `generativelanguage.googleapis.com`. Set a monthly budget alert in Google Cloud.
- [ ] **8.9 Turn off maintenance mode.** Testers delete the old app, install the new build (TestFlight / Play internal testing), sign in, accept consent and import history.
- [ ] **8.10 On the destroy date,** delete the pre-cutover backups.

## Phase 9: Friends run, then public-launch gate

- [ ] Run for 7 days with the testers. Track the correction rate (WP-17 target: under 1%), crashes and sync errors.
- [ ] Before testers turn on sharing, finish `docs/superpowers/plans/2026-11-06-sms-learning-loop.md`, which is built in one continuous run (Parts A, B and C). It fixes the opt-in read bug, moves to opt-in v3, offers sharing in Review, adds admin settings and controls, shares shop categories and names, adds the Learning page, rejects and requeues AI drafts, and tests the whole loop end to end.
- [ ] Ask testers to turn on "Help PandaPay read new bank messages". Review the console Templates tab at least every 2 days, and publish approved drafts to the testers cohort. Track layouts held (App Check problems), drafts ready versus failed, and AI cost per day.
- [ ] **Public-launch gate (not needed for the friends test):** certificate pinning (LO-12, separate plan, with a backup pin), lawyer review (Task 5.5), store declarations approved, and DPDP readiness before 13 May 2027 (breach runbook that notifies the Data Protection Board and every affected user, a retention schedule, and processing logs kept for one year).

## Out of scope (later releases)

- Optional encrypted backup of SMS text with a user-held key (the WhatsApp model).
- A "hide amounts in notifications" setting for lock-screen privacy.
- On-phone regex time limits (LO-14).
- Retention limits for SMS text kept on the phone.
- On-device AI drafting (Apple Foundation Models on iOS 26 Apple Intelligence devices, Gemini Nano through the ML Kit Prompt API on Android), only if too few users opt in to layout sharing. It covers few phones today and needs native plugins.
- Bringing back the per-message AI pipeline (full SMS text on the server). Rejected in D9.
