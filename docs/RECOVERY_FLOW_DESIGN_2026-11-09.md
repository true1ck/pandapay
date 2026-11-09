# Account recovery flow — design for approval, 9 Nov 2026

Status: approved by the owner on 9 Nov 2026, including timing by strength. Design only; no code has
been changed. This replaces the "recovery" part (phase 7) of
`docs/EMAIL_PHONE_LOCK_PLAN_2026-11-09.md` and fixes the mistakes in
`docs/AUTH_EMAIL_PHONE_RECOVERY_REVIEW_2026-11-09.md`.

## What is wrong today, in one paragraph

The code goes only to the contact you type first. The other contact is shown as "last four
characters" and the server does not enforce that step: the replace-contact calls don't need it,
nothing records that it passed, and for emails the expected answer is `lcom` for every Gmail
address. After passing, you go back to log-in and need another code. For an email-only account
there is no path at all.

## Decisions made

| Topic | Decision |
|---|---|
| Way back in | A **recovery email**, added in Settings (not at sign-up), plus a support path |
| Reminders to add one | 1 hour, 1 day, 3 days and 7 days after sign-up, until added; also an entry in Settings |
| Proofs required together | Code to the recovery email, the **full** lost sign-in email, the **full** registered phone, and one fact from their own data |
| Data fact | Last four of a card they added; if no card, the month they signed up |
| If no recovery email | Follow the same flow without the recovery code; after all checks they type a **new sign-in email**, proven by a code |
| Getting back in | **Now, in full, other devices signed out now** |
| New or changed recovery email | **Active right away** (a notice goes to the sign-in email) |

## The flow

**Add a recovery email (Settings)**
1. The person types the address. A code to the **sign-in email** (fresh proof, so a stolen session
   alone cannot do this) and a code to the **recovery email** (proves they control it).
2. It is active at once. The sign-in email gets a notice. It must differ from the account's
   sign-in email and from any other account's sign-in email.

**Recover ("Can't sign in?" on the log-in screen)**
1. They type the lost sign-in email, the registered phone in full, and the data fact. The server
   checks all three together. The reply is the same whether or not they match: "If these details
   match, we have sent a code to your recovery email." Nothing is shown before proof, so a stranger
   typing someone's phone learns nothing.
2. **With a recovery email:** a code (valid 1 minute) goes to it; they type it.
   **Without one:** this step is skipped (see "Reading and one addition" below).
3. They type a **new sign-in email**. A code to that address proves it. With a recovery email they
   may choose "use my recovery email" instead.
4. On success: the new email becomes the sign-in email, every other session is ended (all refresh
   tokens revoked, token version bumped), this device gets a full session, and an audit entry is
   written.

## Timing by strength (approved)

You asked for "now, in full, others out now". That is fine when a code to the recovery email has
proved the person controls a contact. But the path **without** a recovery email rests on facts
only: the lost email, the phone (typed, never verified) and a card's last four. Someone who knows
those three, for example from a shared receipt, would take the account at once and sign the owner out.

So I propose timing by strength:
- **With a recovery email: immediate**, as you chose. The old sign-in email also gets a notice with
  an **undo link valid for 24 hours**. Undo freezes the account and sends the matter to support.
- **Without a recovery email: a 24-hour hold.** The old email and every signed-in device get a
  notice with a cancel button. At the end of the hold the person finishes, gets in, and other
  devices are signed out then.

Approved by the owner. "Immediate for both" was the alternative and was not chosen, because the
weaker path would then be the easiest way to take over an account.

## Rules for every recovery

- 3 attempts a day per account, and a limit per IP and device. Wrong answers never say which
  part was wrong.
- A recovery session expires after 10 minutes of inactivity.
- Every step emails the account's current sign-in email, and the recovery email if there is one.
- Every attempt, success, undo or cancel is written to the audit log, with device and IP.
- Anyone who cannot pass goes to support. Support checks the same facts plus anything else we
  agree, and can only act from the admin console with a reason that is logged.

## What gets built

- **Auth database:** recovery email fields (address, added-at); a recovery request record (state,
  path strong or weak, hold end, cancel and undo token hashes, device, IP).
- **Auth service:** new routes for adding a recovery email, starting recovery, verifying the code,
  setting the new email, finishing, cancelling and undoing. The old contact-check and
  replace-contact routes are removed.
- **API service:** one internal, secret-protected check that answers only yes or no to "does this
  account have a card ending these four digits". Auth cannot read the cards itself.
- **App:** a "Can't sign in?" flow replaces the "Find your account" screen (the last-four screen
  goes); Settings gets "Recovery email"; reminders at 1 hour, 1 day, 3 days and 7 days.
- **Emails and pushes:** recovery started, recovery email added or changed, sign-in email
  changed (with undo), hold finished.
- **Admin console:** a list of recovery requests and an action to freeze, release or complete one.

## Order of work and dependencies

1. The phone collection from the email-and-phone lock plan comes first, because recovery asks for
   the registered phone. Accounts created before that have no phone until they add one at next open.
2. Then the recovery email in Settings, because recovery needs it to exist.
3. Then the recovery flow itself, the notices, and the admin console actions.
4. The old recovery screen and routes are removed last, once the new flow is in the app.

## Settled, and defaults still open to change

1. Strength-based timing: approved.
2. With a recovery email, they may also pick "use my recovery email" as the new sign-in email.
   This is my default; the owner has not objected.
3. The 1 hour, 1 day, 3 day and 7 day reminders go as a push notification and an in-app card, with
   one email at day 7. Also my default, not objected to.
