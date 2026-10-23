import 'package:pandapay_domain/pandapay_domain.dart';
import 'user_cards_repository.dart';

class LiveRefundMatchResult {
  final String debitTxnId;
  final Money originalDebitAmount;
  final Money refundAmount;
  final Money netAmount;
  final int daysApart;

  const LiveRefundMatchResult({
    required this.debitTxnId,
    required this.originalDebitAmount,
    required this.refundAmount,
    required this.netAmount,
    required this.daysApart,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveRefundMatchResult &&
          runtimeType == other.runtimeType &&
          debitTxnId == other.debitTxnId &&
          originalDebitAmount == other.originalDebitAmount &&
          refundAmount == other.refundAmount &&
          netAmount == other.netAmount &&
          daysApart == other.daysApart;

  @override
  int get hashCode =>
      debitTxnId.hashCode ^
      originalDebitAmount.hashCode ^
      refundAmount.hashCode ^
      netAmount.hashCode ^
      daysApart.hashCode;

  @override
  String toString() =>
      'LiveRefundMatchResult(debitTxnId: $debitTxnId, originalDebitAmount: $originalDebitAmount, refundAmount: $refundAmount, netAmount: $netAmount, daysApart: $daysApart)';
}

class AdjustmentMatcher {
  /// Attempts to pair an incoming refund credit with an active spend transaction
  /// that occurred 0 to 30 days prior (or up to 12 hours after for clock skew).
  static LiveRefundMatchResult? findMatchingDebit({
    required Money refundAmount,
    required String refundMerchant,
    required DateTime refundDate,
    required List<TransactionEntry> candidateDebits,
  }) {
    if (refundAmount.paise <= 0 || candidateDebits.isEmpty) return null;
    final rTokens = _tokenize(refundMerchant);

    LiveRefundMatchResult? bestMatch;
    int bestTokenOverlap = 0;
    int closestAmountDelta = 1 << 30;
    int closestTimeDelta = 1 << 30;

    for (final debit in candidateDebits) {
      if (debit.entryKind != TxnEntryKind.spend) continue;
      // Asymmetric window: debit must be 0 to 30 days prior to refund (with 12h clock skew allowance)
      final diff = refundDate.difference(debit.occurredAt);
      if (diff.inHours < -12 || diff > const Duration(days: 30)) continue;
      if (refundAmount.paise > debit.amount.paise) continue;

      final dTokens = _tokenize(debit.merchantName ?? '');
      final overlap = rTokens.where((t) => dTokens.contains(t)).length;
      final match = overlap > 0 || (rTokens.isEmpty && dTokens.isEmpty);
      if (!match) continue;

      final amountDelta = debit.amount.paise - refundAmount.paise;
      final timeDelta = diff.inSeconds.abs();
      if (overlap > bestTokenOverlap ||
          (overlap == bestTokenOverlap && amountDelta < closestAmountDelta) ||
          (overlap == bestTokenOverlap &&
              amountDelta == closestAmountDelta &&
              timeDelta < closestTimeDelta)) {
        bestTokenOverlap = overlap;
        closestAmountDelta = amountDelta;
        closestTimeDelta = timeDelta;
        bestMatch = LiveRefundMatchResult(
          debitTxnId: debit.id,
          originalDebitAmount: debit.amount,
          refundAmount: refundAmount,
          netAmount: Money.fromPaise(amountDelta),
          daysApart: (diff.inHours / 24).round().clamp(0, 30),
        );
      }
    }
    return bestMatch;
  }

  static Set<String> _tokenize(String text) {
    final clean = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    return clean
        .split(RegExp(r'\s+'))
        .where((t) =>
            t.length >= 3 &&
            !const [
              'refund',
              'reversal',
              'cashback',
              'payment',
              'txn',
              'bank',
              'card',
            ].contains(t))
        .toSet();
  }
}
