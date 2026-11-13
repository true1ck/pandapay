# Rewards fix — 13 Nov 2026 (branch `rewards-fix`, cut from `dev`)

Nothing here is pushed, merged or deployed. No database migration.

## What was wrong (found by replaying a real inbox and the live catalogue)

| # | Problem | Where |
|---|---|---|
| 1 | A spend older than one day when captured was "history"; the server skipped reward state for it, so it never got a reward and was never repriced. | `sms_v2_runtime.dart`, `sms_v2/storage.js`, `card_state_v2.js` |
| 2 | A refunded purchase kept its reward (a refund was a separate row that never touched the original). | `card_state_v2.js` |
| 3 | 306 of 419 catalogue cards had bonus rules switched to "info only" by the loader; MoneyBack+ 10X (the 2,500-point case) was one, because of an `emi_excluded` flag the loader did not understand. | `catalogue_v2/conditions.js` |
| 4 | "Reward Points Credited: 2500 …" was ignored; credited points that did parse went nowhere. | `rules/sms/v2`, `reward_credits.js` |
| 5 | The bank's cashback credit was stored as income from "UNKNOWN". | `projection_writer.dart`, `sms_v2/projection.js` |
| 6 | Cut-short merchant names (`PYU*Flipkar`, `Flipka`, `<STATION> PETROLEU`) did not resolve, so Flipkart earned 1% instead of 5% and fuel was not excluded. | `merchant_directory.js` + Dart twin, `category_rules.json` |
| 7 | A refund the bank never texted about (a large Axis spend) left no trace except the card's available limit. | `silent_refund.dart`, banner |
| 8 | Reward display: "Pending confirmation" on every SMS row, no per-transaction reward, cashback cards shown as "pts". | activity / card detail screens |
| 9 | The card screen's points tile read the user-typed starting balance first. The server always sends it (0 by default), so the tile said "0 pts" / "₹0 cashback" while the card had earned points. Found on the emulator, the voice "how many points" answer had the same flaw. | `card_detail_screen.dart`, `voice_answer_service.dart` |

## What changed

**Server**
- History spends earn rewards. `reconcileIfV2` (run on every wallet read) prices unpriced history once, replaying in date order so every month keeps its own caps; writes are bulk. v1-shaped cards are priced oldest-first, 300 per read. Uploads flagged `backfill` are priced by one rebuild per card.
- Refund netting (`refund_matching.js`): a refund is paired with the purchase it reverses (same card, not earlier than the purchase, ≤180 days, merchant equal or cut short, or exact amount); the purchase is priced on what is left. Ignoring/restoring a refund is picked up on the next wallet read.
- Payment-gateway merchants (`PYU*`, `RAZ*`, `PHP*`, "Razorpay" …) are priced as online when the SMS stated no rail.
- Bank-credited points go to `points_ledger` as `confirmed` rows (reason `issuer credit`, idempotent per fact) and are returned as `credited_points`; they are left out of `total_points_earned` so points are not counted twice.
- Cashback credits are stored as `Cashback received`, `reward_state = confirmed`.

**Catalogue loader**: `emi_excluded`-style flags become an EMI exclusion (the engine already models it). A "domestic"/"international" region condition stays a blocker on purpose: a user-confirmed foreign payment is recorded as an ordinary card spend, so the engine cannot assume everything it prices is domestic. Takes effect at the next catalogue import.

**SMS rules** (bundle, reach phones without an app update): `REW-CREDITED-LABEL-CARD` (label-first points credit), `AXIS-CARD-SPEND-INR-B-LIM` (Axis spend SMS now also yields the available-limit reading), category rules for cut-short fuel/Flipkart names. A cash-only voucher ("unlocked your INR 500 Gift Voucher") cannot be a `reward` fact under the frozen contract (it needs points), so it stays ignored; the voucher milestone is tracked from spend instead.

**App**: reward line on the transaction screen (every payment method gets an honest line), `Reward ≈ ₹X` chip on activity rows, cashback cards show ₹ not "pts", "Bank credited N pts" line, "Was this refunded?" banner for silent refunds (Yes = the existing refund action).

## Owner steps after deploying (none are automatic)

1. Deploy normally (fix on `dev` → merge into `prod`). No migration.
2. Re-import + publish the catalogue so the loader fix reaches the data, then `node api/scripts/recompute_card_state.js --apply` (the existing runbook).
3. History is repriced lazily on the next wallet read; to do it for everyone at once run `node api/scripts/recompute_card_state.js --apply --since 2024-01-01`.

## Verified

- Replay of a real inbox of about 6,000 SMS: the 2,500-point credit SMS is now a reward fact on its card; exactly one silent refund is suggested (a large Axis spend), no false positives; no other message changed decision.
- Edge-case review pass (second sweep): milestone/voucher progress and fee-waiver progress are now rebuilt from history too; the history catch-up runs in its own savepoint (a failure falls back to the old behaviour); issuer-credit idempotency is keyed by SMS identity, not fact id; offer-style SMS ("on spending", "T&C") are rejected by the reward-credit rules; a refund no longer pairs with a different named shop; the debit-card variant is excluded.
- On an Android emulator (debug build of this branch, local API + Postgres): a Rs2,000 Flipkart spend on the Axis Flipkart card priced at Rs100 (5%). Home "Rewards earned" Rs100, My Cards "₹100 cashback earned", the Rs4,000/quarter cap bar at Rs100, the transaction screen "Reward ≈ ₹100.00 · Estimated from your card's rules", and the activity row "Reward ≈ ₹100". The same pass caught the points-tile bug (row 9 above); after the fix the card screen's tile reads "₹100 cashback" on the device too.
- Real-card rules (`api/test/real_cards_rewards.test.js`, made-up amounts): Axis 5% on Flipkart rounded down to the rupee; HDFC MoneyBack+ base points plus the 2,500-point 10X bonus cap; slice 1% incl. UPI.

## Not done / limits

- Postgres: the CI Postgres suites (`scripts/test_postgres_suites.sh`, PostgreSQL 16 in Docker) pass for the API/SMS v2 `_pg` suites (72/72) and shared expenses (42/42). Two fixtures fail for reasons unrelated to this change (`db/` is untouched): `account_recovery_drop` needs PostgreSQL 18, and `reviewed_index_reconciliation` fails on the PG 16 test server. `card_state_v2_postgres.test.js` is NOT part of that CI script; run it by hand (needs `CARD_STATE_V2_TEST_URL`, migrations, and `seed_merchant_directory.js --apply`): 17 pass, 2 skip (real cards not imported). Running it found two bugs in the first version of this change (ignored refund not re-priced; a spend with a record but no price never re-priced), both fixed.
- Refund netting covers v2-shaped cards (all published catalogue cards); a legacy v1-shaped card does not net refunds.
- Card rail (online / POS) is still unknown except UPI and gateway merchants; cashback bonuses that need "online" only apply for those.
- Gift-card purchases look like normal Flipkart purchases to the SMS; Axis pays nothing on them, so the estimate can over-state until the purchase is marked refunded/ignored.
- `slice.json` SMS rules in the owner's working tree are uncommitted and were not touched.
