# Foreign payments — release verification, 2 November 2026

The complete feature is one update, version **1.0.16**. The iPhone candidate
uses build **105**. The implementation plan is
`foreign-payments-complete-release-plan-2026-11-02.md`.

## Delivered behavior

Foreign purchase evidence has its own durable account-scoped storage until an
actual INR posting is known. Activity, Home, detail and review show original
currency, frozen historical INR estimates, missing-price states, rate date and
source. Categories remain purchase-purpose categories. Estimates never enter
the INR transaction ledger, reward caps, milestones or confirmed spending.

Editing the original amount, choosing its category, entering actual billed INR,
dismissing and restoring work through a durable local outbox. Independent
payments continue syncing when another payment fails. Replays preserve manual
corrections. Later bank/statement evidence links one purchase only when source
amount evidence or an exact reference and saved account identity support it.
User confirmation uses the canonical INR writer atomically and idempotently.
Its distinct confirmation key cannot resurrect an old ignored credit-limit row.

Statement rows with both original currency and explicitly billed INR preserve
both amounts; a foreign-only amount is never relabelled as INR. Refunds are
separate non-income movements, with optional original-purchase linkage, rather
than additional expenses. Pending estimated refunds do not reduce confirmed
spending. Reference estimates exclude any unconfirmed issuer fees.

Bank limits, balances, outstanding amounts and obligations cannot replace a
purchase price in built-in, downloaded or AI parsing. Limit-change notices with
no payment verb are included in existing-data correction. Untouched source-backed
rows use the normal reversible ignore/state-reversal path. A separate typed-fact
server audit pages through history with durable account-specific progress and
reports unavailable evidence explicitly. Notes, tags, overrides and pending edits
are protected. Corrected ledger state invalidates dependent views, and stale
automatically detected subscriptions lose unsupported historical charge evidence.

Rates are retrieved from a fixed public Frankfurter endpoint using currency and
historical date only. Bounded requests, validation, a database cache, retry delay
and immutable rate snapshots handle outages without inventing amounts. Currency
accounting precision uses the shared SIX ISO 4217 list, not locale display/cash
rounding. Raw SMS stays on the device. `USD .00` remains an unknown original
price; a daily reference rate cannot recover its missing digits.

Portable server backups include current foreign payments and source aliases.
Correction-event history remains in paired PostgreSQL backups. Existing archives
without the additive sections remain accepted. Pending local foreign mutations
block a backup from being incorrectly labelled complete.

## Validation before release

- Full Flutter suite: **2,672 passed**, two opt-in private-data replays skipped.
- Final focused foreign-data/review/widget suite: **67 passed**.
- Full API suite: **1,414 passed**, four optional database checks skipped in the
  ordinary run. The new PostgreSQL check runs separately and is also enabled
  in the API CI job with an isolated PostgreSQL 17 service.
- Real PostgreSQL 17: migration and reapplication, RLS across accounts,
  immutable estimates, protected corrections, concurrent confirmation retry,
  canonical-write rollback, statement reconciliation, refunds and ledger edits
  passed.
- Deployment order tests: **22 passed** in Linux with the production Bash
  semantics. macOS system Bash 3.2 does not support the deployment script's
  empty-array/nounset behavior and is not a production execution target.
- Migration inventory/diagnostic checks: **9 passed**.
- Native iPhone SMS/history/background recovery regression checks passed.
- App analysis: no errors or warnings; existing informational lints remain.
- Historical provider contract: a real USD/INR response validated against its
  requested date and pair.

Build, installation and hosted deployment outcomes must be recorded from their
actual results. This document's source validation alone does not assert that a
mobile-store rollout or production deployment has finished.

## Signed iPhone and existing-data check

- The release source is commit `d8f6c3e`. The approved branch deployment is
  [GitHub Actions run 41451917725](https://github.com/true1ck/pandapay/actions/runs/41451917725).
- The unsigned release and development-signed device build both succeeded.
  `codesign --verify --deep --strict` and the compiled production SMS action
  verifier passed for **1.0.16 (105)**.
- Build 105 was installed over the existing connected iPhone application and
  launched. The existing SQLite database passed `PRAGMA quick_check` before
  and after the update; the app was closed briefly for a consistent snapshot.
  Copying database files while the app writes does not provide an atomic
  snapshot and was not used as integrity evidence.
- All **3,484 captured SMS messages** remained present. One additional untouched
  card-limit-change expense of **INR 300,000** was removed from the active local
  transaction cache, reducing its active count from 1,763 to 1,762.
- Historical local backfill saved **11 USD payment records**: seven missing
  original amounts and four waiting for valuation. At this checkpoint their
  durable outbox is waiting for the coordinated backend deployment; these are
  not yet evidence of successful hosted sync. An existing queue of 35 SMS
  uploads also remains to be checked after deployment.
- The phone installation is a development-signed device update. It does not
  establish an App Store or Play Store rollout.
- The native handoff database also passed its integrity check. Its capture
  rows are all committed, with no pending capture rows. The 35 legacy SMS
  uploads are a separate queue, with a saved retry due at 13:53 UTC. The
  existing catch-up job/window history was inspected without restarting or
  replacing any Shortcut run.

## Android distribution candidate

- The production build wrapper produced `app-prod-release.aab`, version
  **1.0.16 (18105)**, with the configured production keystore. No debug-signing
  exception was used. `jarsigner -verify` reported `jar verified`.
- The packaged manifest has package `app.pandapay.pandapay`, required SMS
  permissions and no broad storage permissions. ARM64, ARMv7 and x86-64 are
  included. Production API and auth URLs and the foreign-payment UI are present
  in all three compiled app libraries. The legal URL was passed by the wrapper;
  its unused `Env.legalBaseUrl` constant is removed by tree shaking.
- Bundle SHA-256:
  `c2ce5d9ffd48241a0e9697e23a1747d4632b78f40f19499b7aac9ee1a60c69f7`.
- No Android device was connected and this bundle has not been uploaded to
  Play Console. It is a distribution candidate, not an installed APK or a
  completed store rollout. The prior debug-signed test phone needs its matching
  debug-signing device-test path for a data-preserving local update; this
  production-signed bundle does not establish that compatibility.

## Deployment preflight and transport correction

The first feature deployment (run 41451917725) passed its complete build/test
gate but stopped at the read-only product migration preflight with
`legacy_baseline_review_required`. Production remained on the existing service;
the foreign endpoints were not live. A direct read-only ledger check confirmed
123 applied migrations with no recorded checksums and no foreign-payment table.

Review of the earlier nominally successful run 41399840151 showed that it ended
after the read-only migration preflight. It did not prove fencing, backup,
checksum adoption, migration or service replacement. The streamed `bash -s`
transport let an stdin-reading child consume the rest of the deployment source.
The shared SSH transport now writes the complete payload to a remote mode-0600
temporary file, executes with child stdin closed and preserves failure/cleanup.
Secrets remain outside process arguments. Both deployment workflows and baseline
inspection use it. All 46 Linux deployment tests passed, including seven real
shell transport regressions; workflow YAML and Bash syntax also passed.

The protected previously approved v2 baseline is not regenerated. Its recorded
SHA-256 is `b6bcf5f863220143671a8968767540f29c74b2e779473113d8c7ba7f523e1511`,
with 123 ledger entries. All historical database sources remain byte-identical
to the prior approval commit 50e4be5; the foreign-payment migration is additive.
Read-only inspection must compare the existing file and current database before
any adoption. Earlier local recovery evidence covered 97 historical migrations,
not the whole current 123-entry baseline. A fresh encrypted paired local export
was saved as set `d9e43b4819abcb22b546a504ff98138e`; its restore outcome must be
recorded separately and is not inferred from export completion.

Read-only run [41457270613](https://github.com/true1ck/pandapay/actions/runs/41457270613)
completed successfully using the corrected transport. The existing protected
baseline hash matched, with `applied=123 legacy=123 pending=21`, and the current
database comparison passed without adopting checksums. A separately captured
local read-only fingerprint matched the same exact baseline bytes.

The fresh paired export was actually restored on an independent RAM-backed
Supabase PostgreSQL 17 clone. Exact source grantors were supplied after checking
their membership projections against the encrypted archive; upgrade SQL ran as
the restored source administrator rather than an arbitrary clone superuser.
The rehearsal exposed missing temporary SET grants in three pending notification
and feedback migrations, plus an unnecessary privileged ALTER ROLE statement.
The fixes preserve and restore grantor-specific membership options and reject
unsafe pre-existing capability roles. They do not modify any already-applied
migration in the 123-entry baseline.

Upgrade and replay passed with **189 original product tables**, **144 verified
checksummed migration entries**, and both required runtime roles preserved.
The only intentional original-table value change is the existing forward
Gemini pilot-pause migration. Its opt-in review is bound to the exact SQL hash,
one flag and four specified fields; all other original values remain checked.
Regression tests reject unrelated flag changes and incorrect pause values.
The contact upgrade/replay preserved **14 account IDs** and seven auth tables,
archiving the two phone claims covered by the existing exact approved proposal.
All application recovery/key checks passed, and the disposable cluster was
removed. Private diagnostics were removed from release source. Protected review
evidence is retained with the local recovery archive. This rehearsal itself
performed no production mutations. Migration/rehearsal unit checks: **28 passed**;
backup-flow checks: **46 passed**.
