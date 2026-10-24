import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show UserCard, TxnInstrument, TransactionEntry;

void main() {
  const body = 'Rs. 420 spent on your card xx8406 at STORE on 22-Oct-26.';
  final debitCard = UserCard(
    id: 'debit-8406',
    cardProductId: 'debit-product',
    cardName: 'HDFC Debit Card',
    cardType: 'debit',
    isDefault: false,
    last4: '8406',
  );

  test('uses a unique saved card suffix instead of assuming credit', () {
    final transaction = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: body,
      receivedAt: DateTime(2026, 10, 22),
      cards: [debitCard],
    )?.transaction;

    expect(transaction?.instrument, TxnInstrument.debitCard);
    expect(transaction?.userCardId, debitCard.id);
    expect(transaction?.cardDisplayName, debitCard.cardName);
  });

  test('does not guess when suffix is unmatched or card type is ambiguous', () {
    final unmatched = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: body,
      receivedAt: DateTime(2026, 10, 22),
    )?.transaction;
    final ambiguous = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: body,
      receivedAt: DateTime(2026, 10, 22),
      cards: [
        debitCard,
        UserCard(
          id: 'credit-8406',
          cardProductId: 'credit-product',
          cardName: 'HDFC Credit Card',
          cardType: 'credit',
          isDefault: false,
          last4: '8406',
        ),
      ],
    )?.transaction;

    for (final transaction in [unmatched, ambiguous]) {
      expect(transaction?.instrument, TxnInstrument.other);
      expect(transaction?.instrumentKnown, isFalse);
      expect(transaction?.userCardId, isNull);
      final cached = TransactionEntry.fromJson(transaction!.toJson());
      expect(cached.instrumentKnown, isFalse);
      expect(cached.toJson()['instrument'], isNull);
    }
  });

  test('explicit SMS card type wins over a suffix-only saved-card match', () {
    final transaction = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs. 420 spent on your credit card xx8406 at STORE.',
      receivedAt: DateTime(2026, 10, 22),
      cards: [debitCard],
    )?.transaction;

    expect(transaction?.instrument, TxnInstrument.creditCard);
    expect(transaction?.userCardId, isNull);
  });

  test('card refunds preserve explicit and saved debit-card identity', () {
    for (final cardLabel in ['debit card', 'card']) {
      final transaction = LocalSmsParser.parse(
        namespace: 'user:test',
        sender: 'HDFCBK',
        body: 'Rs 420 refunded to your $cardLabel xx8406.',
        receivedAt: DateTime(2026, 10, 22),
        cards: [debitCard],
      )?.transaction;
      expect(transaction?.instrument, TxnInstrument.debitCard);
      expect(transaction?.userCardId, debitCard.id);
    }
  });

  test('statement and outstanding words do not turn bank debits into cards', () {
    final transaction = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs 420 debited from account XX8406 for outstanding loan payment.',
      receivedAt: DateTime(2026, 10, 22),
      cards: [debitCard],
    )?.transaction;
    expect(transaction?.instrument, TxnInstrument.upiBank);
    expect(transaction?.userCardId, isNull);
  });

  test('credit-card cash withdrawal keeps its explicit card type', () {
    final transaction = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs 420 withdrawn from your credit card xx8406 at ATM.',
      receivedAt: DateTime(2026, 10, 22),
    )?.transaction;
    expect(transaction?.instrument, TxnInstrument.creditCard);
  });

  test('a missing SMS suffix cannot match a saved card with a missing suffix', () {
    final transaction = LocalSmsParser.parse(
      namespace: 'user:test', sender: 'HDFCBK',
      body: 'Rs 420 spent on your credit card at STORE.',
      receivedAt: DateTime(2026, 10, 22),
      cards: [UserCard(id: 'no-suffix', cardProductId: 'credit',
        cardName: 'Credit Card', cardType: 'credit', isDefault: false)],
    )?.transaction;
    expect(transaction, isNotNull);
    expect(transaction?.userCardId, isNull);
  });

  test('downloaded bank suffix stays an account even if a saved card shares it', () {
    final rule = RestrictedSmsRule.fromJson({
      'id': 'bank-debit',
      'family': 'posted_movement',
      'senderPattern': 'HDFCBK',
      'regex': r'Rs (\d+) debited from account XX(\d{4})',
      'fieldMap': {'amount': 1, 'last4': 2},
      'defaultFields': {'instrument': 'upiBank'},
    })!;
    final transaction = LocalSmsParser.parse(
      namespace: 'user:test',
      sender: 'HDFCBK',
      body: 'Rs 420 debited from account XX8406.',
      receivedAt: DateTime(2026, 10, 22),
      cards: [debitCard],
      downloadedRules: SmsRuleBundle(
        bundleVersion: 1,
        sha256: '',
        publishedAt: DateTime(2026),
        minClientVersion: '1.0.0',
        rules: [rule],
      ),
    )?.transaction;
    expect(transaction?.instrument, TxnInstrument.upiBank);
    expect(transaction?.accountLast4, '8406');
    expect(transaction?.cardLast4, isNull);
    expect(transaction?.userCardId, isNull);
  });

  test('downloaded rules cannot persist full card numbers or security secrets', () {
    final rule = RestrictedSmsRule.fromJson({
      'id': 'card-spend',
      'family': 'posted_movement',
      'senderPattern': 'HDFCBK',
      'regex': r'Rs (\d+) spent on card (\d+)',
      'fieldMap': {'amount': 1, 'cardLast4': 2},
      'defaultFields': {'instrument': 'creditCard'},
    })!;
    for (final body in [
      'Rs 420 spent on card 1234567890123456.',
      'Rs 420 spent on card 8406. Passcode 654321.',
      'Rs 420 spent on card 8406. Secret code 654321.',
    ]) {
      final observation = LocalSmsParser.parse(
        namespace: 'user:test', sender: 'HDFCBK', body: body,
        receivedAt: DateTime(2026, 10, 22),
        downloadedRules: SmsRuleBundle(
          bundleVersion: 1, sha256: '', publishedAt: DateTime(2026),
          minClientVersion: '1.0.0', rules: [rule],
        ),
      );
      expect(observation?.transaction, isNull);
      expect(observation?.reasonCodes, isNot(contains('downloaded_rule_match')));
    }
  });
}
