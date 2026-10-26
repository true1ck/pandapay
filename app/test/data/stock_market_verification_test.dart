import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/investment_classifier.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  group('Stock market and investment verification', () {
    test('verifies exact user screenshot scenario: HDFC MF SIP purchase', () {
      const sender = 'AD-HDFCMF-S';
      const body =
          'Your SIP Purchase in Folio 31447734/65 under HDFC Gold ETF Fund of Fund-DP Growth for Rs. 100.00 has been processed at the NAV of 30.4651 for 3.282 units and 10-Jul-2025. Your smart statement https://shrtsms.in/HDFCMF/xASrMa. Enter your PAN as the password. Sincerely, HDFCMF';

      // 1. Classifier check
      expect(isInvestmentFolioAllotment(body), isTrue);
      expect(LocalSmsParser.isNonTransactionNoise(sender, body), isFalse);

      // 2. Parser check
      final obs = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2025, 7, 11, 10, 50),
      );

      expect(obs, isNotNull);
      expect(obs!.transaction, isNotNull);
      final txn = obs.transaction!;

      // 3. Verify fields
      expect(txn.merchantName, 'HDFC Gold ETF Fund of Fund-DP Growth');
      expect(txn.amount.rupees, 100.00);
      expect(txn.categoryId, 'investments');
      expect(txn.categoryName, 'Investments');
      expect(txn.entryKind, TxnEntryKind.investment);
      expect(txn.status, 'active');
      expect(txn.accountLast4, '4/65'); // folio last 4

      // 4. Verify Total Spend isolation:
      // In PandaPay, spend totals ONLY sum TxnEntryKind.spend rows.
      final isSpend = txn.entryKind == TxnEntryKind.spend;
      expect(isSpend, isFalse, reason: 'Must NOT count as spend!');
    });

    test('verifies October broker running account settlement (Dhan)', () {
      const sender = 'VM-DHANHQ-S';
      const body =
          'Dear Sujay We have transferred Rs 93.82 to your bank account ending with XXXXXXX2626 as a part of running account settlement vide Ref No PO26101713812965. To continue trading and investing, add funds back to your Dhan account.';

      expect(isBrokerSettlementMessage(body, sender), isTrue);
      expect(LocalSmsParser.isNonTransactionNoise(sender, body), isFalse);

      final obs = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2026, 10, 18, 14, 0),
      );

      expect(obs, isNotNull);
      expect(obs!.transaction, isNotNull);
      final txn = obs.transaction!;

      expect(txn.merchantName, contains('Investment return'));
      expect(txn.amount.rupees, 93.82);
      expect(txn.categoryId, 'investments');
      expect(txn.categoryName, 'Investments');
      expect(txn.entryKind, TxnEntryKind.income); // Money In
      expect(txn.status, 'active');
      expect(txn.entryKind == TxnEntryKind.spend, isFalse);
    });

    test('keeps initiated Kotak Neo settlement pending until receipt', () {
      const sender = 'KOTAKN';
      const body =
          'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account. You should receive funds in A/c XX1234 by EOD.';

      expect(isBrokerSettlementMessage(body, sender), isTrue);
      expect(LocalSmsParser.isNonTransactionNoise(sender, body), isFalse);

      final obs = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2026, 10, 10, 15, 30),
      );

      expect(obs, isNotNull);
      expect(obs!.transaction, isNull);
      expect(obs.disposition, LocalSmsDisposition.review);
    });

    test('verifies SEBI quarterly unused funds settlement (Zerodha)', () {
      const sender = 'VK-ZERODHA';
      const body =
          'As per SEBI guidelines, unused funds of Rs 4,500.00 in your trading account have been settled to your bank A/C XX1234 on 06-Oct-2026. Zerodha Broking.';

      expect(isBrokerSettlementMessage(body, sender), isTrue);
      expect(LocalSmsParser.isNonTransactionNoise(sender, body), isFalse);

      final obs = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2026, 10, 6, 18, 0),
      );

      expect(obs, isNotNull);
      expect(obs!.transaction, isNotNull);
      final txn = obs.transaction!;

      expect(txn.merchantName, contains('Investment return'));
      expect(txn.amount.rupees, 4500.00);
      expect(txn.categoryId, 'investments');
      expect(txn.entryKind, TxnEntryKind.income);
      expect(txn.entryKind == TxnEntryKind.spend, isFalse);
    });

    test('verifies pure future advisory notice with zero amount is still non-transaction noise', () {
      const sender = 'VK-LEMONN';
      const body =
          'Dear SUJAY SHANTARAM KURTIKAR, as per SEBI and exchange guidelines, unused funds in your Lemonn trading account will be transferred back to your registered bank account on the day of settlement.';

      // Pure future advisory without completed movement/amount should NOT create a transaction
      expect(LocalSmsParser.isNonTransactionNoise(sender, body), isTrue);
      final obs = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2026, 10, 1),
      );
      expect(obs?.transaction, isNull);
    });
  });
}
