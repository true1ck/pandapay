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
