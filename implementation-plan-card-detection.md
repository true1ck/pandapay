# PandaPay — Implementation Plan: SMS Import and Card Detection

**Companion to:** [`ui-spec.md`](./ui-spec.md) · [`product-plan.md`](./product-plan.md) · [`database.sql`](./database.sql) (aspirational combined schema — the real schema is `db/supabase/migrations/0001–0029`) · [`implementation-plan-group-e-f-g.md`](./implementation-plan-group-e-f-g.md) (Group F — F3/F4/F7 are extended here)

**Governing constraint: nothing here may put the Play Store listing at risk.** Every task below ships *without* adding a permission to the prod manifest. Where a feature would need a restricted permission, the plan changes the feature, not the manifest. §1 states the rule; every task conforms to it.

**Scope:**
1. **§2 SMS import** — get SMS-derived card detection into the *production* build with **zero** SMS permissions. Mostly already built and accidentally hidden.

**Out of scope, deliberately:** Account Aggregator (RBI) integration, and re-adding `READ_SMS`/`RECEIVE_SMS` to prod. Both are legitimate but each is a large, separately-scoped investment with review or cost exposure. See §1.3.

**Map / location work has been removed from this plan** and is deferred. The `ACCESS_BACKGROUND_LOCATION` item in §1.2 is retained because it is a live review risk in the *current* manifest, independent of any map feature.

---

## 0. Audit — verified state (read before writing any code)

Every row below was confirmed by reading the file, not inferred.

| Area | State | File(s) |
|---|---|---|
| **Card discovery** | **Fully built.** `POST /card-discovery` scans `inbound_emails` (gated to `is_known_bank_sender`) + in-memory SMS bodies through one matcher; `FindCardsScreen` shows suggestions with source text, adds nothing without a tap | [index.js:3505](api/src/index.js), `api/src/card_discovery.js`, [find_cards_screen.dart](app/lib/features/cards/find_cards_screen.dart) |
| **Inbound email receiver** | **Built.** Shared-secret auth, constant-time compare, non-enumerable. No mail routed to it yet | [index.js:5288](api/src/index.js) |
| **Forwarding address issuance** | Built. One active address per profile, idempotent | [index.js:5213](api/src/index.js), [email_forwarding_screen.dart](app/lib/features/import/email_forwarding_screen.dart) |
| **SMS backup-file import** | **Fully built** — real `file_picker`, real XML parser for the SMS Backup & Restore format, batched through the existing parser, writes `sms_import_batches`. **Requires no SMS permission.** But unreachable in prod (see S-1) | [sms_backup_import_screen.dart](app/lib/features/sms_import/sms_backup_import_screen.dart), [sms_backup_xml_parser.dart](app/lib/data/sms_backup_xml_parser.dart) |
| **SMS live auto-read** | Built, correctly disabled in prod — manifest strips the permission, `Env.isProd` hides the UI | [sms_import_screen.dart](app/lib/features/sms_import/sms_import_screen.dart), [prod/AndroidManifest.xml](app/android/app/src/prod/AndroidManifest.xml) |
| **IMAP connection** | Built — form + live test-login. No background poller. **See F-10: app passwords are being deprecated by Google** | [imap_connection_screen.dart](app/lib/features/import/imap_connection_screen.dart), [imap_test.js](api/src/imap_test.js) |
| **`user_cards` schema** | Stores no PAN, not even last-4. Do not add one | `database.sql:502` |

**Two findings shape this plan:**

1. **The permission-free SMS path already exists and is hidden by accident.** `SmsBackupImportScreen` needs no SMS permission, but is only reachable *through* `SmsImportScreen` ([sms_import_screen.dart:158](app/lib/features/sms_import/sms_import_screen.dart)), and the Import Hub hides that whole tile when `Env.isProd` ([import_hub_screen.dart:56](app/lib/features/import/import_hub_screen.dart)). The compliant path got hidden along with the non-compliant one. Fixing this is small and delivers SMS-based card detection in the Play build.

2. **Card detection is done and currently finds nothing** — only because no mail is routed to the webhook. That's DNS/provider configuration, not code.

---

## 1. Play Store review posture (read before any task)

### 1.1 The rule
**No task in this plan adds a permission to the prod manifest.** If a feature appears to need one, the plan changes the feature, not the manifest.

Why this framing rather than "apply for the permission": a permission declaration turns every submission into a manual review with a rejection risk attached to *the whole app*, not just the feature. A rejected declaration can hold up an unrelated bugfix release for weeks. Permission-free paths carry none of that.

### 1.2 ⭐ Existing risk to resolve: `ACCESS_BACKGROUND_LOCATION`
The prod manifest currently requests background location plus `FOREGROUND_SERVICE_LOCATION` ([main/AndroidManifest.xml:30](app/android/app/src/main/AndroidManifest.xml)), and the prod flavor does **not** strip them the way it strips SMS. Google requires a Permissions Declaration and a demo video for background location, reviews it manually, and rejects apps whose core function doesn't demonstrably need it. PandaPay's background geofence is an **opt-in toggle, off by default** — precisely the "optional convenience feature" framing the prod SMS manifest comment correctly identified as *disqualifying*.

**Decision needed before the next submission.** Options:
- **(a) Strip `ACCESS_BACKGROUND_LOCATION` from the prod flavor**, exactly as SMS is stripped, and let the one-shot foreground check be prod behavior. **Recommended:** costs one background feature, removes the app's biggest review risk.
- **(b) Keep it and file the declaration** — accept manual review on every release, prepare a demo video, expect scrutiny of whether an off-by-default toggle justifies it.
- **DoD:** a written decision, and if (a), `tools:node="remove"` entries alongside the SMS ones plus `Env.isProd` gating on the background toggle.

### 1.3 Why not just get SMS permission back
The route exists — Google's Permissions Declaration Form, arguing SMS is *core* rather than optional. It's a poor bet: the prod manifest's own comment already concluded PandaPay's SMS import is optional (manual entry and card-scan both work without it). Filing a declaration that contradicts the app's actual design invites rejection. §2 gets the same user value without the form.

> **Note:** Play policy changes, and this plan's policy reasoning has a knowledge cutoff. Re-verify current SMS/Call Log and background-location terms in the Play Console before acting on §1.2 or §1.3.

### 1.4 Data Safety accuracy
Every task below that touches user data must have its Data Safety declaration checked *before* submission. Inaccurate Data Safety answers are themselves a common rejection and enforcement cause. Specifically: SMS backup import means the app *does* process SMS content (even though it never holds the permission), and email forwarding means it processes email content server-side. Both must be declared honestly.

---

## 2. SMS import — full value, zero permissions

### Task S-1 ⭐ Surface the backup import in prod (small change, high value)
`SmsBackupImportScreen` is complete and needs no permission, but is unreachable in the prod build.
- Add a dedicated Import Hub tile — "Import SMS backup file" — **shown in all flavors**, routing directly to `SmsBackupImportScreen` rather than through `SmsImportScreen`.
- Keep the existing "SMS import" (live auto-read) tile `!Env.isProd`-gated exactly as it is. Do not merge the two: one is permission-free and shippable, the other is not.
- Copy must set expectations: the user exports SMS with a backup app (SMS Backup & Restore's XML is the format the parser handles), then picks the file. Explain that parsing happens on-device and that PandaPay never reads their messages directly — that framing is accurate and is exactly why this path is permitted.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** a prod-flavor build reaches the backup import, parses a real export file, and creates transactions — with `READ_SMS` absent from the merged prod manifest (verify with `aapt dump permissions` or the merged-manifest report, don't assume).

### Task S-2 Verify `file_picker` adds no permission to the merged manifest
The point of S-1 is a clean manifest — confirm the plugin doesn't undermine it. `file_picker` uses the Storage Access Framework on modern Android and should need nothing, but plugin manifests merge in silently and a stray `READ_EXTERNAL_STORAGE` would attract exactly the scrutiny this plan is avoiding.
- Inspect the **merged** manifest for the prod release variant, not the source manifest.
- If a storage permission does merge in, strip it with `tools:node="remove"` in the prod flavor and confirm the picker still works (SAF doesn't need it).
- **Skill:** `owasp-mobile-security-checker`.
- **DoD:** the prod merged manifest contains no SMS and no storage permission, and file picking still works.

### Task S-3 Feed the backup import into card discovery
`POST /card-discovery` already accepts an in-memory `smsBodies` array and never persists it — the pipe exists, unused by this path.
- After a successful backup parse, offer "Find my cards from these messages," passing the parsed bodies to `discoverCards()` in the same session.
- Do not persist the bodies. The in-memory-only contract is what makes this defensible in the Data Safety declaration; keep it intact.
- **Skill:** `flutter-riverpod-gorouter`; `flutter-tester` for the pass-through.
- **DoD:** importing a backup file containing bank alerts surfaces card suggestions in `FindCardsScreen`, and no SMS body reaches the database (verify by inspecting the tables after a run, not by reading the code).

### Task S-4 Manual share-to-app (optional, later)
An Android share-target intent lets a user share individual SMS into PandaPay — permission-free, since the user initiates each share. Lower value than S-1 (tedious per-message) but a reasonable fallback for users who won't install a backup app. Defer unless S-1's file-export friction proves too high in practice.

---

## 3. Card detection — already built; what's left

Do not rebuild this. Three design decisions already in the code are worth preserving as-is:
- **Sender verification gates the scan** — only mail matching an active `parser_patterns` sender is scanned, so a stranger emailing "HDFC Millennia" to a forwarding address cannot inject a suggestion.
- **SMS bodies are never persisted** — accepted per request, used in memory.
- **Suggestions carry their evidence** — the failure being designed against is adding a card the user doesn't own and then ranking against a card they can't pay with.

### Task F-8 ⭐ Route mail into the webhook (infrastructure, not code)
Highest value-per-effort in this plan: it switches on a finished feature.
- Point an inbound-parse provider (SendGrid Inbound Parse, Mailgun Routes, Postmark Inbound, or a Cloudflare Email Worker) at `POST /inbound-emails/webhook`, mapping its native payload to `{to, from, subject, text}` at the provider level.
- Set `INBOUND_EMAIL_WEBHOOK_SECRET`; configure DNS/MX for the forwarding domain.
- **Mailbox-agnostic by design:** the webhook resolves users by the issued `local_part`, never by matching the sender to a signup email — so a user who signs up with one address and receives bank alerts at another just forwards from the second.
- **Also build Gmail's verification-code step.** Gmail sends a confirmation code to the forwarding address before it will forward. The webhook receives it, but no UI surfaces it back to the user — without this, Gmail users get stuck partway through setup. A real blocker, not a polish item.
- **DoD:** a real email to an issued address creates an `inbound_emails` row, increments `email_count`, and becomes visible to `POST /card-discovery`; a Gmail user can complete forwarding setup end-to-end.

### Task F-9 Verify `parser_patterns` covers the catalogue's issuers
Discovery is only as good as the seeded sender patterns; an issuer with no active pattern is invisible to both the bank-sender gate and the parser.
- Audit active patterns against the issuers in `v_card_catalogue_export`; seed gaps (HDFC/ICICI/SBI/Axis first).
- **Skill:** `systematic-debugging` — validate against fixtures of real (anonymized) alert formats. The expected long-run failure is a pattern silently dying after a bank redesigns its template; consider a parse-failure-rate alert, since `parser_failures` already exists.
- **DoD:** a fixture email per major issuer passes the bank-sender gate and yields a correct catalogue match.

### Task F-10 IMAP poller — **recommend dropping**
Previously scoped as "build or drop." The recommendation is now **drop**, on new information: Google is deprecating app passwords in favour of OAuth 2.0, having already ended basic-auth IMAP for Workspace accounts and turned off less-secure-app access entirely in March 2025. Building a poller on app-password IMAP means building on a foundation Google is actively removing.
- Forwarding covers the same need without storing anyone's credentials and depends on no Google policy being withdrawn.
- **DoD:** a written decision to drop IMAP in favour of forwarding, and removal or clear deprecation-marking of the IMAP connection UI so it doesn't imply a working feature.

### Task F-11 Security pass before the webhook goes live
- No email body content in server logs or error tracking — extend the "never logged/echoed" discipline already applied to IMAP passwords ([imap_connection_screen.dart:19](app/lib/features/import/imap_connection_screen.dart)).
- Confirm non-enumerability survives deployment: an unknown `local_part` must stay indistinguishable from accepted, or the endpoint becomes an address-enumeration oracle.
- **Skill:** `owasp-mobile-security-checker`, proactively per this project's `CLAUDE.md` posture.
- **DoD:** checklist pass confirming nothing PAN-adjacent is stored, logged, or transmitted beyond what the source email already exposed.

---

## Sequencing

1. **§1.2 background-location decision** — before the next submission, independent of everything else. It's the live review risk.
2. **S-1 + S-2** — small, already-built, permission-free. Ships SMS-derived card detection into prod.
3. **F-8 + F-11** — infrastructure wiring that turns on the finished discovery feature. Pair them; do not go live without the security pass.
4. **S-3** — connects the two once both work.
5. **F-9**, once real mail flows and patterns can be validated against actual received emails.
6. **F-10** — record the decision to drop, and stop the IMAP UI implying a working feature.

**The through-line:** items 2 and 3 add substantial user-visible capability without touching the manifest, while item 1 *removes* the app's biggest review exposure. The Play Store position should be strictly better after this plan than before it.

---

## Not in this plan — open decision

**On-device Gmail OAuth** is the strongest long-term email path: one tap, no app passwords, no deprecation risk, PKCE with tokens never leaving the device, and parsing done locally so no message content reaches PandaPay servers. Cards the user confirms would still sync normally — a `user_cards` row is a user-confirmed fact, indistinguishable from a manually-added one.

It is deliberately not scoped here because it is blocked on an unresolved question: whether Google's annual CASA security assessment applies to an app that stores and transmits no restricted scope data on any server. Google's own documentation is contradictory — the restricted scope verification page says *"If you store or transmit restricted scope data on servers, then you need to complete a security assessment,"* while support.google.com/cloud/answer/13465431 states the requirement unconditionally.

Resolve that before scoping the work. Nothing else in this plan depends on the answer.
