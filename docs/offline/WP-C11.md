# WP-C11: account and settings work offline

Findings: W-14, W-16, R-07, S-03 of `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`; decision D8. Branch `offline/c11`.
Kill switch: `kAccountLocalFirst` in `lib/features/account/account_local_first.dart`.

## What changed

* **Command outbox kinds** (`AccountCommand`, handlers in `account_commands.dart`, one spread line in
  `commandHandlersFor`): consent submit, profile name, contributions opt-in, support ticket, card request,
  data-error report, inbox mark-read / mark-all-read, merchant rule update / disable. The `command_outbox`
  table is already in `QueueRegistry`, so the banner and sign-out count them. No new tables.
* **`sendOrQueue`**: one live attempt (8 s); offline, timeout, 5xx or 401 queues the write; a real 4xx is rethrown.
* **SMS-reading consent**: revoke clears the SMS-reading mirror (and the shared-learning mirror via
  `SmsSharedLearningConsentMirror.set(ns,false)`) BEFORE the server call, then sends or queues the audit POST with a
  client mutation id. Grant offline is allowed from the disclosure (the policy text is on screen): row queued, mirror set.
  The shared-learning grant does not set its mirror offline (that mirror is written only from a server answer).
  Same purpose queued twice keeps the latest intent. D8: `hasSmsReadingConsent` treats a mirror written for an older policy
  version as granted when the server cannot be reached; a reachable server with no current grant clears it (re-prompt).
  The Android background listener uses `isGrantedOrCarriedOver`. Consents list and history are saved in `ResponseCache`
  and shown cache-first with queued changes laid over them.
* **Profile name / opt-in**: applied to the profile cache and `saveProfileDisplayName` at once; server write queued.
* **Support / report a problem / card requests / data-error reports**: queued with a client id ("Saved - we'll send it when
  you're online"); the merchant-rule preview after "Report a problem" has a 4 s timeout and is skipped when queued.
* **Reads**: What's New (8 s timeout + last good copy), own and member avatars and member names (cache-first), merchant
  future rules (cache + queued edits with `expectedVersion`; a conflict re-fetches, then parks "changed on another device"),
  linked devices (persisted list), notifications inbox (cache-first, background refresh, optimistic read marks).
* **Settings sync** also runs on offline->online and on app resume.
* **"Needs internet"** disables: delete account, erase server data, phone change, recovery email, revoke device,
  onboarding "all set".

## Online healthy user
Same screens and calls. Differences: consent POST bodies carry `clientMutationId`; lists paint from the saved copy and refresh
behind it; a 5xx on a consent grant is now queued instead of showing an error.

## Tests
`test/features/consent/consent_offline_test.dart`, `test/features/account/account_offline_test.dart`,
`test/features/account/account_reads_offline_test.dart`.

## Not done / notes
* Onboarding add-first-card and card-details gating skipped (WP-C6 may make add-card work offline).
* Invite-code validate gating skipped (no matching call site found).
* Card requests / data-error reports have no server dedupe id: a lost reply can duplicate a report.
* Old servers ignore `id` / `clientMutationId`; replays can then duplicate (tickets, consent audit rows).
