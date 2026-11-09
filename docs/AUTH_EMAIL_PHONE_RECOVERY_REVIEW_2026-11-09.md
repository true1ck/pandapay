# Email, phone and recovery flow review — 9 Nov 2026

Question asked: is one email locked to one phone number, can the same email sign in with a
different phone, and is the recovery flow correct? This is a review only. No flow behaviour was
changed. (The same session did remove guest login and cut the code lifetime to 1 minute; see
the bottom.)

## Short answer

**No. In the live configuration an email is not locked to any phone number**, because the phone
number typed into the form is thrown away. Email alone is the identity. And the recovery flow
has a dead end for every email-only account, which is every new account.

Why the configuration is this way: prod has `ENABLE_PHONE_OTP=false`
(`docker-compose.prod.yml`), so no phone can be verified, and the app builds on the 6-digit
(v2) code path, where the server refuses a phone field.

## How it works today

| Step | What happens | Where |
|---|---|---|
| Sign-up form | Asks for email and phone, checks the phone has 10+ digits | `app/lib/features/auth/login_screen.dart:198-224` |
| Request code (v2) | Sends only `email` and `device_id`. The phone is not sent | `app/lib/data/auth_api.dart:277-280` |
| Server, v2 | Any extra field, including `phone_number`, returns 400 `invalid_v2_otp_request` (run to confirm) | `auth/src/routes/versionedOtpRoutes.js:15-17` |
| Verify code | If no account has that email, one is created with the email only. No phone | `auth/src/routes/authRoutes.js:943-948` |
| Log-in form | Also demands a phone, and also never sends it | `login_screen.dart:357` |

The old (v1) path also discards the phone: it uses it for a conflict check at request time and
then creates the account without it. The comment on `AuthMode` ("sign-up links it to the new
account", `login_screen.dart:33-38`) is wrong.

What does lock contacts to one account is the database: unique live email and unique live phone
hash (`auth/db/migrations/9001_active_contact_uniqueness.sql`). So two accounts cannot share an
email, and two accounts cannot share a phone. I read the migration; I could not check that it is
applied on the production database.

## Mistakes found

### In sign-in and sign-up

1. **The phone field does nothing.** It is required on sign-up and log-in, validated, then
   dropped. Users are told a phone is "linked" when it is not.
2. **Log-in can create an account.** The server has no separate log-in. A valid email that has no
   account (a second address, a typo that still receives mail) silently gets a new empty account
   (`authRoutes.js:943-948`). The Terms and 18+ tick boxes are checked only on the sign-up screen,
   not by the server.
3. **The sign-up phone conflict check is gone in v2.** In v1 a phone already used by another
   account was refused at request time. v2 never sees the phone, so that check cannot happen.

### In recovery ("Find your account")

4. **Dead end for email-only accounts.** After the code is accepted the screen says "No phone
   number is linked to this account." The "Return to sign in" button exists only when a phone is
   linked (`account_recovery_screen.dart:470-531`). The only button left is "Add a phone number",
   and the server refuses it with "SMS verification is currently unavailable"
   (`recoveryContactRoutes.js:122`). The user can only press the back arrow. I read this in the
   code; I did not run the screen.
5. **Recovery by phone is offered but switched off.** The screen says "Enter the email address or
   phone number" with a phone example, but phone codes return 403 "Phone authentication is
   currently disabled".
6. **Two codes for nothing.** Recovery proves control of the email, exactly what a normal
   sign-in proves, then throws the session away (`_pendingTokens` is never saved) and asks for a
   second code to sign in. For an email-only account there is nothing to recover.
7. **The "last 4 digits" check protects nothing.** The server does not record that it passed, the
   replace-contact calls do not require it, and "I can't access this phone" is on the same screen.
   Passing it only closes the screen. (It also cannot be brute forced in practice: 10 tries an
   hour.)
8. **Replacing a contact is instant and silent.** With one verified channel you can swap the other
   (`recoveryContactRoutes.js:216-221`). The old contact is not told, there is no waiting period,
   and other signed-in devices are not signed out. Once phone codes are on, a SIM-swapper could
   replace the email and lock the owner out for good.
9. **One channel is enough, not two.** Email OR phone gets full access, so pairing them adds a
   second way in, not a second lock. If you want "this email only works with this phone", that
   means asking for both codes, which is a product decision.
10. **Existence leak while replacing.** "This contact cannot be linked" tells a holder of any
    recovery session that some other account uses that email or phone
    (`recoveryContactRoutes.js:127`, checked before the rate budget at `:130`).
11. **Recovery looks like a login.** It marks the device active and updates last login even though
    no session results, so the device list can show a device that never signed in.
12. **Codes go to any address.** A recovery or sign-in request for an unregistered email still
    sends a real email (limited to 3 per 10 minutes per address).

## Decisions needed from you

- **Phone field:** (A) remove it from sign-up and log-in until SMS is on (recommended: it is
  honest and removes mistakes 1-3); (B) keep it and verify it with an SMS code at sign-up so the
  pair is stored and locked; (C) require both codes at every sign-in.
- **Recovery for email-only accounts:** show "Return to sign in" and skip the second code, or
  remove the screen until a backup channel exists and point to support.
- **Log-in vs sign-up:** make the server refuse to create an account from the log-in screen.

## Changed in this session (not a flow change)

- `POST /auth/guest-login` and all guest handling removed; leftover guest tokens are refused by
  auth and the API.
- `/auth/refresh` now refuses a missing, deleted or disabled account and a signed-out device.
- Code lifetime is 60 seconds everywhere (`auth/src/utils/otpLifetime.js`), including the emails,
  the app timers and the admin console.
