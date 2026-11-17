import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/instruments/card_transaction_relinker.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/ui/found_instruments_screen.dart';
import 'package:pandapay/features/sms_v2/ui/instrument_evidence.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// The "Accounts and cards we found" screen: sections fold, the cards that are
// not in the wallet are said up front, and a card's page shows the
// transactions its messages stand for before it is added.
void main() {
  Instrument found(
    String id, {
    InstrumentKind kind = InstrumentKind.bankAccount,
    InstrumentStatus status = InstrumentStatus.confirmed,
    String issuer = 'hdfc',
    String? mask = '1234',
    String? userCardId,
    int evidence = 3,
  }) => Instrument(
    instrumentId: id,
    kind: kind,
    issuerSlug: issuer,
    maskDigits: mask,
    displayName: '$issuer $id',
    status: status,
    userCardId: userCardId,
    firstSeenAt: DateTime.utc(2026, 11, 1),
    lastSeenAt: DateTime.utc(2026, 11, 2),
    evidenceCount: evidence,
  );
  String id(int n) =>
      '${n.toString().padLeft(8, '0')}-0000-4000-8000-000000000000';

  Widget list(List<Instrument> items) => MaterialApp(
    home: Scaffold(
      body: FoundInstrumentsList(
        instruments: items,
        onConfirm: (_) {},
        onReject: (_) {},
        onRename: (_) {},
        onOpen: (_) {},
      ),
    ),
  );

  group('Accounts and cards we found', () {
    // Seven confirmed accounts and one card the wallet does not have.
    final accounts = [
      for (var n = 1; n <= 7; n++) found(id(n), mask: '10$n$n'),
    ];
    final missingCard = found(
      id(9),
      kind: InstrumentKind.creditCard,
      status: InstrumentStatus.detected,
      mask: '8127',
      evidence: 140,
    );

    testWidgets('a long list opens only the sections with something to do', (
      tester,
    ) async {
      await tester.pumpWidget(list([...accounts, missingCard]));
      expect(find.text('Bank accounts'), findsOneWidget);
      expect(find.text('Credit cards'), findsOneWidget);
      // The card to add is shown; the confirmed accounts are folded away.
      expect(find.text('HDFC ••8127'), findsOneWidget);
      expect(find.text('HDFC ••1011'), findsNothing);
      expect(find.text('1 to add'), findsOneWidget);
      // Tapping a section opens it, tapping again folds it.
      await tester.tap(find.byKey(const Key('section-Bank accounts')));
      await tester.pumpAndSettle();
      expect(find.text('HDFC ••1011'), findsOneWidget);
      final creditCards = find.byKey(const Key('section-Credit cards'));
      await tester.scrollUntilVisible(creditCards, 200);
      await tester.tap(creditCards);
      await tester.pumpAndSettle();
      expect(find.text('HDFC ••8127'), findsNothing);
    });

    testWidgets('cards not in the wallet are said at the top, and open their section', (
      tester,
    ) async {
      await tester.pumpWidget(list([...accounts, missingCard]));
      final summary = find.byKey(const Key('not-in-wallet-summary'));
      expect(summary, findsOneWidget);
      expect(find.text('1 card is not in your wallet'), findsOneWidget);
      // Folded by hand, then brought back by the summary.
      await tester.tap(find.byKey(const Key('section-Credit cards')));
      await tester.pumpAndSettle();
      expect(find.text('HDFC ••8127'), findsNothing);
      await tester.tap(summary);
      await tester.pumpAndSettle();
      expect(find.text('HDFC ••8127'), findsOneWidget);
    });

    testWidgets('no summary when every card with messages is in the wallet', (
      tester,
    ) async {
      final inWallet = found(
        id(9),
        kind: InstrumentKind.creditCard,
        mask: '8127',
        userCardId: '99999999-9999-4999-8999-999999999999',
      );
      await tester.pumpWidget(list([...accounts, inWallet]));
      expect(find.byKey(const Key('not-in-wallet-summary')), findsNothing);
    });

    testWidgets('a card whose messages print no number says so', (
      tester,
    ) async {
      await tester.pumpWidget(
        list([
          found(
            id(9),
            kind: InstrumentKind.creditCard,
            status: InstrumentStatus.detected,
            issuer: 'federal',
            mask: null,
          ),
        ]),
      );
      expect(find.text('FEDERAL · no number in its messages'), findsOneWidget);
      expect(find.textContaining('unknown'), findsNothing);
    });

    test('what still needs the person', () {
      expect(cardNotInWallet(missingCard), isTrue);
      expect(
        cardNotInWallet(
          found(id(9), kind: InstrumentKind.creditCard, userCardId: 'w'),
        ),
        isFalse,
      );
      // An older build could confirm a card without a wallet card.
      expect(
        cardNotInWallet(found(id(9), kind: InstrumentKind.creditCard)),
        isTrue,
      );
      expect(
        cardNotInWallet(
          found(
            id(9),
            kind: InstrumentKind.creditCard,
            status: InstrumentStatus.rejected,
          ),
        ),
        isFalse,
      );
      expect(instrumentNeedsAction(accounts.first), isFalse);
      expect(
        instrumentNeedsAction(
          found(id(9), status: InstrumentStatus.detected),
        ),
        isTrue,
      );
    });
  });

  group('a card\'s page', () {
    final card = found(
      id(9),
      kind: InstrumentKind.creditCard,
      status: InstrumentStatus.detected,
      mask: '8127',
    );
    TransactionEntry row(String rowId, int paise, String shop, int day) =>
        TransactionEntry(
          id: rowId,
          eventId: rowId,
          pipelineVersion: 2,
          source: 'sms',
          amount: Money.fromPaise(paise),
          occurredAt: DateTime.utc(2026, 11, day),
          merchantName: shop,
          instrument: TxnInstrument.creditCard,
          cardLast4: '8127',
          status: 'active',
        );
    final rows = [
      row('v2:b', 25000, 'SWIGGY', 5),
      row('v2:a', 119000, 'AMAZON', 3),
    ];

    Widget page(Instrument instrument, List<TransactionEntry> evidence) {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: ListView(
                children: [
                  InstrumentStatusPanel(instrument: instrument),
                  InstrumentEvidenceSection(instrument: instrument),
                ],
              ),
            ),
          ),
          GoRoute(
            path: '/activity/:id',
            builder: (_, state) =>
                Scaffold(body: Text('opened ${state.pathParameters['id']}')),
          ),
        ],
      );
      return ProviderScope(
        overrides: [
          instrumentTransactionsProvider.overrideWith(
            (ref, _) async => evidence,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    testWidgets('a card not in the wallet says what adding it brings', (
      tester,
    ) async {
      await tester.pumpWidget(page(card, rows));
      await tester.pumpAndSettle();
      expect(find.text('Not in your wallet'), findsOneWidget);
      expect(find.textContaining('its 2 spends (₹1,440.00)'), findsOneWidget);
      expect(find.byKey(const Key('instrument-add')), findsOneWidget);
      expect(find.text('Add to wallet'), findsOneWidget);
      expect(find.text('Not mine'), findsOneWidget);
    });

    testWidgets('its transactions are listed newest first and each opens', (
      tester,
    ) async {
      await tester.pumpWidget(page(card, rows));
      await tester.pumpAndSettle();
      expect(find.text('Transactions from its messages'), findsOneWidget);
      final swiggy = tester.getTopLeft(find.text('SWIGGY'));
      final amazon = tester.getTopLeft(find.text('AMAZON'));
      expect(swiggy.dy, lessThan(amazon.dy));
      await tester.tap(find.text('AMAZON'));
      await tester.pumpAndSettle();
      expect(find.text('opened v2:a'), findsOneWidget);
    });

    testWidgets('a long list shows the newest first and the rest on request', (
      tester,
    ) async {
      final many = [
        for (var n = 0; n < 30; n++) row('v2:$n', 1000 + n, 'SHOP $n', 1),
      ];
      await tester.pumpWidget(page(card, many));
      await tester.pumpAndSettle();
      expect(find.text('Show all 30'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Show all 30'), 200);
      await tester.ensureVisible(find.text('Show all 30'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show all 30'));
      await tester.pumpAndSettle();
      expect(find.text('Show all 30'), findsNothing);
    });

    testWidgets('a card in the wallet says so and offers nothing to add', (
      tester,
    ) async {
      final linked = found(
        id(9),
        kind: InstrumentKind.creditCard,
        mask: '8127',
        userCardId: '99999999-9999-4999-8999-999999999999',
      );
      await tester.pumpWidget(page(linked, rows));
      await tester.pumpAndSettle();
      expect(find.textContaining('In your wallet'), findsOneWidget);
      expect(find.byKey(const Key('instrument-add')), findsNothing);
      // Why it was linked: the same transactions are listed.
      expect(find.text('SWIGGY'), findsOneWidget);
    });
  });

  test('the transactions behind a card are read through its own messages', () {
    final database = AppDatabase.forTesting(sqlite3.openInMemory());
    final financial = FinancialStore(database);
    addTearDown(() {
      financial.dispose();
      database.db.dispose();
    });
    const namespace = 'user:evidence';
    final bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    SmsIntakeRepository(database);
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
      categoryIdBySlug: const {'other': 'cat-other', 'dining': 'cat-dining'},
    ).process(
      SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: '1' * 64,
        observedAt: DateTime.utc(2026, 11, 1, 7),
      ),
    );
    final instrument = InstrumentStore(
      database.db,
      namespace: namespace,
    ).list().single;
    final keys = [
      for (final r in database.db.select(CardTransactionRelinker.factKeysSql, [
        namespace,
        instrument.instrumentId,
      ]))
        r['source_key'] as String,
    ];
    final rows = financial.smsTransactionsForSourceKeys(namespace, keys);
    expect(rows, hasLength(1));
    expect(rows.single.sourceKey, '1' * 64);
    // Another account's keys find nothing.
    expect(financial.smsTransactionsForSourceKeys('user:other', keys), isEmpty);
    expect(financial.smsTransactionsForSourceKeys(namespace, const []), isEmpty);
  });
}
