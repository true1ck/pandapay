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
| Referral reward only after real use (added 10 Nov 2026) | product DB migration `20261117030000_referral_real_use_gate.sql`, section below | `campaign_versions.real_use_required_days = 0` (off) |

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

## One phone, many accounts: the phone id (added 11 Nov 2026)

Why: to stop one person opening account after account on the same phone for a free trial.
The old `device_id` was a random code made per install, so deleting the app gave a new
one. From app 1.0.18 build 154 the sign-in `device_id` is the phone's own id
(`accountDeviceId` in `app/lib/data/device_identity.dart`). The per-install id is kept
unchanged for the local database key and the SMS runtime; do not merge the two.

| Platform | The id | Survives reinstall | Changes when |
|---|---|---|---|
| iPhone | `k2-` + a random UUID in the Keychain, service `app.pandapay.device-identity` (not the service InstallGuard wipes), `first_unlock_this_device` | yes | the phone is erased; also once if the signing team changes |
| Android | `a2-` + first 32 hex of sha256("pandapay-device-v1:" + ANDROID_ID); the raw value never leaves the phone | yes (same signing key) | factory reset; a different signing key (sideloaded build vs Play build); a second user profile or Secure Folder |

Server side (`auth/src/services/deviceAccountLimit.js`), all behind the existing switches:
`DEVICE_ACCOUNT_LIMIT` (accounts per phone), `DEVICE_ACCOUNT_LIMIT_ENFORCE` (refuse, not just
log), `DEVICE_ACCOUNT_LIMIT_COUNT_DELETED` (default true: deleted accounts still count, so
delete-and-recreate gives no fresh start), `DEVICE_REQUIRE_STRONG_ID` (with enforcement on,
a new account from a build without the phone id is refused with `DEVICE_ID_UPDATE_REQUIRED`).

Order: ship the build; raise `min_supported_version` to it; watch `account_clusters.js flags`
for a week (counts only `k2-`/`a2-` ids as trustworthy); then `DEVICE_REQUIRE_STRONG_ID=true`
and `DEVICE_ACCOUNT_LIMIT_ENFORCE=true`. Never enforce before the minimum version is raised: an
old build sends a per-install id and could simply be reinstalled. Sign-in to an existing account
is never blocked; only creating a new one. Test phones and emulators hold many accounts: raise
the limit while testing. A Google sign-up only records, it is not refused.

Limits, honestly: both ids come from the app, so a rooted phone or a rewritten app can send any
value, and a factory reset or a second Android profile starts over. Play Integrity (Android) and
App Attest (iOS, needs the paid Apple Developer Program) would bind it to the hardware; they are
not built.

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

## Referral reward only after real use (built 10 Nov 2026, OFF by default)

Today a referee qualifies for the referral reward by opening the app on 3 consecutive days
(`promotions.record_engagement_day`, and the home screen counts). This adds a second
condition that is **off until you set it**, so nothing about who qualifies changes when the
migration is deployed. Row 5 of `EMAIL_PHONE_LOCK_PLAN_2026-11-09.md`.

**The setting:** `promotions.campaign_versions.real_use_required_days`. `0` is off (the
default, and the value every existing campaign version has). `1` to `30` means the referee
must also have that many distinct days with real use. You chose 3 on 10 Nov 2026.

**What counts as one real-use day** (your choices on 10 Nov 2026: parsed SMS or email only,
3 days, and allowed on the live campaign too):

- a spend entry that came from an **SMS or email import** (`source` `sms` or `email`);
  typed-in entries, statement uploads, CSV imports and old bulk imports do **not** count;
- not a **history scan** (the phone flags the one-off inbox scan on install as backfill);
- still **active** (an entry the person ignores or deletes stops counting) and of kind
  **spend** (not income or transfers);
- the day is **when the server received it**, in India time, not the date on the message,
  because the phone chooses the message date;
- only days from the referee's join date up to their deadline, any days, not necessarily in
  a row. Two entries on one day are one day.

Qualification is checked each time the app checks in (every home-screen open) until it is
recorded. Once recorded it is final: ignoring entries later does not undo it.

### Switching it on

Nothing here is run for you. Do it in a database session as the admin (it bypasses row
security, which the counting query below needs), and never paste referee ids into chat.

1. **Deploy the migration first** (the normal `deploy.sh`, `db-migrate` step). It changes
   nothing while the setting is 0. It adds the column, one counting function in the
   `pandapay` schema, and a replacement `record_engagement_day`. No `api` change and no new
   app build are needed.
2. **See who it would hold.** Read-only. Change the `3` if you pick another number.

   ```sql
   select r.days as real_use_days, count(*) as referees_with_streak_done
     from promotions.referral_attributions a
     join promotions.campaign_versions v on v.version_key = a.campaign_version
     cross join lateral (
       select count(distinct (t.created_at at time zone v.calendar_zone)::date) as days
         from public.transactions t
        where t.profile_id = a.referee_id and t.status = 'active' and t.entry_kind = 'spend'
          and t.source in ('sms', 'email') and t.is_backfill = false
          and t.created_at >= a.joined_at and t.created_at < a.deadline_at
     ) r
    where a.campaign_version = (select active_campaign_version from promotions.access_settings where singleton)
      and a.reward_eligible and a.qualified_at is null and a.disqualified_at is null
      and a.deadline_at > now() and a.best_streak_days >= v.required_consecutive_days
    group by 1 order by 1;
   ```

   Rows with `real_use_days` of 3 or more would qualify at their next app open; rows below 3
   are the people the switch would hold.
3. **Switch on.** Pick the campaign version, then:

   ```sql
   select version_key, real_use_required_days from promotions.campaign_versions;
   update promotions.campaign_versions set real_use_required_days = 3
    where version_key = '<the version key>';
   ```

   Two ways to use it. **On a new campaign version**: people who already joined keep the
   rule they joined under; only people who join under the new version are held to it. **On
   the live version** (what you allowed): every referee in that version who has not yet
   qualified is held to it from their next check-in, including people who are partway
   through and joined under the old terms. The campaign terms text may need to say so.
4. **Switch off** (also the rollback): `update ... set real_use_required_days = 0`. It keeps
   no state, so anyone held back qualifies at their next app open.

### What to watch

- Re-run the query in step 2 daily for the first week. If most people with the streak done
  sit at 0 or 1 days and their deadlines are close, parsed data is not reaching the server
  for them (SMS permission off, no iPhone Shortcut, no email import). Switch off and look.
- Qualifications per day, before and after the switch:

  ```sql
  select (qualified_at at time zone 'Asia/Kolkata')::date as day, count(*)
    from promotions.referral_attributions where qualified_at is not null
   group by 1 order by 1 desc limit 14;
  ```
- A held referee's check-in answer carries `realUseRequiredDays`, `realUseDays` and
  `realUseMet` (only while the setting is above 0).

### Limits (read before relying on it)

- **It is a speed bump, not a wall, and I did not try to forge it.** The server cannot tell
  a real SMS from an uploaded one: a script with a valid session could post correctly
  shaped parsed events on three separate days (no history flag) and pass. The gate moves
  the cost from "open the app three days" to that. How much it moves depends on SMS v2
  attestation: the code default is `SMS_V2_ATTESTATION_MODE=monitor`, which accepts uploads
  without a device check. I did not look at what production runs. `enforce` makes an
  upload need a genuine App Check token, which is the real protection here.
- **iPhone referees only produce parsed entries through the iOS Shortcut or an email
  import.** With typed-in entries not counting (your choice), an iPhone referee who has set
  up neither is held until they do. The app shows nothing about this today: it only calls
  check-in and does not read the progress fields, so a held referee sees no explanation.
  Showing one is a small app change and a new build; it is not needed to switch the gate on.
- **Several days of offline phone then one upload counts as one day**, because the day is
  when the server received it.
- **A referee is only re-checked when they open the app** before their deadline. The 3-day
  streak needs that anyway.
- **Production and the hosted database were not touched.** The migration and test ran on a
  throwaway PostgreSQL 18 here; the test file is for disposable databases only.

## What this does not do (read before relying on it)

- **The phone is typed, not verified.** The lock stops lazy reuse of one number. A person
  with many SIMs still gets many accounts. The email, device and address checks are what
  make that costly, and they are speed bumps, not walls.
- **Device limit uses the install id.** A reinstall makes a new one. Real binding to the
  hardware needs Play Integrity and App Attest, which need credentials from the owner.
- **Reward after real use is built but OFF** (10 Nov 2026, see the section below). Until
  you switch it on, merely opening the home screen on three days in a row still qualifies a
  referee. Once on, it is a speed bump, not a wall: see "Limits" in that section.
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
