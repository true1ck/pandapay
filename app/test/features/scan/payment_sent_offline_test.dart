import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/scan/payment_sent_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _Repo extends UserCardsRepository {
  _Repo() : super(apiBaseUrl: 'http://test', accessToken: 't');
}

void main() {
  testWidgets('log it saves one outbox row with vpa/mcc/rail, no network needed', (
    tester,
  ) async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final outbox = TransactionOutboxRepository(db, namespace: 'user:synthetic');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsRepositoryProvider.overrideWithValue(_Repo()),
          outboxRepositoryProvider.overrideWith((ref) async => outbox),
          acceptanceReportsRepositoryProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          home: PaymentSentScreen(
            merchantName: 'Synthetic Cafe',
            amount: Money.fromRupees(120),
            cardName: 'Synthetic Card',
            userCardId: 'card-1',
            categoryId: null,
            merchantVpa: 'cafe@synthetic',
            mcc: '5814',
            expectedValue: Money.fromRupees(2),
            confidence: Confidence.estimated,
            vpa: 'cafe@synthetic',
            cardNetwork: CardNetwork.visa,
            autoLog: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final rows = await outbox.all();
    expect(rows, hasLength(1));
    expect(rows.single.merchantVpa, 'cafe@synthetic');
    expect(rows.single.mcc, '5814');
    expect(rows.single.rail, 'upi_qr');
    expect(rows.single.userCardId, 'card-1');
  });

  group('coming back from the UPI app asks if the payment went through', () {
    Future<TransactionOutboxRepository> pumpSent(
      WidgetTester tester, {
      String cardName = 'Synthetic Card',
      String? userCardId = 'card-1',
    }) async {
      final db = openInMemoryForTesting();
      addTearDown(db.close);
      final outbox = TransactionOutboxRepository(db, namespace: 'user:synthetic');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsRepositoryProvider.overrideWithValue(_Repo()),
            outboxRepositoryProvider.overrideWith((ref) async => outbox),
            acceptanceReportsRepositoryProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            home: PaymentSentScreen(
              merchantName: 'Synthetic Cafe',
              amount: Money.fromRupees(120),
              cardName: cardName,
              userCardId: userCardId,
              categoryId: null,
              merchantVpa: 'cafe@synthetic',
              mcc: '5814',
              expectedValue: Money.fromRupees(2),
              confidence: Confidence.estimated,
              vpa: 'cafe@synthetic',
              cardNetwork: CardNetwork.visa,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return outbox;
    }

    Future<void> goToUpiAppAndBack(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    testWidgets('nothing is asked before the user has left for the UPI app', (
      tester,
    ) async {
      await pumpSent(tester);
      expect(find.text('Did the payment go through?'), findsNothing);
    });

    testWidgets('Yes records the spend at once', (tester) async {
      final outbox = await pumpSent(tester);

      await goToUpiAppAndBack(tester);
      expect(find.text('Did the payment go through?'), findsOneWidget);

      await tester.tap(find.text('Yes, it went through'));
      await tester.pumpAndSettle();

      final rows = await outbox.all();
      expect(rows, hasLength(1));
      expect(rows.single.merchantVpa, 'cafe@synthetic');
      expect(rows.single.rail, 'upi_qr');
      expect(find.text('Logged.'), findsOneWidget);
    });

    testWidgets('Not yet records nothing, and it asks again on the next return', (
      tester,
    ) async {
      final outbox = await pumpSent(tester);

      await goToUpiAppAndBack(tester);
      await tester.tap(find.text('Not yet'));
      await tester.pumpAndSettle();
      expect(await outbox.all(), isEmpty);
      expect(find.text('Logged.'), findsNothing);

      await goToUpiAppAndBack(tester);
      expect(find.text('Did the payment go through?'), findsOneWidget);
    });

    testWidgets('once recorded it does not ask again', (tester) async {
      await pumpSent(tester);
      await goToUpiAppAndBack(tester);
      await tester.tap(find.text('Yes, it went through'));
      await tester.pumpAndSettle();

      await goToUpiAppAndBack(tester);
      expect(find.text('Did the payment go through?'), findsNothing);
    });

    testWidgets('a bank-account payment has no card to record, so no question', (
      tester,
    ) async {
      await pumpSent(tester, cardName: '', userCardId: null);
      await goToUpiAppAndBack(tester);
      expect(find.text('Did the payment go through?'), findsNothing);
    });
  });
}
