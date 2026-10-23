import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/adjustment_matcher.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('AdjustmentMatcher', () {
    test('exact amount refund matching within 30 days', () {
      final debitDate = DateTime(2026, 10, 10, 12, 0);
      final refundDate = DateTime(2026, 10, 14, 15, 30); // 4 days apart

      final candidate = TransactionEntry(
        id: 'txn-swiggy-debit-1',
        amount: Money.fromRupees(500),
        occurredAt: debitDate,
        merchantName: 'Swiggy',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      final match = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(500),
        refundMerchant: 'Swiggy',
        refundDate: refundDate,
        candidateDebits: [candidate],
      );

      expect(match, isNotNull);
      expect(match!.debitTxnId, 'txn-swiggy-debit-1');
      expect(match.originalDebitAmount, Money.fromRupees(500));
      expect(match.refundAmount, Money.fromRupees(500));
      expect(match.netAmount, Money.zero());
      expect(match.daysApart, 4);
    });

    test('partial refund matching (e.g. ₹450 refund for ₹1000 spend)', () {
      final debitDate = DateTime(2026, 10, 1, 10, 0);
      final refundDate = DateTime(2026, 10, 6, 14, 0); // 5 days apart

      final candidate = TransactionEntry(
        id: 'txn-amazon-debit-1',
        amount: Money.fromRupees(1000),
        occurredAt: debitDate,
        merchantName: 'Amazon Seller Services Pvt Ltd',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      final match = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(450),
        refundMerchant: 'Amazon',
        refundDate: refundDate,
        candidateDebits: [candidate],
      );

      expect(match, isNotNull);
      expect(match!.debitTxnId, 'txn-amazon-debit-1');
      expect(match.originalDebitAmount, Money.fromRupees(1000));
      expect(match.refundAmount, Money.fromRupees(450));
      expect(match.netAmount, Money.fromRupees(550));
      expect(match.daysApart, 5);
    });

    test('rejection if refund is older than 30 days or merchant tokens completely differ', () {
      final debitDate = DateTime(2026, 8, 1, 10, 0);
      final refundDate = DateTime(2026, 9, 15, 10, 0); // 45 days later (> 30 days)

      final oldDebit = TransactionEntry(
        id: 'txn-old-swiggy',
        amount: Money.fromRupees(500),
        occurredAt: debitDate,
        merchantName: 'Swiggy',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      // 1. Rejected because older than 30 days
      final oldMatch = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(500),
        refundMerchant: 'Swiggy',
        refundDate: refundDate,
        candidateDebits: [oldDebit],
      );
      expect(oldMatch, isNull);

      // 2. Rejected because merchant tokens completely differ
      final recentUberDebit = TransactionEntry(
        id: 'txn-uber-1',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 9, 12, 10, 0), // 3 days before refund
        merchantName: 'Uber India',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      final differentMerchantMatch = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(500),
        refundMerchant: 'Swiggy',
        refundDate: refundDate,
        candidateDebits: [recentUberDebit],
      );
      expect(differentMerchantMatch, isNull);
    });

    test('handles clock skew up to 12 hours after refund', () {
      final refundDate = DateTime(2026, 10, 15, 10, 0);
      final debitDate = DateTime(2026, 10, 15, 14, 0); // 4 hours after refund

      final candidate = TransactionEntry(
        id: 'txn-skew',
        amount: Money.fromRupees(350),
        occurredAt: debitDate,
        merchantName: 'Flipkart',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      final match = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(350),
        refundMerchant: 'Flipkart Internet',
        refundDate: refundDate,
        candidateDebits: [candidate],
      );

      expect(match, isNotNull);
      expect(match!.debitTxnId, 'txn-skew');
      expect(match.daysApart, 0);
    });

    test('prefers closest amount then closest date when multiple candidates exist', () {
      final refundDate = DateTime(2026, 10, 20, 12, 0);

      final debit1000Older = TransactionEntry(
        id: 'txn-1000-older',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 10, 10, 12, 0), // 10 days ago
        merchantName: 'Zomato',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );
      final debit1000Recent = TransactionEntry(
        id: 'txn-1000-recent',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 10, 18, 12, 0), // 2 days ago
        merchantName: 'Zomato',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );
      final debit500Exact = TransactionEntry(
        id: 'txn-500-exact',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 10, 15, 12, 0), // 5 days ago
        merchantName: 'Zomato',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      // Case 1: Exact amount (₹500) wins even though ₹1000-recent is closer in date
      final matchExact = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(500),
        refundMerchant: 'Zomato',
        refundDate: refundDate,
        candidateDebits: [debit1000Older, debit1000Recent, debit500Exact],
      );
      expect(matchExact, isNotNull);
      expect(matchExact!.debitTxnId, 'txn-500-exact');

      // Case 2: When amounts tie (both ₹1000 for ₹1000 refund), closest date wins
      final matchTied = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(1000),
        refundMerchant: 'Zomato',
        refundDate: refundDate,
        candidateDebits: [debit1000Older, debit1000Recent],
      );
      expect(matchTied, isNotNull);
      expect(matchTied!.debitTxnId, 'txn-1000-recent');
    });

    test('rejects refund exceeding debit amount', () {
      final candidate = TransactionEntry(
        id: 'txn-small',
        amount: Money.fromRupees(300),
        occurredAt: DateTime(2026, 10, 10),
        merchantName: 'Uber',
        source: 'sms',
        status: 'active',
        entryKind: TxnEntryKind.spend,
      );

      final match = AdjustmentMatcher.findMatchingDebit(
        refundAmount: Money.fromRupees(500),
        refundMerchant: 'Uber',
        refundDate: DateTime(2026, 10, 12),
        candidateDebits: [candidate],
      );

      expect(match, isNull);
    });
  });
}
