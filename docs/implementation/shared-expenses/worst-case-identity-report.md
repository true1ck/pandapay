# Worst-case identity and lifecycle report (people, numbers, many splits)

Run: 7 November 2026, against the LOCAL stack only (API :4001 with `SHARED_EXPENSE_PHONE_SHARING` on, auth :3210 with test OTP,
Postgres container `pp-split-labels-pg`). Every scenario below was executed through the real HTTP API (commands, invitations, directory,
group links, reads); account deletion and phone change were done by editing the local auth/profile rows exactly like the deletion trigger and
the auth service would. Product code was not modified. Throwaway accounts are `wc_*@example.com` (display names `WC ...` or the stated test name);
the seed accounts for the emulator are `seed_*@example.com`. Account A (`test@example.com`) was only used for seeding (nothing of A's was deleted,
none of A's earlier pending requests was approved or declined).

Verdicts: PASS = behaves as the contract says and is safe. FAIL = unexpected. BUG = defect or dead end. Severity: S1 wrong money or privacy, S2 confusing or stuck, S3 polish.
`KNOWN` = already recorded in `worst-case-concurrency-report.md` (B10).

Pure tests (no DB): `node --test api/test/shared_expenses_worst_identity_labels.test.js` (12 pass, 2 `todo` = the two label defects below).

## Scenario table

| ID | Scenario | What actually happened | Verdict | Sev | Repro (minimal) |
| --- | --- | --- | --- | --- | --- |
| W01 | Same real person, same number, added as friend 3 times with names Pat / Patrick Bhai / Dr Pat Singh, plus a group member "Paddy" | All 4 invites accepted (no cross-split duplicate check). After she accepts, the OWNER sees 3 friends with 3 names and the person sees 3 splits ALL titled with the owner's profile name ("WC Owner 3" x3). Inside each split her own row shows the owner's typed name for her ("Patrick Bhai"). `lookup` returns `existingContextId` only for a joined direct split (null while the invite is pending and for group-only). | BUG | S2 | `context.create direct "Pat"` + `POST /invitations phoneNumber` three times with different names, then accept all as the person and `GET /contexts` |
| W02 | Phone formats: `+91 98111 00001`, `98111-00001`, `9811100001`, `+91-(981)-110-0001`, trailing space | All 5 resolve to one hash (one real person, 5 independent splits). | PASS | - | `POST /invitations` x5 |
| W02b | `09811100001`, `0 98111 00001`, `919811100001`, `91 98111 00001`, `0091 ...`, Arabic-Indic and full-width digits, `... ext 5`, trailing letter | All `400 invalid_input/phoneNumber`. The app's `sharedCleanPhone` fixes `0xxxxxxxxxx` and `91xxxxxxxxxx` before calling; Unicode digits are refused rather than converted (the app strips them to nothing and refuses too). | PASS | S3 note | same |
| W03 | Name-only friend "Raju", later the number is given (A6) | Number can be bound to the existing name-only friend (`POST /invitations` on the same member: ok). A second split "Raju Kaka" with the same number is also allowed, so the person gets 2 invites from one owner. There is NO merge of two splits. | PASS (bind) / gap (merge) | S3 | direct "Raju" -> invite number; direct "Raju Kaka" -> same number |
| W04 | One person, two numbers (home registered, office not) | Two independent splits "Tara" and "Tara (office)"; the person only sees "Tara"; nothing links them. | PASS (by design) | S3 | two directs, two numbers |
| W05 | Two people, one landline, same group | First member invited; second -> `invitation_duplicate`. They can still be added with a link invite. | PASS | S3 | group, 2 members, same landline |
| W06 | Two contacts with the same number (Mom / Mummy) | Allowed across splits (see W01). Same split: `invitation_duplicate`. | PASS | - | - |
| W07 | Two Chandreshes: directs "Chandresh"/"Chandresh"/"chandresh "/"Chandresh S"; group same | 2nd and 3rd direct `friend_name_taken`, group `member_name_taken`, "Chandresh S" accepted (different key). Two registered Chandresh Shah added with typed "Chandresh (gym)" / "(work)" are shown that way to everyone. Three link joiners with profile "Chandresh Shah" become `Chandresh Shah`, `(2)`, `(3)`. | PASS | - | as listed |
| W08 | One person in 20 groups + 1 direct: names per context | Owner: group name + direct title = own typed label; person: group names, direct title = OWNER'S profile name; a third member sees the typed label of that group ("Pat", "Patty", "Paddy", ... in 20 groups). Typed label wins even on the person's own row. The inbox shows only 20 pending invites (see W25). | PASS (contract) | S3 | 20 groups, same number, 20 labels |
| W09 | Person registers AFTER 3 owners added her with 3 labels (Nina / Nin-Nin / Aunty Nina); expense already allocated to her | One verified-phone signup sees 3 invites, accepts all. Member id kept, owner's typed label kept, the pre-registration expense (share 500) shows as a proposal she must approve, balance moves only after her approval (+50000/-50000). Old proposals are reviewable. | PASS | - | invite -> propose with invited member -> register -> inbox -> accept -> approve |
| W10 | Registered user renames herself (profile name) | Owner-typed rows never change. Link-joined placeholder rows keep the profile name captured at join time ("Chandresh Shah" stays after rename to "Chandy Renamed"). | PASS (stale) | S3 | link join, change `profiles.display_name`, `GET members` |
| W11 | Friend renames HERSELF in my direct split (A11) | `member.rename` on her own row is accepted: my Friends title silently becomes "Sweetie Pie"; she can rename to "Rahul" and I then have TWO friends titled "Rahul" (friend_name_taken bypass, by contract). Reserved names and the owner's own profile name are still refused. No notification to the owner. | BUG | S2 | accept invite, then `member.rename` own row "Rahul" while owner has friend "Rahul" |
| W11b | Owner renames friend B to friend A's label | `friend_name_taken` | PASS | - | - |
| W12 | Person changes phone number | Pending invites bound to the old number vanish from her inbox; lookup of old number -> not found, new number -> found; her memberships unaffected. | PASS | - | change `users.phone_number`, call `/directory`, `/inbox` |
| W13 | Recycled number (A13): new holder of the old number | Sees the previous holder's pending invite ("Phone Changer", `inviterName` null), ONE tap joins the owner's split immediately (no owner approval), and sees the pending proposal "Rent share" with amounts. | BUG | S1 | invite number N, holder changes number, new account verified on N -> `GET /inbox` -> `accept` -> `GET /expenses` |
| W14 | Person deletes account, same number re-registers (A16) | History, balances (+40000 / -45000) and typed labels stay on the former member (shown as "Deepa", marked as profile-less). The reborn account sees nothing (no balance leak: PASS). But the owner cannot re-add the same person: direct label "Deepa" is `friend_name_taken` (dead split still counts), group re-invite by number is `invitation_duplicate` (old joined invite holds the number), and the empty member "Deepa Again" is stranded as `invited`. The former member cannot be removed (`membership_conflict`) while balances exist. Only a new differently named split works, with no history. | BUG | S2 | delete profile, re-register number, owner `POST /invitations` into the same group |
| W15 | Owner deletes account (take-over) | Owner row becomes "Former member" (still owner, still holds balance); first member `take-over` -> owner; second member -> `owner_still_present`; new owner can add members. | PASS | - | delete owner profile, `POST /contexts/take-over` |
| W16 | Owner adds their own number: `+91...`, bare, spaced, dashed, as group member | All `400 invitation_self`. `lookup` of own number before the owner's first directory touch returns `found:false,self:false` (self only works after `/directory` or `/inbox`). | PASS / S3 | S3 | invite own number in 4 formats |
| W17 | Same person is friend AND group member (two balances) | Two separate balances (direct 50000 owed to owner, group 35000 owed to person); `/overview` shows gross owed 50000 / owing 35000 / net 15000. No cross-context netting or settlement. | PASS (by design) | S3 | expense in each context |
| W18 | Left member re-add / rejoin (A19) | Leah leaves (ok). Re-claim of the group link -> `409 membership_conflict` (no explanation). Re-invite by number into a new row "Leah L" -> `invitation_duplicate`. So she can never come back; the new row is stranded as `invited`. | BUG | S2 | member joins, `POST /contexts/leave`, claim link again |
| W18b | Removed / blocked | `members/remove` works only for unjoined people (joined -> `membership_conflict`). Owner declines a link request -> same person re-claims -> `join_declined_recently`. Removed unjoined label is reusable. | PASS | - | - |
| W18c | Invitee DECLINES a phone invite | `POST /invitations/decline` -> 500 `internal_error` every time (SQL binds 5 params, references 4: 42P18). The invite stays open for 7 days, the 7 day decline pause never starts, so the owner can re-invite at once. | BUG (KNOWN B10) | S2 | `POST /shared-expenses/invitations/decline` |
| W19 | Group-link flood + `Name (2)` collisions | 49 claimants: first 20 pending, the rest `join_requests_full`. 20 approved with identical profile "Sam Flood" -> `Sam Flood`, `(2)` ... `(20)`; later 4 more `(21)..(23)`; typed "Sam Flood (2)" first -> joiners skip to `(3)`; profile equal to owner's name -> `WC Owner Seventeen (2)`; null / reserved / emoji-only / "..." profile -> `PandaPay user`, `(2)`... ; "Former Member" -> `PandaPay user`; bidi and zero width stripped; 80 char profile cut to 40. | PASS | - | 49 users claim one link |
| W20 | 200 member group, 20 members named Amit | 200 reached, 201st -> `context_member_limit` (also on link claim, before approval). "Amit", "Amit.", "AMIT" collide; "Amit K." and "Amit Kumar" coexist; 20 "Amit <surname>" fine. 50 sharers ok, 51 -> `invalid_participant_count`. 4 s for 199 adds. | PASS | - | - |
| W21 | Real-life label table (see below) | See table below. | BUG (UX) | S3 | `member.invite` with each label |
| W22 | Contact picker: lookup -> invite -> create friend when the number is already used | `lookup`: registered -> `found`, `existingContextId` only when a JOINED direct split exists; pending invite / group-only -> null; unregistered number with an open invite -> `found:false`. Same number again in another split -> allowed; same group other member -> `invitation_already_member`; re-invite a joined member -> `invitation_conflict`. A phone-invited placeholder whose person then joins by link is left behind as a stranded `invited` row (W24). Phone-less "Invite again" keeps the phone binding. | PASS / S3 | S3 | see W22 table rows |
| W23 | What the invitee's inbox shows | `contextName` = OWNER'S typed label for the invitee ("Yashu bhai"), `inviterName` = masked directory name ("Priyanka O.") or `null` if the inviter never opened the app's directory/inbox call. | BUG | S2 | `GET /invitations/inbox` |
| W24 | Placeholder with an expense + person joins by link (A6 merge gap) | Two rows: "Yash (placeholder)" (invited, owes 30000) and the real "Yash Invitee". Cannot bind her number to the placeholder (`invitation_already_member`), cannot remove it (`member_has_expenses`), no merge. A fresh link for the placeholder can still be minted. | BUG | S2 | placeholder with expense, person claims group link |
| W25 | Person invited to 21 splits | Inbox returns the newest 20 only, no cursor/`hasMore`; the 21st appears after acting on one. | BUG | S3 | invite one number into 21 splits, `GET /inbox` |
| W26 | Rename edge cases (owner) | own label re-cased/spaced/dotted ("Ramkumar", "RAM  KUMAR", "Ram Kumar.") ok; to another member's key -> `member_name_taken`; "Admin Shyam" -> `member_name_reserved`; emoji -> `invalid_member_name`; zero width trimmed. | PASS | - | - |
| W27 | Owner renames the label after inviting | Owner's list updates, invitee's inbox `contextName` stays the old label (frozen `contexts.name`). | BUG | S3 | rename, then `GET /inbox` |
| W28 | Typed "Sam Flood (2)" vs "Sam Flood2" | Second refused (same key). | PASS | - | - |
| W29 | Owner private nickname exposed | An invite carrying label "Mota Zoya (fat)" shows exactly that text in the invitee's inbox before she joins (consequence of W23). | BUG | S2 | `member.invite displayName` nickname + number |

### W21 real-life labels (live API; group `member.invite`, same result as direct friend `context.create`)

Wrongly blocked (a plausible contact label was refused):

| Label | Answer | Why |
| --- | --- | --- |
| `Owner (flat 4)` (landlord) | 400 member_name_reserved | starts with "owner" |
| `Admin office` | 400 member_name_reserved | starts with "admin" |
| `Support Raj` | 400 member_name_reserved | starts with "support" |
| `Unknown number` | 400 member_name_reserved | starts with "unknown" |
| `Ownerji`, `Someone`, `Deleted ...` | 400 member_name_reserved | prefix rule (`Landlord`, `Office admin`, `Raj (support)` are fine) |
| `Me`, `You`, `Myself` | 400 member_name_reserved | exact words (intended) |
| `😀` emoji only | 400 invalid_member_name | no key (intended) |

Merged / blocked as "same person" when they may be two contacts (second one refused, `member_name_taken` / `friend_name_taken`):
`Ram Kumar` vs `Ramkumar`, `Anu Raj` vs `Anuraj`, `Amit.` vs `Amit`, `Mom` vs `Mom ` vs `MOM`, `José` vs `Jose`, `Ñandú` vs `Nandu`, `Mr. Kumar` vs `Mr Kumar`, `Dr. Mehta` vs `Dr Mehta`, `Flat 4B` vs `Flat4B`, `Jean-Luc` vs `Jean Luc`, `Kumar Singh` vs `Kumar-Singh`, `O'Brien` vs `OBrien`, `李明` vs `李 明`, `Raj` vs `Raj 😀`, fullwidth `Ａｍｉｔ` vs `Amit`, Cyrillic `Аmit`/`Sаm` vs Latin (intended), two 41+ char names with the same first 40.

Accepted correctly: `Mom`, `Landlord`, `Dad (work)`, `Dr. Mehta`, `Dr. Mehta` + `Mehta`, `Meera`/`Mira`, `Mehul`, `Youssef`, `Admiral Nelson`, `O'Brien`, `Jean-Luc`, `Mary-Ann O'Neil`, `R2-D2`, Devanagari, Tamil, Arabic, Chinese, Japanese, Cyrillic `Сергей`, `Pooja`/`Puja`, `Raj`/`Rájá`.

Changed silently on save: names over 40 characters are cut mid-word ("Kunal Subramaniam Venkataraman Iyer Juni"); a zero width joiner / non-joiner is removed, which changes correct spelling (Persian "می‌خواهم" is stored as "میخواهم", Devanagari/Tamil conjunct requests lose the joiner). `todo` tests in the pure suite pin both.

## Top bugs

1. W13 (S1, privacy, known open gap A13): a recycled number gives the new holder one-tap membership of the old holder's splits and a view of pending proposals; no owner approval for phone-bound invites. Needs a freshness check (number changed since invite) or owner confirmation.
2. W18 / W14 / W24 (S2, dead ends): left member can never rejoin (link `membership_conflict`, phone `invitation_duplicate`); deleted-and-reborn person cannot be re-added to the same group or under the same friend label; a placeholder that holds an expense cannot be merged or removed once the person joins by another route. All three strand rows and balances.
3. W18c (S2, KNOWN B10): decline invitation always 500; the 7 day pause and the "declined" state never happen.
4. W11 (S2): a friend can silently re-label herself in my Friends list and create duplicate titles; no notice to me.
5. W23 / W29 / W27 (S2/S3): the invitee's inbox shows the owner's private label for the invitee as the split name and often no inviter name; stale after a rename.
6. W25 plus the join-request list: both are cut at 20 with no `hasMore`. Seeding showed it: with 26 pending requests the owner sees only the newest 20, the oldest 6 are invisible (see seeding note).
7. W21 (S3): reserved prefixes block everyday labels (`Owner (flat 4)`, `Admin office`, `Support Raj`, `Unknown number`); space/accent folding blocks two different `Ram Kumar`/`Ramkumar`.
8. W01 (S2): one person can be added unlimited times in different splits with no "this number is already your friend X" hint while the invite is pending; the person sees 3 splits with the same title.

## Part 2: seed for the emulator (owner A = test@example.com)

Everything was created with the same API calls the app makes (`context.create`, `member.invite`, invitations, group links, claim, respond, `expense.propose/respond`, `settlement.report`). Nothing failed to seed (0 failures after the one label that hit the reserved rule, "Admin Kalpana", was renamed "Kalpana (front desk)"). State (ids) is in the scratchpad file `wc_seed_state.json` (local only).

A now has 73 splits: the 21 that existed + 40 direct + 12 groups (A owner of 10, plain member of 2) and one group A left, plus one invite waiting in A's inbox.

Direct friends (40): 14 unique names (Aditya Verma ... Nandini Rao); 9 look-alikes in 3 sets (Chandresh Shah / Chandresh S. / Chandresh Shah (gym); Priya Nair / Priya N / Priya Nayar; Rahul K / Rahul Kapoor / Rahul Kapur); 2 long names (cut at 40: "Subramaniam Venkataraman Iyer Junior Jr." and "Mr. and Mrs. Ramaswamy Krishnamurthy Associates Ltd"); 5 non Latin (देवेश कुमार, अनुराधा शर्मा, श्रीमान् क्षत्रिय with joiner, தமிழ்செல்வி, محمد علي); 4 phone-bound open invites to unregistered numbers (Landlord Mr. Gowda, Maid Lakshmi, Cab driver Raju, Plumber Suresh); 6 registered friends whose typed name differs from their profile name (Mummy = Sunita Deshpande, Roomie Rohit, Boss = Vikram Singh, Didi = Bhavna Kulkarni, Tutor Karthik = Karthik Subramanian accepted; Gym buddy Neha = Neha Gupta invited, not yet accepted). Balances: Mummy, Roomie Rohit (large rent), Boss, Tutor Karthik, Didi (one accepted, "Movie tickets" waiting for A's approval), "Cab to airport" waiting for Boss.

Groups (member counts active/invited):

| Group | A is | Members | Notes |
| --- | --- | --- | --- |
| Weekend Trek | owner | 6/0 | 2 expenses, A is owed 13,000 |
| Family | owner | 3/10 | 6 name-only relatives, 4 pending join requests (see below), A owed 16,000 |
| College Friends 2012 | owner | 9/16 (25) | 8 registered, 16 name-only, A owes 4,000 |
| Society Maintenance | owner | 4/12 | 11 flats/roles name-only, 1 pending request (profile has no name, shared number), A owed 18,000 |
| Diwali Party | owner | 5/5 | proposal "Decor and lights" waiting on 2 of 5 |
| Cricket Sunday | owner | 6/9 (15) | A owes 750 |
| Roommates HSR | owner | 4/0 | 3 expenses, A owed 5,000, 2 pending settlements |
| Wedding Planning | owner | 6/14 (20) | A owes 23,000 and is owed 3,000; proposals pending |
| Book Club | owner | 3/0 | two members both called "Rohit Sharma" -> "Rohit Sharma" and "Rohit Sharma (2)" |
| Office Lunch Gang | owner | 9/7 | pizza proposal pending |
| Kerala Road Trip | plain member (owner Arjun Reddy) | 6/2 | A owes 6,000 (accepted) and is owed 10,000; one proposal waiting for A |
| Neighbours WhatsApp | plain member (owner Ananya Das, joined by phone invite) | 4/1 | A owed 3,750 |
| Old Flatmates | LEFT (owner Sandeep Joshi) | - | A joined then left; not in A's list |
| Movie Night | invited | - | one invite waiting in A's inbox (inviter shown as "Manish A.") |

Pending join requests for A (new, all consent states): Family: shared (Sandeep Joshi, `+91 70••• •0012`), declined (Pooja Iyer), none (Eshan Email-only, no verified phone), not_asked (Manish Agarwal); Society Maintenance: shared with no profile name. A's 15 earlier requests (Join QA, Goa trip, Flat 4B, Rahul) are untouched.
IMPORTANT: the list API returns only the newest 20 pending requests. I first created 11 new ones (26 total) and the oldest 6 of A's own disappeared from the list, so I resolved 6 of MY OWN seeded requests (3 approved, 3 declined) to bring the total back to exactly 20. Any new request will push A's oldest one out of view again (bug in the list above).

Settlements pending (5): Boss reported paying A 2,250 (A to confirm); A reported paying Tutor Karthik 1,500 and Roomie Rohit 5,000 (they must confirm); in Roommates HSR, Pooja Iyer reported paying A 3,000 (A to confirm) and A reported paying Rohit Sharma 2,000 (he must confirm).
Activity: far more than 10 events (the personal feed has over 100: expenses, approvals, joins, settlements, leave).
Overview for A after seeding: owed 73,075, owing 50,830, net 22,245, 23 expenses, 73 splits.

Seed users: `seed_1..26@example.com` (verified phones +91 70010 10001..), `seed_emailonly@example.com` (no phone), `seed_noname@example.com` (no profile name). Throwaway test users: `wc_*@example.com`.
