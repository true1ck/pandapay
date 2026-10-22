import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardBillEvidence _ev(
  DateTime at, {
  String? last4 = '8080',
  bool explicitStatement = true,
  DateTime? due,
  Money? amount,
  Money? minimum,
}) => CardBillEvidence(
  cardLast4: last4,
  statementDate: at,
  statementDateExplicit: explicitStatement,
  dueDate: due,
  amountDue: amount,
  minimumDue: minimum,
  confidence: 0.9,
);

TransactionEntry _payment(
  String id, {
  required DateTime occurredAt,
  required Money amount,
  required String merchant,
  String? cardLast4,
  String? userCardId,
}) => TransactionEntry(
  id: id,
  amount: amount,
  occurredAt: occurredAt,
  merchantName: merchant,
  entryKind: TxnEntryKind.transfer,
  instrument: TxnInstrument.creditCard,
  source: 'sms',
  status: 'active',
  cardLast4: cardLast4,
  userCardId: userCardId,
);

void main() {
  final now = DateTime(2026, 11, 1);
  final card = UserCard.fromJson({
    'id': 'card-a',
    'card_product_id': 'p',
    'card_name': 'Axis Flipkart',
    'last4': '8080',
    'is_default': false,
  });
  final other = UserCard.fromJson({
    'id': 'card-b',
    'card_product_id': 'p',
    'card_name': 'ICICI Amazon',
    'last4': '1234',
    'is_default': false,
  });
  final twoCards = [card, other];

  test('single bill SMS becomes the current bill', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          minimum: Money.fromRupees(1078),
        ),
      ],
      payments: const [],
      now: now,
    );
    final bill = ledgers['card-a']!.current!;
    expect(bill.amountDue, Money.fromRupees(21560));
    expect(bill.minimumDue, Money.fromRupees(1078));
    expect(bill.dueDate, DateTime(2026, 11, 2));
    expect(bill.isPaid, isFalse);
    expect(bill.outstanding, Money.fromRupees(21560));
    expect(ledgers.containsKey('card-b'), isFalse);
  });

  test('duplicate reminders for one cycle merge into one bill', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(DateTime(2026, 10, 18), due: DateTime(2026, 11, 2)),
        _ev(
          DateTime(2026, 10, 20),
          explicitStatement: false,
          amount: Money.fromRupees(21560),
          minimum: Money.fromRupees(1078),
        ),
      ],
      payments: const [],
      now: now,
    );
    final bill = ledgers['card-a']!.current!;
    expect(bill.statementDate, DateTime(2026, 10, 18));
    expect(bill.amountDue, Money.fromRupees(21560));
    expect(bill.minimumDue, Money.fromRupees(1078));
    expect(ledgers['card-a']!.previous, isNull);
  });

  test('a later SMS must not shrink the amount due', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(DateTime(2026, 10, 18), amount: Money.fromRupees(21560)),
        _ev(DateTime(2026, 10, 19), amount: Money.fromRupees(5000)),
      ],
      payments: const [],
      now: now,
    );
    expect(ledgers['card-a']!.current!.amountDue, Money.fromRupees(21560));
  });

  test('explicit last4 payment marks the bill paid', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 21),
          amount: Money.fromRupees(21560),
          merchant: 'Credit card bill payment',
          cardLast4: '8080',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.isPaid, isTrue);
    expect(ledgers['card-a']!.current!.lastPaymentAt, DateTime(2026, 10, 21));
    expect(ledgers['card-a']!.previous, isNull);
  });

  test('minimum-due payment leaves partial state', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          minimum: Money.fromRupees(1078),
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 21),
          amount: Money.fromRupees(1078),
          merchant: 'Credit card bill payment',
          cardLast4: '8080',
        ),
      ],
      now: now,
    );
    final bill = ledgers['card-a']!.current!;
    expect(bill.isPaid, isFalse);
    expect(bill.hasPayments, isTrue);
    expect(bill.outstanding, Money.fromRupees(20482));
  });

  test('a payment made before the next statement settles the previous bill', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
        ),
        _ev(
          DateTime(2026, 9, 18),
          due: DateTime(2026, 10, 2),
          amount: Money.fromRupees(9500),
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 10),
          amount: Money.fromRupees(9500),
          merchant: 'Credit card bill payment',
          cardLast4: '8080',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.isPaid, isFalse);
    expect(ledgers['card-a']!.previous!.isPaid, isTrue);
  });

  test('a late payment of the previous cycle does not mark the new bill paid', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
        ),
        _ev(
          DateTime(2026, 9, 18),
          due: DateTime(2026, 10, 2),
          amount: Money.fromRupees(9500),
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 25),
          amount: Money.fromRupees(9500),
          merchant: 'Credit card bill payment',
          cardLast4: '8080',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.isPaid, isFalse);
    expect(ledgers['card-a']!.previous!.isPaid, isTrue);
  });

  test('overpaid bill stays paid', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 21),
          amount: Money.fromRupees(21600),
          merchant: 'Credit card bill payment',
          cardLast4: '8080',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.isPaid, isTrue);
  });

  test('two open windows and no card signal leave the payment unattributed', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          last4: '8080',
        ),
        _ev(
          DateTime(2026, 10, 17),
          due: DateTime(2026, 11, 3),
          amount: Money.fromRupees(21560),
          last4: '1234',
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 21),
          amount: Money.fromRupees(21560),
          merchant: 'Credit card bill payment',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.hasPayments, isFalse);
    expect(ledgers['card-b']!.current!.hasPayments, isFalse);
    expect(
      ledgers.values.every((l) => l.current?.paidToward.paise == 0),
      isTrue,
    );
  });

  test('a single open window infers the card', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          last4: '8080',
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 21),
          amount: Money.fromRupees(10000),
          merchant: 'Credit card bill payment',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.paidToward, Money.fromRupees(10000));
  });

  test('amount triangulation attributes a window-less payment to one card', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          last4: '8080',
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 12, 10),
          amount: Money.fromRupees(21558),
          merchant: 'Card bill pay',
        ),
      ],
      now: now,
    );
    final bill = ledgers['card-a']!.current!;
    expect(bill.isPaid, isFalse);
    expect(bill.hasPayments, isTrue);
    expect(bill.outstanding, Money.fromRupees(2));
  });

  test('exact triangulation settles the bill when the band fits', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          last4: '8080',
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 12, 10),
          amount: Money.fromRupees(21560),
          merchant: 'Card bill pay',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.isPaid, isTrue);
  });

  test('payment text naming the ending digits attributes explicitly', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(
          DateTime(2026, 10, 18),
          due: DateTime(2026, 11, 2),
          amount: Money.fromRupees(21560),
          last4: '8080',
        ),
      ],
      payments: [
        _payment(
          'p1',
          occurredAt: DateTime(2026, 10, 21),
          amount: Money.fromRupees(21560),
          merchant: 'Paid to Axis Flipkart card ending 8080',
        ),
      ],
      now: now,
    );
    expect(ledgers['card-a']!.current!.isPaid, isTrue);
  });

  test('evidence older than a quarter stops feeding the ledger', () {
    final ledgers = deriveCardBills(
      cards: twoCards,
      evidence: [
        _ev(DateTime(2026, 10, 18), amount: Money.fromRupees(21560)),
        _ev(DateTime(2026, 5, 10), amount: Money.fromRupees(70000)),
      ],
      payments: const [],
      now: now,
    );
    expect(ledgers['card-a']!.current!.amountDue, Money.fromRupees(21560));
    expect(ledgers['card-a']!.previous, isNull);
  });

  test('a family-only bill SMS attaches to the card it names', () {
    final tata = UserCard.fromJson({
      'id': 'card-t',
      'card_product_id': 'p',
      'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
      'last4': '7788',
      'is_default': false,
    });
    CardBillEvidence ev(String? family) => CardBillEvidence(
      cardLast4: null,
      family: family,
      statementDate: DateTime(2026, 10, 21),
      statementDateExplicit: true,
      dueDate: DateTime(2026, 11, 8),
      amountDue: Money.fromRupees(8331),
      minimumDue: null,
      confidence: 0.95,
    );

    // Without a named family the null-last4 evidence attaches nowhere.
    expect(
      deriveCardBills(
        cards: [card, tata],
        evidence: [ev(null)],
        payments: const [],
        now: now,
      ),
      isEmpty,
    );

    final ledgers = deriveCardBills(
      cards: [card, tata],
      evidence: [ev('MYTNEU')],
      payments: const [],
      now: now,
    );
    expect(ledgers.keys, ['card-t']);
    expect(ledgers['card-t']!.current!.dueDate, DateTime(2026, 11, 8));
    expect(ledgers['card-t']!.current!.amountDue, Money.fromRupees(8331));
  });

  test('family bill merges into the last4 statement of the card it names', () {
    final tata = UserCard.fromJson({
      'id': 'card-t',
      'card_product_id': 'p',
      'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
      'last4': '1366',
      'is_default': false,
    });
    // HDFC's statement template carries neither the amount nor the due
    // date; the Tata Neu bill SMS a day later carries both without digits.
    final ledgers = deriveCardBills(
      cards: [card, tata],
      evidence: [
        CardBillEvidence(
          cardLast4: '1366',
          statementDate: DateTime(2026, 10, 20),
          statementDateExplicit: false,
          dueDate: null,
          amountDue: null,
          minimumDue: null,
          confidence: 0.6,
        ),
        CardBillEvidence(
          cardLast4: null,
          family: 'MYTNEU',
          statementDate: DateTime(2026, 10, 21),
          statementDateExplicit: true,
          dueDate: DateTime(2026, 11, 8),
          amountDue: Money.fromRupees(8331),
          minimumDue: null,
          confidence: 0.95,
        ),
      ],
      payments: const [],
      now: now,
    );
    expect(ledgers['card-t'], isNotNull);
    final bill = ledgers['card-t']!.current!;
    expect(bill.statementDate, DateTime(2026, 10, 21));
    expect(bill.statementDateVerified, isTrue);
    expect(bill.dueDate, DateTime(2026, 11, 8));
    expect(bill.amountDue, Money.fromRupees(8331));
  });
  test('aggregator HDFC bill triangulates by spend when multiple HDFC cards exist', () {
    final moneyBack = UserCard.fromJson({
      'id': 'card-mb',
      'card_product_id': 'p1',
      'card_name': 'MoneyBack+ Credit Card',
      'last4': '8708',
      'is_default': false,
    });
    final tataNeu = UserCard.fromJson({
      'id': 'card-tn',
      'card_product_id': 'p2',
      'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
      'last4': '1366',
      'is_default': false,
    });

    final txns = <TransactionEntry>[
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 10, 16),
        userCardId: 'card-mb',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
      TransactionEntry(
        id: 't2',
        amount: Money.fromRupees(7831),
        occurredAt: DateTime(2026, 10, 8),
        userCardId: 'card-mb',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
      TransactionEntry(
        id: 't3',
        amount: Money.fromRupees(12),
        occurredAt: DateTime(2026, 9, 23),
        userCardId: 'card-tn',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
    ];

    final ledgers = deriveCardBills(
      cards: [moneyBack, tataNeu],
      evidence: [
        CardBillEvidence(
          cardLast4: '8708',
          statementDate: DateTime(2026, 10, 20),
          statementDateExplicit: false,
          dueDate: null,
          amountDue: null,
          minimumDue: null,
          confidence: 0.6,
        ),
        CardBillEvidence(
          cardLast4: '1366',
          statementDate: DateTime(2026, 10, 20),
          statementDateExplicit: false,
          dueDate: null,
          amountDue: null,
          minimumDue: null,
          confidence: 0.6,
        ),
        CardBillEvidence(
          cardLast4: null,
          family: 'MYTNEU',
          statementDate: DateTime(2026, 10, 21),
          statementDateExplicit: true,
          dueDate: DateTime(2026, 11, 8),
          amountDue: Money.fromRupees(8331),
          minimumDue: null,
          confidence: 0.95,
        ),
      ],
      payments: const [],
      transactions: txns,
      now: now,
    );

    expect(ledgers['card-mb'], isNotNull);
    final mbBill = ledgers['card-mb']!.current!;
    expect(mbBill.amountDue, Money.fromRupees(8331));
    expect(mbBill.dueDate, DateTime(2026, 11, 8));
    expect(ledgers['card-tn']?.current?.amountDue, isNull);
  });

  test('aggregator HDFC bill resolves to card with historical AutoPay evidence when offline', () {
    final moneyBack = UserCard.fromJson({
      'id': 'card-mb',
      'card_product_id': 'p1',
      'card_name': 'MoneyBack+ Credit Card',
      'last4': '8708',
      'is_default': false,
    });
    final tataNeu = UserCard.fromJson({
      'id': 'card-tn',
      'card_product_id': 'p2',
      'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
      'last4': '1366',
      'is_default': false,
    });

    final ledgers = deriveCardBills(
      cards: [moneyBack, tataNeu],
      evidence: [
        CardBillEvidence(
          cardLast4: '8708',
          family: 'JK-MYTNEU-S',
          statementDate: DateTime(2026, 10, 20),
          statementDateExplicit: false,
          dueDate: null,
          amountDue: null,
          minimumDue: null,
          confidence: 0.6,
        ),
        CardBillEvidence(
          cardLast4: null,
          family: 'JK-MYTNEU-S',
          statementDate: DateTime(2026, 10, 21),
          statementDateExplicit: true,
          dueDate: DateTime(2026, 11, 8),
          amountDue: Money.fromRupees(8331),
          minimumDue: null,
          confidence: 0.95,
        ),
      ],
      payments: const [],
      transactions: const [],
      now: now,
    );

    expect(ledgers['card-mb'], isNotNull);
    final mbBill = ledgers['card-mb']!.current!;
    expect(mbBill.amountDue, Money.fromRupees(8331));
    expect(mbBill.dueDate, DateTime(2026, 11, 8));
    expect(ledgers['card-tn'], isNull);
  });

  test('candidate cycle spend ignores bill payments, autopay, and huge single anomalies', () {
    final moneyBack = UserCard.fromJson({
      'id': 'card-mb',
      'card_product_id': 'p1',
      'card_name': 'MoneyBack+ Credit Card',
      'last4': '8708',
      'is_default': false,
    });
    final tataNeu = UserCard.fromJson({
      'id': 'card-tn',
      'card_product_id': 'p2',
      'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
      'last4': '1366',
      'is_default': false,
    });

    final txns = <TransactionEntry>[
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(4000),
        occurredAt: DateTime(2026, 10, 10),
        userCardId: 'card-mb',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
      TransactionEntry(
        id: 't2',
        amount: Money.fromRupees(20000),
        occurredAt: DateTime(2026, 10, 12),
        merchantName: 'HDFC Credit Card Bill Payment',
        userCardId: 'card-mb',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
      TransactionEntry(
        id: 't3',
        amount: Money.fromRupees(15000),
        occurredAt: DateTime(2026, 10, 14),
        merchantName: 'AutoPay Mandate Debit',
        userCardId: 'card-tn',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
      TransactionEntry(
        id: 't4',
        amount: Money.fromRupees(60000),
        occurredAt: DateTime(2026, 10, 20),
        userCardId: 'card-tn',
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.creditCard,
        source: 'sms',
        status: 'active',
      ),
    ];

    final ledgers = deriveCardBills(
      cards: [moneyBack, tataNeu],
      evidence: [
        CardBillEvidence(
          cardLast4: null,
          family: 'JK-TNBPAY-S',
          statementDate: DateTime(2026, 10, 21),
          statementDateExplicit: true,
          dueDate: DateTime(2026, 11, 8),
          amountDue: Money.fromRupees(4000),
          minimumDue: null,
          confidence: 0.95,
        ),
      ],
      payments: const [],
      transactions: txns,
      now: now,
    );

    expect(ledgers['card-mb'], isNotNull);
    expect(ledgers['card-mb']!.current!.amountDue, Money.fromRupees(4000));
    expect(ledgers['card-tn'], isNull);
  });
}
