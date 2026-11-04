# PandaPay shared expenses: scenario and acceptance matrix

Updated 4 November 2026. Used with the [production implementation plan](shared-expenses-production-implementation-plan.md), [agent register](shared-expenses-agent-work-packages.md) and [product/accounting/UX specification](shared-expenses-product-ux-accounting-spec.md).

Execution evidence is recorded in the [implementation register](../implementation/shared-expenses/README.md) and [P02 handoff](../implementation/shared-expenses/P02-status.md). The first increment tests calculation portions of M01–M11/M14/V14 and source-identity shape portions of V01/V02 in Node and Dart. Those helper assertions do not complete the full API/local/UI/DB scenarios below; all other coverage remains pending its packet.

This is a **risk-based scenario register**, not a claim that every possible future failure is enumerable or that any test has run. Extend it when source investigation, tests or incidents reveal a new case. Each enabled scenario requires both data correctness and the user-visible state; a screenshot alone does not verify financial behavior. Preserve product fixtures C01–C22 in addition to these rows.

Current baseline: **`sms-v2/integration` @ `bf6bec9b`**. The [branch review](shared-expenses-sms-v2-branch-review.md) supersedes old universal transaction-UUID/report-owner assumptions. V01–V18 below add current source/correction/replay/foreign/readiness gates; all earlier scenarios remain applicable.

## 1. Evidence contract

- P0: required before any corresponding financial write/recognized report is enabled. P1: required before enabling that specific feature; otherwise the capability is unavailable with safe read compatibility. P1 does not mean optional correctness.
- Layer codes: **D** pure domain/property tests in Node and Dart; **B** real PostgreSQL/migration/RLS/concurrency; **L** real SQLite/process/recovery; **C** HTTP/schema/compatibility; **U** rendered Flutter interactions/accessibility; **S** security/abuse; **P** profile/load/fault/soak. Device evidence follows `AGENTS.md`.
- Every executable case records input fixture/clock, initial canonical and local state, action/interruption, expected final money/IDs/revisions/permissions, expected UI/actions and exact evidence/build. Not started, failed, blocked and inconclusive stay explicit.
- All money assertions use exact minor units. Assert source IDs/private metadata, journal sums, obligation allocations, personal facts and source-based rewards where relevant. Do not only assert a formatted balance string.
- Run important combinations: offline × member removal; settlement × expense edit; source merge × pending create; restore × lost response; auth switch × delayed response; high load × retry/lease expiry; old client × converted legacy split. Pairwise tests alone do not replace these known multi-way races.

## 2. Money, allocation and funding

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| M01 / P0 | ₹100 equally among three | Persist 3,334 + 3,333 + 3,333 paise, stable tie order, exact payer/share sums. | Bill total ₹100; each precise share visible; no invented ₹0.01 fee. | D/B/L/U; P02/P03/P06 |
| M02 / P0 | Same split retried, reordered or participants renamed | Identical saved amounts and identities; display ordering cannot change a remainder. | Existing saved shares remain unchanged. | D/C/L; P02/P05 |
| M03 / P0 | Hundreds of repeated rounded splits | Every expense balances; total accepted cost equals total expense value at same scope. | No accumulating unexplained remainder. | D/B; P02/P12 |
| M04 / P0 | ₹0.01 across several people | Zero beneficiary shares allowed; no extra money; exact tie policy. | Zero amounts distinguish included-zero from omitted participant. | D/U; P02/P06 |
| M05 / P0 | Zero/negative/NaN/infinity/excess decimals/unsupported numeric strings | Reject before effect; no partial DB/local command mutation. | Actionable amount error; user input retained. | D/C/B/L/U; P02/P03/P06 |
| M06 / P0 | Maximum amount, overflow during weight multiplication or accumulated balances | Checked exact arithmetic across API/DB/Dart/web/exports; no rounding or signed overflow. | Clear limit/error; never show a wrapped negative value. | D/B/C; P02/P03/P08 |
| M07 / P1 | Exact amounts do not equal total | No accepted unbalanced revision. | “₹X left to allocate” / “Over by ₹X”; save disabled or server error retained. | D/B/U; P02/P06 |
| M08 / P1 | Percent total not 100%, fractional scale ambiguity | One frozen percentage scale and exact remainder policy; invalid sum rejected. | Live remaining percent; no silent normalization. | D/C/U; P02/P06 |
| M09 / P1 | Shares 2:1:1, all-zero shares or invalid weight | Rational allocation, positive total weights, deterministic minor-unit distribution. | Weighted preview; explain invalid all-zero input. | D/U; P02/P06 |
| M10 / P0 | ₹1,200 paid by you, ₹600 shared with Rahul | Owner residual ₹600 + own shared portion ₹300 = own cost ₹900; Rahul share ₹300. | Full bill, shared portion and total personal cost distinguishable. | D/B/L/U; P02/P06/P08 |
| M11 / P0 | Multiple payers fund one bill | Contributions sum once to expense; one share/member; no payer×share join multiplication. | Show each contribution; do not assign whole bill to every card. | D/B/U; P02/P03/P06/P08 |
| M12 / P0 | Cash plus own card plus friend's card | Keep correct owner/instrument/funding amounts; no disclosure of friend's source. | Own actual charge differs from bill and share; private evidence protected. | B/S/U; P01/P06/P08 |
| M13 / P0 | Author is neither payer nor beneficiary | Author permission separate from amount semantics; configured acceptance policy applies. | Recorded by X, Paid by Y; no automatic debt to author. | D/B/S/U; P03/P07 |
| M14 / P0 | You paid, own share zero | Receivable exists, consumption zero; no zero-value posting inflation. | “You paid for others”; never “Not involved”. | D/B/U; P02/P07/P08 |
| M15 / P0 | You paid zero, own share zero | Authorized group-only view contributes no own spend, movement, reward or obligation. | “Not included in this split”; not false Settled. | D/B/U; P07/P08 |
| M16 / P0 | Gift/nonrepayable payment | Explicit meaning/reallocation; no debt or fake paid settlement without agreement. | Ask repayable versus gift; summary matches choice. | D/B/U; P02/P06 |
| M17 / P0 | Discount/tax/tip/service fee | Allocate actual funded invoice and agreed shared fees exactly once. | Total/fees explained on demand; no double discount. | D/B/U; P02/P06 |
| M18 / P0 | Payer gets rewards/cashback | Source rewards retain issuer classification; friend's obligation not automatically discounted. | Rewards separate from share; no promise of another member's reward. | D/B/U; P08 |
| M19 / P0 | Card interest/EMI/annual fee appears | Cardholder cost by default; explicit consent needed for separate shared fee. | No surprise charging friends financing costs. | D/B/U; P08/P11 |
| M20 / P1 | Mixed INR/USD/EUR or unsupported currency imported | No currency summation or guessed rate; safe unsupported review/read state. | Original currency + unsupported conversion message; hide unsupported payment control. | D/C/U; P02/P09 |

## 3. Recognition, friend-paid and duplicate prevention

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| E01 / P0 | Rahul pays ₹900 for three; you record it | One expense, own share ₹300, no own source/debit/default card. | Paid by Rahul; own funding controls absent; own share clear. | B/L/U; P03/P05/P06 |
| E02 / P0 | Existing source already has a shared expense | Open/link stable expense; second active funding claim prevented. | View split replaces create action. | B/C/U; P03/P06 |
| E03 / P0 | Manual entry then matching SMS/statement/receipt | Canonical source dedup or explicit candidate review; same expense identity retained. | Link/View recorded payment; no duplicate purchase card. | B/L/U; P03/P06/P11 |
| E04 / P0 | Import first then manual shared creation | Existing source picker reused; unique source reservation. | Offer recorded payment before creating new own payment. | B/L/U; P06/P11 |
| E05 / P0 | Two same-amount/date legitimate purchases | Identity/reference/explicit review, not automatic amount-only collapse. | Keep separate supported. | B/C/U; P03/P06 |
| E06 / P0 | You and friend independently record same dinner | Common identity or reviewed consolidation; preserve private classifications; one accepted personal fact. | Side-by-side amount/payer/date/member comparison. | B/L/S/U; P06/P10 |
| E07 / P0 | Own source saves but expense/link fails | Atomic server operation or durable dependency graph resumes same source ID. | “Payment saved; split needs attention.” | B/L/C/U; P03/P05/P06 |
| E08 / P0 | Double tap/save/retry after timeout | Same operation/hash gives at most one financial effect. | One pending/save result; tap debounce is supplementary. | B/L/C/U; P03/P05/P06 |
| E09 / P0 | Same operation ID with different payload | Conflict, no second effect; canonical committed receipt unchanged. | Explain review/retry as a new edited intent. | B/C/U; P03/P05 |
| E10 / P0 | Same source concurrently linked to two expenses | Reservation lock/unique constraint and sum bounds; one winner or explicit conflict. | Losing draft remains reviewable; View existing split. | B/L/U; P01/P03/P06 |
| E11 / P0 | Duplicate-source merge, one expense | Atomically remap to survivor ID, preserve attachments/metadata and single cost. | Canonical detail remains reachable. | B/L/U; P03/P06 |
| E12 / P0 | Duplicate-source merge, two different accepted expenses | No silent obligation merge; explicit review; preserve both histories until resolved. | Preview conflicting splits and Keep separate where valid. | B/L/U; P03/P06 |
| E13 / P0 | Source amount reduced/deleted while expense save races | Shared source reservation protocol enforces funding bounds; accepted effects cannot overfund. | Review changed funding; no vanished payment history. | B/U; P01/P03/P06 |
| E14 / P0 | Source restore after a voided shared expense | Restore evidence once; does not automatically revive shared obligations. | Explicit restore versus reactivate distinction. | B/L/U; P06 |
| E15 / P0 | Pending claim not accepted, rejected or disputed | Recognition separates pending/provisional from agreed debt/report facts; no reminder/payment eligibility for disputed edges. | Review/decline/dispute visible; not an accepted bank purchase. | B/S/U; P03/P07/P10 |
| E16 / P0 | Legacy split still loading or fetch fails | Unknown is not empty; block destructive overwrite or require explicit recovery. | Loading/retry/View saved local state; retain notes. | L/C/U; P05/P06 |

## 4. Groups, friends, direct context and lifecycle

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| G01 / P0 | Create group/add friend with no expense | Identity/context only, no money postings or messages without chosen share action. | No expenses, not a fabricated zero transaction. | B/L/U; P07 |
| G02 / P0 | Direct expense without creating a group | Stable private scope, expense/member authorization; bucket is presentation only. | Non-group expenses supported, no forced group setup. | B/S/U; P01/P07 |
| G03 / P0 | Same friend receivable in group and payable directly | Both obligation scopes retained; friend net informational. | Expand both; no automatic settlement by net. | D/B/U; P03/P07 |
| G04 / P0 | Group/friend/overall summaries | Same recognized scope/currency/snapshot reconciles; never add Friends and Groups together. | Consistent labels/amounts; gross and net distinguished. | D/B/L/U; P03/P07/P08 |
| G05 / P0 | Net zero with opposite or circular obligations | Obligation/credit counts remain; no Settled based only on vector net. | “Net ₹0; balances remain” and View balances. | D/B/U; P02/P07 |
| G06 / P0 | Truly settled versus no expenses | Distinct history/recognition states; pending/disputed/credit exceptions respected. | Settled versus No expenses copy. | B/U; P07 |
| G07 / P0 | Hide/show settled then refresh/reinstall | Per-user preference, no history/ledger deletion; recover preference appropriately. | Show/Hide label matches actual expansion. | B/L/U; P05/P07 |
| G08 / P0 | New expense after settled context hidden | Recognized new obligation makes context visible or needs-attention without losing preference semantics. | Reappears with accurate amount; no missed action. | B/L/U; P07 |
| G09 / P0 | Member joins existing group | Explicit historical-access/recognition policy; no automatic acceptance of all old claims. | Clear roster/invite/history status. | B/S/U; P01/P07/P10 |
| G10 / P0 | Remove/leave with debt, credit or pending draft | Preserve accepted history; block or constrain unsupported leave; reauthorize draft and future writes. | Explain outstanding balance and saved draft; no debt-erasing button. | B/L/S/U; P01/P05/P07 |
| G11 / P0 | Role/admin transfer or last admin leaves | Authorization remains valid, no orphaned group configuration; record audit. | Explicit transfer/block action; old admin cannot keep editing. | B/S/U; P01/P07 |
| G12 / P0 | Rename/image change / duplicate display names | Stable IDs, safe avatar fallback; no financial identity changes from labels. | Long names wrap; distinguish people safely. | B/U; P07 |
| G13 / P0 | Archive group versus void expense | Presentation/lifecycle only unless separate financial correction explicitly accepted. | History and outstanding balances remain inspectable. | B/L/U; P07/P09 |
| G14 / P1 | Optional settle-up date, timezone change, daylight transition | Store intended date/timezone policy, idempotent reminder; no automatic payment or issuer-date change. | Local date and editable reminder; respects quiet hours. | B/L/U; P07/P11 |
| G15 / P0 | Group/beneficiary/payer limit exceeded | Bounded validation before effect; no silently dropped person. | Clear limit and remedy, preserved draft. | B/C/U/P; P01/P06/P07 |
| G16 / P0 | Attempt to move accepted expense to another group | Initial behavior blocks unsafe relocation; reviewed correction/new-context flow requires explicit permissions and no duplicate cost. | Explain original context/history; no silent move of settled obligations. | B/S/U; P03/P07/P09 |

## 5. Settlement, UPI, correction and refund

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| S01 / P0 | Owes ₹500, confirmed pays ₹300 | Record ₹300 settlement/allocations, ₹200 remains; no new consumption/reward. | “₹300 confirmed. ₹200 remains.” | D/B/L/U; P02/P09 |
| S02 / P0 | Pays full balance | Clear eligible obligations, preserve history and provenance. | Settled only when no unresolved exception; appropriate restrained success feedback. | D/B/U; P09 |
| S03 / P0 | Actual payment exceeds balance | Allocate eligible part and explicit pair/context credit; never clamp actual payment. | Explain excess credit/refund, not negative debt confusion. | D/B/U; P02/P09 |
| S04 / P0 | Two simultaneous settlement confirmations | Serialize quote/outstanding allocation; one effect per payment; actual independent excess remains credit. | Latest resulting balance; no discarded real payment. | B/C/U; P03/P09 |
| S05 / P0 | Settlement races expense edit/void/refund | One accepted ordering with immutable history and balanced correction. | Review final amount/refunds and why they changed. | B/U; P03/P09 |
| S06 / P0 | UPI app missing/cancelled | Attempt state retained; no settled effect; safe alternative copy/QR only under contract. | Choose app, copy UPI ID or cancel; no paid animation. | L/U; P09 |
| S07 / P0 | UPI return says success but no authoritative evidence | Unconfirmed/reportable state, not provider verified or automatically settled. | Check payment app; mark reported with provenance. | B/C/L/U; P09 |
| S08 / P0 | No callback/app killed during external launch | Durable attempt resumes uncertain; no auto relaunch. | Payment status unknown with next-step guidance. | L/U; P05/P09 |
| S09 / P0 | Malformed/malicious callback or intent fields | Strict validation/encoding/auth; raw text cannot alter amount/payee/confirmation. | Safe failure; no sensitive data in error/log. | C/S/U; P09 |
| S10 / P0 | Amount/payee changed since quote | Revalidate at launch/report/confirm; receiver identity visible; no guessing another creditor. | Quote changed, review current payment details. | B/C/U; P09 |
| S11 / P0 | Payer reports, receiver hasn't confirmed | No accepted confirmation effect until policy met; report cannot masquerade as bank verification. | Awaiting receiver confirmation; reminders not duplicated. | B/U; P09/P11 |
| S12 / P0 | Report disputed/declined, confirmed payment reversed | Separate audited decisions/reversal, linked original event, at most one reversal effect. | Explain reopened obligation and dispute status. | D/B/U; P09 |
| S13 / P0 | Received bank SMS/statement matches an existing settlement | Link actual movement once using strong evidence or user review; exclude principal reimbursement from earned income. | Split repayment label; source inspectable. | B/L/U; P08/P09/P11 |
| S14 / P0 | Same-amount unrelated credit/debit near settlement | No automatic reassignment based solely on amount/time. | Possible payment → Review, with Keep separate. | B/L/U; P09/P11 |
| S15 / P0 | Refund after full settlement | Adjust expense cost at agreed occurrence period, retain payments and create exact refund obligations. | Preview who returns money; historical payment still visible. | D/B/L/U; P02/P08/P09 |
| S16 / P0 | Partial refund, unknown/pending refund, refund to another instrument | Actual source credit separate from agreed shared correction; pending is not cash received. | Pending refund/original recipient disclosed without false card reduction. | D/B/U; P08/P09 |
| S17 / P0 | Void shared expense but genuine purchase remains | Reverse shared effects, retain own unshared cost/source and explicit credits. | Distinguish Stop sharing from Delete purchase. | D/B/U; P06/P09 |
| S18 / P0 | Delete/unlink private source after settlement | Private evidence operation does not erase journal/repayment. | Clear unlink versus shared correction choice. | B/S/U; P06/P09 |
| S19 / P0 | Receipt-only/cash/manual external settlement | Provenance explicitly user-reported/receiver-confirmed; no invented bank reference. | Recorded externally; never Provider verified. | B/U; P09 |
| S20 / P1 | Bulk settlement or debt simplification requested | Disabled until explicit scope/allocation/consent contract; never fake expense item. | Explain supported per-context settlement; no misleading shortcut. | D/B/U; P02/P09 |

## 6. Offline, concurrency, identity and recovery

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| O01 / P0 | Elevator/flight offline create | Draft/provisional fact/command atomic, stable IDs and queued dependencies. | Saved on this device, not delivered/accepted by friends. | L/U; P05/P06 |
| O02 / P0 | Response lost after server commit | Status lookup/resend same operation returns canonical result, one effect. | Resolves pending without another expense/payment. | B/C/L; P03/P05 |
| O03 / P0 | Process killed before/after each local commit/ack | Durable state machine, resume graph; no half-save/drop/double replay. | Retained draft/pending result or accurate Not saved. | L/U; P05 |
| O04 / P0 | Disk full/corrupt local row/schema upgrade failure | No false durable success; quarantine recoverable evidence, fail safely. | Keep editing / retry / recover; no cleared account data. | L/U; P05 |
| O05 / P0 | Two devices edit money concurrently | Required revision rejects stale financial whole-document change. | Compare latest/draft; no last-clock-wins hidden merge. | B/L/U; P03/P05/P06 |
| O06 / P0 | Member removed or account restricted offline | Reauthorize server-side on reconnect; preserve private draft, no unauthorized effects. | Permission changed; review privately. | B/L/S/U; P01/P05/P07 |
| O07 / P0 | Account switch/logout during send or delayed response | Namespace fence, token ownership rechecked, late response can't contaminate new account. | Correct account state, no leaked prior summary. | L/C/S/U; P05 |
| O08 / P0 | Many dependent offline group/member/source/expense commands | Topological bounded processing, explicit failed dependency, no orphan financial record. | Per-item pending/blocked remedy, progressive sync. | B/L/P/U; P03/P05 |
| O09 / P0 | Retry storm/429/503/flaky reconnection | Jitter/Retry-After, admission/concurrency caps, same IDs; no tight loop. | Waiting to sync; no battery/network hammering. | B/L/P/U; P05/P13 |
| O10 / P0 | Partial page/expired cursor/changed filter | Atomic rows+cursor, cursor scope validation/reset, pending overlay retained; no delete-by-absence. | Refreshing/coverage incomplete, not empty final result. | B/C/L/U; P03/P05 |
| O11 / P0 | Out-of-order commits/events or duplicate delivery | Commit-safe cursor and idempotent consumer; aggregate revisions applied safely, gap not skipped. | Correct refreshed history without duplicate activity. | B/L/P; P03/P05/P12 |
| O12 / P0 | Worker lease expires while original worker runs | Fencing/unique effect; stale worker cannot ack/repeat monetary effect. | At most one event/result. | B/P; P03/P12 |
| O13 / P0 | Backup with pending shared commands | Captured consistent pending section or explicitly incomplete/blocked export; not silent exclusion. | Backup status truthful with retry/resume. | B/L/U; P05 |
| O14 / P0 | Restore old backup after payments committed | Operation IDs/canonical rehydrate prevent acknowledged replay; relationships/private metadata preserved. | Existing settlements/history restored once. | B/L/U; P05/P09 |
| O15 / P0 | Two devices restore same backup | Global effect uniqueness; pending changes reconcile under current revisions. | No doubled balances; review genuine conflicts. | B/L/U; P05/P12 |
| O16 / P0 | Wrong account/password/tampered/truncated backup | Validation/authentication before exposure/apply; no partial account contamination. | Safe rejection, original data intact. | B/L/S/U; P05 |
| O17 / P0 | Server disaster/failover after acknowledged commit | Actual configured RPO/RTO honored/proven; receipts/reconciliation detect gap; no invented zero-loss guarantee. | Accurate recovery/read-only state. | B/P; P12/P13 |
| O18 / P0 | Poison command/consumer outage | Bounded retry, quarantine with safe IDs, replay after repair; financial history not dropped. | Needs attention or delayed refresh; normal app usable. | B/L/P/U; P03/P05/P13 |

## 7. Identity, invitations, authorization and abuse

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| A01 / P0 | Nonmember guesses expense/group/source ID | Deny list/detail/command/export/attachment, including cache/worker paths. | Generic safe unavailable/access message; no existence leak. | B/C/S; P01/P03/P10 |
| A02 / P0 | Group member attempts another's private source/tag/receipt | Shared ACL doesn't grant raw evidence; attachment URL access enforced. | Only authorized summary; explicit receipt-sharing consent. | B/S/U; P01/P06/P10 |
| A03 / P1 | Invite forwarded/expired/revoked/wrong recipient | Scope/expiry/revocation and identity checks; no auto claim; current auth checked. | Review access or request invitation. | B/C/S/U; P10 |
| A04 / P1 | WhatsApp/link-preview bot GET | Read-only intentional generic preview; no join, notification or debt acceptance. | Safe share preview without private financial metadata. | C/S; P10 |
| A05 / P0 | Shadow identity with historic ₹1,200 claims verifies OTP | Bind verified identity atomically but claims remain reviewable/unaccepted per policy. | Show pending claims with Review/Decline; no surprise accepted spend. | B/S/U; P01/P10 |
| A06 / P0 | Two simultaneous shadow claims/bindings | Unique binding/transaction ordering; one authorized identity, no accidental person merge. | Retry/review correct account, no mixed balances. | B/S/U; P01/P10 |
| A07 / P0 | Recycled number, same name, wrong contact selected | No name/number-only historical disclosure or automatic acceptance; alias/binding audit. | Resolve identity/review; private debt not public. | B/S/U; P01/P10 |
| A08 / P0 | Contacts/SMS/camera permission denied | Manual entry and existing-source linking remain available; no permission bypass. | Optional contextual permission with manual alternative. | L/U; P06/P10/P11 |
| A09 / P0 | Product access/referral invite mistaken for split invite | Separate token purpose/access gate; no referral qualification or auth bypass from split. | Correct destination after user-completed sign-in. | B/C/S/U; P10 |
| A10 / P0 | Token in URL/log/referrer/analytics | Redaction/referrer controls/scoped capability and no secret in social metadata; safe link handling. | User sees readable safe summary; no exposed VPA/account details. | C/S; P10/P13 |
| A11 / P0 | Invite/debt/reminder spam, blocked sender or dispute | Per-actor/group limits, report/mute, reauthorization at send; stop inappropriate reminders. | Quiet-hours/mute respected, actionable Report/Decline. | B/S/P/U; P07/P10/P11 |
| A12 / P0 | Account deletion/erasure during pending task/shared debt | Existing lifecycle admission; explicit retention/access policy; no cross-account replay or unexplained history deletion. | Clear supported action and effect on shared records. | B/L/S/U; P01/P05/P13 |

## 8. Reports, rewards, dates and recurring behavior

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| R01 / P0 | Same period Home/Spending/detail/budget/export | Same recognized personal-cost basis/snapshot where labels match; account view actual basis explicit. | Identical meaning → identical amount; no unexplained drift. | D/B/L/U; P08 |
| R02 / P0 | Category parent/child or multiple tags | Parent not summed with child as disjoint slices; tag union counts one fact; overlap labeled. | Totals/percent chart reconcile; no inflation. | D/B/L/U; P08 |
| R03 / P0 | Private category/tag edit/merge/archive | Stable personal fact associations; no change to another member's private data or economic identity. | Existing editor and filters remain; shared label separate. | B/L/S/U; P06/P08 |
| R04 / P0 | Card/account history, issuer due, utilization/caps/milestones/fees | Actual eligible own charges and existing issuer rules remain; split-only command no reward-state application. | Full charged/issuer amount with optional share subtitle. | D/B/L/U; P08 |
| R05 / P0 | Reward rate or best-card comparison after split | Same source-based reward denominator; no friend's reward counted or friend-paid missed opportunity invented. | Rewards separate from own share and reimbursements. | D/B/U; P08 |
| R06 / P0 | Repayment appears as bank Money in/out | Actual movement retained with purpose; no new personal expense/earned income/purchase reward. | Split repayment; no duplicate dinner. | B/L/U; P08/P09 |
| R07 / P0 | Source/refund/expense dates cross month/local midnight/DST | Expense occurrence/correction policy distinct from movement/event time; identical calendar/filter bounds. | Old-period restatement explained; repayment month not consumption month. | D/B/L/U; P08 |
| R08 / P0 | Existing budgets versus new personal-cost basis | No silent historical basis/default migration; pace/forecast/alert numerator consistent and deduplicated. | Basis label, explicit choice; no backfill alert storm. | D/B/L/U; P08 |
| R09 / P0 | Empty/partial local report or lagging replica | Coverage/freshness/read token explicit; no incomplete zero/total claimed authoritative. | Cached useful data + refreshing/coverage message. | B/L/P/U; P03/P05/P08 |
| R10 / P0 | Projection rebuild/replay after correction or rollback | Consumer-idempotent deltas update old/new buckets, canonical recompute reconciles. | No totals jump from duplicate projection, current revision visible. | B/L/P; P03/P08/P12 |
| R11 / P1 | Subscription mandate/ceiling/forecast, no actual charge | Planned sharing only; no posted debt/expense from authorization limit. | Full service/unknown amount, personal forecast labeled. | B/U; P08/P11 |
| R12 / P1 | Renewal detected by recurring engine, SMS, import and manual action | Canonical actual-cycle identity and source reservation link once. | One expense, one service lifecycle/history. | B/L/U; P06/P11 |
| R13 / P1 | Historical import/backfill thousands of transactions | Bounded work, no repeated suggestions/notification storm or cap-state replay. | Progress and retroactive split available by choice. | B/L/P/U; P11 |
| R14 / P1 | Self-transfer/card-bill/settlement/reversed/failed/uncertain debit | Exclude proactive split suggestion; classification owner unchanged. | No irrelevant Split this bill prompt. | B/L/U; P11 |
| R15 / P1 | Mute/quiet hours/fatigue cap/repeat charge | Dedup per canonical eligible event, user preferences and measured caps. | Restrained contextual suggestion opens draft, sends no invitation automatically. | B/L/U; P11 |
| R16 / P0 | Widget/assistant/report share amounts hidden | Basis and privacy inherited; no raw shared financial leakage in lockscreen/share. | Current visibility preference respected. | B/L/S/U; P08 |

## 9. Navigation, design system and UI states

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| U01 / P0 | Enter Splits from Insights/Home/You/source deep link | Same feature/data/detail owners, preserve source context. | Insights retained, no duplicate dashboards or replaced main destination. | C/U; P04/P06/P07 |
| U02 / P0 | Friends/Groups/Activity switch and Back | Independent query/scroll/selection state, cancel irrelevant reads; scoped lifecycle. | Underline tabs consistent with app; no duplicate bottom bar. | L/U/P; P04/P07 |
| U03 / P0 | Group Expenses/Balances/Totals and nested detail | One active tab level/header, Back restores parent context. | Familiar app hierarchy, no stacked duplicate app bars. | U; P04/P07 |
| U04 / P0 | Old Subscriptions link or direct service notification | Select Payments third tab or same detail ID; safe Back/fallback and preserved list/draft. | Existing subscription content/actions remain once. | C/L/U; P04 |
| U05 / P0 | Empty/loading/error/refresh/offline/conflict | Typed state, retain last useful data/draft, explicit retry action. | No infinite skeleton or false empty/settled state. | L/U; P04/P05 |
| U06 / P0 | 320/360/430 widths, long names, many members, keyboard | Adaptive wrapping/scroll, preserved amount accuracy, reachable save. | No clipped paisa, overlapped CTA, squeezed tabs or lost input. | U/P; P04/P06/P07 |
| U07 / P0 | Large text/screen reader/reduced motion | Semantic tab/list/amount/state labels, correct focus, minimum targets, motion preference. | Direction not color-only; useful announcements; no inaccessible swipe-only step. | U; P04/P06/P07/P09 |
| U08 / P0 | Actual app fonts, fresh/offline launch | Current Bamboo font path works; no new font dependency or unapproved screen-local fetch. | Outfit heading/UI; IBM Plex Sans tabular money; no default-theme mismatch. | U/P; P04 |
| U09 / P0 | Cancel sheet/switch mode/back with edits | Preserve current draft or confirm discard; no hidden replacement of exact/%/share values. | User sees preserved input and live validation. | L/U; P06 |
| U10 / P0 | Paid-for-others/not-involved/settled/no-expenses/pending | Correct domain state mapping, not an amount-zero shortcut. | Distinct readable copy and correct enabled actions. | D/U; P07/P09 |
| U11 / P0 | Account switch while a detail/search/modal is open | Access state fenced, no old data/result under another user. | Safe close/review, no financial leakage in navigation restoration. | L/S/U; P04/P05 |
| U12 / P0 | Repeated Add expense/Scan entry from many app pages | One owner and stable intent, receipt scan distinct from merchant QR. | One primary creation action, no duplicate manual forms/FAB overlap. | L/U; P04/P06 |

## 10. Migration, compatibility, performance and operations

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| X01 / P0 | Upgrade populated legacy account with pending splits | IDs/amounts/notes/tags/receipts/queues preserved; legacy meaning versioned. | Existing UI and data remain; reviewed conversion only. | B/L/U; P01/P05/P06 |
| X02 / P0 | Interrupted/repeated backfill/index migration | Idempotent checkpoints, bounded locks, invalid-index detection, no applied-file rewrite/checksum bypass. | Normal app remains usable or honest maintenance state. | B/P; P01/P13 |
| X03 / P0 | Older app edits a converted source | Capability/version fence or compatible owner path; no silent overwrite of accepted shared allocation. | Safe read/update-required guidance; bank source retained. | B/C/L/U; P01/P06 |
| X04 / P0 | Kill switch/compatible binary rollback | Stop unsafe writes/automation, retain read/recovery/export/new schema and real payment history. | Existing app functional, pending drafts not lost. | B/L/P/U; P13 |
| X05 / P0 | Representative peak read/write mix | Meet proposed/agreed latency/error/resource budgets on recorded environment; correctness checks continue. | No endless loading or stale false success under load. | B/P; P12/P13 |
| X06 / P0 | Hot group/popular user, 50-way shared expenses | Contention/backpressure explicit, bounded lock waits and retry; no bypass of money invariants. | Retry/refresh guidance with preserved draft. | B/P/U; P03/P12 |
| X07 / P0 | High-history user / 30–365-day dataset | Indexed bounded reads, no history-scaled UI work/N+1, storage/maintenance forecast accepted. | Smooth useful pagination and accurate full-scope summary. | B/L/P; P03/P05/P08/P12 |
| X08 / P0 | 2× headroom/5× burst/provider or notification outage | Controlled shedding, bounded queues and recovery; core financial effects remain correct. | Nonessential delivery delayed; no false payment failure/relaunch. | B/P/U; P09/P11/P12/P13 |
| X09 / P0 | DB/worker/replica/network fail/restart | Leases/checkpoints/retries recover without missed or duplicate effects; read freshness honored. | Recoverable offline/refresh state, no data reset claim. | B/L/P/U; P03/P05/P12 |
| X10 / P0 | 24-hour soak and repeated account/tab navigation | Bounded memory/CPU/connections/cache/queue and no timer/stream leaks. | Stable scroll/state/battery use. | L/P; P04/P05/P12 |
| X11 / P0 | Reconciliation mismatch or privacy incident | Alert, fence affected writes, preserve evidence and reviewed repair/compensation. | Honest unavailable/review state, safe data access retained. | B/P/S/U; P12/P13 |
| X12 / P0 | Logging/metrics at million-user cardinality | Bounded metric dimensions, sampled allowlisted traces, protected domain audit, no financial PII/secrets. | No sensitive callback/SMS/phone data in reports. | S/P; P03/P12/P13 |
| X13 / P0 | Physical/emulator verification and sign-in | Follow exact serial/backend/build/auth handoff; update install only; no app data clear. | Signed-in target flow visibly exercised before verified claim. | U/P; P12 |
| X14 / P0 | Flutter test/analyzer hangs or CI unavailable | Mark inconclusive, retain logs, establish reliable runner evidence; no fabricated pass. | Release remains gated. | C/P; P12/P13 |
| X15 / P1 | Fresh install / app link cold start / different app variants | Production host association and current route/access checks verified on intended target. | Authorized preview/context after manual sign-in, safe fallback if app absent. | C/S/U; P10/P12 |
| X16 / P0 | Backup/retention/partition maintenance at forecast growth | No deletion of unresolved obligations/idempotency keys; tested uniqueness/FKs/rebuild/restore and measured cost. | History/recovery available under stated policy. | B/P; P01/P05/P12/P13 |

## 11. SMS v2 branch compatibility gates

| ID / gate | Scenario | Required technical outcome | Required UI outcome | Evidence / packets |
| --- | --- | --- | --- | --- |
| V01 / P0 | Local `v2:<event hash>` row before canonical server transaction | Typed source reference waits for admitted authorized canonical mapping; no UUID cast or fake source. | Recoverable pending source link; existing split action doesn't call invalid UUID route. | B/C/L/U; P00/P03/P05/P06 |
| V02 / P0 | Server UUID differs from local projection ID | Alias mapping preserves one source reservation, expense, private metadata and pending operation. | Same detail/shared record after sync; no duplicated purchase. | B/L/U; P03/P05/P06 |
| V03 / P0 | Legacy transaction superseded by equivalent v2 event | Remap established identity atomically or require review; preserve old split notes/history. | View split remains reachable through canonical source. | B/L/U; P01/P03/P06 |
| V04 / P0 | v2 correction changes amount/kind/instrument/source leg | Recheck source funding and accepted financial revision policy; no silent debt/cost overwrite. | Show source changed and review allocations, preserving previous accepted shared state. | B/L/U; P03/P06/P09 |
| V05 / P0 | Rejected instrument removes source ledger/projection | Retire bank projection under source owner; shared history remains, new funding paused/reviewed. | Source unavailable/needs review, no lost settlement or fake alternative charge. | B/L/U; P03/P05/P06 |
| V06 / P0 | Replay interrupted/repeated with pending/accepted shared links | Chunk/cursor/alias state reconciles once; no shared command replay or note loss. | Migration progress and pending link status truthful. | B/L/U; P05/P06/P12 |
| V07 / P0 | Flag off, flag on/no v2 data, mixed history and ready v2 | Current source reporting owner selected consistently; shared cost overlays once, coverage explicit. | Headline/drill-down/row/export agree without abrupt duplicate totals. | B/L/U; P00/P08 |
| V08 / P0 | complete/user_confirmed source event or awaiting_leg/ambiguous | Event interpretation state not shared acceptance/payment proof; typed ledger eligibility decides next action. | Review/source status differs from debt accepted or payment confirmed. | D/B/U; P03/P09/P11 |
| V09 / P0 | Own transfer/card bill/IPO hold/points/attempt versus eligible purchase | Preserve typed source semantics; split hooks neither add consumption nor infer debt from nonpurchase evidence. | No irrelevant split prompt; original source screen unchanged. | D/B/L/U; P08/P11 |
| V10 / P0 | Partial-visibility wallet load treated as purchase by source policy | Consume canonical typed eligibility, not blanket wallet-topup exclusions or reparse. | Actual eligible purchase can be shared once with correct funding label. | D/B/U; P08/P11 |
| V11 / P0 | Foreign source estimate/unknown/missing currency or ignored row | Retain original/estimate state; no accepted INR funding or card reward from estimate. | Existing valuation flow before accepted share; no guessed rate. | B/L/U; P02/P06/P08 |
| V12 / P0 | Confirmed billed-INR foreign purchase then matching statement | Link existing foreign/source identity once; preserve frozen valuation and actual source amount. | One purchase/shared record, original currency remains inspectable. | B/L/U; P03/P06/P08 |
| V13 / P0 | Foreign refund/revaluation after split settled | Source refund direction and shared correction separate; accepted correction produces exact credit with payment history. | Who owes a refund explained; no second expense from refund. | D/B/U; P08/P09 |
| V14 / P0 | SMS integer minor wire ↔ split decimal-string amounts | Checked exact adapters and bounds; source schema unchanged, no float round trip or truncation. | Identical amount/paisa across source and split previews. | D/C/L; P00/P02 |
| V15 / P0 | v2 outbox payload updated/acked while shared settlement pending | Separate immutable shared commands; source and shared acknowledgments/dependencies distinct. | Correct pending state, no lost or coalesced payment report. | B/L/U; P05/P09 |
| V16 / P0 | Current full ledger snapshot plus multiple split tabs at scale | Shared read owner reused; indexed bounded projection/deltas, no new full account scan per tab. | Useful cached content and smooth tabs with measured history-size budget. | L/P/U; P03/P05/P08/P12 |
| V17 / P0 | Source pipeline rollback/cutover gate or stale v2 dependency installation | Independent capabilities; retain compatible source/link reads; refresh exact branch dependencies before tests. | No automatic source cutover, false pass or destructive reset. | C/L/P; P00/P12/P13 |
| V18 / P0 | Incoming share review accepts only one financial side | Proposed/private recorded state separated; whole accepted journal changes only after required revision consent. | Pending claim does not become accepted owed/owing or budget alert for one party. | D/B/L/U; P00/P03/P07/P10 |

## 12. Coverage tracking and combinatorial expansion

Maintain a machine-readable or tabular execution register keyed by these stable IDs. Each row may expand into many tests. Required fields: ID, capability, owner, fixture, implementation commit, layers tested, status, command/run ID, artifact and reviewer. A layer skipped for a valid reason must be explained; do not mark the whole row passed from one unit test.

Golden monetary/property tests should vary amount, participant/payer count, zero shares, partial source linkage, rounding ties, date boundaries and revisions. Stateful tests generate create/edit/report/confirm/refund/void/retry sequences and compare a simple independent reference ledger to stored projections. Seed failures for reproducibility. Load/fault tests continuously check the same invariants; a fast wrong result is a failure.

At least these multi-way cases must be named fixtures:

1. Manual source created offline → app killed → server accepted but response lost → SMS arrives → backup restored on another device: one source, one expense, one own cost.
2. Group member removed while offline with an expense edit and pending payment report: preserve private draft; reauthorize report/financial effect; no copied access to other members' bank data.
3. Expense fully settled → partial merchant refund → duplicate-source merge → old client edit: preserve real payments, exact refund obligations and current source identity; block incompatible old financial overwrite.
4. Two devices claim the same shadow person while friends independently record the dinner: bind identity once, review debt separately, consolidate only explicit common identity/review.
5. Context net zero with circular obligations and a pending/overpaid settlement during lease expiry: no false settled state, no duplicate credit, deterministic actual allocations.
6. Replica delayed and report worker replaying while user confirms a settlement then switches accounts: read token/freshness correct, no personal-cost repricing and no cross-account result leakage.
7. Bulk historical import during reconnect/backfill/low disk: no notification storm, bounded work, truthful local save/backup coverage and no cleared existing data.

The lead updates this matrix for each newly discovered production risk. Required unsupported paths are explicitly capability-gated and reviewed; they must not quietly become enabled without their scenario evidence.
