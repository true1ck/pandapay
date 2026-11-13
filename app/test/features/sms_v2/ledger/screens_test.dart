import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/main.dart' show MoneyText;
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2_ledger.dart';

List<TransactionEntry> rows() => [
  for (final (id, kind, minor) in [
    ('spend', TxnEntryKind.spend, 10000),
    ('refund', TxnEntryKind.refund, 4000),
    ('investment', TxnEntryKind.investment, 50000),
    ('transfer', TxnEntryKind.transfer, 100000),
  ])
    TransactionEntry(
      id: id,
      entryKind: kind,
      amount: Money.fromPaise(minor),
      occurredAt: DateTime.now(),
      merchantName: id,
      source: 'manual',
      status: 'active',
    ),
];
void main() {
  testWidgets('Activity uses ledger summary and keeps transfer rows visible', (
    tester,
  ) async {
    final transactions = rows();
    final model = LedgerReadModel(
      ledger: LedgerSnapshot(entries: [], events: []),
      transactions: transactions,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsV2LedgerReadModelProvider.overrideWith((ref) async => model),
          activityTransactionsProvider.overrideWith(
            (ref) async => transactions,
          ),
          foreignPaymentsProvider.overrideWith((ref) async => const []),
          accessTokenProvider.overrideWith((ref) => 'test-token'),
          sessionInitProvider.overrideWith((ref) async {}),
          userCardsRepositoryProvider.overrideWithValue(null),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: ActivityScreen())),
      ),
    );
    await tester.pumpAndSettle();
    final out = tester
        .widgetList<MoneyText>(find.byType(MoneyText))
        .where((w) => w.prefix == '−')
        .first;
    // Money out is spending net of the refund (10,000 - 4,000) plus the money
    // put into investments (50,000). The transfer is in neither.
    expect(out.amount.paise, 56000);
    expect(find.text('3 txns'), findsOneWidget);
    expect(find.text('transfer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'an account without v2 data yet keeps its history until its account has v2 data',
    (tester) async {
      final transactions = rows()
          .where((r) => r.entryKind != TxnEntryKind.refund)
          .toList();
      final model = LedgerReadModel(
        ledger: LedgerSnapshot(entries: [], events: []),
        transactions: [],
        v2Ready: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            smsV2LedgerReadModelProvider.overrideWith((ref) async => model),
            activityTransactionsProvider.overrideWith(
              (ref) async => transactions,
            ),
            foreignPaymentsProvider.overrideWith((ref) async => const []),
            accessTokenProvider.overrideWith((ref) => 'test-token'),
            sessionInitProvider.overrideWith((ref) async {}),
            userCardsRepositoryProvider.overrideWithValue(null),
            userCardsProvider.overrideWith((ref) async => const []),
            categoriesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: Scaffold(body: ActivityScreen())),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<MoneyText>(find.byType(MoneyText))
            .where((w) => w.prefix == '−')
            .first
            .amount
            .paise,
        60000,
      );
      expect(find.text('3 txns'), findsOneWidget);
    },
  );

  testWidgets('Home consumes the real ledger report', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final model = LedgerReadModel(
      ledger: LedgerSnapshot(entries: [], events: []),
      transactions: rows(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsV2LedgerReadModelProvider.overrideWith((ref) async => model),
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
          sessionInitProvider.overrideWith((ref) async {}),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('home_spend_summary'));
    await tester.scrollUntilVisible(
      card,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widgetList<MoneyText>(
            find.descendant(of: card, matching: find.byType(MoneyText)),
          )
          .any((w) => w.amount.paise == 6000),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
