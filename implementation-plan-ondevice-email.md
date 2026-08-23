# PandaPay — Implementation Plan: On-Device Gmail Linking

**Companion to:** [`implementation-plan-card-detection.md`](./implementation-plan-card-detection.md) (SMS + forwarding paths) · [`ui-spec.md`](./ui-spec.md) · [`database.sql`](./database.sql)

**Goal:** the user taps once, signs in to Gmail, and PandaPay finds their credit cards — the same "link your email to track statements" pattern competitors already ship.

**The differentiator:** competitors (CheQ, INDmoney, SaveSage) send mailbox data to their servers. This design does everything **on the device** — OAuth, token storage, fetch, parse. No message content ever reaches PandaPay infrastructure. That is both a genuine privacy claim and, potentially, the thing that exempts us from Google's annual security assessment (see E-0).

**Scope: Google/Gmail only.** Outlook/Hotmail/Live and Yahoo are deliberately out of scope for now. Worth knowing for later: both have materially lighter requirements than Google — Microsoft needs publisher verification with no paid annual assessment equivalent, Yahoo needs a manual application. Neither carries a CASA-style recurring fee. If Gmail's cost answer comes back bad, they become the fallback.

---

## E-0 Cost question — resolve before publishing, not before building

**This does not block development.** In Testing mode the OAuth app works with restricted scopes for up to 100 users, free, with no verification and no assessment. Build the whole feature, test it with real mailboxes, and validate the UX without spending anything. CASA only matters when you publish past 100 users.

So treat this as a **launch gate**, not a build gate — but start it early, because the answer takes time to come back and it shapes the go/no-go.

Google's own documentation contradicts itself on whether CASA applies to an app that never puts restricted-scope data on a server:

- Restricted scope verification page: *"If you store or transmit restricted scope data on servers, then you need to complete a security assessment."* — conditional, and scoped to apps that have *"the ability to access data from or through a third-party server."*
- support.google.com/cloud/answer/13465431: *"Applications requesting access to restricted scopes must undergo an annual security assessment."* — unconditional.

**Action:** post the question at [discuss.google.dev](https://discuss.google.dev) and send the same text to two assessors from the [official list](https://appdefensealliance.dev/casa/casa-assessors) (TAC Security, NetSentries), asking both *"does this need CASA?"* and *"if so, which tier and what price?"*

**Get the answer in writing.** In an ambiguous area, an emailed confirmation is what protects us if the position shifts later.

| Outcome | What we do |
|---|---|
| **Exempt** | Build as specified. Free, no annual fee. Best case. |
| **Tier 2** (~$540–1,800/yr, unverified) | Likely still worth it. Architecture unchanged, only cost. |
| **Tier 3** (pen test, multiples of that) | Reconsider. Fall back to forwarding + SMS backup import, or revisit Outlook/Yahoo. |

**Development proceeds in parallel.** Register the OAuth app in Testing mode, add the team's Gmail addresses as test users, and build E-1 onward immediately. The only thing you cannot do while E-0 is open is publish.

---

## 1. Architecture

### Task E-1 On-device OAuth (PKCE) — the load-bearing detail
- Authorization Code flow **with PKCE**, performed on the device (`flutter_appauth`).
- **Never request a `serverAuthCode`, and never exchange or refresh tokens through our backend.** If a token passes through our server, the "no restricted scope data on servers" claim — and the E-0 exemption argument — is void. This is the easiest way to silently break the entire design, and it is the default in many tutorials.
- Store access and refresh tokens in `flutter_secure_storage` (Keychain / Android Keystore).
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** a token is obtained, stored, and refreshed entirely on-device; a network trace of our own API shows no token and no mail content.

### Task E-2 Keep sign-in and mail access separate
- App login stays plain Google Sign-In (basic scopes, already built at `auth/src/services/googleAuthService.js`). Do **not** add mail scopes to it.
- Request `gmail.readonly` later, as **incremental authorization**, when the user taps "Find my cards."
- Rationale: users abandon signup when asked for inbox access up front, and Google's reviewers expect a scope request tied to a visible feature moment rather than buried in onboarding.
- **DoD:** a user can complete signup and use the app fully without ever granting mail access.

### Task E-3 Fetch, filtered at the source
- Gmail API: `messages.list` with `q=from:(...)`, then `messages.get`. Use `history.list` for incremental sync after the first backfill.
- **Use the Gmail API, not IMAP.** `gmail.readonly` is narrower than the `mail.google.com` IMAP scope, and a narrower scope reviews better. It also avoids app passwords entirely, which Google is retiring.
- The sender list comes from `parser_patterns` — pull it down once and cache locally. **Non-bank mail is never downloaded**, which is what makes "we only read bank mail" technically true rather than a promise.
- Quota is a non-issue: 80M units/day per project, `messages.get` costs 20. A user with 50 bank emails/month costs ~1,100 units/month.
- **DoD:** a mailbox with 100 messages of which 5 are bank alerts results in exactly 5 fetched.

### Task E-4 Port the parser to Dart
- The parser currently runs server-side against `parser_patterns` regex. Port it to run locally.
- **Risk to budget for:** those patterns are regex written for Postgres/JS. Dart's dialect differs — some will not port cleanly. Re-validate every pattern against fixtures rather than assuming.
- Extract `{amount, merchant, date, masked last-4}`, then **discard the message body**. Never persist raw content.
- **Skill:** `systematic-debugging` — validate against real (anonymized) alert fixtures per issuer.
- **DoD:** a fixture set per major issuer (HDFC/ICICI/SBI/Axis) parses identically on-device and server-side.

### Task E-5 Port the card matcher to Dart
- `api/src/card_discovery.js` matches extracted text against the catalogue. Port that logic.
- **Do not call `POST /card-discovery`** from this path — that would send email-derived content to our API and defeat the design.
- Reuse the existing catalogue cache (`card_products` already exists in the on-device SQLite schema).
- **DoD:** the same input text yields the same catalogue match on-device as the server produces today.

### Task E-6 Suggestions → the existing confirm flow
- Show discovered cards the way `FindCardsScreen` already does: each suggestion carries the source text that produced it, and **nothing is added without a tap**. Preserve that — the failure being designed against is adding a card the user doesn't own and then ranking recommendations against a card they can't pay with.
- Confirming pre-fills the existing `_AddCardForm` ([my_cards_screen.dart](app/lib/features/cards/my_cards_screen.dart)); the save path is unchanged.
- **DoD:** confirming a suggestion writes a `user_cards` row indistinguishable from a manually added one.

### Task E-7 The "Link email" screen
- One provider for now (Gmail), a linked-account chip with a remove action, and a short value line — reward tracking, automatic card updates, statement insights.
- Support **multiple linked Gmail accounts** per user; people receive bank mail at more than one address.
- Include an explicit disconnect that deletes the stored token and all locally derived data for that mailbox.
- **Do not ship this screen until the app is verified.** Until then it is capped at 100 test users and shows a "Google hasn't verified this app" warning — bad on a finance app. Gate it behind a flag.
- **Skill:** `flutter-riverpod-gorouter`; `design-polish`.
- **DoD:** link, re-link and disconnect all work; disconnect leaves no token and no derived rows.

### Task E-8 Scheduling — under-promise it
- Android: WorkManager (already in the project). iOS: `BGAppRefreshTask` is opportunistic and may not run for hours.
- **Realistic model: sync on app open, best-effort in background.** Do not promise continuous sync in UI copy — users on Xiaomi/Oppo/Vivo ROMs (a large share of the Indian market, aggressive background-task killers) will otherwise think the app is broken.
- Users open a card-recommendation app *before* paying, which is exactly when fresh data matters — so sync-on-open is a reasonable primary path.
- **DoD:** copy says "updates when you open the app," and a manual refresh control exists.

---

## 2. Data boundary

| Syncs to server | Stays on device |
|---|---|
| `user_cards` — cards the user confirmed | Raw message content |
| Everything already syncing today | OAuth tokens |
| | Unconfirmed suggestions |
| | Email-derived transaction rows |

**The test:** if the synced record looks identical whether the user typed it manually or email suggested it, it is not email data. A `user_cards` row is `card_product_id` + nickname + limit — a fact the user confirmed, not message content. Sync it normally.

Flag email-derived transactions as local-origin and exclude them from sync. If that changes later (e.g. for monthly reports), make it a deliberate decision, not a drift.

---

## 3. Privacy and compliance

### Task E-9 Make the claim actually true
- **Scrub crash reporting and analytics.** A Sentry/Crashlytics breadcrumb containing a subject line or body silently sends message content to a third party and voids the entire claim. This is the most likely way to break it by accident.
- Never log parsed fields or raw messages, on device or server.
- **Data Safety declaration** must state honestly that the app processes email content on-device. "On-device" does not mean "not collected" — declare it accurately; inaccurate Data Safety answers are themselves an enforcement cause.
- Privacy policy line: *"Your Gmail is read on your device to find your cards. Message content never reaches our servers. Once you confirm a card, that card is saved to your account like any card you add by hand."*
- Google's **Limited Use** requirements apply regardless of the CASA outcome: no ads, no selling, no human reading, use only for the user-facing feature. This design already satisfies them — say so in the verification justification.
- **Skill:** `owasp-mobile-security-checker`, proactively per this project's `CLAUDE.md` posture.
- **DoD:** a deliberate crash during a parse produces a report containing no message content.

### Task E-10 Accept the operational blind spot
On-device parsing means losing the `parser_failures` table — when a bank redesigns its alert template, we will not know until users complain.
- Mitigate with an **opt-in, content-free** failure signal: pattern ID + failure count only, never text.
- Ship a manual "report a missing card" path so users can tell us when detection fails.
- **DoD:** a written decision on whether the failure counter ships, and exactly what it transmits.

---

## Sequencing

1. **E-0** — send the CASA question today. Costs nothing, answer takes time, does not block anything below.
2. **Register the OAuth app in Testing mode** and add the team as test users. Free, immediate, unblocks all development.
3. **E-1 + E-2** — OAuth foundation. Get the token boundary right first; it is the hardest thing to retrofit.
4. **E-3 + E-4 + E-5** — fetch, parse, match. The pipeline.
5. **E-6** — suggestions into the existing confirm flow.
6. **E-9** — privacy hardening. **Do not ship without this.**
7. **Submit for OAuth verification.** Weeks of calendar time; start as early as the app is demonstrable.
8. **E-7 + E-8** — release the link screen once verified, with honest sync copy.
9. **E-10** — blind-spot mitigation.

---

## Risks to state plainly to the team

- **Cost is unknown** until E-0 is answered — but it only affects launch, not development. Build in Testing mode meanwhile.
- **Verification takes weeks.** Until it completes: 100-user cap and an "unverified app" warning that looks alarming on a finance app. Budget calendar time, not just dev time.
- **Parser porting may not be 1:1** — regex dialect differences are a real schedule risk.
- **Background sync is unreliable**, especially on iOS and Indian OEM ROMs.
- **We lose server-side visibility** into parse failures.
- **Gmail-only means no fallback provider** if E-0 comes back badly. Outlook and Yahoo remain available as a hedge, on lighter terms.
