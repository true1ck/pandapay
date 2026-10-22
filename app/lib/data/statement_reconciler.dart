import 'package:pandapay_domain/pandapay_domain.dart';
import 'import_models.dart';
import 'indian_narration_sanitizer.dart';

/// Represents a matched debit and refund/reversal pair within a statement window.
class RefundNettingPair {
  final ParsedStatementLine debitLeg;
  final ParsedStatementLine creditLeg;
  final Money netCost;
  final int daysApart;

  const RefundNettingPair({
    required this.debitLeg,
    required this.creditLeg,
    required this.netCost,
    required this.daysApart,
  });
}

/// Represents two matched reciprocal legs of an internal self-transfer.
class InternalTransferPair {
  final ParsedStatementLine debitLeg;
  final ParsedStatementLine creditLeg;
  final Money amount;
  final int hoursApart;

  const InternalTransferPair({
    required this.debitLeg,
    required this.creditLeg,
    required this.amount,
    required this.hoursApart,
  });
}

/// Result of mathematical statement reconciliation.
class StatementReconciliationResult {
  final Money? openingBalance;
  final Money? closingBalance;
  final Money totalDebits;
  final Money totalCredits;
  final Money netMovement;
  final Money? discrepancy;
  final bool isBalanced;
  final bool ruleOf9TranspositionDetected;
  final List<String> findings;
  final List<RefundNettingPair> refundPairs;
  final List<InternalTransferPair> transferPairs;

  const StatementReconciliationResult({
    this.openingBalance,
    this.closingBalance,
    required this.totalDebits,
    required this.totalCredits,
    required this.netMovement,
    this.discrepancy,
    required this.isBalanced,
    required this.ruleOf9TranspositionDetected,
    required this.findings,
    required this.refundPairs,
    required this.transferPairs,
  });
}

/// Mathematical reconciliation engine for bank statements, PDF parser rows,
/// running balance integrity checks, 30-day refund netting, and reciprocal transfer pairing.
class StatementReconciler {
  /// Reconciles parsed statement lines against optional opening and closing balances.
  static StatementReconciliationResult reconcile({
    required List<ParsedStatementLine> lines,
    Money? openingBalance,
    Money? closingBalance,
  }) {
    var debitsPaise = 0;
    var creditsPaise = 0;

    for (final line in lines) {
      if (line.isCredit) {
        creditsPaise += line.amount.paise;
      } else {
        debitsPaise += line.amount.paise;
      }
    }

    final totalDebits = Money.fromPaise(debitsPaise);
    final totalCredits = Money.fromPaise(creditsPaise);
    final netMovement = Money.fromPaise(creditsPaise - debitsPaise);

    Money? discrepancy;
    var isBalanced = true;
    var ruleOf9 = false;
    final findings = <String>[];

    if (openingBalance != null && closingBalance != null) {
      final expectedClosingPaise = openingBalance.paise + creditsPaise - debitsPaise;
      final diffPaise = (expectedClosingPaise - closingBalance.paise).abs();
      discrepancy = Money.fromPaise(diffPaise);

      if (diffPaise == 0) {
        isBalanced = true;
        findings.add('Mathematical reconciliation verified: Opening + Credits - Debits == Closing.');
      } else {
        isBalanced = false;
        final rupeesDiff = (diffPaise / 100).round();
        if (rupeesDiff > 0 && rupeesDiff % 9 == 0) {
          ruleOf9 = true;
          findings.add(
            'Discrepancy of ₹${(diffPaise / 100).toStringAsFixed(2)} detected. Discrepancy is divisible by 9, indicating a probable digit transposition error in OCR.',
          );
        } else {
          findings.add(
            'Discrepancy of ₹${(diffPaise / 100).toStringAsFixed(2)} detected between running transactions and closing balance.',
          );
        }
      }
    }

    final refundPairs = findRefundPairs(lines);
    if (refundPairs.isNotEmpty) {
      findings.add('Identified ${refundPairs.length} netted refund/reversal pair(s).');
    }

    final transferPairs = findReciprocalTransfers(lines);
    if (transferPairs.isNotEmpty) {
      findings.add('Identified ${transferPairs.length} reciprocal internal transfer pair(s).');
    }

    return StatementReconciliationResult(
      openingBalance: openingBalance,
      closingBalance: closingBalance,
      totalDebits: totalDebits,
      totalCredits: totalCredits,
      netMovement: netMovement,
      discrepancy: discrepancy,
      isBalanced: isBalanced,
      ruleOf9TranspositionDetected: ruleOf9,
      findings: findings,
      refundPairs: refundPairs,
      transferPairs: transferPairs,
    );
  }

  /// Finds credit refunds that match an earlier debit at the same merchant within a 30-day window.
  static List<RefundNettingPair> findRefundPairs(List<ParsedStatementLine> lines) {
    final pairs = <RefundNettingPair>[];
    final debits = lines.where((l) => !l.isCredit).toList();
    final credits = lines.where((l) => l.isCredit).toList();
    final claimedCredits = <int>{};

    for (final debit in debits) {
      final debitMerchant = _normalizedMerchant(debit.description);
      if (debitMerchant.isEmpty) continue;

      for (var i = 0; i < credits.length; i++) {
        if (claimedCredits.contains(i)) continue;
        final credit = credits[i];

        final creditMerchant = _normalizedMerchant(credit.description);
        final isRefundDesc = credit.description.toLowerCase().contains('refund') ||
            credit.description.toLowerCase().contains('reversal') ||
            credit.isTransfer;

        // Same merchant or refund description matching merchant
        final merchantMatch = debitMerchant == creditMerchant ||
            (creditMerchant.isNotEmpty &&
                (debitMerchant.contains(creditMerchant) || creditMerchant.contains(debitMerchant)));

        if (!merchantMatch && !isRefundDesc) continue;

        // Window: refund must occur after debit, within 30 days (720 hours)
        final diffHours = credit.date.difference(debit.date).inHours;
        if (diffHours < -2 || diffHours > 720) continue;

        // Refund amount must not exceed original debit
        if (credit.amount.paise <= debit.amount.paise) {
          claimedCredits.add(i);
          pairs.add(
            RefundNettingPair(
              debitLeg: debit,
              creditLeg: credit,
              netCost: Money.fromPaise(debit.amount.paise - credit.amount.paise),
              daysApart: (diffHours / 24).round().clamp(0, 30),
            ),
          );
          break;
        }
      }
    }

    return pairs;
  }

  /// Pairs internal transfers where money moves from Account A to Account B within 48 hours.
  static List<InternalTransferPair> findReciprocalTransfers(List<ParsedStatementLine> lines) {
    final pairs = <InternalTransferPair>[];
    final debits = lines.where((l) => !l.isCredit && l.isTransfer).toList();
    final credits = lines.where((l) => l.isCredit && l.isTransfer).toList();
    final claimedCredits = <int>{};

    for (final debit in debits) {
      for (var i = 0; i < credits.length; i++) {
        if (claimedCredits.contains(i)) continue;
        final credit = credits[i];

        // Exact amount
        if (debit.amount.paise != credit.amount.paise) continue;

        // Time window: within 48 hours
        final diffHours = (debit.date.difference(credit.date).inHours).abs();
        if (diffHours <= 48) {
          claimedCredits.add(i);
          pairs.add(
            InternalTransferPair(
              debitLeg: debit,
              creditLeg: credit,
              amount: debit.amount,
              hoursApart: diffHours,
            ),
          );
          break;
        }
      }
    }

    return pairs;
  }

  static String _normalizedMerchant(String desc) {
    final sanitized = IndianNarrationSanitizer.sanitize(desc);
    return sanitized.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }
}
