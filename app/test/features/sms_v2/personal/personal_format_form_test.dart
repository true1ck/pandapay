import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/personal/personal_format_service.dart';
import 'package:pandapay/features/sms_v2/ui/personal_format_form.dart';
import 'package:pandapay_domain/sms_v2.dart';

void main() {
  final message = SmsMessage(
    sender: 'VM-SYNTHBK-S',
    body: 'SYNTHBANK a/c **5678 posted INR 100.00 to ALPHA on 2026-11-01.',
    observedAt: DateTime.utc(2026, 11, 3),
    sourceKey: 'synthetic',
  );
  final instrument = Instrument(
    instrumentId: '00000000-0000-4000-8000-000000000001',
    kind: InstrumentKind.bankAccount,
    issuerSlug: 'synthetic',
    maskDigits: '5678',
    displayName: 'Synthetic bank',
    status: InstrumentStatus.confirmed,
    firstSeenAt: DateTime.utc(2026),
    lastSeenAt: DateTime.utc(2026),
    evidenceCount: 1,
  );
  Future<void> choose(WidgetTester tester, String key, String label) async {
    final control = find.byKey(Key(key));
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'form requires explicit account and printed amount then returns field spans',
    (tester) async {
      PersonalFormatChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  choice = await showModalBottomSheet<PersonalFormatChoice>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => PersonalFormatForm(
                      message: message,
                      instruments: [instrument],
                      groupCount: 2,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Each keeps its own amount'), findsOneWidget);
      await tester.ensureVisible(find.text('Use this format'));
      await tester.tap(find.text('Use this format'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a confirmed account or card'), findsOneWidget);
      expect(
        find.text('Choose the amount, not account digits'),
        findsOneWidget,
      );
      await choose(tester, 'personal-instrument', 'Synthetic bank ••5678');
      final amount = RegExp(r'100\.00').firstMatch(message.body)!;
      await choose(
        tester,
        'personal-amount',
        '100.00  (position ${amount.start + 1})',
      );
      await tester.ensureVisible(find.byKey(const Key('personal-merchant')));
      await tester.enterText(
        find.byKey(const Key('personal-merchant')),
        'ALPHA',
      );
      await choose(tester, 'personal-date', '2026-11-01');
      await tester.ensureVisible(find.text('Use this format'));
      await tester.tap(find.text('Use this format'));
      await tester.pumpAndSettle();
      expect(choice, isNotNull);
      expect(choice!.amount.text(message.body), '100.00');
      expect(choice!.merchant!.text(message.body), 'ALPHA');
      expect(choice!.date!.text(message.body), '2026-11-01');
      expect(choice!.instrumentId, instrument.instrumentId);
    },
  );
  testWidgets('form offers held or released semantics for IPO money', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PersonalFormatForm(message: message, instruments: [instrument]),
        ),
      ),
    );
    await choose(tester, 'personal-type', 'IPO money held or released');
    expect(find.text('What does the amount mean?'), findsOneWidget);
    expect(find.text('Money blocked (not spending)'), findsOneWidget);
  });
}
