# Gmail "1‑Tap Auto Find" — OAuth setup (required, one‑time)

The **Connect Gmail (1‑Tap Auto Find)** button in *Find my cards* fails today with
Google's **"Something went wrong"** screen right after you pick an account. The
Flutter code is correct — the app just has **no Google OAuth client registered**,
so Google rejects the sign‑in (`ApiException: 10 / DEVELOPER_ERROR` on Android).

Nothing here can be done from the codebase. It needs the Google Cloud Console and
the app's signing certificates. ~30 minutes.

## What the feature does (so the consent screen copy is accurate)

- Requests exactly one scope: `https://www.googleapis.com/auth/gmail.readonly`.
- On device only: the access token never leaves the phone, no token or email body
  is sent to any PandaPay server.
- Searches Gmail for bank statement / card‑alert emails from a fixed allow‑list of
  ~20 Indian bank domains, last 15 months (see `bankAlertsQuery` in
  `app/lib/features/import/gmail_discovery_service.dart`).
- Parses each matched email **on‑device** (`LocalCardDiscoveryEngine`) to guess
  which catalogue cards the user holds. Only card identity + last‑4 is kept, and
  only after the user taps "Yes, I have this". Same model as the SMS scanner.

## Steps

### 1. Google Cloud project + Gmail API

1. https://console.cloud.google.com/ → create project **PandaPay** (or reuse one).
2. **APIs & Services → Library → Gmail API → Enable.**

### 2. OAuth consent screen

1. **APIs & Services → OAuth consent screen.** User type: **External**.
2. App name `PandaPay`, support email, developer email, app logo, links to the
   hosted privacy policy (`deploy/legal/privacy.html`) and terms.
3. **Scopes → Add → `.../auth/gmail.readonly`.** This is a **restricted** scope.
4. **Test users → Add** every Google account you'll test with (e.g.
   `panda.paths123@gmail.com`). While the app is unverified, only listed test
   users can complete sign‑in — everyone else gets "Access blocked / Something
   went wrong". The new error copy in the app now tells testers this.

### 3. Android OAuth client(s)

**Credentials → Create credentials → OAuth client ID → Android**, once per package
id you build:

| Flavor  | Package id                       |
|---------|----------------------------------|
| dev     | `app.pandapay.pandapay.dev2`     |
| staging | `app.pandapay.pandapay.staging`  |
| prod    | `app.pandapay.pandapay`          |

For each, add **every SHA‑1** that will sign that package:

```bash
cd app/android && ./gradlew signingReport
```

Use the `SHA1` under the relevant `Variant` (e.g. `devDebug`, `prodRelease`). For
Play Store builds you also need the **App signing key** SHA‑1 from
*Play Console → Test and release → App integrity*.

> `google_sign_in` matches the Android client automatically by package + SHA‑1.
> You do **not** need `google-services.json` or the `google-services` Gradle
> plugin for this readonly‑scope flow.

### 4. (Optional) iOS client — skip for an Android‑only beta

iOS also can't read SMS, so Gmail is the main channel there. Create an **iOS**
OAuth client for bundle id `app.pandapay.pandapay`, then:

- Build with `--dart-define=PANDAPAY_IOS_GOOGLE_CLIENT_ID=<the iOS client id>`
  (wired in `app/lib/app/env.dart` → `Env.iosGoogleClientId`, passed to
  `GoogleSignIn` only on iOS/macOS).
- Add the **reversed client id** as a URL scheme in `app/ios/Runner/Info.plist`
  (`CFBundleURLTypes` → `CFBundleURLSchemes` = `com.googleusercontent.apps.NNN…`).
  This one can't be a dart‑define — it must be in the plist.

### 5. What to hand back to the developer

Once the project exists, send:

1. **Nothing secret is required** — client ids are public. But confirm:
2. The **package + SHA‑1 pairs** you registered (so we can double‑check they
   match `./gradlew signingReport`).
3. The **iOS client id** (only if doing iOS).
4. Which **Google account(s)** you added as test users.
5. Confirm **Gmail API is enabled** and the **consent screen is in "Testing"**
   with the `gmail.readonly` scope listed.

No code change is needed for Android once the client is registered — the app
already requests `gmail.readonly` and matches the client by package + SHA‑1.

### 6. Verify

1. `flutter run --flavor dev` on a device signed in with a **test‑user** account.
2. *Find my cards → Connect Gmail (1‑Tap Auto Find)* → the in‑app explanation
   screen (`GmailConnectScreen`) → *Allow read‑only access & continue* → pick
   account → Google's consent screen → allow.
3. Expected: "We read N bank emails and think you carry X of these."
4. *Settings → Privacy & Permissions* now shows **Gmail — Connected — you@gmail**
   with a **Disconnect** (revokes the grant via `GoogleSignIn.disconnect()`).
5. If it fails, the in‑app message names the cause (unregistered client, scope
   denied, API disabled, not a test user).

## What the code already does (no server, on‑device)

- `GmailConnectScreen` — pre‑consent explanation (Limited Use / DPDP requirement).
- `GmailConnectController` (`gmail_connect_service.dart`) — owns the Google
  Sign‑In, persists **only** the connected email locally (SharedPreferences),
  `disconnect()` revokes the grant.
- `GmailDiscoveryService` — device‑to‑Google Gmail REST calls, downloads full
  bank‑email bodies, parses them **on device** via `LocalCardDiscoveryEngine`.
  The access token and email content never touch a PandaPay server.
- Suggestions still require a tap to add — same model as the SMS scanner.

## Launch gate — 100‑user cap

Google caps **unverified** restricted‑scope apps at **100 users total**. Past that
you need a **CASA Tier 2** security assessment ($15k–$75k, ~3–6 months, annual
recert) plus OAuth app verification. Fine for a closed beta; must be commissioned
before public launch. (Already tracked in `TODO_OWNER.md` / beta plan Task 21.)
