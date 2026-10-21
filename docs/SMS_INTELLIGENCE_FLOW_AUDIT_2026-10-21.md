# SMS intelligence flow audit — 21 Oct 2026

Audit of the implemented system against the planned flow (master plan §3–§8 and
the attached diagram). One question per box: is it implemented, wired end to
end, and does it run in production today?

Legend: **done** = implemented and reachable · **partial** = implemented but a
link is missing · **missing** = not implemented · **off** = implemented but
deliberately not enabled in production.

## 1. The flow, box by box

| # | Diagram box | State | Evidence |
|---|---|---|---|
| 1 | New SMS arrives | **done** | Broadcast receiver + incremental inbox scanner + backup import: `app/lib/features/sms_import/sms_listener_service.dart`, `sms_inbox_scanner.dart` |
| 2 | On-device safety and relevance filter | **done** | `sms_text_hint.dart`: `looksLikeTransactionSms` (strict) and `capturesFinancialSms` (widened to mandate/failed-attempt/bill families); OTP, security and promotion vetoes are absolute |
| 3 | OTP / offer / unrelated → ignore as transaction | **done** | `_looksOtpOrSecurity`, `_looksPromotional`; verified by corpus tests on both sides |
| 4 | Apply downloaded shared rules + user-specific rules | **missing** | The device classifier is `app/lib/data/local_sms_parser.dart` — hardcoded rules, no bundle. No rule-pack table, endpoint or client download exists anywhere (`git grep rule_pack\|rule_bundle` → no hits in `app/`, `api/`, `db/`). User-specific rules exist only as *corrections* (`fact_overrides` server-side, `sms_facts_outbox` override queue device-side), not as reusable patterns. |
| 5 | Strong rule match + required fields valid? | **done** | `LocalSmsParser.parse` → typed `LocalSmsObservation` (event type, amount/date roles, card suffix, confidence); the server mirrors it in `api/src/sms_parser.js` |
| 6 | Auto-classify and save transaction | **done** | Device saves the observation + a provisional transaction (`financial_store.saveObservation` / `saveProvisional`); the server materialises the confirmed row from the same source key (`POST /transactions/from-sms`) or from typed facts (`POST /sms/facts`) |
| 7 | Server checks and Gemini suggestion | **off** | `api/src/ai_queue_route.js`, `gemini_queue.js`, `gemini_worker.js`, `ai_fact_evidence.js` exist and are tested; **disabled in production** — no `GEMINI_API_KEY`/`AI_WORKER_TOKEN`, so acceptance is closed and the worker profile never starts |
| 8 | Validated final confidence | **done** | `ai_fact_evidence.js` validates each result (amount/date roles, lifecycle, identity, duplicate state) before anything is written; no model self-rating is trusted |
| 9 | Needs Review: prefill safe fields, explain uncertainty | **done** | `needs_review_repository.dart` kinds: transaction, commitment, security/service alert, investment settlement, mandate; `needs_review_screen.dart` renders family-specific wording and safe prefill |
| 10 | User decision → save transaction + user correction | **done** | `POST /sms/facts/overrides` → `fact_overrides`; the read path applies overrides before specialists, so a correction outranks a later parser or AI result |
| 11 | Dismiss and record label | **done** | `sms_learning_feedback` (source hash + HMAC sender fingerprint + family + allowlisted field), written only for a profile that opted into contributions |
| 12 | Monitor rule accuracy and corrections | **done** | Console screen `sms_ai_operations_screen.dart` + read-only admin APIs (queue depth/age, batches, quota, provider use, correction candidates). No raw SMS is exposed |
| 13 | Cluster reviewed messages by issuer and wording | **partial** | `pandapay.sms_learning_candidates()` groups confirmed corrections by sender fingerprint + family + field. It clusters *corrections*, not wording structure: there is no template extraction, so the "by wording" step of the diagram is missing |
| 14 | Generate candidate reusable template | **missing** | No template generation anywhere (`candidate_template`, `generateTemplate` → no hits) |
| 15 | Test against positive, negative, historical examples | **missing** | No replay/evaluation harness (`evaluateCandidate`, `promotion_gate` → no hits). The phase-6 report states it plainly: "The signal currently does not train an executable classifier." |
| 16 | Meets promotion gate? | **partial** | `pandapay.sms_learning_decide()` records an admin approve/rollback per candidate, but the gate it applies is "≥5 distinct profiles" — not the diagram's precision gate over positive/negative/historical examples |
| 17 | Publish versioned shared rule | **missing** | No versioned rule-pack artefact. `parser_patterns` remains an admin-authored table used by the server at parse time; nothing is published for devices |
| 18 | Devices download updated rule bundle | **missing** | No download/cache path in the app |
| 19 | Apply downloaded shared rules + user-specific rules (back edge) | **missing** | Follows from 17–18 |

## 2. The two things you emphasised

### Central SMS data, one date everywhere

**Implemented, with one seam left open.**

* One source identity per SMS: `smsSourceKey` (device) and `importSourceKey`
  (server) — user + normalised sender + normalised body. Receipts, the fact
  store and the dedupe index all key on it, so a message has exactly one home
  and every projection reads that one home.
* One typed fact contract across both sides: `api/src/sms_facts.js` (server) and
  `app/lib/data/local/sms_facts_outbox.dart` (device) mint the same fact types
  with the same required fields — `posted_movement`, `balance_snapshot`,
  `bill_obligation`, `bill_payment`, `mandate_lifecycle`,
  `pending_or_failed_attempt`. Amount roles and date roles are separate fields,
  never one collapsed number or one date.
* The dates themselves are now timezone-stable: `api/src/due_date_parser.js`
  pins every parsed statement/due date to IST midnight regardless of the host
  timezone, so the same SMS yields the same date on the phone, in CI and in
  production. (This was the bug behind the API CI failure earlier today.)

**Seam:** the device keeps its own `sms_observations` and the server keeps
`sms_sources` / `sms_source_facts`. The device is the source of truth for raw
context; the server is the source of truth for materialised projections. The
contract keeps them consistent, but there is no single physical store — a
phone-only capture never reaches the server unless a fact is minted and
uploaded, and a server-side parse never returns the raw body to the device.

### Classifier on the device

**Implemented for the local rules; not for shared ones.**

* The device classifies first: `LocalSmsParser` decides event type, amount
  roles, date roles, card suffix and confidence, and only then does anything
  leave the phone. Gemini is a fallback for unresolved facts, never a
  prerequisite — the flow works fully offline.
* The device now also mints typed facts (`sms_facts_outbox.dart`) and posts
  them to `/sms/facts`, so the server's projections come from the same
  classification the user already saw on the phone.
* What the device does **not** do: apply a *downloaded* rule. Its rules are
  compiled into the app, so improving the shared parser requires a new app
  build. The diagram's back edge (published rule → device bundle → better
  local classification) does not exist yet.

## 3. What is running in production today

* Deployed: `a686742` (server AutoPay bill-notice parity fix), preceded by
  `179315f` (recurring-screen 500 fix, deploy role-script fix) and `38e400f`
  (IST date pinning).
* Gemini path: **off** (no provider key on the host; acceptance closed).
* AI queue tables and learning tables: migrated ✓ (deploy applies migrations;
  the DB gate passes locally against a throwaway Postgres with the real
  migrations — all 8 SQL test files pass, including the new SMS-AI RLS, worker
  lease and provider-capacity test).
* Verified on the physical phone (`ZA222MS4SF`): 6 bank accounts (the SBIUPI
  phantom is gone), Tata Neu bill ₹8,331 due 08 Nov, Flipkart Axis ₹2,147 due
  02 Nov, SMS-evidence panel on transaction detail.

## 4. The gap that actually bites the user today

The MoneyBack+ card (••8708) still shows no amount and a wrong due date,
because the seven HDFC AutoPay messages were captured under the old parser
and nothing re-reads history:

* The device parser now reads them correctly (bill, amount, due date) — proven
  against the real captured bodies.
* The server parser now agrees (the AutoPay alert is no longer a ₹10,944
  spend — that was the corruption).
* But captured messages are marked `processed=1` and never re-parsed, and the
  version-gated review replay aborts on the first message the server refuses,
  so the ~1 073 open review items are never re-examined. Fix in this branch:
  a rejected message is skipped instead of stopping the pass
  (`reviewReplayShouldStop` in `app/lib/app/providers.dart` + its test).

Once that replay completes, the AutoPay reminders reach the server, the card's
`due_day` is learned from them (8 or 9, not 20), and the MoneyBack row shows
a real due date instead of the invented one.

## 5. Order of work to finish the diagram

1. **Close the live loop** (in progress): review replay no longer blocked →
   MoneyBack due date learned from the AutoPay evidence.
2. **Central store, one physical home** (plan §4): decide whether the device
   or the server owns the canonical SMS record and make the other a
   projection. Today the contract makes them agree, but there are two stores.
3. **Rule distribution** (diagram 17–19): a versioned rule pack the server
   publishes and the device downloads and caches, so a parser improvement
   reaches phones without an app release.
4. **Learning loop** (diagram 13–16): template extraction from reviewed
   messages, a replay/evaluation harness over positive, negative and
   historical examples, and a precision gate that can actually promote a
   candidate into the rule pack of step 3.
