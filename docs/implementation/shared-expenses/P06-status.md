# P06: existing-form expansion and exact editable calculations

Owner: root, after command/API worker capacity ended. Baseline `sms-v2/integration`, dependency `a120130c` plus the P01/P03/P05 integration under review. Status: **implementing**, calculation foundation verified; existing-form save/source integration remains incomplete. No other writer currently owns these files.

Calculation checkpoint: **`731806dd`**. Integrated dependencies: server `941aeffb`, local/HTTP/recovery `360110fd`, gated runtime/navigation `a6991f61`. These are local commits only. Use their packet contracts and retained failing/passing evidence before extending the editor; no new source-guard migration or source-funded save path exists yet.

## Delivered calculation sub-increment

- `app/lib/features/shared_expenses/composer/shared_amount_input.dart`: bounded ASCII decimal input with distinct empty/incomplete/valid/invalid states. Convert rupee text to paise using BigInt; never round a fractional paisa or keep a previous valid value after an invalid edit. Integer formatting avoids a rupee-double roundtrip.
- `shared_draft.dart`: immutable editable bill/shared values, stable persisted membership order, selected participants, per-payer full/shared contributions and equal/exact/percentage/shares fields. Snapshot rows and input collections are detached/frozen. The draft emits no bank transaction and exposes no save/post operation.
- Full contributions equal the full bill; shared contributions equal the shared amount; each shared contribution cannot exceed its payer's full payment. Own residual equals own full payment minus own shared contribution. Own personal cost equals that residual plus own share. Another payer's residual is never assigned to the user.
- Example: bill ₹1,400, shared ₹1,200, three equal shares. Own payer: paid ₹1,400 / shared contribution ₹1,200 / own residual ₹200 / own share ₹400 / personal cost ₹600. Friend payer: own payment/residual ₹0 / own share and personal cost ₹400. Rewards and bank/card balances are untouched.
- Typed source references remain attached to source-origin intents. Disabled funding, missing canonical/current fingerprint or unconfirmed valuation blocks the local proposal gate. Server authorization/consent remains mandatory even if local validation passes. New own-payment intent cannot silently become unlinked cash/friend-paid intent.

## Evidence

Tests were written first and failed on missing modules. **16 draft tests passed** after implementation. An added mutable-roster case reproduced a one-paisa tie-order drift, then passed after detaching the order input. Combined root runtime + draft suite: **23 passed**. No UI/backend/device completion claim follows from this pure preview.

Run from `app` with current locked dependencies:

```powershell
dart C:\flutter\flutter\bin\cache\flutter_tools.snapshot test --no-pub --concurrency=1 test/features/shared_expenses/data/shared_draft_test.dart --reporter expanded
```

The sandbox uses the direct Dart SDK executable, repository-local `.flutter-direct-appdata3` APPDATA/LOCALAPPDATA and `.pub-cache`. Do not treat the initial missing-module test or the aborted widget HTTP timing attempt as a passing result.

## Next implementation gates

1. Reuse existing Quick Add amount/merchant/category/tag/date/receipt owner and transaction detail split action. Embed sharing controls; no separate global form, duplicated source transaction or new bottom destination.
2. Persist full-bill metadata separately from shared financial snapshot before shipping partial sharing. Current server snapshot total is shared total; never relabel that as full bill total. Current runtime correctly says Shared total when full bill metadata is unavailable.
3. Source admission/registration/budget guards, source-writer correction/retraction safety and immutable own-source-plus-expense orchestration precede a source-funded save path. Preserve a recoverable source-saved/split-pending state rather than dropping the source reference.
4. Add current member/payer pickers, whole-revision review, pending/conflicted operations and in-context navigation. Draft validation does not infer a person from private legacy notes or convert old split documents automatically.
5. Complete authoritative personal-cost recognition/report integration exactly once; never recompute purchase rewards, card caps or issuer liability from shares. Include narrow/large-text/keyboard/privacy/rendered Bamboo-font checks and actual signed-in emulator verification after implementation.

No migration/deployment, existing bank/reward writes, source cutover or device install was performed by this sub-increment. Capability gates remain off.
