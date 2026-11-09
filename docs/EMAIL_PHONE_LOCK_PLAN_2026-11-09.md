# Email and phone lock — plan for approval, 9 Nov 2026

Status: planning only. No code has been changed for this. Waiting for a go-ahead.

## Goal

Stop one person from making many accounts (thousands of email addresses) to collect trials and
rewards. Every account carries a phone number as well as an email, and one phone number can
back only one account.

## Decisions made

- Sign-in stays **email code only** (code valid 1 minute, already done).
- The phone number is **collected at sign-up and required, but not verified** (no SMS code, no call).
- **India (+91 mobile) now**; other countries later, so country rules are a list, not hard-coded.
- **Existing email-only accounts must add a phone** the next time they open the app.
- **Strict lock:** if the typed phone is already on another account, the sign-up is blocked, with
  a **support release** for the real owner.
- **First release includes all four extra layers:** email hygiene, reward only after real use,
  one account per device, admin cluster view.

## The honest limit

A number nobody proves is only something typed in. Anyone with 1,000 emails can type 1,000
different made-up Indian numbers. So the phone lock stops the lazy case (one real person reusing
their own number) and nothing more. The four extra layers are what make fake accounts cost
something. Also, because the number is unproven, anyone can type your number first and block you
from registering; the support release and the expiry rule below are the answer to that.

## Rules

1. A **complete account has both** an email and a phone. Until the phone is added the account can
   only finish that step. Existing accounts hit the same gate at next open.
2. One canonical form: `+91` and ten digits starting 6 to 9, then keyed-hashed. `98765 43210`,
   `+91-98765-43210` and `+919876543210` are the same number. (Today rate limits and the stored
   hash normalise differently.)
3. **One phone, one live account**, enforced by the database so two sign-ups cannot race. The
   error says only "this number can't be used" and points to signing in with the original email or
   contacting support. It never says which email holds it.
4. **A claimed number is never treated as proven.** It lives in its own fields (claimed phone,
   hash, claimed-at), so the existing "verified phone" checks, recovery and sign-in logic cannot
   mistake it for a verified one.
5. **Numbers are remembered after deletion** (hashes only; the privacy policy needs a line), so
   delete-and-sign-up-again does not reset a trial.
6. **A number held by an account that never became active** (no profile, no real use) is released
   after 14 days, so a squatter cannot hold it forever.
7. The user **cannot edit the phone**. Changes and releases go through support, which logs who
   did it and why.
8. **Log-in asks for the email only.** A typed phone proves nothing at log-in; the phone box lives
   on sign-up and the profile (masked).
9. **Rewards need the phone claim as well as the email claim.** Today the rewards check only ever
   sees the email.

## Phases, in order

| # | Phase | What it touches | Size |
|---|---|---|---|
| 1 | Data and rules | Auth database migration (claimed-phone fields, lifetime registry, unique index, "needs phone" state), one canonical phone function, switch `REQUIRE_PHONE_AT_SIGNUP` (off at first) | M |
| 2 | Server endpoints | `POST /users/me/phone` (claim, strict check, atomic bind, rate-limited per IP and device); product access and rewards activation refuse an account with no phone; rewards add the phone claim | M |
| 3 | Email hygiene | Gmail dots and `+tags` collapse to one mailbox for uniqueness and claims; disposable-email domain blocklist (a list we keep updated) | S |
| 4 | Device limit | Play Integrity and App Attest checks tied to the install key; cap accounts per device | L |
| 5 | Reward after real use | Release rewards only after real activity (parsed transactions on several days), on top of the existing consecutive-days rule | M |
| 6 | App | Sign-up becomes email code, phone, profile, resuming at the phone step; log-in is email only; masked phone on profile; remove the dead phone box and the recovery dead end | M |
| 7 | Recovery | Replaced by the design in `docs/RECOVERY_FLOW_DESIGN_2026-11-09.md` (recovery email, four proofs, timing by strength). Depends on phase 2 and 6, because it asks for the registered phone | L |
| 8 | Admin console | Release or change a number with a reason and an audit entry; list of accounts sharing a phone, device or IP | M |
| 9 | Tests, rollout | Server first with the switch off, then the new app build, then raise the minimum app version, then switch on; rollback is switching off | M |

Phases 1 to 3 and 8 can start together; 4 is the long one and can ship after the lock goes live
if it threatens the date, with the device check running in "log only" mode first.

## Existing accounts

They see "Add your phone number to continue" at next open. A number already claimed by someone else
shows the same blocked message and a support link. Before switching on, run a count of live
accounts so we know how many to expect.

## Risks

- **Support load** from blocked sign-ups: real people who changed numbers or share one. Needs a
  named owner and a reply time.
- **Number squatting** by typing someone's number. Covered only by the 14-day expiry and the
  support release.
- **Device checks** can wrongly block old or rooted phones. That is why phase 4 starts in log-only mode.
- **Privacy:** storing used phones after deletion must be disclosed and limited to keyed hashes.
- **Foreign numbers later** need a country rule list and, ideally, real verification, because
  typed foreign numbers are even easier to invent.

## Not part of this plan

SMS or call verification (you chose not to), and the other findings in the security review
(retire flags, rate limiting at the edge, signing keys). They are separate work.
