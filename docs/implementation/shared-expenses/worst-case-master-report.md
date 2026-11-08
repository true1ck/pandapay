# Split / shared expenses: worst-case master report

Consolidates six executed review passes on branch `split-labels` (nothing pushed). Every PASS below came from an executed assertion; every BUG has a `todo` (known-bug) test or a repro in the linked report. Passing tests stay as regression tests.

Detail reports (same folder): `worst-case-money-report.md`, `worst-case-concurrency-report.md`, `worst-case-security-report.md`, `worst-case-identity-report.md`, `worst-case-scale-report.md`. Design reviews (people directory, online-write, lifecycle catalog) were read-only analyses and are summarised in the plan section.

## What was verified and held
- Ledger arithmetic: 1,060-operation randomized run + extra seeds; every step checked (member/pair balances = recomputation from the journal, no unapproved journal lines); rounding for 1/100/101/9999 paise among 3/7/33/50 people for all split kinds; caps (50 sharers, 8 payers, amounts); 2,000 expenses in one split.
- Idempotency: replays of every command kind (parallel + late) give one effect; changed body => conflict; replays after the world changed do not resurrect anything.
- Caps under races: 20 pending, 200 members, 5 reveals/h, 3 check-phone attempts, 25 lookups/day.
- Mixed random workloads (16-20 workers, thousands of ops): no 500s, no unabsorbed deadlocks, all invariants hold.
- Authorization: every read route vs cross-tenant owner/member/stranger/unauthenticated/expired/forged/wrong-audience tokens: uniform 401/403/404, no existence oracle. Hostile input (injection, huge, NUL, unicode, mass assignment, `__proto__`): only one S3 defect (NUL byte -> 500).
- Number reveal, key tamper, token guessing, link reuse, ex-owner access: all refused. Registered-number lookup is not an oracle between discoverable/non-discoverable/unregistered, scrape-capped (~22).
- Identity: number formats, two same-name people, person registering after several owners saved them (labels, balances, reviewable proposals), number change, owner deletion with take-over.
- Scale: 2,000 contexts list p95 46 ms, search 88 ms, overview 32 ms; 200-member commands 6-12 ms; accept path with 19,900 pairs 13 ms.

## Defects, by priority

### P0: wrong or stuck money, privacy, data loss
| ID | Defect | Source |
|---|---|---|
| W13/A13 | Recycled/moved number: new holder sees the old holder's pending invite, joins in one tap with no owner approval, sees pending proposals | identity, security |
| B15/B16 | Feed and activity pages order by a TEXT alias: "10" sorts before "2"; events are skipped forever (feed at limit 30: 2 of 60 lost; activity walk delivers 35 of 43) | concurrency, scale |
| B4 | `leave_context` checks only net balance; a member with net 0 but pair debts leaves and those debts can never be settled | money |
| B5/B6 | Payer leaves with a pending settlement report; creditor deletes account: debtors cannot settle or leave; no write-off | money |
| E7 | Erase leaves: settlement bank/UPI refs, source private snapshot (merchant, phone digits, bank text), private cost facts, the person's typed label, open phone-bound invites they issued (claimed after erase, auto-join into an ownerless group), their group link | security |
| B10(dec) | Invitee `decline_invitation` always returns 500 (5 binds, SQL uses 4); the 7-day pause never starts | concurrency, identity |
| B01/B02/B03/B05 | Ownership/leave checks run before the context lock: ex-owner's second transfer/invite succeeds; promoted member can leave leaving 0 owners; a member whose leave committed can still add an expense | concurrency |
| B2/B3/B10(money)/B12 | Stuck proposals: a rejected proposal blocks leaving forever; void/edit after a participant left can never be approved; a name-only person who never joins wedges the split; a pending edit stuck after a member leaves | money, concurrency |
| B18/B19 | Split "full" wedge (declined/left rows count toward 200 for expenses only); expense push: 0 of 20 required reviewers notified, 50 bystanders pinged | scale |

### P1: dead ends and confusing behaviour
| ID | Defect |
|---|---|
| W18/W14/W24 | Left member can never rejoin; deleted-then-reborn person cannot be re-added; placeholder holding an expense cannot be merged/removed (stranded rows/balances) |
| W11/A11 | A friend renaming themselves in my direct split overwrites my label and can create duplicate titles (friend_name_taken bypass) |
| W23/W27/W29 | Invitee inbox shows the owner's private label for the invitee (can be a nickname) and it goes stale; no inviter name unless inviter touched the directory |
| W01 | Same person added many times (4 ways), no duplicate hint; person sees several splits with the same title |
| B22, 20-cap | `list_invitations` pages by a different key than it orders (67 of 130 shown, 6 repeated); join-request list and invitee inbox cut at 20 with no `hasMore` (summary row shows "20" when there are more) |
| B17/B23/Z02/Z03 | Activity page O(revisions) (2.2 s at 15k events), first feed page 1.2 s at 5000 expenses, new-device initial sync 62 s at 1000 expenses (about 45 min projected at 5000), catching up 100k events = 10,000 pages, personal activity search 4.9 s |
| B26 | No per-user/day cap on creating splits, no rate limit or consent on `invite_member`; 10,000 groups in 20 s, 2,000 invites to one victim in 2.6 s; victim cannot block |
| B7/B8/B9 | Any member can file a settlement "X paid Y"; null currency slips validators; settlement reports never expire/cancel; impossible dates give raw DB error; year 0001/9999 accepted |
| NUL | `displayName` with a NUL byte returns 500 instead of 400 |
| UI | "Still loading the latest" banner stays minutes on a busy account (feed pulls 2 pages per 45 s); header (join row, invite card, balance, banner, create) takes about 2/3 of the first screen on every tab |

### P2/P3: hygiene, performance, rules
- Label rules misfire on real life: reserved prefixes block `Owner (flat 4)`, `Admin office`, `Support Raj`, `Unknown number`; key strips spaces/punctuation/diacritics so `Ram Kumar`/`Ramkumar`, `Anu Raj`/`Anuraj`, `Amit.`/`Amit`, `MOM`/`Mom`, `José`/`Jose`, `Dr. Mehta`/`Dr Mehta`, `Jean-Luc`/`Jean Luc`, `O'Brien`/`OBrien` merge; 40-char silent mid-word cut; ZWJ/ZWNJ stripped (Persian/Devanagari/Tamil text changes) (G3/G4/B27/W21).
- Races/locks: 10/h claim cap and 50/h invite cap not locked (B06/B07); revoke link vs in-flight claim (B11); lost-reply retry of leave/transfer gets 403 (B09); parallel leaves emit 3 events (B04); reveal reads request before lock (B08); claim hashes current flag (B14), reordered JSON keys give conflict (B13); lock cycles L03 (claim lazy purge vs respond) and L04 (phone swap) end as retryable 409.
- Performance hygiene: `readBalances` keyset (1.5 ms vs 34 ms), RLS definer per row (B24: 5,862 calls for a 50-row list), `_friend_context` O(n) (166 ms at 3000 splits) + no `contexts(created_by)` index (B21), 10,000-context search 440 ms, operation_receipts no TTL (653 B/command), phone purge 1,000 rows/hour backlog, profile_events 136 KB per accepted expense in a 200-member split.
- Data: member `profileId` visible to every member (S3); duplicate verified phones allowed in local auth (check production); email-only claimants unverifiable.

## Plan (order)
0. Decisions + spec; one shared phone normalizer with vectors.
1. Correct local rules (key keeps spaces, exact reserved words, warn on truncation, allow ZWJ/ZWNJ).
2. P0 hotfix track on its own (do not wait for the people model): feed/activity ordering, decline 500, lock ordering (ownership/leave/expense), leave check on pair balances, withdraw proposal + deemed consent for exited members, creditor write-off, erase scrub of split data (+ invites/links issued), recycled-number invite rule (invites bound to the number-holder-at-issue; owner approval for phone-bound group joins), reviewer-first push, split-full counting rule.
3. Online-write path + atomic friend add; remove the changes feed/queue after the drain window (removes the banner, B15, B23, initial-sync cost).
4. People directory (one person = one number = one name, private per owner, rename in one place, picker reuses saved person) incl. dedupe hints, per-viewer labels, merge, rejoin/relink, invitee-inbox fix.
5. Limits and abuse: per-user caps, invite rate/consent/block, `hasMore` on all lists, receipts retention, purge loop, indexes.
6. Later: per-person summary across friends+groups, simplify debts, currency, statement export, kick/archive.

## Decisions required
Person/label model (private per owner; self-chosen name; who sees what), expenses with a person who has not joined (consent-only vs private unverified tracking), write-off/relink after account deletion, exited-member read-only history and rejoin, kick + block, discoverability opt-in and the lookup oracle, what the 200 cap counts, per-user caps, reviewer-first notifications, retention (receipts/reveals/events), refuse vs truncate names over 40, snapshot sync vs event replay (moot if the feed is removed), currency scope.
