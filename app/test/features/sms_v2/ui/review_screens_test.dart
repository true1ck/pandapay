import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/ui/screen_parts.dart';
import 'package:pandapay/features/sms_v2/ui/found_instruments_screen.dart';
import 'package:pandapay/features/sms_v2/ui/why_sheet.dart';
import 'package:pandapay_domain/sms_v2.dart';

void main() {
  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));
  testWidgets('every async screen state has a clear recovery or empty state', (
    tester,
  ) async {
    await tester.pumpWidget(app(const SmsLoading()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    var retried = false;
    await tester.pumpWidget(app(SmsError(onRetry: () => retried = true)));
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
    await tester.pumpWidget(app(const SmsEmpty('No accounts found yet')));
    expect(find.text('No accounts found yet'), findsOneWidget);
  });
  testWidgets('found accounts group by kind and expose all three choices', (
    tester,
  ) async {
    final instrument = Instrument(
      instrumentId: '11111111-1111-4111-8111-111111111111',
      kind: InstrumentKind.bankAccount,
      issuerSlug: 'hdfc',
      maskDigits: '1234',
      displayName: 'HDFC account',
      status: InstrumentStatus.detected,
      firstSeenAt: DateTime.utc(2026, 11, 1),
      lastSeenAt: DateTime.utc(2026, 11, 2),
      evidenceCount: 2,
    );
    String? action;
    await tester.pumpWidget(
      app(
        FoundInstrumentsList(
          instruments: [instrument],
          onConfirm: (i) => action = 'confirm',
          onReject: (i) => action = 'reject',
          onRename: (i) => action = 'rename',
          onOpen: (i) {},
        ),
      ),
    );
    expect(find.text('Bank accounts'), findsOneWidget);
    expect(find.textContaining('1234'), findsOneWidget);
    expect(find.textContaining('unknown'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    expect(action, 'confirm');
    await tester.tap(find.text('Not mine'));
    expect(action, 'reject');
    await tester.tap(find.text('Rename'));
    expect(action, 'rename');
  });
  testWidgets('tapping a found account opens its detail page', (tester) async {
    final instrument = Instrument(
      instrumentId: '55555555-5555-4555-8555-555555555555',
      kind: InstrumentKind.bankAccount,
      issuerSlug: 'axis',
      maskDigits: '2468',
      displayName: 'AXIS account ••2468',
      status: InstrumentStatus.confirmed,
      availableMinor: 12745,
      firstSeenAt: DateTime.utc(2026, 11, 1),
      lastSeenAt: DateTime.utc(2026, 11, 9),
      evidenceCount: 2,
    );
    Instrument? opened;
    await tester.pumpWidget(
      app(
        FoundInstrumentsList(
          instruments: [instrument],
          onConfirm: (_) {},
          onReject: (_) {},
          onRename: (_) {},
          onOpen: (i) => opened = i,
        ),
      ),
    );
    await tester.tap(find.text('AXIS account ••2468'));
    expect(opened?.instrumentId, instrument.instrumentId);
    opened = null;
    await tester.tap(find.text('Available'));
    expect(opened?.instrumentId, instrument.instrumentId);
    // The action buttons must not also open the page.
    opened = null;
    await tester.tap(find.text('Rename'));
    expect(opened, isNull);
  });
  testWidgets('a number that is both a card and an account asks which it is', (
    tester,
  ) async {
    Instrument make(String id, InstrumentKind kind) => Instrument(
      instrumentId: id,
      kind: kind,
      issuerSlug: 'axis',
      maskDigits: '2468',
      displayName: 'Axis',
      status: InstrumentStatus.confirmed,
      firstSeenAt: DateTime.utc(2026, 11, 1),
      lastSeenAt: DateTime.utc(2026, 11, 2),
      evidenceCount: 2,
    );
    final account = make(
      '33333333-3333-4333-8333-333333333333',
      InstrumentKind.bankAccount,
    );
    final creditCard = make(
      '44444444-4444-4444-8444-444444444444',
      InstrumentKind.creditCard,
    );
    bool? choseCard;
    await tester.pumpWidget(
      app(
        FoundInstrumentsList(
          instruments: [account, creditCard],
          onConfirm: (_) {},
          onReject: (_) {},
          onRename: (_) {},
          onOpen: (_) {},
          onResolveKind: (i, isCard) {
            expect(i.instrumentId, account.instrumentId);
            choseCard = isCard;
          },
        ),
      ),
    );
    expect(find.textContaining('Which is it?'), findsOneWidget);
    await tester.tap(find.text('Credit card'));
    expect(choseCard, isTrue);
    await tester.tap(find.text('Bank account'));
    expect(choseCard, isFalse);
  });
  Instrument card({
    required InstrumentStatus status,
    String? userCardId,
    InstrumentKind kind = InstrumentKind.creditCard,
  }) => Instrument(
    instrumentId: '22222222-2222-4222-8222-222222222222',
    kind: kind,
    issuerSlug: 'yes',
    maskDigits: '1260',
    displayName: 'YES credit card',
    status: status,
    userCardId: userCardId,
    firstSeenAt: DateTime.utc(2026, 11, 1),
    lastSeenAt: DateTime.utc(2026, 11, 2),
    evidenceCount: 2,
  );
  Future<void> pumpFound(
    WidgetTester tester,
    Instrument instrument, {
    ValueChanged<Instrument>? onConfirm,
  }) => tester.pumpWidget(
    app(
      FoundInstrumentsList(
        instruments: [instrument],
        onConfirm: onConfirm ?? (_) {},
        onReject: (_) {},
        onRename: (_) {},
        onOpen: (_) {},
      ),
    ),
  );
  testWidgets('a found credit card offers to add it to the wallet', (
    tester,
  ) async {
    Instrument? chosen;
    await pumpFound(
      tester,
      card(status: InstrumentStatus.detected),
      onConfirm: (i) => chosen = i,
    );
    expect(find.text('Confirm'), findsNothing);
    expect(find.text('In wallet'), findsNothing);
    await tester.tap(find.text('Add to wallet'));
    expect(chosen?.kind, InstrumentKind.creditCard);
  });
  testWidgets(
    'a credit card confirmed without a wallet card is not shown as in the wallet',
    (tester) async {
      await pumpFound(tester, card(status: InstrumentStatus.confirmed));
      expect(find.text('In wallet'), findsNothing);
      expect(find.text('Confirmed'), findsNothing);
      expect(find.text('Add to wallet'), findsOneWidget);
    },
  );
  testWidgets('a credit card with a wallet card shows it is in the wallet', (
    tester,
  ) async {
    await pumpFound(
      tester,
      card(
        status: InstrumentStatus.confirmed,
        userCardId: '33333333-3333-4333-8333-333333333333',
      ),
    );
    expect(find.text('In wallet'), findsOneWidget);
    expect(find.text('Add to wallet'), findsNothing);
    expect(find.text('Confirm'), findsNothing);
  });
  testWidgets('a confirmed bank account still reads Confirmed', (tester) async {
    await pumpFound(
      tester,
      card(status: InstrumentStatus.confirmed, kind: InstrumentKind.bankAccount),
    );
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('Add to wallet'), findsNothing);
  });
  testWidgets('why sheet explains category choice and offers a report', (
    tester,
  ) async {
    var reported = false;
    await tester.pumpWidget(
      app(
        WhyContent(
          trace: {
            'ruleId': 'HDFC-CARD',
            'ruleVersion': 4,
            'category': {'source': 'user'},
            'event': {'linkRuleId': 'CARD-BILL-PAIR'},
          },
          onReport: () => reported = true,
        ),
      ),
    );
    expect(find.textContaining('version 4'), findsOneWidget);
    expect(find.textContaining('you chose'), findsOneWidget);
    await tester.tap(find.text('Report a problem'));
    expect(reported, isTrue);
  });
  testWidgets('the inbox shows one row per format with the full action count', (
    tester,
  ) async {
    final items = [
      for (var i = 0; i < 3; i++)
        LocalReviewItem(
          id: 'item:$i',
          kind: 'template',
          payload: const {'templateHash': 'same', 'hasReading': true},
        ),
    ];
    List<LocalReviewItem>? applied;
    await tester.pumpWidget(
      app(
        ReviewInboxList(
          items: items,
          onAction: (group, action) => applied = group,
        ),
      ),
    );
    expect(find.text('3 messages'), findsOneWidget);
    expect(find.text('Correct'), findsOneWidget);
    await tester.tap(find.text('Correct'));
    expect(applied, hasLength(3));
  });
  test('why text covers each category source and link family', () {
    for (final source in [
      'user',
      'shared',
      'catalogue',
      'mcc',
      'history_confirmed',
      'ai',
      'default',
    ]) {
      expect(
        explainDecision({
          'category': {'source': source},
        }).single,
        startsWith('Category:'),
      );
    }
    for (final rule in [
      'LINK-CARD-BILL',
      'LINK-IPO',
      'LINK-REFUND',
      'LINK-WALLET',
      'LINK-DUPLICATE',
      'LINK-RECEIPT',
    ]) {
      expect(
        explainDecision({
          'event': {'linkRuleId': rule},
        }),
        isNotEmpty,
      );
    }
  });
}
