/// Links a refund that names no account to the one earlier spend it can only be
/// returning.
///
/// A refund notice from a wallet or a gateway often says "Refund of Rs X for
/// order ... processed" without any account. The earlier spend of exactly that
/// amount is the original; if there is exactly one such spend in the window the
/// refund is accepted as an inference (so the person is asked), otherwise it is
/// left alone and stays in review.
library;

import '../contract/enums.dart';
import '../contract/fact.dart';

/// How far back a refund looks for its original spend.
const Duration kRefundHistoryWindow = Duration(days: 90);

/// Confidence of a refund accepted from history: below the review bar.
const double kRefundInferredConfidence = 0.6;

const _spendPurposes = {
  MovementPurpose.purchase,
  MovementPurpose.billPayment,
  MovementPurpose.fee,
  MovementPurpose.emi,
};

Set<String> _words(String? s) => {
  for (final w in RegExp(r'[a-z]{4,}').allMatches((s ?? '').toLowerCase()))
    w.group(0)!,
};

/// The single earlier spend of [minor] a refund seen at [at] returns, or null.
///
/// [text] is what the refund says (its body): when the spend names a merchant,
/// that merchant must be mentioned, since a spend at an unrelated merchant is
/// not the original. A spend that names no merchant is not excluded by it.
MovementFact? matchEarlierSpend({
  required int minor,
  required DateTime at,
  required Iterable<MovementFact> history,
  String? text,
}) {
  final want = _words(text);
  final matches = <String, MovementFact>{};
  for (final f in history) {
    if (f.direction != Direction.debit || f.evidenceOnly == true) continue;
    if (!_spendPurposes.contains(f.purpose)) continue;
    final posted = f.amounts.where((a) => a.role == AmountRole.posted);
    if (posted.isEmpty || posted.first.minor != minor) continue;
    final seen = f.effectiveAt;
    if (seen.isAfter(at) || at.difference(seen) > kRefundHistoryWindow) continue;
    final have = _words(f.counterparty?.name);
    if (have.isNotEmpty && want.intersection(have).isEmpty) continue;
    matches[f.sourceKey] = f;
  }
  return matches.length == 1 ? matches.values.single : null;
}
