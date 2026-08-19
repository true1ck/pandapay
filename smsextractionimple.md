
# PandaPay — Implementation Plan: SMS Import and Card Detection

> ## Implementation status — 2026-08-19
>
> | Task | Status |
> | --- | --- |
> | **§1.2** background-location decision | ⛔ **Open — needs your call.** Option (a) removes a working feature, so it wasn't taken unilaterally. The CI guard in S-2 has the check pre-written and commented out |
> | **S-0** privacy truth | ✅ Done — on-device pre-filter before upload, three false strings rewritten, drop counts shown to the user |
> | **S-1a** D2–D6 + batching | ✅ Done — dates preserved, `backfill` flag, per-card attribution, empty-cards path, UTF-8 + size guard, batch endpoint with progress/cancel |
> | **S-1b** surface in prod | ✅ Done — dedicated Import Hub tile in all flavors, behind an `app_status` kill switch |
> | **S-2** manifest guard | ✅ Done — `scripts/check_prod_manifest.sh`, wired into CI; `file_picker` pinned |
> | **S-3** backup → discovery | ✅ Done — filtered bodies passed to `FindCardsScreen`, most-recent-500 rather than arbitrary truncation |
> | **F-8** route mail into webhook | ⚠️ **Partial.** The Gmail verification-code blocker is built (endpoint + UI). The DNS/provider wiring is infra and can't be done from here |
> | **F-9** card_discovery tests | ✅ Done — 17 tests, and they **found a live bug** (see below) |
> | **F-10** drop IMAP | ✅ Done — tile relabelled "test only"; the decision itself is still yours to ratify |
> | **F-11** security pass | ⬜ Not started — belongs with F-8 go-live |
>
> **Bug found while writing the F-9 tests:** `card_discovery.js` matched product
> tokens as substrings, so routine Axis Bank mail suggested "Axis Ace" at
> score 1.0 — "ace" was being read out of *interface*, *place* and *space*.
> Short product names are common in this catalogue (Ace, One, Neo, Pro), so
> this misfired constantly. Fixed by matching product tokens on word
> boundaries while keeping issuer tokens substring-matched (so
> `alerts@hdfcbank.net` still identifies HDFC). Regression test included.
>
> **Verified, not assumed:** 379 Flutter tests and 76 API tests pass; migration
> 0036 was applied to a scratch Postgres and the re-import no-op, the
> manual-row non-collision and the per-profile salting were each confirmed by
> query. The manifest guard was run against both a clean and a deliberately
> poisoned manifest.
>
> **Not verified:** nothing has been run on a device or emulator, so the two
> rebuilt screens are compile- and widget-test-correct but visually unproven.

**Companion to:** [`ui-spec.md`](./ui-spec.md) · [`product-plan.md`](./product-plan.md) · [`database.sql`](./database.sql) (aspirational combined schema — the real schema is `db/supabase/migrations/0001–0035`) · [`implementation-plan-group-e-f-g.md`](./implementation-plan-group-e-f-g.md) (Group F — F3/F4/F7 are extended here)

**Two governing constraints:**

1. **Nothing here may put the Play Store listing at risk.** Every task ships *without* adding a permission to the prod manifest. Where a feature would need a restricted permission, the plan changes the feature, not the manifest. §1 states the rule; every task conforms to it.
2. **Nothing here may ship a privacy claim the code does not honour.** §0.2 documents three user-facing statements that are currently false. Correcting them is a *blocker* on shipping the SMS path to prod, not a polish item — an inaccurate Data Safety declaration is a bigger enforcement risk than the permission it was written to avoid.

**Scope:** get SMS-derived transaction import and card detection into the *production* build with **zero** SMS permissions.

**Out of scope, deliberately:** Account Aggregator (RBI) integration, and re-adding `READ_SMS`/`RECEIVE_SMS` to prod. Both are legitimate but each is a large, separately-scoped investment with review or cost exposure. See §1.3.

**Map / location work has been removed from this plan** and is deferred. The `ACCESS_BACKGROUND_LOCATION` item in §1.2 is retained because it is a live review risk in the *current* manifest, independent of any map feature.

---

## 0. Audit — verified state

Every row was confirmed by reading the file or running the command, not inferred. **The previous revision of this plan over-reported readiness**; the corrected column is `Actually ready?`.

| Area | State | Actually ready? | File(s) |
| --- | --- | --- | --- |
| **Card discovery matcher** | Built. `POST /card-discovery` scans `inbound_emails` (gated to `is_known_bank_sender`) + in-memory SMS bodies through one matcher; `FindCardsScreen` shows suggestions with source text, adds nothing without a tap | **Yes**, but **zero test coverage** — no `api/test/card_discovery.test.js` exists. See F-9. | [index.js:3505](api/src/index.js), [card_discovery.js](api/src/card_discovery.js), [find_cards_screen.dart:62](app/lib/features/cards/find_cards_screen.dart) |
| **Inbound email receiver** | Built. Shared-secret auth, constant-time compare, non-enumerable. Retention is real (`purge_after` + [0013_cron_jobs.sql](db/supabase/migrations/0013_cron_jobs.sql)). No mail routed to it yet | **Yes** — blocked on infra only (F-8) | [index.js:5262](api/src/index.js) |
| **Forwarding address issuance** | Built. One active address per profile, idempotent | Yes | [index.js:5213](api/src/index.js), [email_forwarding_screen.dart](app/lib/features/import/email_forwarding_screen.dart) |
| **SMS backup-file import** | Real `file_picker`, real XML parser for the SMS Backup & Restore format, writes `sms_import_batches`. Requires no SMS permission | **No — six blocking defects.** See §0.1. Do not surface this in prod as-is | [sms_backup_import_screen.dart](app/lib/features/sms_import/sms_backup_import_screen.dart), [sms_backup_xml_parser.dart](app/lib/data/sms_backup_xml_parser.dart) |
| **SMS live auto-read** | Correctly disabled in prod — manifest strips the permission, `Env.isProd` hides the UI | Yes (as disabled) | [sms_import_screen.dart](app/lib/features/sms_import/sms_import_screen.dart), [prod/AndroidManifest.xml](app/android/app/src/prod/AndroidManifest.xml) |
| **IMAP connection** | Form + live test-login. No background poller | Recommend **drop** — see F-10 | [imap_connection_screen.dart](app/lib/features/import/imap_connection_screen.dart), [imap_test.js](api/src/imap_test.js) |
| **`user_cards` schema** | Stores no PAN, not even last-4. Do not add one | Yes | [0004_user_domain.sql:69](db/supabase/migrations/0004_user_domain.sql) |
| **Prod merged manifest** | **Verified clean.** `prodRelease` packaged manifest contains no SMS and no storage permission. `ACCESS_BACKGROUND_LOCATION` *is* present | Answers old task S-2 — see S-2 (now a regression guard) | `app/build/app/intermediates/packaged_manifests/prodRelease/…/AndroidManifest.xml` |

### 0.1 The six defects in the backup-import path

The screen runs end-to-end, which is why it read as "done". Each of these is a correctness or privacy problem, not a polish item, and each is cheap to fix.

| # | Defect | Evidence | Consequence |
| --- | --- | --- | --- |
| **D1** | **Every message is uploaded.** The loop POSTs *all* parsed messages to `/transactions/from-sms`; parsing is server-side against `parser_patterns`. There is no Dart-side parser. The live listener at least pre-filters with `looksLikeTransactionSms()`; the backup path does not | [sms_backup_import_screen.dart:78](app/lib/features/sms_import/sms_backup_import_screen.dart), [user_cards_repository.dart:813](app/lib/data/user_cards_repository.dart), [sms_listener_service.dart](app/lib/features/sms_import/sms_listener_service.dart) vs. [sms_text_hint.dart](app/lib/features/sms_import/sms_text_hint.dart) | The user's entire personal SMS history — friends, OTPs, medical, everything — is transmitted to PandaPay's servers. Contradicts the on-screen copy (§0.2) and any honest Data Safety answer |
| **D2** | **Every imported transaction is dated *now*.** The XML parser reads only `address`/`body` and discards the `date` attribute; the endpoint defaults `occurredAt` to `new Date()` | [sms_backup_xml_parser.dart:40](app/lib/data/sms_backup_xml_parser.dart), [index.js:2756](api/src/index.js) | A two-year backup dumps every historical spend into the current cycle. `applyTransactionState` then applies caps, milestones and fee-waiver progress against it — corrupting the exact numbers the app exists to compute |
| **D3** | **All messages are attributed to one card.** The screen requires a single `_selectedCardId` up front and logs every message against it | [sms_backup_import_screen.dart:249](app/lib/features/sms_import/sms_backup_import_screen.dart) | A three-card user's backup lands entirely on one card. `extractLast4Hint()` already exists and is unused here |
| **D4** | **Unusable with zero cards.** Import is disabled until a card is selected, and there is no empty-state for `cards == []` | same line | A new user — the exact user "find my cards from SMS" targets — hits a dead screen. **This alone breaks S-1's stated goal** |
| **D5** | **Re-import duplicates silently.** `detectDuplicates` requires `source != $4`; both runs are `source='sms'`, so re-importing the same file creates a second full set with no flag | [index.js:2435](api/src/index.js) | Import twice, double every number |
| **D6** | **UTF-8 is mangled, and there is no size guard.** `String.fromCharCodes(bytes)` treats bytes as code units; `XmlDocument.parse` loads the whole file into memory | [sms_backup_import_screen.dart:52](app/lib/features/sms_import/sms_backup_import_screen.dart) | `₹` (3 UTF-8 bytes) becomes three garbage characters — in an INR-only app, that breaks amount parsing for any issuer using the symbol. A large backup OOMs the picker |

Secondary, non-blocking: one sequential HTTP round-trip per message with no batching, no progress indicator beyond `Importing…`, and no cancel. A 5,000-message backup is 5,000 requests behind a static label.

### 0.2 ⛔ The privacy claim the code does not honour

Three user-facing statements are currently false:

| Where | Claim | Reality |
| --- | --- | --- |
| [sms_consent_screen.dart:43](app/lib/features/sms_import/sms_consent_screen.dart) | *"Parsing happens entirely on this device — message text is never uploaded"* | Message text is uploaded. All parsing is server-side |
| [sms_consent_screen.dart:49](app/lib/features/sms_import/sms_consent_screen.dart) | *"Only messages matching a known bank-alert pattern are used; everything else is ignored"* | The pattern match happens *after* upload. On the backup path there is no pre-filter at all |
| [sms_backup_import_screen.dart:170](app/lib/features/sms_import/sms_backup_import_screen.dart) | *"Parsing happens on-device using the same parser the live listener uses"* | Only XML extraction is on-device |

`POST /card-discovery`'s own doc-comment cites this consent screen as the promise it is honouring, so the inaccuracy has already propagated into the server's design rationale.

**Why this outranks everything else in the plan.** These strings are today only reachable in dev/staging, so nothing has shipped. S-1 as previously written would have carried the same claim into prod-visible copy and into the Data Safety form. §1.4 correctly identifies inaccurate Data Safety answers as a common enforcement cause — this is that, concretely. **S-0 below is a hard prerequisite for S-1.**

### 0.3 What is genuinely good and should not be touched

- Sender verification gates the email scan — a stranger emailing "HDFC Millennia" to a forwarding address cannot inject a suggestion.
- `smsBodies` on `/card-discovery` is genuinely in-memory-only, and `parser_failures` stores a redacted shape with a `redacted_shape_has_no_digits` CHECK.
- Suggestions carry their evidence; nothing is auto-added.
- `inbound_emails` has real retention (`purge_after`, cron-purged).
- Duplicate detection and cap/milestone state run through the *same* helper for manual and SMS transactions.

---

## 1. Play Store review posture

### 1.1 The rule

**No task in this plan adds a permission to the prod manifest.** If a feature appears to need one, the plan changes the feature, not the manifest.

Why this framing rather than "apply for the permission": a permission declaration turns every submission into a manual review with a rejection risk attached to *the whole app*, not just the feature. A rejected declaration can hold up an unrelated bugfix release for weeks.

### 1.2 ⭐ Existing risk to resolve: `ACCESS_BACKGROUND_LOCATION`

**Confirmed present in the built prod artefact**, not just the source manifest — `ACCESS_BACKGROUND_LOCATION` and `FOREGROUND_SERVICE_LOCATION` both appear in `prodRelease`'s packaged manifest. The prod flavor does not strip them the way it strips SMS.

Google requires a Permissions Declaration and a demo video for background location, reviews it manually, and rejects apps whose core function doesn't demonstrably need it. PandaPay's background geofence is an **opt-in toggle, off by default** — precisely the "optional convenience feature" framing the prod SMS manifest comment correctly identified as *disqualifying*.

**Decision needed before the next submission.** Options:

- **(a) Strip `ACCESS_BACKGROUND_LOCATION` + `FOREGROUND_SERVICE_LOCATION` from the prod flavor**, exactly as SMS is stripped, and let the one-shot foreground check be prod behaviour. **Recommended:** costs one background feature, removes the app's biggest review risk.
- **(b) Keep it and file the declaration** — accept manual review on every release, prepare a demo video, expect scrutiny of whether an off-by-default toggle justifies it.
- **DoD:** a written decision, and if (a): `tools:node="remove"` entries alongside the SMS ones, `Env.isProd` gating on the background toggle in `nearby_merchants_screen.dart`, **and** a re-built `prodRelease` packaged manifest confirming both permissions are gone.

### 1.3 Why not just get SMS permission back

The route exists — Google's Permissions Declaration Form, arguing SMS is *core* rather than optional. It's a poor bet: the prod manifest's own comment already concluded PandaPay's SMS import is optional (manual entry and card-scan both work without it). Filing a declaration that contradicts the app's own design invites rejection. §2 gets the same user value without the form.

> **Note:** Play policy changes, and this plan's policy reasoning has a knowledge cutoff. Re-verify current SMS/Call Log and background-location terms in the Play Console before acting on §1.2 or §1.3.

### 1.4 Data Safety accuracy

Every task that touches user data must have its Data Safety declaration checked *before* submission. Given §0.2, the honest answers today are:

- **SMS messages → collected, transmitted off-device.** Not "processed ephemerally on-device." This stays true even after S-0's pre-filter narrows *which* messages are sent; a narrower set is still a transmitted set. The available honest improvement is scope ("only messages matching a bank-alert pattern"), not category.
- **Email content → collected and stored server-side**, with a stated retention window (`purge_after`).
- Declare "data is not sold", "user can request deletion" (`delete from inbound_emails where profile_id` already exists in [0010_functions_and_views.sql:333](db/supabase/migrations/0010_functions_and_views.sql)).

---

## 2. SMS import — full value, zero permissions

### Task S-0 ⛔ **BLOCKER** — make the privacy story true, then say it

Do this before S-1. It is the prerequisite that makes S-1 shippable.

**Code, in order:**

1. **Pre-filter before upload.** Apply the existing `looksLikeTransactionSms()` to every parsed message *in the app* and drop non-matches before any network call. Report the drop count to the user ("4,812 messages read, 96 looked like bank alerts, 4,716 never left your phone"). Fixes **D1** and makes claim #2 in §0.2 true. Consider tightening the keyword list — it is currently English-only and misses `₹`-led formats.
2. **Rewrite the three strings** in §0.2 to describe what actually happens. Suggested framing, which is both accurate and still reassuring:
   > "PandaPay reads the backup file on your phone and keeps only the messages that look like bank alerts. Those are sent to PandaPay over an encrypted connection to extract the amount, merchant and date. The message text itself is never stored on our servers."
   That last sentence is verifiable: `/transactions/from-sms` stores only the parsed transaction, and on failure only `redactSmsShape(body)`.
3. **Add an assertion test** that fails if the consent copy claims on-device parsing while `logTransactionFromSms` still posts a body — so this cannot silently regress.
4. **Update the Data Safety draft** per §1.4 in the same change.

- **Skill:** `flutter-riverpod-gorouter`; `owasp-mobile-security-checker` for the copy/behaviour audit.
- **DoD:** no user-facing string claims on-device parsing or non-upload; a staging run of a real backup file shows the drop count and a network capture confirms only pre-filtered messages leave the device; Data Safety draft updated and attached to the release checklist.

### Task S-1a ⭐ Fix D2–D6 (correctness), before anything is surfaced

- **D2 — preserve the real date.** Extend `BackupSmsMessage` to `({String sender, String body, DateTime? sentAt})`, read the `date` attribute (epoch milliseconds in the SMS Backup & Restore format), and pass it as `occurredAt`. Messages with no usable date should be *skipped and reported*, not silently dated today.
  **Also decide, explicitly:** whether a backdated import should mutate cap/milestone/fee-waiver state at all. Recommendation — add a `backfill: true` flag to `/transactions/from-sms` that inserts the transaction but skips `applyTransactionState`, and say so in the UI ("imported history is recorded, but doesn't change this cycle's progress"). Without this, a clean historical import still corrupts current-cycle numbers.
- **D3/D4 — fix card attribution.** Replace the mandatory single-card dropdown with: run `extractLast4Hint()` per message on-device, group messages by hint, and let the user map each group to a card (or to "skip"). Messages with no hint fall back to a single default-card choice. When the user has **no** cards, show an empty state that routes to `FindCardsScreen` instead of a disabled button.
- **D5 — make re-import idempotent.** Send a stable per-message key (hash of sender + body + date) and add a unique partial index so a repeat import is a no-op rather than a silent double-count. Cheaper alternative if a migration is unwelcome: extend `detectDuplicates` to also match same-source rows when a source key is present.
- **D6 — decode and bound.** `utf8.decode(bytes, allowMalformed: true)` instead of `String.fromCharCodes`; reject files over a stated size (start at 25 MB) with a clear message rather than an OOM.
- **Non-blocking but do it here:** batch the uploads (a `POST /transactions/from-sms/batch` taking up to ~200 messages per request), show real progress, and allow cancel.
- **Skill:** `flutter-riverpod-gorouter`; `test-driven-development` — D2, D5 and D6 all have exact, cheap unit tests.
- **DoD:** a real multi-year, multi-card export imports with correct per-message dates, correct per-card attribution, `₹` amounts parsed correctly, and a second run of the identical file adds **zero** new transactions. Verified against the database, not the UI.

### Task S-1b ⭐ Surface the backup import in prod

Only after S-0 and S-1a.

- Add a dedicated Import Hub tile — "Import SMS backup file" — **shown in all flavors**, routing directly to `SmsBackupImportScreen` rather than through `SmsImportScreen` ([import_hub_screen.dart:56](app/lib/features/import/import_hub_screen.dart) is the gate that currently hides it).
- Keep the existing "SMS import" (live auto-read) tile `!Env.isProd`-gated exactly as it is. Do not merge the two: one is permission-free and shippable, the other is not.
- Copy must set expectations: the user exports SMS with a backup app (SMS Backup & Restore's XML is the format the parser handles), then picks the file — and must use the S-0 wording, not the old on-device claim.
- **Add a kill switch.** Gate the tile behind a server-side flag so the feature can be disabled without a release if the first real-world exports behave unexpectedly. The blast radius of a bad import is the user's whole transaction history.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** a prod-flavor build reaches the backup import, parses a real export file, and creates correctly-dated transactions — with `READ_SMS` absent from the rebuilt `prodRelease` packaged manifest.

### Task S-2 Regression guard on the merged manifest (was: "verify file_picker")

**Already verified — no work needed to answer the original question.** The current `prodRelease` packaged manifest contains no SMS and no storage permission; `file_picker`'s own library manifest contributes only a `<queries>` block for `GET_CONTENT`, and `telephony`'s contributes only `ACCESS_COARSE_LOCATION` (already present via the geofence feature). The Storage Access Framework assumption held.

What is actually worth doing instead:

- **Turn the check into CI.** Add a build step that greps the `prodRelease` packaged manifest for a denylist (`READ_SMS`, `RECEIVE_SMS`, `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`, and — if §1.2 goes with (a) — `ACCESS_BACKGROUND_LOCATION`) and fails the build on a hit. A plugin bump is exactly how this regresses silently, and a human spot-check will not catch it.
- **Pin `file_picker`.** `pubspec.yaml` currently declares `file_picker: ">=12.0.0-beta.1"` with **no upper bound**, resolving to `12.0.0-beta.7`. An unbounded range on a pre-release is a live risk of a breaking pull on any `pub upgrade`, in the one dependency this whole feature depends on. Pin to `12.0.0-beta.7` exactly, with a note to move to stable 12.x when it lands.
- **Skill:** `codemagic-yaml-quickstart` for the CI step; `owasp-mobile-security-checker` for the denylist.
- **DoD:** CI fails on an artificially-added `READ_SMS`; `file_picker` pinned.

### Task S-3 Feed the backup import into card discovery

`POST /card-discovery` already accepts an in-memory `smsBodies` array and never persists it — the pipe exists and is unused. [find_cards_screen.dart:62](app/lib/features/cards/find_cards_screen.dart) calls `discoverCards()` with no bodies at all.

- After a successful backup parse, offer "Find my cards from these messages," passing the **pre-filtered** bodies (S-0) to `discoverCards()` in the same session.
- **Sequencing note:** with D4 fixed, this becomes the *primary* entry point for a new user — discover cards first, then attribute transactions to them. Consider offering discovery *before* the import step rather than after, since the import needs the cards to exist.
- The server caps `smsBodies` at 500 ([index.js:3528](api/src/index.js)); a large backup will exceed it. Send the highest-signal subset (most recent bank-alert matches) rather than an arbitrary first-500 truncation.
- Do not persist the bodies. The in-memory-only contract is what makes this defensible in the Data Safety declaration.
- **Skill:** `flutter-riverpod-gorouter`; `flutter-tester` for the pass-through.
- **DoD:** importing a backup containing alerts from two different issuers surfaces both cards in `FindCardsScreen`, and no SMS body reaches the database — verified by inspecting `inbound_emails`, `parser_failures` and `transactions.note` after a run.

### Task S-4 Manual share-to-app (optional, later)

An Android share-target intent lets a user share individual SMS into PandaPay — permission-free, since the user initiates each share. Lower value than S-1 (tedious per-message) but a reasonable fallback for users who won't install a backup app. Defer unless S-1's file-export friction proves too high in practice.

---

## 3. Card detection — what's left

Do not rebuild the matcher. See §0.3 for the design decisions worth preserving.

### Task F-8 ⭐ Route mail into the webhook (infrastructure, not code)

Highest value-per-effort in this plan: it switches on a finished feature.

- Point an inbound-parse provider (SendGrid Inbound Parse, Mailgun Routes, Postmark Inbound, or a Cloudflare Email Worker) at `POST /inbound-emails/webhook`, mapping its native payload to `{to, from, subject, text}` at the provider level.
- Set `INBOUND_EMAIL_WEBHOOK_SECRET`; configure DNS/MX for the forwarding domain.
- **Mailbox-agnostic by design:** the webhook resolves users by the issued `local_part`, never by matching the sender to a signup email — so a user who signs up with one address and receives bank alerts at another just forwards from the second.
- **Also build Gmail's verification-code step.** Gmail sends a confirmation code to the forwarding address before it will forward. The webhook receives it, but no UI surfaces it back to the user — without this, Gmail users get stuck partway through setup. A real blocker, not a polish item.
- **Add operational basics the route currently lacks:** a rate limit (the endpoint is unauthenticated apart from the shared secret and will be scanned), and an alert on repeated 401s. Also confirm the provider's payload size limit against `inbound_emails.body_text` — a large HTML statement email will otherwise fail silently at the DB layer.
- **DoD:** a real email to an issued address creates an `inbound_emails` row, increments `email_count`, and becomes visible to `POST /card-discovery`; a Gmail user can complete forwarding setup end-to-end; a burst of bad-secret requests is rate-limited and alerts.

### Task F-9 Test and extend `parser_patterns` coverage

Discovery is only as good as the seeded sender patterns; an issuer with no active pattern is invisible to both the bank-sender gate and the parser.

- **First: there are no tests for `card_discovery.js` at all.** `api/test/` has `sms_parser.test.js` and `email_ingest.test.js` but nothing for the matcher — the module that decides which cards a user is told they own. Write them: the issuer-alone-is-not-enough rule, the exact-name-wins rule, the stopword floor, and the last-4-as-evidence-only rule are all directly unit-testable with no IO (the module is pure by design).
- Audit active patterns against the issuers in `v_card_catalogue_export`; seed gaps (HDFC/ICICI/SBI/Axis first).
- Build fixtures from real (anonymized) alert formats for both channels. The expected long-run failure is a pattern silently dying after a bank redesigns its template — add a parse-failure-rate alert, since `parser_failures` and its `occurrences` aggregation already exist.
- **Skill:** `systematic-debugging`; `flutter-tester` / plain node:test for the fixtures.
- **DoD:** `card_discovery.test.js` exists and covers the four rules above; a fixture email *and* a fixture SMS per major issuer passes the bank-sender gate and yields a correct catalogue match; a parse-failure-rate alert fires on a seeded bad pattern.

### Task F-10 IMAP poller — **drop**

Previously scoped as "build or drop." The recommendation is **drop**: Google is deprecating app passwords in favour of OAuth 2.0, having already ended basic-auth IMAP for Workspace accounts and turned off less-secure-app access entirely in March 2025. Building a poller on app-password IMAP means building on a foundation Google is actively removing.

- Forwarding covers the same need without storing anyone's credentials and depends on no Google policy being withdrawn.
- **The UI is currently reachable in prod** — the Import Hub shows an "IMAP connection (fallback)" tile in all flavors with a live status line, implying a working feature that has no poller behind it. Whatever the decision, that tile must not keep making that implication.
- **DoD:** a written decision; the IMAP tile either removed from `ImportHubScreen` or relabelled to state plainly that it tests a connection and does not yet sync; any stored credentials purged if the feature is removed.

### Task F-11 Security pass before the webhook goes live

- No email body content in server logs or error tracking — extend the "never logged/echoed" discipline already applied to IMAP passwords ([imap_connection_screen.dart:19](app/lib/features/import/imap_connection_screen.dart)). Note that `console.error` on the webhook path currently logs the whole error object; confirm no provider payload rides along.
- Confirm non-enumerability survives deployment: an unknown `local_part` must stay indistinguishable from accepted, or the endpoint becomes an address-enumeration oracle. **Check timing as well as status code** — the unknown-`local_part` path currently short-circuits inside the RPC and may return measurably faster than an accepted one.
- Re-run the S-0 network check: confirm what actually leaves the device on the SMS path matches what the Data Safety form says.
- **Skill:** `owasp-mobile-security-checker`, proactively per this project's `CLAUDE.md` posture.
- **DoD:** checklist pass confirming nothing PAN-adjacent is stored, logged, or transmitted beyond what the source email already exposed; timing difference between known and unknown `local_part` under a stated threshold.

---

## Sequencing

| # | Work | Why here | Blocks |
| --- | --- | --- | --- |
| 1 | **§1.2 background-location decision** | The live review risk, independent of everything else | Next submission |
| 2 | **S-0** (privacy truth) | Hard prerequisite — S-1b would otherwise ship a false claim into prod copy and the Data Safety form | S-1b |
| 3 | **S-1a** (D2–D6) | A backup import that misdates and misattributes every transaction is worse than no feature | S-1b |
| 4 | **S-1b + S-2** | Surface it, and guard the manifest in CI so it stays clean | — |
| 5 | **F-8 + F-11** | Infrastructure that turns on the finished discovery feature. Pair them; do not go live without the security pass | — |
| 6 | **S-3** | Connects SMS to discovery once both work. Note the "discover before import" reordering | — |
| 7 | **F-9** | Once real mail flows, patterns can be validated against actual received emails — but write the matcher tests any time | — |
| 8 | **F-10** | Record the decision; stop the IMAP tile implying a working feature | — |

**What changed from the previous revision:** items 2 and 3 are new and are prerequisites, not additions. The old plan sequenced S-1 second on the belief that the screen was finished; it is not, and shipping it as-is would have put incorrect transaction data into users' accounts and an incorrect claim into the Data Safety declaration.

**The through-line is unchanged and still holds:** this plan adds substantial user-visible capability without touching the manifest, while §1.2 *removes* the app's biggest review exposure. The Play Store position should be strictly better after this plan than before it.

---

## Not in this plan — open decision

**On-device Gmail OAuth** is the strongest long-term email path: one tap, no app passwords, no deprecation risk, PKCE with tokens never leaving the device, and parsing done locally so no message content reaches PandaPay servers. Cards the user confirms would still sync normally — a `user_cards` row is a user-confirmed fact, indistinguishable from a manually-added one.

Note that "parsing done locally" would require a **Dart-side parser that does not exist today** — §0.2 established that all parsing is currently server-side. That is a real cost of this option, and also a reason it is attractive: it is the only path where the on-device claim would be true.

It is deliberately not scoped here because it is blocked on an unresolved question: whether Google's annual CASA security assessment applies to an app that stores and transmits no restricted scope data on any server. Google's own documentation is contradictory — the restricted scope verification page ties the assessment to storing or transmitting restricted scope data on servers, while support.google.com/cloud/answer/13465431 states the requirement unconditionally.

Resolve that before scoping the work. Nothing else in this plan depends on the answer.
