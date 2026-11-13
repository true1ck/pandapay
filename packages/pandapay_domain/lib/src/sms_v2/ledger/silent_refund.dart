/// Finds refunds the bank never texted about.
///
/// A merchant refund to a credit card often arrives with no SMS at all. The only
/// trace is the card's available limit: it jumps back up although nothing the
/// messages describe (a payment, a refund, a cashback, a limit increase) can
/// explain the jump. When the unexplained rise matches a recent spend, that
/// spend was very probably refunded, and its reward should not be counted.
///
/// This only suggests. It never changes a transaction by itself: the person
/// confirms, and only then is a refund recorded.
///
/// Pure: plain inputs, no clock, no storage.
library;

/// One reading of a card's available limit, in minor units (paise).
class LimitReading {
  const LimitReading({
    required this.instrumentId,
    required this.at,
    required this.availableMinor,
  });
  final String instrumentId;
  final DateTime at;
  final int availableMinor;
}

/// A spend on the card.
class SpendOnCard {
  const SpendOnCard({
    required this.instrumentId,
    required this.eventId,
    required this.at,
    required this.amountMinor,
  });
  final String instrumentId;
  final String eventId;
  final DateTime at;
  final int amountMinor;
}

/// Money the messages DO explain: a card payment, a refund, a cashback, a limit
/// increase, a reversal. Anything that legitimately raises the available limit.
class ExplainedCredit {
  const ExplainedCredit({
    required this.instrumentId,
    required this.at,
    required this.amountMinor,
  });
  final String instrumentId;
  final DateTime at;
  final int amountMinor;
}

/// A spend that was probably refunded without a message.
class SuspectedRefund {
  const SuspectedRefund({
    required this.instrumentId,
    required this.spendEventId,
    required this.spendAmountMinor,
    required this.limitRoseByMinor,
    required this.noticedAt,
  });
  final String instrumentId;
  final String spendEventId;
  final int spendAmountMinor;

  /// How much the available limit rose that no message explains.
  final int limitRoseByMinor;

  /// The time of the reading that showed the rise.
  final DateTime noticedAt;
}

/// Smallest unexplained rise worth asking about (₹500): small drifts from
/// rounding, tiny reversals and delayed postings must not raise a question.
const int silentRefundMinimumMinor = 50000;

/// How close the rise must be to the spend (the rise may fall short by other
/// small spends, or overshoot by a few rupees of reversal).
const double silentRefundLowerRatio = 0.9;
const double silentRefundUpperRatio = 1.05;

/// A spend this old (or older) than the rise is not paired with it.
const Duration silentRefundMaxAge = Duration(days: 120);

/// [readings], [spends] and [credits] may span several cards and arrive in any
/// order. Each spend is suggested at most once, and each rise explains at most
/// one spend.
List<SuspectedRefund> detectSilentRefunds({
  required Iterable<LimitReading> readings,
  required Iterable<SpendOnCard> spends,
  required Iterable<ExplainedCredit> credits,
  Set<String> alreadyRefundedEventIds = const {},
}) {
  final out = <SuspectedRefund>[];
  final used = <String>{...alreadyRefundedEventIds};
  final byInstrument = <String, List<LimitReading>>{};
  for (final r in readings) {
    byInstrument.putIfAbsent(r.instrumentId, () => []).add(r);
  }
  for (final entry in byInstrument.entries) {
    final id = entry.key;
    final list = [...entry.value]..sort((a, b) => a.at.compareTo(b.at));
    final cardSpends = spends.where((s) => s.instrumentId == id).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    final cardCredits = credits.where((c) => c.instrumentId == id).toList();
    for (var i = 1; i < list.length; i++) {
      final before = list[i - 1];
      final after = list[i];
      final rise = after.availableMinor - before.availableMinor;
      if (rise <= 0) continue;
      // What the messages account for between the two readings.
      var explained = 0;
      for (final c in cardCredits) {
        if (c.at.isAfter(before.at) && !c.at.isAfter(after.at)) {
          explained += c.amountMinor;
        }
      }
      final unexplained = rise - explained;
      if (unexplained < silentRefundMinimumMinor) continue;

      SpendOnCard? best;
      for (final s in cardSpends) {
        if (used.contains(s.eventId)) continue;
        if (s.at.isAfter(after.at)) continue;
        if (after.at.difference(s.at) > silentRefundMaxAge) continue;
        final low = (s.amountMinor * silentRefundLowerRatio).floor();
        final high = (s.amountMinor * silentRefundUpperRatio).ceil();
        if (unexplained < low || unexplained > high) continue;
        // Closest in amount wins; the more recent spend breaks a tie.
        if (best == null ||
            (unexplained - s.amountMinor).abs() <
                (unexplained - best.amountMinor).abs() ||
            ((unexplained - s.amountMinor).abs() ==
                    (unexplained - best.amountMinor).abs() &&
                s.at.isAfter(best.at))) {
          best = s;
        }
      }
      if (best == null) continue;
      used.add(best.eventId);
      out.add(
        SuspectedRefund(
          instrumentId: id,
          spendEventId: best.eventId,
          spendAmountMinor: best.amountMinor,
          limitRoseByMinor: unexplained,
          noticedAt: after.at,
        ),
      );
    }
  }
  out.sort((a, b) => a.noticedAt.compareTo(b.noticedAt));
  return out;
}
