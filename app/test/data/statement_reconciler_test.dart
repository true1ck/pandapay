import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay/data/statement_reconciler.dart';

void main() {
  group('StatementReconciler', () {
    test('verifies mathematical reconciliation when opening + credits - debits == closing', () {
      final lines = [
        ParsedStatementLine(
          date: DateTime(2026, 10, 1),
          description: 'SALARY CREDIT',
          amount: Money.fromRupees(50000),
          isCredit: true,
          isTransfer: false,
          isInvestment: false,
        ),
        ParsedStatementLine(
          date: DateTime(2026, 10, 2),
          description: 'SWIGGY BANGALORE',
          amount: Money.fromRupees(1200),
          isCredit: false,
          isTransfer: false,
          isInvestment: false,
        ),
        ParsedStatementLine(
          date: DateTime(2026, 10, 3),
          description: 'AMAZON PAY INDIA',
          amount: Money.fromRupees(3800),
          isCredit: false,
          isTransfer: false,
          isInvestment: false,
        ),
      ];

      // Opening = 10,000; Credits = 50,000; Debits = 5,000; Closing = 55,000
      final result = StatementReconciler.reconcile(
        lines: lines,
        openingBalance: Money.fromRupees(10000),
        closingBalance: Money.fromRupees(55000),
      );

      expect(result.isBalanced, isTrue);
      expect(result.discrepancy?.paise, equals(0));
      expect(result.totalCredits.rupees, equals(50000));
      expect(result.totalDebits.rupees, equals(5000));
      expect(result.netMovement.rupees, equals(45000));
      expect(result.ruleOf9TranspositionDetected, isFalse);
    });

    test('detects Rule of 9 OCR transposition error when digits are swapped', () {
      final lines = [
        ParsedStatementLine(
          date: DateTime(2026, 10, 1),
          description: 'STORE PURCHASE',
          // Actual debit was 540, but OCR read 450 (diff 90)
          amount: Money.fromRupees(450),
          isCredit: false,
          isTransfer: false,
          isInvestment: false,
        ),
      ];

      // Opening = 10,000; Closing was 9,460 (10000 - 540); but with 450 expected closing is 9,550 (diff 90)
      final result = StatementReconciler.reconcile(
        lines: lines,
        openingBalance: Money.fromRupees(10000),
        closingBalance: Money.fromRupees(9460),
      );

      expect(result.isBalanced, isFalse);
      expect(result.discrepancy?.rupees, equals(90));
      expect(result.ruleOf9TranspositionDetected, isTrue);
      expect(result.findings.any((f) => f.contains('Rule of 9') || f.contains('transposition')), isTrue);
    });

    test('pairs debits with credit refunds within 30 days', () {
      final debit = ParsedStatementLine(
        date: DateTime(2026, 10, 5, 14, 0),
        description: 'AMAZON SELLER BANGALORE',
        amount: Money.fromRupees(2499),
        isCredit: false,
        isTransfer: false,
        isInvestment: false,
      );

      final refund = ParsedStatementLine(
        date: DateTime(2026, 10, 9, 10, 0),
        description: 'REFUND AMAZON SELLER',
        amount: Money.fromRupees(2499),
        isCredit: true,
        isTransfer: true,
        isInvestment: false,
      );

      final lines = [debit, refund];
      final pairs = StatementReconciler.findRefundPairs(lines);

      expect(pairs.length, equals(1));
      expect(pairs.first.debitLeg, equals(debit));
      expect(pairs.first.creditLeg, equals(refund));
      expect(pairs.first.netCost.paise, equals(0));
      expect(pairs.first.daysApart, equals(4));
    });

    test('pairs reciprocal internal transfers between accounts within 48 hours', () {
      final outLeg = ParsedStatementLine(
        date: DateTime(2026, 10, 12, 10, 0),
        description: 'TRANSFER TO SAVINGS A/C',
        amount: Money.fromRupees(15000),
        isCredit: false,
        isTransfer: true,
        isInvestment: false,
      );

      final inLeg = ParsedStatementLine(
        date: DateTime(2026, 10, 12, 11, 30),
        description: 'TRANSFER FROM SALARY A/C',
        amount: Money.fromRupees(15000),
        isCredit: true,
        isTransfer: true,
        isInvestment: false,
      );

      final lines = [outLeg, inLeg];
      final pairs = StatementReconciler.findReciprocalTransfers(lines);

      expect(pairs.length, equals(1));
      expect(pairs.first.amount.rupees, equals(15000));
      expect(pairs.first.hoursApart, equals(1));
    });
  });
}
