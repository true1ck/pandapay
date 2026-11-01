import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';

// Synthetic fixtures; no real account suffix, transaction reference or SMS.
const ns = 'user:sender-card-fixture';
const posted =
    'Rs.42.50 spent on your SBI Credit Card ending with 4242 at '
    'TESTTECHNOLOGIES on 01-11-26 via UPI (Ref No. SYNTHETIC).';
const request =
    'TEST TECHNOLOGIES PRIVATE LIMITED has requested money from '
    'you on PhonePe. Rs.42.50 will be debited from your account on approving '
    'the request - https://phone.pe/TEST';
const card = UserCard(
  id: 'saved-rupay',
  cardProductId: 'sbi-phonepe-rupay',
  cardName: 'PhonePe SBI RuPay Credit Card',
  nickname: 'My PhonePe card',
  cardType: 'credit',
  last4: '4242',
  isDefault: false,
);

Map<Object?, Object?> input(String sender, String body) => {
  'sender': sender,
  'senderEvidence': 'text',
  'body': body,
  'receivedAt': '2026-11-01T08:00:00Z',
};

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late SmsImportStore intake;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    store.replaceCards(ns, [card]);
    intake = SmsImportStore(store);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  test(
    'main iOS text handoff and Android shared input produce the same card payment',
    () {
      final batch = IosShortcutSmsBatch.fromRows([
        input('SBICRD-S', posted),
      ], allowSenderInference: false);
      expect(batch.missingSender, 0);
      expect(batch.messages.single.sender, 'SBICRD-S');
      intake.captureBatch(ns, batch.messages);
      final saved = TransactionEntry.fromJson(
        store.entities(ns, 'transactions').single,
      );
      final direct = LocalSmsParser.parse(
        namespace: ns,
        sender: 'SBICRD-S',
        body: posted,
        receivedAt: batch.messages.single.receivedAt,
        cards: [card],
      )!.transaction!;
      expect(
        saved.toJson(),
        TransactionEntry.fromJson(direct.toJson()).toJson(),
      );
      expect(saved.amount.rupees, 42.50);
      expect(saved.merchantName, 'TESTTECHNOLOGIES');
      expect(saved.instrument, TxnInstrument.creditCard);
      expect(saved.paymentMethod, 'upi');
      // Generic UPI cannot establish a QR scan or its reward eligibility.
      expect(saved.rail, TxnRail.unknown);
      expect(saved.userCardId, card.id);
      expect(saved.cardDisplayName, card.nickname);
      expect(saved.accountLast4, isNull);
      expect(saved.cardLast4, '4242');
      expect(saved.smsReceivedAt, DateTime.utc(2026, 11, 1, 8));
      expect(saved.copyWith(note: 'test').paymentMethod, 'upi');
    },
  );

  test(
    'request and completion retain distinct sources but create one expense on replay',
    () {
      for (final bodies in [
        [input('PHONPE-S', request), input('SBICRD-S', posted)],
        [input('SBICRD-S', posted), input('PHONPE-S', request)],
      ]) {
        final batch = IosShortcutSmsBatch.fromRows(
          bodies,
          allowSenderInference: false,
        );
        intake.captureBatch(ns, batch.messages);
        intake.captureBatch(ns, batch.messages);
        expect(store.entities(ns, 'transactions'), hasLength(1));
        expect(store.entities(ns, 'sms_observations'), hasLength(2));
      }
      expect(
        LocalSmsParser.parse(
          namespace: ns,
          sender: 'PHONPE-S',
          body: request,
          receivedAt: DateTime(2026, 11, 1),
        )?.transaction,
        isNull,
      );
    },
  );

  test(
    'missing text sender goes to review without a fabricated bank address',
    () {
      final batch = IosShortcutSmsBatch.fromRows([
        input('', posted),
      ], allowSenderInference: false);
      expect(batch.missingSender, 1);
      expect(batch.messages.single.sender, '');
      intake.captureBatch(ns, batch.messages);
      expect(store.entities(ns, 'transactions'), isEmpty);
      expect(
        db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [
          ns,
        ]),
        hasLength(1),
      );
    },
  );

  test('unknown or ambiguous card suffix never selects the default card', () {
    for (final cards in <List<UserCard>>[
      [],
      [
        card,
        const UserCard(
          id: 'second',
          cardProductId: 'other',
          cardName: 'Other Credit Card',
          cardType: 'credit',
          last4: '4242',
          isDefault: true,
        ),
      ],
    ]) {
      final txn = LocalSmsParser.parse(
        namespace: ns,
        sender: 'SBICRD-S',
        body: posted,
        receivedAt: DateTime(2026, 11, 1),
        cards: cards,
      )!.transaction!;
      expect(txn.userCardId, isNull);
      expect(txn.instrument, TxnInstrument.creditCard);
      expect(txn.paymentMethod, 'upi');
    }
  });

  test('UPI support text alone cannot assert the payment method', () {
    final txn = LocalSmsParser.parse(
      namespace: ns,
      sender: 'SBICRD-S',
      body: posted.replaceFirst(
        ' via UPI (Ref No. SYNTHETIC)',
        '. For UPI help visit https://example.test/help',
      ),
      receivedAt: DateTime(2026, 11, 1),
      cards: [card],
    )!.transaction!;
    expect(txn.paymentMethod, isNull);
  });

  test(
    'server reconciliation keeps exact-source UPI evidence without changing QR rail',
    () {
      final batch = IosShortcutSmsBatch.fromRows([
        input('SBICRD-S', posted),
      ], allowSenderInference: false);
      intake.captureBatch(ns, batch.messages);
      final local = store.entities(ns, 'transactions').single;
      final remote = TransactionEntry.fromJson(
        {...local, 'id': 'server-confirmed'}..remove('payment_method'),
      );
      store.saveTransactions(ns, [remote]);
      expect(store.entities(ns, 'transactions'), hasLength(1));
      final saved = TransactionEntry.fromJson(
        store.entities(ns, 'transactions').single,
      );
      expect(saved.paymentMethod, 'upi');
      expect(saved.rail, TxnRail.unknown);
      store.saveTransactions('user:other', [remote]);
      expect(
        TransactionEntry.fromJson(
          store.entities('user:other', 'transactions').single,
        ).paymentMethod,
        isNull,
      );
      store.saveTransactions(ns, [
        TransactionEntry.fromJson({
          ...remote.toJson(),
          'id': 'unrelated-source',
          'source_key': 'different-key',
        }),
      ]);
      expect(
        TransactionEntry.fromJson(
          store.entities(ns, 'transactions', id: 'unrelated-source').single,
        ).paymentMethod,
        isNull,
      );
    },
  );
}
