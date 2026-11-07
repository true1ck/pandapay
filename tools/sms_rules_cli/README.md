# sms_rules_cli

Command-line tools for the SMS pipeline v2 rules: `redact`, `cluster`, `golden`, `build`, `lint`, `sign-dev`, `fetch-baseline` (see `bin/sms_rules.dart`), plus the private-corpus scorer and replay described below. Run from this folder.

## Private evaluation folder

Real messages never enter the repository. Keep them in one private folder outside the checkout (for example a fresh directory under `/tmp`, owner-only permissions). The scorer refuses paths outside `/tmp`. Files are created with mode 600. Layout, with generic names:

| File | Contents |
| --- | --- |
| `sms.jsonl` | The corpus, one JSON message per line: `sender`, `body`, `observedAt`, optional `iosFilter`. |
| `label-sample.drafted.jsonl` | The labeled sample, one row per line: `message`, `expected`, `sampling_family`, `family_population`, `family_sample`. `expected` carries `reading`, `countsAs`, optional `amount`, `instrumentKind`, `instrumentMask`, `confidence` (`sure` or `unsure`). Labels are drafts, not ground truth. |
| `<bundle>.json` | A rule bundle built with `dart run bin/sms_rules.dart build --rules ../../rules/sms/v2 --bundle-version 0 --created-at <ISO time> --out <private>/<bundle>.json`. |
| `<prefix>-sample-phone.json`, `<prefix>-corpus-phone.json` | Replay output (below). |
| `<report>.json`, `<report>.disagreements.jsonl`, `<report>.disagreements.txt` | Scorer output (below). |

Never paste message bodies, amounts or results from these files into commits or documents.

## Replay: the real phone pipeline over the private corpus

`app/test/tool/sms_private_replay_test.dart` feeds the corpus and the sample through the phone runtime (interpret, instruments, linker, ledger) in an in-memory database and writes, per input, the decision and the events with their ledger rows for every message. It skips unless `SMS_PRIVATE_DIR` is set.

```sh
cd app
SMS_PRIVATE_DIR=/tmp/PRIVATE SMS_BUNDLE=<bundle>.json SMS_REPLAY_PREFIX=<prefix> \
  flutter test --no-pub --concurrency=1 test/tool
```

Optional variables: `SMS_SAMPLE` (default `label-sample.drafted.jsonl`), `SMS_CORPUS` (default `sms.jsonl`), `SMS_REPLAY_CORPUS=0` to replay only the sample, `SMS_OWNER_NAMES` (comma-separated names of the account owner as the profile holds them, so a payment to or from the owner under their own name is read as a transfer between their accounts; leave it unset to see what the phone does with no profile name). The test prints counts only and writes only inside `SMS_PRIVATE_DIR`. Besides outcomes, each report holds invariants: transaction count, totals, open review items, money facts reused by more than one counted event, card-bill and IPO events counted as spending.

## Scorer

```sh
dart run tool/score_private.dart BUNDLE LABELS REPORT [PHONE_OUTCOMES]
```

Without `PHONE_OUTCOMES` the effect of a row is inferred from its single-message fact. With the replay's sample output the effect and amount come from the real ledger. The scoring rules are pure functions in `lib/scoring.dart`.

Reading table: readings come from facts and the rule family, never from rule ids (a `payment_request` is a pending debit attempt with no stated purpose; a `statement` is a bill-due from a rule in family `card_statement`; a `bill_receipt` is an evidence-only bill-payment movement; a `recharge` is one from a rule whose id has a `RCH` segment). `$`, `USD` and `US$` in a body mean USD. An expected `not_financial` agrees with any non-financial reading. An info fact's `amountMinor` is read for the amount check but is never money and never reaches totals.

Headline metrics (reported for `sure` rows and for all rows):

- Weighted accuracy: each row weighs `family_population` divided by the rows of that family in the subset, so the weights of a family sum to its population and the result estimates the whole inbox. Unweighted accuracy is reported beside it.
- Totals-correct: over rows whose expected effect changes totals (spending, money in, refund, investment invested or withdrawn), the share with the right effect and the right amount.
- False counts: over rows whose expected effect does not change totals (`none`, `transfer`), the share that counts in totals anyway, with the money involved.
- Event fidelity per feature (IPO, investments, subscriptions, refunds, by expected reading): the share of rows whose reading, effect, amount and instrument are right and, with a replay, whose counting event has the expected type.

The disagreement export (`.disagreements.jsonl` for tools and `.disagreements.txt` for reading) lists every disagreement with the message, ordered by consequence (false count, wrong effect or amount, missed count, other) and then by weight. Keep it in the private folder.

## Tests

`dart test` runs the CLI tests, including synthetic scorer tests (`test/scoring_test.dart`, `test/score_private_test.dart`) that use invented messages only.
