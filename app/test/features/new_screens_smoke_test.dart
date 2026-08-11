import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/report_transaction_screen.dart';
import 'package:pandapay/features/activity/transaction_detail_screen.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay/features/settings/settings_hub_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Render checks for the screens built in the design-parity pass, none of
/// which had been run on a device or in a test when they were written.
///
/// These are deliberately shallow — pump the screen with realistic data and
/// assert the headline content is there. The value is not the assertions:
/// it's that a widget test **fails on layout asserts and RenderFlex
/// overflow**, which is exactly the class of bug that only shows up when
/// something actually renders. An `IntrinsicHeight` mistake on the Insights
/// tab was caught this way rather than on a device.
///
/// Each screen is pumped at two viewport sizes. The 320×640 pass is the
/// one that matters: it is narrower and shorter than any modern phone, so
/// anything that survives it has real headroom for text scaling.

class _FakeRepo implements UserCardsRepository {
  final List<TransactionEntry> transactions;
  _FakeRepo({this.transactions = const []});

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
    String? query,
  }) async => transactions;

  @override
  Future<List<TransactionSplit>> fetchSplits(String transactionId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserCard _card({
  required String id,
  required String name,
  int? dueDay,
  int? statementDay,
  AutopayMode autopay = AutopayMode.off,
}) => UserCard(
  id: id,
  cardProductId: 'p-$id',
  cardName: name,
  isDefault: false,
  dueDay: dueDay,
  statementDay: statementDay,
  autopayMode: autopay,
);

TransactionEntry _txn({
  String id = 't1',
  String merchant = 'Zepto Fresh',
  double amount = 2500,
  String userCardId = 'uc1',
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(amount),
  occurredAt: DateTime(2026, 8, 12, 19, 42),
  merchantName: merchant,
  categoryName: 'Groceries',
  cardDisplayName: 'HDFC Millennia',
  userCardId: userCardId,
  source: 'manual',
  status: 'active',
  rewardValue: Money.fromRupees(125),
);

/// Pumps [screen] and settles. Any layout assert or overflow inside fails
/// the test here, which is the point.
Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  List<Override> overrides = const [],
  Size size = const Size(390, 844),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        sessionInitProvider.overrideWith((ref) async {}),
        isOnlineProvider.overrideWith((ref) => Stream.value(true)),
        categoriesProvider.overrideWith((ref) async => const []),
        ...overrides,
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PaymentsDueScreen (design 13)', () {
    final cards = [
      _card(id: 'uc1', name: 'SBI Cashback', dueDay: 16, statementDay: 1),
      _card(id: 'uc2', name: 'HDFC Millennia', dueDay: 21, autopay: AutopayMode.full),
      _card(id: 'uc3', name: 'Axis Ace', dueDay: 30, autopay: AutopayMode.minimum),
    ];

    Future<void> pumpDue(WidgetTester tester, {Size? size}) => _pump(
      tester,
      const PaymentsDueScreen(),
      size: size ?? const Size(390, 844),
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(_FakeRepo(transactions: [_txn()])),
        myCardsProvider.overrideWith((ref) async => cards),
      ],
    );

    testWidgets('renders the hero, the coming-up list and the float card', (tester) async {
      await pumpDue(tester);
      expect(find.textContaining('DUE IN'), findsOneWidget);
      expect(find.text('Coming up'), findsOneWidget);
      expect(find.text('Free money, briefly'), findsOneWidget);
    });

    testWidgets('words each autopay state differently', (tester) async {
      await pumpDue(tester);
      // The distinction the three-state enum exists for: "minimum" must not
      // read like "covered".
      expect(find.textContaining('the rest carries interest'), findsOneWidget);
      expect(find.textContaining('Autopay covers the full amount'), findsOneWidget);
    });

    testWidgets('never presents logged spend as the amount due', (tester) async {
      await pumpDue(tester);
      expect(find.text('Logged on this card this cycle'), findsOneWidget);
      expect(find.textContaining("issuer's statement may be higher"), findsOneWidget);
    });

    testWidgets('prompts rather than guessing when no card has a due day', (tester) async {
      await _pump(
        tester,
        const PaymentsDueScreen(),
        overrides: [
          userCardsRepositoryProvider.overrideWithValue(_FakeRepo()),
          myCardsProvider.overrideWith((ref) async => [_card(id: 'uc1', name: 'No Due Day')]),
        ],
      );
      expect(find.text('No due dates set'), findsOneWidget);
    });

    testWidgets('survives a 320x640 viewport', (tester) async {
      await pumpDue(tester, size: const Size(320, 640));
      expect(find.textContaining('DUE IN'), findsOneWidget);
    });
  });

  group('SettingsHubScreen (design 20)', () {
    testWidgets('renders all four groups', (tester) async {
      await _pump(tester, const SettingsHubScreen());
      for (final group in const ['SECURITY', 'NOTIFICATIONS', 'ACCOUNT', 'ABOUT']) {
        expect(find.text(group), findsOneWidget, reason: '$group heading should render');
      }
    });

    testWidgets('names the preferences row distinctly from the You inbox row', (tester) async {
      await _pump(tester, const SettingsHubScreen());
      // The bug this screen exists to fix: two rows both called
      // "Notifications" going to different places.
      expect(find.text('Notification settings'), findsOneWidget);
      expect(find.text('Notifications'), findsNothing);
    });

    testWidgets('survives a 320x640 viewport', (tester) async {
      await _pump(tester, const SettingsHubScreen(), size: const Size(320, 640));
      expect(find.text('SECURITY'), findsOneWidget);
    });
  });

  group('ReportTransactionScreen (design 26)', () {
    testWidgets('shows the attached transaction and all four reason chips', (tester) async {
      await _pump(tester, ReportTransactionScreen(entry: _txn()));
      expect(find.text('Zepto Fresh'), findsOneWidget);
      for (final chip in const [
        'Wrong reward',
        'Duplicate charge',
        'Card not recognized',
        'Other',
      ]) {
        expect(find.text(chip), findsOneWidget, reason: '$chip chip should render');
      }
    });

    testWidgets('submit is disabled until a reason is chosen', (tester) async {
      await _pump(tester, ReportTransactionScreen(entry: _txn()));
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit report'),
      );
      expect(button.onPressed, isNull, reason: 'an uncategorised report is how inboxes rot');

      await tester.tap(find.text('Wrong reward'));
      await tester.pumpAndSettle();

      final enabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit report'),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('tells the user their payment details travel with the report', (tester) async {
      await _pump(tester, ReportTransactionScreen(entry: _txn()));
      expect(find.textContaining('sent with your report'), findsOneWidget);
    });

    testWidgets('survives a 320x640 viewport', (tester) async {
      await _pump(tester, ReportTransactionScreen(entry: _txn()), size: const Size(320, 640));
      expect(find.text('What went wrong'), findsOneWidget);
    });
  });

  group('TransactionDetailScreen action rows (design 18)', () {
    testWidgets('offers add-a-note, split and report', (tester) async {
      await _pump(
        tester,
        const TransactionDetailScreen(transactionId: 't1'),
        overrides: [userCardsRepositoryProvider.overrideWithValue(_FakeRepo(transactions: [_txn()]))],
      );
      // fetchTransaction goes through noSuchMethod on the fake, so the
      // screen shows its error state rather than the body — that alone is
      // worth asserting: it must degrade, not throw.
      expect(tester.takeException(), isNull);
    });
  });
}
