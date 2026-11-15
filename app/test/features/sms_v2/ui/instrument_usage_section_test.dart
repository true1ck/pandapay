import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/ui/ledger_screens.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

/// "Holds and usage" shows only what is known: no "unknown" rows, no default
/// 0 points, no empty-IPO note, and no panel at all when nothing is known.
void main() {
  final t = DateTime.utc(2026, 11, 1);
  Instrument card({
    int? limit,
    int? available,
    int? points,
    InstrumentKind kind = InstrumentKind.creditCard,
  }) => Instrument(
    instrumentId: 'i1',
    kind: kind,
    issuerSlug: 'hdfc',
    maskDigits: '8708',
    displayName: 'HDFC card',
    status: InstrumentStatus.confirmed,
    creditLimitMinor: limit,
    availableMinor: available,
    pointsBalance: points,
    firstSeenAt: t,
    lastSeenAt: t,
    evidenceCount: 1,
  );

  Future<void> show(WidgetTester tester, Instrument i) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InstrumentUsageSection(
          instrument: i,
          model: LedgerReadModel(
            ledger: LedgerSnapshot(entries: [], events: []),
          ),
        ),
      ),
    ),
  );

  testWidgets('nothing known: no panel, no "unknown", no 0 points', (
    tester,
  ) async {
    await show(tester, card(points: 0));
    expect(find.text('Holds and usage'), findsNothing);
    expect(find.text('unknown'), findsNothing);
    expect(find.text('No active IPO holds'), findsNothing);
  });

  testWidgets('only the known rows show', (tester) async {
    await show(tester, card(limit: 5000000, available: 4000000, points: 120));
    expect(find.text('Holds and usage'), findsOneWidget);
    for (final label in ['Available', 'Limit', 'Used', 'Points']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('unknown'), findsNothing);

    await show(tester, card(available: 4000000));
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('Limit'), findsNothing);
    expect(find.text('Used'), findsNothing);
    expect(find.text('Points'), findsNothing);
  });
}
