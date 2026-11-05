# Store and legal checklist (owner work)

This is Task 5.5 of the fresh-start release plan. It is owner work, not code: nothing here is done by the app or the server. Everything in sections 3 and 4 is a draft you can paste, then check against what you see in the Play Console and App Store Connect forms.

Policy version for this release: **2026-11-15** (the published policy date; one constant for every consent screen).

## 1. Before anything is published

- [ ] **Fill every `[OWNER TO FILL: ...]` placeholder** in the hosted pages and the in-app text. They appear on purpose so they cannot be missed. To change a placeholder, edit both `deploy/legal/privacy.html` / `terms.html` and `app/lib/features/settings/legal_text.dart` (a test fails if the two differ).
  - Legal entity name and registered address (privacy 1).
  - Grievance officer name (privacy 1).
  - Grievance officer email (privacy 1).
  - Hosting provider and region (privacy 6).
  - Where error reports are hosted: GlitchTip, self-hosted or cloud (privacy 6).
  - Governing law and courts (terms 11).
- [ ] **Name a grievance officer.** The DPDP Act expects one to be published with contact details and a reply time. The policy promises a reply within 30 days.
- [ ] **Confirm the general contact address.** The pages still use `panda.paths123@gmail.com` as the general contact. Replace it if you want a company address on a public policy.
- [ ] **Confirm with the hosting provider that the server's disks are encrypted at rest.** The policy does not claim it. Add a sentence to privacy section 7 only after you have the answer in writing.
- [ ] **Confirm the backup retention.** The policy says encrypted server backups expire within 30 days after account data is deleted. Check the real backup schedule matches, or change section 8.
- [ ] **Publish the legal pages**: copy `deploy/legal/*.html` to `/var/www/pandapay-legal/` (see `deploy/DEPLOY.md`). The app links to them through `PANDAPAY_LEGAL_BASE_URL`. Use those URLs as the privacy policy URL in both stores.
- [ ] **Apply the new database migration** `db/supabase/migrations/20261115050000_user_consents_email_sms_purposes.sql` before the release goes live. Without it the `user_consents` table rejects the `email_import` and `sms_reading` consent rows.
- [ ] **Set `PRODUCT_TERMS_VERSION=2026-11-15`** in the production environment, or remove the variable so the new default applies. The app now sends `2026-11-15` at sign-up; a server still on `2026-08-07` rejects sign-up with `product_terms_changed`.
- [ ] **Before public launch (not needed for the friends test):** an Indian fintech privacy lawyer reviews the privacy policy, terms and consent screens.

## 2. Account and console requirements

- [ ] **Apple developer account is an Organization account.** Money-management apps need this (App Store guidelines 5.1.1(ix) and 3.2.1(viii)).
- [ ] **Google Play developer account is an Organization account** where Play requires it for finance apps.
- [ ] **Play: target audience is 18 and over, not designed for children.** Matches the "I am 18 or older." sign-up box.
- [ ] **Play: financial features declaration** (personal finance management; no loans, no payments processed).
- [ ] **Play: account deletion.** Play asks for an in-app deletion path and a web link where a person can request deletion. The app has the in-app path (Settings). Provide a web URL or an email-based request page.
- [ ] **Play: background location.** The Android manifest declares `ACCESS_BACKGROUND_LOCATION` and a location foreground service for location alerts. Play needs its own declaration and a prominent in-app disclosure for background location. If location alerts are not in this release, remove the permission instead of declaring it.

## 3. Google Play

### 3.1 SMS permission declaration ("SMS-based money management")

Permissions: `READ_SMS`, `RECEIVE_SMS`. Core functionality: automatic recording of bank, card and wallet transactions from SMS.

Paste into the declaration form:

> PandaPay is a personal finance app. Its core function is recording the user's bank, card and wallet transactions automatically from the transaction SMS they receive. The app reads messages on the phone, picks out messages from banks, cards and wallets, and records the amount, merchant, date, card or account ending, and type of each transaction. Personal messages and one-time passwords are skipped. The message text is never sent to PandaPay's servers; only the transaction details are sent, so the user's spending shows on any phone they sign in to. The app is not the device's default SMS handler and does not send SMS.

**Prominent disclosure (shipped copy, shown before every permission request):**

> **PandaPay reads your bank SMS on this phone**
> - PandaPay reads messages from banks, cards and wallets to record your transactions automatically, including in the background when a new message arrives.
> - Messages are read on this phone. Only the transaction details (amount, merchant, date, card or account ending, and type) are sent to PandaPay, so your spending shows on any phone you sign in to.
> - Personal messages and one-time passwords are skipped and never sent.
> - Messages already on this phone will be added to the account {masked phone or email}.
> - You can turn this off in Settings at any time.
>
> ☐ I agree to PandaPay reading my bank SMS as described.
> [Continue] [Not now]

Where it appears (Android): onboarding permissions, add first card, find cards, auto SMS sync, SMS import, and Settings > Privacy & Permissions > "Read my bank SMS". "Not now" never reaches the system permission prompt.

**Video for the declaration** (about 30 to 60 seconds, on a test phone with a test account and synthetic messages only):

1. Sign up or sign in with a test account.
2. Reach the SMS step and tap "Allow SMS & find my spends".
3. Show the full disclosure, tick the box, tap Continue.
4. Show the Android permission prompt that follows.
5. Show a transaction appearing from a test SMS.
6. Open Settings > Privacy & Permissions and show the "Read my bank SMS" switch.

### 3.2 Data safety form (draft answers)

General:

| Question | Answer |
|---|---|
| Does the app collect or share user data? | Yes |
| Is all collected data encrypted in transit? | Yes (HTTPS/TLS) |
| Can people ask for their data to be deleted? | Yes (in-app account deletion; add the web link from section 2) |
| Does the app follow the Families policy? | No (18+ only) |

Data types (collected = leaves the phone):

| Category | Data type | Collected | Shared | Optional | Purpose | Notes |
|---|---|---|---|---|---|---|
| Personal info | Email address | Yes | No | No | Account management, App functionality | Sign-in |
| Personal info | Phone number | Yes | No | No | Account management | Sign-in and matching |
| Personal info | Name | Yes | No | Yes | App functionality | Display name and the name of people added to shared expenses |
| Personal info | User IDs | Yes | No | No | App functionality, Account management | Account ID |
| Financial info | Purchase history | Yes | No | No | App functionality | Transaction details read from SMS, entered by hand or imported |
| Financial info | Other financial info | Yes | No | No | App functionality | Card names, card or account ending, bills, limits, balances. No full card number, PIN or CVV |
| Messages | SMS or MMS | Yes | No | Yes | App functionality | Only redacted templates, only when "Help PandaPay get better for everyone" is on. The SMS text itself is never sent |
| Messages | Emails | Yes | No | Yes | App functionality | Only when email import is connected; deleted once read, unread ones within 30 days |
| Location | Approximate location | Yes | No | Yes | App functionality | Nearby merchants and alerts |
| Location | Precise location | Yes | No | Yes | App functionality | Nearby merchants and alerts; coordinates pass to Google Places or OpenStreetMap-based providers acting for us |
| Contacts | Contacts | Yes | No | Yes | App functionality | Only a person you pick for a shared expense: name and number |
| App activity | App interactions | Yes | No | No | Analytics, App functionality | Fixed list of events, no free text |
| App info and performance | Crash logs | Yes | No | No | App functionality | Error type, code location, app version, phone type; no message text, amounts or IDs |
| Device or other IDs | Device or other IDs | Yes | No | No | App functionality | Push token and install ID |

Notes for the form:

- "Shared" is No throughout: Novu, Firebase Cloud Messaging, GlitchTip, hosting, Google Places/OpenStreetMap-based providers and Google Gemini act as service providers on our behalf. Google Gemini only sees redacted templates, and only with the opt-in. If the form's wording makes you answer Yes for a provider, answer it per type.
- Data not collected (stays on the phone): SMS text, receipts and attachments, messages waiting for review.
- Camera, photos and microphone: used on the phone (QR and card scanning, receipt text recognition, voice input through the phone's own speech recognition). Confirm that no audio or image leaves the phone before answering "Not collected".
- Optional data is marked optional because the person can use PandaPay without it.

## 4. Apple App Store

### 4.1 App Privacy labels (draft)

Does the app track people? **No.** (No advertising or cross-app tracking.)

Data linked to the user:

| Category | Data type | Purpose |
|---|---|---|
| Contact Info | Email Address, Phone Number, Name | App Functionality |
| Financial Info | Other Financial Info (transaction details, card or account ending, bills) | App Functionality |
| Location | Precise Location (optional) | App Functionality |
| Contacts | Contacts (optional: only a picked contact) | App Functionality |
| User Content | Emails or Text Messages (optional: email import; redacted templates if sharing is on) | App Functionality |
| Identifiers | User ID, Device ID (push token and install ID) | App Functionality |
| Usage Data | Product Interaction | Analytics, App Functionality |

Data not linked to the user: **Diagnostics, Crash Data** (error reports carry no user or device identifier). If you decide they are linkable, move them to the list above.

The iPhone does not give apps direct SMS access. PandaPay reads the bank messages a person shares through a Shortcut; only the transaction details leave the phone, so SMS text is not a collected data type.

### 4.2 Review notes (paste)

> PandaPay records transactions from bank messages. On iPhone, iOS does not let apps read SMS, so the user installs a Shortcut and chooses to share bank messages with PandaPay. Before the Shortcut setup the app shows a full-screen disclosure with a required tick box. Messages are read on the phone; only transaction details (amount, merchant, date, card or account ending, and type) are sent to the account. Message text is never sent. Demo account: [OWNER TO FILL: reviewer email and phone, and how the review code is delivered]. The account contains only synthetic data.

### 4.3 Other

- [ ] The privacy policy URL and terms URL are the hosted pages from section 1.
- [ ] Age rating answers match 18+ ("Unrestricted web access: No"; finance features: yes).
- [ ] Sign in with Apple is not required if the only third-party login is email and phone plus Google sign-in; check the current guideline 4.8 wording against your final login options.

## 5. After the stores accept

- [ ] Keep the screen recording and the exact disclosure text with the release record. If the disclosure wording changes, update the Play declaration and these answers in the same change.
- [ ] If the policy text changes, change `consentPolicyVersion` (`app/lib/data/consent_policy.dart`) and the server's `PRODUCT_TERMS_VERSION` together. People are asked again.
