import '../../../data/cached_regexp.dart';
import '../../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind, TxnInstrument;
import '../voice_format.dart';

/// A past purchase a refund may belong to.
class RefundCandidate {
  const RefundCandidate({
    required this.transactionId,
    required this.merchant,
    required this.amount,
    required this.occurredAt,
    required this.instrument,
    required this.score,
    this.categoryId,
    this.userCardId,
  });

  final String transactionId;
  final String? merchant;
  final double amount;
  final DateTime occurredAt;
  final TxnInstrument instrument;
  final double score;
  final String? categoryId;
  final String? userCardId;

  /// "Amazon · ₹2,499 · Fri 6 Nov"
  String label(DateTime now) =>
      '${merchant ?? 'Purchase'} · ${VoiceFormat.rupees(amount)} · '
      '${VoiceFormat.day(occurredAt, now)}';
}

/// Finds the purchases a refund most plausibly belongs to: the same shop,
/// at least the refunded amount, within the last [windowDays] days.
class RefundCandidates {
  const RefundCandidates._();

  static List<RefundCandidate> find(
    Iterable<TransactionEntry> transactions, {
    required DateTime now,
    String? merchant,
    double? amount,
    int windowDays = 120,
    int limit = 5,
  }) {
    final from = now.subtract(Duration(days: windowDays));
    final wanted = _words(merchant);
    final out = <RefundCandidate>[];
    for (final t in transactions) {
      if (t.entryKind != TxnEntryKind.spend || t.status != 'active') continue;
      if (t.occurredAt.isBefore(from) || t.occurredAt.isAfter(now)) continue;
      final rupees = t.amount.rupees;
      if (amount != null && rupees < amount - 0.005) continue;
      var score = 0.0;
      if (wanted.isNotEmpty) {
        final have = _words(t.merchantName);
        final overlap = wanted.where(have.contains).length;
        if (overlap == 0) continue;
        score += 3 + overlap * 0.5;
      }
      if (amount != null) {
        score += (rupees - amount).abs() < 0.005 ? 3 : 1;
      }
      out.add(
        RefundCandidate(
          transactionId: t.id,
          merchant: t.merchantName,
          amount: rupees,
          occurredAt: t.occurredAt,
          instrument: t.instrument,
          score: score,
          categoryId: t.categoryId,
          userCardId: t.userCardId,
        ),
      );
    }
    out.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : b.occurredAt.compareTo(a.occurredAt);
    });
    return out.take(limit).toList();
  }

  static Set<String> _words(String? text) => (text ?? '')
      .toLowerCase()
      .split(cachedRegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2)
      .toSet();
}
