import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/acceptance_reports_repository.dart';
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
}
