# Can PandaPay read the device's Gmail *without* the Gmail API / a fresh sign‑in?

**Question investigated:** instead of the Google OAuth + Gmail REST API path, can the
app tap the Gmail account **already signed in on the phone**, ask the user once for
permission (with our own wording about what we read), pull the bank emails, do all
filtering **on device**, export nothing, and show card suggestions — with **no
separate sign‑in**?

**Short answer:** The "no separate sign‑in / uses the device account" part is
already true today. The "skip the Gmail API and Google's consent + policy" part is
**not possible on stock Android or iOS**. Every legitimate path funnels through the
same OAuth token and the same restricted‑scope rules. Details below.

---

## 1. Why you can't just read the Gmail app's data

Android sandboxes every app. `com.google.android.gm` (Gmail) stores its messages in
its own private area and its `ContentProvider` is guarded by a **signature‑level
permission** — only apps signed with Google's certificate can query it. A
third‑party app cannot read Gmail's local database, cache, or message store without
**root**. iOS is stricter still: no app‑to‑app data access at all.

So "read the local Gmail app's emails directly" is off the table regardless of
consent. The only question is which *sanctioned* channel to use.

---

## 2. Every channel, with a verdict

| # | Mechanism | Re‑sign‑in? | Uses device account? | On‑device only? | Needs Gmail API / OAuth client? | Subject to restricted‑scope policy (100‑user cap / CASA)? | Verdict |
|---|---|---|---|---|---|---|---|
| A | **Modern Google Sign‑In** (`google_sign_in`, what the app uses now) | No password — account‑picker tap + one‑time consent | ✅ yes | ✅ token + bodies stay on device | ✅ yes | ✅ yes | **This already is what you're asking for.** Only friction: register the OAuth client (SHA‑1), one consent screen. |
| B | **`AccountManager.getAuthToken`** with `oauth2:…/gmail.readonly` | Same as A (picker + consent) | ✅ yes | ✅ | ✅ yes (historically auto‑provisioned; **that loophole was closed for Gmail after Project Strobe, 2019**) | ✅ yes | No advantage over A. Same token, same policy, lower‑level API, more code. |
| C | **IMAP** (`imap.gmail.com`) with the device account | — | ✅ in principle | ✅ if client‑side | Needs **app password** (user generates manually, requires 2FA) *or* OAuth `XOAUTH2` with `https://mail.google.com/` (even more restricted than readonly) | app‑password: no; OAuth: yes | App‑password UX is bad and Google is deprecating it. Already half‑built (`imap_connection_screen.dart`) as a *server‑side* poller — exports data, contradicts the goal. |
| D | **Gmail `ContentProvider`** (`content://com.google.android.gm/…`) | — | ✅ | ✅ | No | No | **Blocked** — signature permission. Only exposes per‑label *unread counts*, never message content. Useless for parsing. |
| E | **`NotificationListenerService`** — read Gmail notifications as they arrive | No | ✅ | ✅ | No | No | Only *new* mail while notifications are on and unread; misses all history; only the preview text; requires the scary "Notification access" settings grant; **Play Store restricts this API** and will ask for a declaration. Not viable as the primary mechanism; marginal as a supplement. |
| F | **AccessibilityService** scraping the Gmail UI | No | ✅ | ✅ | No | No | **Play Store policy violation** (accessibility APIs may not be used for this). Fragile, breaks on every Gmail update. Do not. |
| G | **Share intent** — user taps ⋯ → Share → PandaPay on each email | No | ✅ | ✅ | No | No | Manual, one email at a time. Not "auto‑find". Fine as a tiny extra entry point. |
| H | **Google Workspace Add‑on** (Apps Script card in Gmail) | Separate Google auth | n/a | ❌ runs on Google's servers | Different product | Add‑on review, not CASA | Wrong shape — it's a Gmail‑side plugin, not something your app drives. |
| I | **Email forwarding** to an in‑app address (`email_forwarding_screen.dart`, already built) | No Google auth at all | n/a | ❌ parsed on your server | No | **No** — never touches a Google API | The one path with **zero Google policy exposure** and no per‑user cap. Cost: not on‑device, needs a one‑time forwarding‑rule setup per user. |

---

## 3. "No need to sign in again" — you already have this

The worry seems to be that the current button makes users **log into Gmail with a
password**. It does not. `google_sign_in` on Android:

1. Reads the Google accounts already on the device (via Play Services).
2. Shows a **native account picker** — the user taps their account. No password.
3. Shows **one consent screen** the first time only. After that, tapping the button
   re‑uses the stored grant silently (`signInSilently()` — already added in the
   last change).

That *is* "connect to the local signed‑in Gmail." There is no lighter version of
it. `AccountManager` (row B) produces the exact same two dialogs.

---

## 4. The consent screen is not removable — but you control the framing

Reading someone's email requires **explicit informed consent** under Google policy
*and* under India's DPDP Act 2023. You cannot suppress the Google consent dialog.
What you **can** do:

- Show **your own full‑screen explanation first** (before calling `signIn()`):
  exactly which senders you search, that parsing is on‑device, that nothing is
  uploaded, that they can disconnect anytime. Full design control here.
- Customise the OAuth consent screen's **app name, logo, and support links**.
- The scope line itself is Google's fixed wording — for `gmail.readonly` it reads
  roughly *"View your email messages and settings."* You can't reword it, only
  precede it with your own screen.

---

## 5. The two real costs — and whether any alternative dodges them

### Cost 1 — Register the OAuth client (SHA‑1). *Unavoidable for A/B/C‑OAuth.*
Free, ~30 min, one‑time. Covered in `docs/gmail-oauth-setup.md`. Rows D–I don't
need it, but D/E/F/H aren't usable and G/I aren't "auto‑find on device."

### Cost 2 — Restricted‑scope policy: **100‑user cap, then CASA.**
`gmail.readonly` is a **restricted** scope. While the OAuth app is in *Testing*
status: max **100 lifetime test users**, free, instant. To go *Production* (anyone
can connect): OAuth verification **+ annual CASA security assessment**
($540 self‑scan → $15k–$75k assisted, yearly).

There is a **genuinely unresolved question** already flagged in
`smsextractionimple.md` §"Not in this plan": Google's docs contradict each other on
whether CASA applies when the app **stores/transmits no restricted‑scope data on
any server** — which is exactly PandaPay's on‑device design. Worth a written
clarification request to Google's OAuth support before committing either way.

**Ways to avoid Cost 2:**

| Option | What you give up |
|---|---|
| Stay ≤ 100 users (closed beta) | Nothing, until you outgrow it |
| Get Google to confirm **CASA doesn't apply** to a no‑server‑storage app (the open question above) | Time / uncertainty; if they say it does apply, you're back to paying |
| Lean on **SMS** (Android) + **forwarding** (row I) + PDF import for scale; keep Gmail OAuth as the ≤100‑user path | iOS has no SMS, so iOS users past the cap lose auto‑detect |
| **Forwarding only** (row I) | Not on‑device; one‑time rule setup per user |

**`gmail.metadata` is NOT an escape hatch** (corrected — earlier draft was wrong):
it is **also a *restricted* scope** and **also needs CASA** above 100 users. Worse,
the Gmail API **forbids the `q` search parameter entirely** with this scope — you
can only filter by `labelIds`, so you'd have to page the *whole* mailbox and filter
client‑side on the `From` header. And it returns headers only — no body, no
`snippet` — so no last‑4 and no specific‑product match. Strictly worse than
`gmail.readonly` for the same compliance cost. The only Gmail scopes that are
merely *sensitive* (`gmail.send`, `gmail.labels`, `gmail.compose`, …) cannot read
messages at all. **There is no read‑Gmail scope that avoids CASA.**

---

## 6. iOS

No `AccountManager`, no notification access to other apps, no IMAP shortcut. iOS
Gmail access is **OAuth‑only**, same restricted‑scope policy. Since iOS also can't
read SMS, the practical iOS card‑detection channels are: OAuth Gmail (≤100 users or
post‑CASA), forwarding, PDF statement import, camera scan, manual pick.

---

## 7. Recommendation

1. **Keep channel A (current design).** It already meets every functional goal:
   device account, no password, on‑device parsing, zero export. It is the correct
   architecture.
2. **Do the free OAuth client registration** (`docs/gmail-oauth-setup.md`) — this
   is what actually unblocks the button. Nothing else removes this step.
3. **Ship the closed beta under the 100‑user cap.** No cost, no CASA.
4. **Before public launch, resolve the CASA question in writing with Google.** If
   CASA is required and too costly, fall back to **SMS + forwarding + PDF import**
   as the scale channels (no Google API, no cap), with `gmail.readonly` reserved
   for users who opt in while the ≤100 slots remain. `gmail.metadata` does **not**
   help — same CASA requirement, no `q` search, headers only.
5. Add channel **G** (share‑an‑email → PandaPay) as a cheap, policy‑free extra —
   handy on iOS especially.

**Bottom line:** there is no hidden door. "Use the local Gmail" *is* OAuth with the
device account, and that's already what the code does — it's only waiting on a
30‑minute, free console setup. The alternatives that skip OAuth either can't read
mail content (D, E), violate policy (F), aren't automatic (G), or aren't on‑device
(H, I).
