# Request from WP-03b to WP-02: default `asOf` for a balance_snapshot

**What:** when a rule emits a `balance_snapshot` and the emit gives no `attrs.asOf` (no printed date, no `sameAs`), the engine should set `asOf` to the fact's `occurredAt`, else its `observedAt`. Today `BalanceSnapshotFact` requires `asOf`, so such a rule is rejected when the fact is built (read from `fact.dart`; not run).

**Why:** wallet balance-only messages (for example "Your Paytm wallet balance is Rs 380") print no date, and a rule that emits only a `balance_snapshot` has no earlier emit to point `sameAs` at. 03b therefore emits no standalone wallet balance rule; balances are captured only inside spend and load messages. The same gap affects any other family with undated balance messages.

**Files:** `packages/pandapay_domain/lib/src/sms_v2/engine/rule_engine.dart` (attrs build in `_buildEmit`), with a test in `packages/pandapay_domain/test/sms_v2/engine/engine_test.dart`. No contract change: the fact still carries `asOf`.

**Affects:** WP-02 (engine), WP-03a/03b/03c/03d (rules may then drop the explicit `asOf`).
