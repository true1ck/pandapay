# Learning loop: data flows and processing record

Status: **draft for lawyer review**, written 2026-11-06 from the code on branch `claude/learning-loop-c19dfa`. It records what the shared-learning opt-in collects, why, where it is stored, who can see it, how long it is kept, who processes it and how it is deleted. It is meant to serve as the DPDP processing record and as the basis for the lawyer review listed in `store-and-legal-checklist.md`. Every statement below is backed by code or a test named in the last section. If the code changes, change this file in the same change.

## 1. The one opt-in

There is one optional setting, **"Help PandaPay get better for everyone"** (consent purpose `sms_shared_learning`, policy version `sms-shared-learning-v3`). It is off until the person turns it on, and nothing in this record is collected without it. A consent given under an older policy version (`v1`, `v2`) is not accepted: the server asks for the v3 opt-in again.

Shipped wording (`TemplateSharingCopy` in `app/lib/features/consent/template_sharing_disclosure.dart`):

> **Help PandaPay get better for everyone**
> If you turn this on, PandaPay shares:
> - the layout of bank messages it can't read, with every amount, name, number and date removed
> - the shop names it couldn't put in a category, and the categories and shop names you pick for shops
>
> It never shares your messages, amounts, account numbers or the people you pay. Google Gemini may process message layouts and shop names to suggest new rules. Nothing is shared unless you turn this on. If you turn it off, what you shared is deleted. Rules already added for everyone stay, and they contain nothing about you.

Where it is offered: Settings > Privacy & Permissions, the sharing line on the fix screen of a message, and a card in Review that can be dismissed ("Not now" hides it for 30 days and it stops after the third dismissal). Where it is described: privacy policy and terms, section 5 ("Optional: sharing message layouts, shop categories and shop names").

Legal purpose: consent (DPDP Act, section 6), for the purpose of improving automatic reading and categorising of transaction messages for all users. The consent is specific, optional, not a condition of using the app, recorded with a timestamp and the screen it was given on (`user_consents`), and withdrawable at any time with the same ease as it was given.

## 2. What is collected

| Flow | What leaves the phone | Filters on the phone | Table (server) | Who can see it |
|---|---|---|---|---|
| **Message layouts** | The layout of a bank message the rules could not read: the text with every amount, date, number, name, link, email and phone number replaced by a placeholder, the sender brand (for example `HDFCBK`), and a hash of the layout | Redaction happens on the phone; the server refuses anything that still looks like a number of 6 or more digits, an email, a link, a web address or a phone number | `sms_v2_unknown_templates`, `sms_v2_template_submitters` | Admins with `learning.read`: the redacted layout and how many people sent it. Never who. |
| **Extraction fixes** | When the person corrects what a message was read as (wrong amount, wrong kind of message), the case carries the same redacted layout and sender brand, and what the person says is right | Same redaction. Only with the opt-in; without it the case holds no layout | `sms_v2_correction_cases` | Admins with `learning.read`, in the corrections queue |
| **Category choices** | The shop key (the normalised shop name, for example `SWIGGY`), the sender brand, and the category the person picked from the fixed list | Only for purchases at shops: people, the person's own accounts and non-purchases are dropped. Keys with 4 or more digits in a row (QR and terminal numbers), `@`, more than 60 characters or characters outside letters, digits, space and `& ' . -` are dropped. Custom categories and personal preferences are never shared | `sms_v2_learning_signals` (`kind = category_choice`) | Admins: counts per shop and category, only when at least K distinct people have reported the shop (see section 4) |
| **Shop names** | The shop key and the name the person gave it (for example `PAYU SWIGGY` renamed `SWIGGY`) | Same key filters; the name must be a plain upper-case name and different from the key | `sms_v2_learning_signals` (`kind = merchant_name`) | Same as category choices |
| **Shops left in "Other"** | The shop key and the sender brand of a shop the rules could not put in a category | Same key filters. Sent once per shop key and account; the phone forgets what it sent when sharing is switched off | `sms_v2_learning_signals` (`kind = uncategorised`) | Same as category choices |

What is **never** sent: the text of any message, amounts, dates, account or card numbers, balances, one-time passwords, the people the person pays, contacts, locations, or any custom category name. The phone parses messages locally; this record is about the small derived items above.

Each signal row is identified by the pseudonymous account id (`profile_id`, a random UUID) so that one person counts once per shop and value. Nothing else about the person is stored with it.

## 3. Who processes it

| Processor | Receives | Purpose | Terms |
|---|---|---|---|
| **Google Gemini** (Google LLC), on a paid API key | For a layout: the redacted layout, the sender brand, the shape of a few existing rules for that sender, counts of distinct people by kind of report, and up to three earlier layouts of the same sender that an admin rejected, with the reason code. For a shop: the shop key and up to five sender brands | Drafting a rule for a layout the rules cannot read, and suggesting a category for a shop left in "Other" | Paid-tier terms with data-processing terms; **owner to confirm in writing before launch that prompts are not used to train models and where they are processed** (open point 1) |
| Hosting provider | The database | Storage | See privacy policy section 6 |

Nothing that identifies a person is placed in a prompt: no account id, no count smaller than the K threshold is revealed to the model beyond "number of distinct people", no message, no amount. The prompt tells the model that the layout and the shop name are untrusted data, not instructions; hostile text is refused or quoted as a plain value before it reaches a prompt (`api/test/sms_v2_learning_prompt_injection.test.js`).

The model's answer is never applied by itself. It is stored as a draft (`sms_v2_unknown_templates.ai_draft`, `sms_v2_merchant_suggestions`), checked by the rule validator, and shown only to the phones that sent that layout as a private rule on that phone, or to an admin as a suggestion. It reaches everyone only after an admin approves it, the golden check passes, and it is published to four cohorts in turn (testers, 5%, 25%, everyone).

Spend is capped: monthly budget, requests and tokens per minute are console settings under environment ceilings. The model name and prompt version are recorded for every attempt (`sms_v2_template_attempts`: counters, cost and outcome only, no text).

## 4. Who can see what

- **Phones** see only their own rows and the rules everyone receives. Direct database access as an app user returns nothing from any learning table, even for the person's own rows (`api/test/sms_v2/learning_security_pg.test.js`).
- **Admins** (roles `owner`, `operator`; role `reviewer` and `readonly` have no learning access) see the console's Learning pages through a private API on a separate listener. Reading needs `learning.read`; every change needs `learning.publish`, a fresh sign-in and a written reason.
- **K-anonymity.** A shop appears in the Learning pages only when at least K distinct, attested people have reported it (setting `signals_min_distinct_users`, editable in the console from 1 to 20; the default is 1 during the friends run, where every tester has opted in, and it should be raised before a public launch so that one person cannot decide); the page then shows how they split between categories, so disagreement is visible. One account sending the same signal 100 times counts once. Phones that did not pass App Check are stored but never counted. The console shows counts and the split between categories, not people.
- **Accounts list.** The console's "Reporters" section lists the pseudonymous account ids that sent the most in the last 7 days (up to 90 can be chosen), with counts only, so an admin can find a flood and set a per-account limit. It shows no message, layout text or name.
- **Audit.** Every setting change, per-account limit, decision, draft, publish, rejection, requeue and block is written to `admin_audit_log` with the admin, the reason and the before and after values. Refused calls are not audited because they change nothing.

## 5. Retention

| Data | Kept for | Mechanism |
|---|---|---|
| Learning signals (categories, names, shops in Other) | `signals_retention_days`, default **180 days** (30 to 730) after the last time the person sent it | Hourly job `runRuleJobs` deletes older rows |
| Layouts and who sent them | While at least one person who still has the opt-in on has sent the layout; deleted with the last such person | Trigger `sms_v2_template_submitter_deleted` |
| Extraction fixes | With the account. The layout, corrected values and AI output in a case are erased when the person withdraws | Trigger `sms_v2_correction_consent_withdrawal` |
| AI attempt counters | Kept for cost and quality review; contain no text and no account id | Admin tables |
| Published rules, category rules and shop-name rules | Until an admin replaces or rolls them back. They hold a pattern or a shop key and a category, and nothing about any person | Admin publish |
| Admin decisions on candidates | Kept as the record of why a rule exists or was dismissed; they hold the shop key, the number of people at the time and the reason | `sms_v2_learning_decisions` |
| Audit log | Per the admin audit retention. An entry for a per-account limit holds the account id (a random UUID) and the limit | `admin_audit_log` |

## 6. Deletion

- **Turning sharing off** (consent withdrawal, a new `granted = false` record, the latest record wins): the person's learning signals are deleted at once (`sms_v2_revoke_signals`), their layout submissions are removed and layouts with no remaining sender are deleted (`sms_v2_revoke_template_consent`), and contributed evidence in their fixes is erased (`sms_v2_correction_consent_withdrawal`). Counts in the console drop at the same moment. The server refuses new signals and layouts until the person opts in again.
- **Deleting the account**: every learning table that holds an account id references the profile with `ON DELETE CASCADE` (`sms_v2_learning_signals`, `sms_v2_user_limits`, `sms_v2_template_submitters`, `sms_v2_correction_cases`, `sms_v2_testers`). The other tables of the loop (`sms_v2_settings`, `sms_v2_learning_decisions`, `sms_v2_alias_drafts`, `sms_v2_category_drafts`, `sms_v2_merchant_suggestions`) hold no account id. The tests check each table by name and search every row for the deleted account id.
- **What stays**: rules already published for everyone, shop-name and category rules, admin decisions, and audit entries. None of them identifies the person; a rule built from several people's agreement cannot be traced to any of them. The privacy policy says so in plain words.
- **Backups**: encrypted server backups expire within the period stated in privacy policy section 8.

## 7. Safeguards against abuse and error

Phone filters (section 2), the K threshold, attestation, one row per account, shop and value, daily caps per account (`signals_per_user_per_day`, `templates_per_user_per_day`, with per-account overrides that expire within 90 days), the kill switch `intake_enabled` (refuses all intake with 503), the AI switch and budget, admin approval for every rule, the golden check, cohort rollout, and automatic pause of a staged rule when enough distinct attested phones correct it more than the threshold. One phone, or phones that did not pass App Check, cannot pause a rule.

## 8. Open points for the lawyer

1. **Gemini terms.** Confirm the paid-tier data-processing terms, that prompts are not used for training, and the processing location; decide whether the cross-border transfer needs wording beyond section 5 of the policy.
2. **Is a shop key personal data?** It is a merchant name chosen from a bank message and counted only with others. It is stored with an account id until the retention period. We treat it as personal data for deletion and retention.
3. **Retention periods.** 180 days for signals is a default the owner can change; confirm what to publish.
4. **Audit entries after account deletion.** Entries for a per-account limit keep the account id. Decide whether to publish this or to scrub those entries on deletion.
5. **Reporters list.** Admins see pseudonymous account ids with counts. Confirm this is covered by the policy's description of admin access.
6. **Children.** The app is 18 and over; the opt-in has no separate age check.
7. **Grievance and withdrawal path.** Confirm the in-app switch is accepted as the withdrawal mechanism, with the grievance officer as the fallback.

## 9. Where each statement is enforced

| Statement | Code | Test |
|---|---|---|
| One v3 opt-in covers every flow; older versions refused | `db/supabase/migrations/20261116000000_sms_shared_learning_v3.sql` | `api/test/sms_v2/learning_consent_pg.test.js` |
| Phone filters, queueing only with the opt-in, outbox emptied on withdrawal | `app/lib/features/sms_v2/sync/learning_signals.dart` | `app/test/features/sms_v2/learning_signals_test.dart`, `learning_loop_phone_test.dart` |
| Server key and value filters; one row per account, shop and value | `api/src/sms_v2/learning_signals.js`, `20261116010000_sms_v2_learning_signals.sql` | `api/test/sms_v2_learning_signals.test.js`, `learning_signals_pg.test.js` |
| K, attestation, repeats, rule auto-pause | `api/src/sms_v2/rule_stats.js`, `learning_admin_route.js` | `api/test/sms_v2/learning_security_pg.test.js` |
| Private tables closed to app users; roles; fresh sign-in; audit | `20261116*.sql` policies, `api/src/admin/route_manifest.js` | `learning_security_pg.test.js`, `api/test/sms_v2_admin_coverage.test.js` |
| Withdrawal and account deletion | triggers named in section 6 | `learning_security_pg.test.js`, `learning_loop_e2e_pg.test.js` |
| Prompts treat layouts and shop names as data; nothing the AI returns is published | `api/src/sms_v2/template_worker.js`, `merchant_suggestions.js` | `api/test/sms_v2_learning_prompt_injection.test.js` |
| Retention | `api/src/sms_v2/rules_store.js` (`pruneSignals`) | `api/test/sms_v2/learning_signals_pg.test.js` |

## Friends run: seeing a tester whose phone cannot pass App Check (7 Nov 2026)

A free Apple developer account cannot produce an App Check token, so every layout, signal and case from such a phone is
stored as not eligible and never reaches the Learning page. The console setting `testers_count_without_attestation`
(Settings tab, default **off**) changes that for profiles listed in `sms_v2_testers` only:

- On: those profiles count as eligible like an attested phone. Rate limits still treat the phone as unverified.
- Off, or the profile is not in `sms_v2_testers`: nothing changes.
- The list is a table (`sms_v2_testers`), edited by the owner; there is no console screen for it yet.

The admin Corrections list also shows, for each layout, how many **different people** reported it, the mix of what was
wrong (category, shop name, payment method, type, amount, date, missed SMS), and the totals of shared against
private cases. Patterns many people hit come first. Account ids are never part of that answer.


## Rolling AI drafts out to every member (10 Nov 2026)

`testers_count_without_attestation` needs an account in a table. To roll the AI drafts out to **everyone who has
registered and agreed to share**, use the console setting `members_count_without_attestation` (Settings tab, default
**off**; migration `20261120030000`). On: every member counts as eligible like an attested phone, with no list of
accounts, so a sideloaded or Staging build, or a phone whose attestation failed, still gets its layouts queued and
its results back. Off: only attested phones and listed testers count, as before.

- Consent still decides: a member who did not agree to share is refused either way.
- The per-person daily cap (`templates_per_user_per_day`) and the monthly AI budget (`ai_monthly_budget_usd`) still
  apply, so the cost is bounded.
- The server remembers each account's answer for a minute, so the switch takes effect within a minute.
- It also lets unattested members count toward the Learning page and shared cases. Turn it off before a public
  launch so only attested phones count (and raise `signals_min_distinct_users`).
- Layouts an uncounted phone sent earlier are stored `held` and never resent. When the phone sees "counted now, N
  held" (`GET /sms/v2/ai-status`), it forgets what it sent and sends them again, at most once every 6 hours
  (`app/lib/features/sms_v2/sync/template_resend.dart`). Nothing is edited by hand per account.
