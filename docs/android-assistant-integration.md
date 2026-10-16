# Android Assistant integration

PandaPay exposes Android App Actions and launcher shortcuts as secure entry
points into the existing app. These actions open a PandaPay screen; they do
not return private spending, SMS, card, or wallet data to Gemini or Google
Assistant.

## Supported commands

| User intent | PandaPay destination |
| --- | --- |
| Show spending / spending this month, week, quarter, or year | Spending trends |
| Add spending of an amount, optionally at a merchant and category | Quick Add draft |
| Show card payment due dates | Due Date Calendar |
| Open wallet / show my cards | Wallet |
| Find my cards / scan messages for cards | Find My Cards |
| Check nearby merchants | Nearby Merchants |
| Scan a UPI QR | UPI scanner |
| Show the best card | Home / current best-card recommendation |

The command is carried in a validated `pandapay://assistant/...` URI. Unknown
paths, foreign schemes, invalid amounts, and oversized text are ignored. The
normal PandaPay session, onboarding, biometric-lock, and API guards still run
after the command is received.

## Gemini and privacy boundary

App Actions are fulfillment intents. Current Android App Actions documentation
describes them as launching an in-app destination or widget; it does not give
PandaPay a general-purpose channel to inject authenticated financial results
into an arbitrary Gemini conversation. The app therefore renders the result
after authentication. A future glanceable widget could show a deliberately
limited, user-approved summary, but it must not expose raw SMS or full card
details.

## Testing and release

1. Use the Android Studio Google Assistant/App Actions preview tool with the
   query patterns in `app/android/app/src/main/res/values/assistant_strings.xml`.
2. Test cold launch, warm launch, signed-out launch, biometric lock, and
   malformed URIs. Every path must land in PandaPay or the normal auth gate;
   none should become a raw GoRouter 404.
3. App Actions are registered from a Play-distributed release. A locally
   installed APK can validate the deep-link/shortcut plumbing, but it does not
   make every Assistant/Gemini query available to all users.
