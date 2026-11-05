import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  late AppDatabase db;
  late ResponseCache cache;
  List<UserCard> capturedCards() => cache.financialStore
      .entities('user:account-a', 'cards')
      .map(UserCard.fromJson)
      .toList();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  test(
    'generic Tata Neu HDFC bill does not teach the wrong card when two HDFC cards exist',
    () {
      cache.financialStore.replaceCards('user:account-a', [
        UserCard.fromJson({
          'id': 'moneyback',
          'card_product_id': 'moneyback',
          'card_name': 'MoneyBack+ Credit Card',
          'last4': '8708',
          'is_default': false,
        }),
        UserCard.fromJson({
          'id': 'tata-neu',
          'card_product_id': 'tata-neu',
          'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
          'last4': '1366',
          'is_default': false,
        }),
      ]);

      SmsImportStore(cache.financialStore).capture(
        'user:account-a',
        QueuedSms(
          sender: 'JX-TNBPAY-S',
          body:
              'Your HDFC BANK CREDIT CARD bill of Rs.1147.00 is generated. Pay by 2026-09-08 to avoid late charges.',
          receivedAt: DateTime(2026, 8, 29),
        ),
      );

      final cards = cache.financialStore
          .entities('user:account-a', 'cards')
          .map(UserCard.fromJson)
          .toList();
      expect(cards.every((card) => card.dueDay == null), isTrue);
      expect(cards.every((card) => card.statementDay == null), isTrue);
    },
  );

  test('capture and historical reads preserve explicitly cleared user dates', () {
    cache.financialStore.replaceCards('user:account-a', [
      const UserCard(
        id: 'user-cleared',
        cardProductId: 'credit',
        cardName: 'Credit Card',
        isDefault: false,
        last4: '8708',
        dueDaySource: 'user',
        statementDaySource: 'user',
      ),
    ]);
    SmsImportStore(cache.financialStore).capture(
      'user:account-a',
      QueuedSms(
        sender: 'HDFCBK',
        body:
            'Your credit card XX8708 statement is generated. Total amount due Rs 800. Pay by 24-10-2026.',
        receivedAt: DateTime(2026, 10, 20),
      ),
    );
    final card = capturedCards().single;
    expect(card.dueDay, isNull);
    expect(card.statementDay, isNull);
    expect(card.dueDaySource, 'user');
    expect(card.statementDaySource, 'user');
  });

  test('aggregator utility notices cannot teach a saved HDFC card cycle', () {
    cache.financialStore.replaceCards('user:account-a', [
      UserCard(
        id: 'hdfc',
        cardProductId: 'hdfc',
        cardName: 'HDFC Credit Card',
        cardType: 'credit',
        last4: '8708',
        isDefault: false,
      ),
    ]);
    SmsImportStore(cache.financialStore).capture(
      'user:account-a',
      QueuedSms(
        sender: 'JX-TNBPAY-S',
        body: 'Alegra Broadband ... Payment of Rs.800/- is due on 24-10-2026.',
        receivedAt: DateTime(2026, 10, 20),
      ),
    );
    final card = capturedCards().single;
    expect(card.dueDay, isNull);
    expect(card.statementDay, isNull);
  });

  test('ambiguous card suffixes never teach multiple credit-card cycles', () {
    cache.financialStore.replaceCards('user:account-a', [
      for (final id in ['one', 'two'])
        UserCard(
          id: id,
          cardProductId: id,
          cardName: 'Credit Card $id',
          cardType: 'credit',
          last4: '8708',
          isDefault: false,
        ),
    ]);
    SmsImportStore(cache.financialStore).capture(
      'user:account-a',
      QueuedSms(
        sender: 'HDFCBK',
        body:
            'Your credit card XX8708 statement is generated. Total amount due Rs 800. Pay by 24-10-2026.',
        receivedAt: DateTime(2026, 10, 20),
      ),
    );
    final cards = capturedCards();
    expect(
      cards.every((card) => card.dueDay == null && card.statementDay == null),
      isTrue,
    );
  });

}
