import 'dart:math';
import 'package:pandapay_domain/pandapay_domain.dart';
import '../data/flashtext_merchant_extractor.dart';
import '../data/indian_narration_sanitizer.dart';

/// Recurrence cadence categories for detected recurring payments.
enum RecurrenceCadence {
  weekly,
  fortnightly,
  monthly,
  quarterly,
  halfYearly,
  annual,
  custom,
}

/// Type of recurrence: fixed amount (SaaS, OTT) vs variable amount (utilities, metered).
enum RecurrenceAmountType {
  fixed,
  variableMetered,
}

/// A detected recurring subscription or commitment.
class DetectedRecurrence {
  final String merchantKey;
  final String displayName;
  final String category;
  final RecurrenceCadence cadence;
  final int cadenceDays;
  final RecurrenceAmountType amountType;
  final Money typicalAmount;
  final Money minAmount;
  final Money maxAmount;
  final DateTime lastOccurredOn;
  final DateTime nextExpectedOn;
  final double confidenceScore;
  final int occurrenceCount;

  const DetectedRecurrence({
    required this.merchantKey,
    required this.displayName,
    required this.category,
    required this.cadence,
    required this.cadenceDays,
    required this.amountType,
    required this.typicalAmount,
    required this.minAmount,
    required this.maxAmount,
    required this.lastOccurredOn,
    required this.nextExpectedOn,
    required this.confidenceScore,
    required this.occurrenceCount,
  });

  @override
  String toString() =>
      'DetectedRecurrence($displayName, cadence: ${cadence.name}, typical: ₹${typicalAmount.rupees}, next: $nextExpectedOn)';
}

/// Input historical transaction row for recurrence analysis.
class RecurrenceTransactionInput {
  final String id;
  final String merchantName;
  final Money amount;
  final DateTime occurredAt;
  final bool isDebit;
  final String? categoryHint;

  const RecurrenceTransactionInput({
    required this.id,
    required this.merchantName,
    required this.amount,
    required this.occurredAt,
    this.isDebit = true,
    this.categoryHint,
  });
}

/// On-device recurrence detection engine.
/// Identifies subscriptions, EMIs, and utility obligations from transaction history.
class RecurrenceEngine {
  static const int minOccurrences = 3;
  static const double amountTolerance = 0.12; // ±12%
  static const double cadenceTolerance = 0.25; // ±25%

  /// Analyzes a list of transaction records and discovers active subscriptions and recurring obligations.
  static List<DetectedRecurrence> detectRecurrences(List<RecurrenceTransactionInput> txns) {
    if (txns.isEmpty) return const [];

    // Filter to completed spending/debits
    final validDebits = txns.where((t) => t.isDebit && t.amount.paise > 0).toList();
    if (validDebits.length < minOccurrences) return const [];

    // Group transactions by normalized merchant series key
    final grouped = <String, List<RecurrenceTransactionInput>>{};
    for (final txn in validDebits) {
      final key = _seriesKey(txn.merchantName);
      if (key.isNotEmpty) {
        grouped.putIfAbsent(key, () => []).add(txn);
      }
    }

    final detected = <DetectedRecurrence>[];

    for (final entry in grouped.entries) {
      final seriesKey = entry.key;
      final rows = entry.value;

      if (rows.length < minOccurrences) continue;

      // Sort chronological
      rows.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));

      // Calculate gaps in days between adjacent transactions
      final gaps = <int>[];
      for (var i = 1; i < rows.length; i++) {
        final days = rows[i].occurredAt.difference(rows[i - 1].occurredAt).inDays;
        if (days > 0) gaps.add(days);
      }

      if (gaps.isEmpty) continue;

      final medianGap = _median(gaps);
      if (medianGap < 6 || medianGap > 400) continue;

      // Check cadence regularity: at least 70% of gaps must fall within cadenceTolerance
      final lowerGapBound = medianGap * (1.0 - cadenceTolerance);
      final upperGapBound = medianGap * (1.0 + cadenceTolerance);
      final regularGaps = gaps.where((g) => g >= lowerGapBound && g <= upperGapBound).length;

      if (regularGaps / gaps.length < 0.65) continue;

      // Check amounts
      final amountsPaise = rows.map((r) => r.amount.paise).toList();
      final medianAmountPaise = _median(amountsPaise);
      final minPaise = amountsPaise.reduce(min);
      final maxPaise = amountsPaise.reduce(max);

      final isFixedAmount = (maxPaise - minPaise) <= (medianAmountPaise * amountTolerance);

      // Resolve merchant metadata and category
      final sampleDesc = rows.last.merchantName;
      final extracted = FlashTextMerchantExtractor.defaultExtractor.extractFirst(sampleDesc);
      final displayName = extracted?.canonicalName ?? _cleanDisplayName(sampleDesc);
      final category = extracted?.category ?? rows.last.categoryHint ?? 'bills';

      final cadence = _classifyCadence(medianGap);
      final lastDate = rows.last.occurredAt;
      final nextExpected = lastDate.add(Duration(days: medianGap));

      // Confidence score calculation
      final occurrenceFactor = min(1.0, rows.length / 5.0);
      final regularityFactor = regularGaps / gaps.length;
      final amountFactor = isFixedAmount ? 1.0 : 0.85;
      final score = (occurrenceFactor * 0.4 + regularityFactor * 0.4 + amountFactor * 0.2);

      detected.add(
        DetectedRecurrence(
          merchantKey: seriesKey,
          displayName: displayName,
          category: category,
          cadence: cadence,
          cadenceDays: medianGap,
          amountType: isFixedAmount ? RecurrenceAmountType.fixed : RecurrenceAmountType.variableMetered,
          typicalAmount: Money.fromPaise(medianAmountPaise),
          minAmount: Money.fromPaise(minPaise),
          maxAmount: Money.fromPaise(maxPaise),
          lastOccurredOn: lastDate,
          nextExpectedOn: nextExpected,
          confidenceScore: double.parse(score.toStringAsFixed(2)),
          occurrenceCount: rows.length,
        ),
      );
    }

    return detected;
  }

  static String _seriesKey(String name) {
    final sanitized = IndianNarrationSanitizer.sanitize(name);
    final match = FlashTextMerchantExtractor.defaultExtractor.extractFirst(sanitized);
    if (match != null) return match.canonicalName.toLowerCase();

    // Strip special characters, numbers and leading words
    final clean = sanitized.replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '').trim().toLowerCase();
    final firstWord = clean.split(RegExp(r'\s+')).first;
    return firstWord.length >= 3 ? firstWord : clean;
  }

  static String _cleanDisplayName(String name) {
    final sanitized = IndianNarrationSanitizer.sanitize(name);
    return sanitized.isEmpty ? name : sanitized;
  }

  static RecurrenceCadence _classifyCadence(int days) {
    if (days >= 6 && days <= 10) return RecurrenceCadence.weekly;
    if (days >= 12 && days <= 18) return RecurrenceCadence.fortnightly;
    if (days >= 25 && days <= 35) return RecurrenceCadence.monthly;
    if (days >= 75 && days <= 105) return RecurrenceCadence.quarterly;
    if (days >= 160 && days <= 200) return RecurrenceCadence.halfYearly;
    if (days >= 330 && days <= 400) return RecurrenceCadence.annual;
    return RecurrenceCadence.custom;
  }

  static int _median(List<int> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isEven ? ((sorted[mid - 1] + sorted[mid]) ~/ 2) : sorted[mid];
  }
}
