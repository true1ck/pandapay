# Account lock and recovery: what was built, how to roll it out

Written 9 Nov 2026. Everything below is committed on `dev` and **not pushed, not deployed,
not built into an app**. Nothing has touched production. Plans and designs this follows:
`EMAIL_PHONE_LOCK_PLAN_2026-11-09.md`, `RECOVERY_FLOW_DESIGN_2026-11-09.md`,
`AUTH_SECURITY_REVIEW_2026-11-09.md`.

## What is in the code

| Piece | Where | Switch / default |
|---|---|---|
| Guest login removed, sign-in codes last 60 s | `auth/`, `api/`, `console/`, app | always on |
| Phone typed at sign-up, locked to one live account, never verified | `auth/` migration 0015, `phoneClaim`, app Add phone step | `REQUIRE_PHONE_AT_SIGNUP=false` |
| One mailbox, one account (Gmail dots and `+tags` collapse), throwaway-mail domains refused | migration 0016, `emailIdentity.js` | always on |
| Recovery email (add, change, remove) with two codes; reminders 1h, 1d, 3d, 7d | migration 0017, app Settings | day-7 email `RECOVERY_REMINDER_EMAILS_ENABLED=false` |
| "Can't sign in?" recovery (4 proofs, 24 h undo or 24 h hold) | migration 0018, `/auth/recovery/*`, app screen | always on once deployed |
| Card question for recovery | `api` `POST /internal/recovery/card-fact` | uses `AUTH_INTERNAL_SERVICE_SECRET` |
| One phone, many accounts | `deviceAccountLimit.js` | `DEVICE_ACCOUNT_LIMIT=3`, `DEVICE_ACCOUNT_LIMIT_ENFORCE=false` (log-only) |
| Support tools | `auth/scripts/recovery_support.js`, `auth/scripts/account_clusters.js` | need `AUTH_SUPPORT_DATABASE_URL` |

## Order of rollout

1. **Before the deploy, check mailbox duplicates.** Migration 0016 refuses to apply (count
   only, nothing changes) if two live accounts already share one mailbox, for example
   `a.b@gmail.com` and `ab@gmail.com`. If the deploy stops there, those accounts have to be
   merged or closed by hand first. Find them by pasting the `auth_canonical_email` function
   from the top of 0016 into a transaction you roll back, then grouping live users by it.
2. **Set two values in the server `.env`:** `AUTH_PUBLIC_BASE_URL` (the public https address
   of auth, no trailing slash, used for the "stop this" links in recovery emails) and
   leave `PRODUCT_API_INTERNAL_URL` as the compose files set it (`http://api:4000`).
3. **Deploy server with `deploy.sh` as usual.** `api` and `auth` must go out together: if
   `auth` is new and `api` is old, recovery cannot ask the card question and every recovery
   fails closed (safe, but nobody can recover). Migrations 0015 to 0018 apply in the
   `db-migrate` step. With the flags above at their defaults, today's app builds keep
   working unchanged.
4. **Build and release the app** (this is a new build: new recovery screen, phone step,
   recovery email screen, Settings card). Test on the iPhone first, see the list below.
5. **When the new build is the minimum supported version**, set
   `REQUIRE_PHONE_AT_SIGNUP=true`. Existing accounts are then asked for a phone at next
   open. Turning it on earlier locks old builds out of the product.
6. **After the app is out**, set `RECOVERY_REMINDER_EMAILS_ENABLED=true`. Every account older
   than 7 days with no recovery email becomes due at once (it sends 25 at a time).
7. **Watch the device flags for a week**: `node auth/scripts/account_clusters.js flags`.
   Only if the numbers look right, set `DEVICE_ACCOUNT_LIMIT_ENFORCE=true`. A refused
   sign-up returns 403 `DEVICE_ACCOUNT_LIMIT`; the app has no special wording for it yet,
   so it shows a generic sign-in failure.

## Check on the iPhone before releasing

- Sign up with a new email: phone box shown, number saved, next open does not ask again.
- Settings, Email & phone: add a recovery email (two codes), then remove and add again.
- Sign out, "Need help signing in?", then each path: with a recovery email (code, new email
  code, signed in, other device signed out); with "I don't have a recovery email" (24 h
  notice, come back, finish); a wrong code; a wrong phone (the message must not say which
  part was wrong).
- While a recovery is waiting, Settings on another signed-in device shows the red card and
  its button cancels it; the email link to the old address shows a button, and pressing it
  cancels.

## Support, in short

```
node auth/scripts/recovery_support.js list --state pending_hold
node auth/scripts/recovery_support.js show --email someone@gmail.com
node auth/scripts/recovery_support.js cancel --attempt-id <uuid> --actor <name> --reason "<8+ chars>"
node auth/scripts/recovery_support.js restore --user-id <uuid> --actor <name> --reason "..."   # lifts a freeze
node auth/scripts/recovery_support.js release-phone --user-id <uuid> --actor <name> --reason "..."
node auth/scripts/account_clusters.js devices | ips | flags
```

Each change needs a named actor and a written reason, and writes an `auth_audit` row.
`restore` only works on an account a recovery freeze closed. Output shows masked emails
and never a phone, token or code.

## What this does not do (read before relying on it)

- **The phone is typed, not verified.** The lock stops lazy reuse of one number. A person
  with many SIMs still gets many accounts. The email, device and address checks are what
  make that costly, and they are speed bumps, not walls.
- **Device limit uses the install id.** A reinstall makes a new one. Real binding to the
  hardware needs Play Integrity and App Attest, which need credentials from the owner.
- **Reward after real use is NOT built.** Qualification lives in the production SQL
  function `promotions.record_engagement_day`, where merely opening the home screen counts
  as a day (`home_summary`). Tightening that changes who gets rewards, and I could not run
  it against the promotions schema here, so I left it alone. It needs the owner's decision
  and a tested migration.
- **The 14-day expiry of an unused phone claim is not built.** It needs an "activated"
  signal from the product database.
- **Reminders are local notifications that fire when the app is opened or comes to the
  front**, not scheduled in the background. The day-7 email covers people who never open it.
- **A no-recovery-email account is the weak path.** The proofs are the lost email, the
  phone typed in full, and either a card's last four or the sign-up month (about 36
  possible answers). What protects it is the 24-hour wait, the email to the old address with
  a cancel link, and 3 starts per day per mailbox. Someone who knows the email, the number
  and roughly when the person signed up can start one; only the real owner noticing stops
  it. Adding a recovery email is the fix, which is why the reminders exist.
- **Old app builds** keep working against the server (their recovery routes are still
  there). The new build removes the old "last four digits" screen.
- **The stop link carries its token in the URL**, so it appears in proxy access logs for
  24 hours of usefulness. It can only cancel or freeze, never grant access.
