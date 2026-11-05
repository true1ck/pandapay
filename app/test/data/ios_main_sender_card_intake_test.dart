import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
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
    'missing text sender is remembered without a fabricated bank address',
    () {
      final batch = IosShortcutSmsBatch.fromRows([
        input('', posted),
      ], allowSenderInference: false);
      expect(batch.missingSender, 1);
      expect(batch.messages.single.sender, '');
      intake.captureBatch(ns, batch.messages);
      expect(store.entities(ns, 'transactions'), isEmpty);
      // Deferred capture only remembers the message for the v2 pipeline.
      expect(SmsIntakeRepository(db).pending(ns), hasLength(1));
    },
  );
}
