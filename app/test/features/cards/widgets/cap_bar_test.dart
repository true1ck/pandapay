import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/cards/cap_progress.dart';
import 'package:pandapay/features/cards/widgets/cap_bar.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../support/v2_catalogue_fixtures.dart';

final _now = DateTime(2026, 11, 15);

CapProgress _progress({
  Object? native = 1240,
  String capKind = 'bonus_points',
  num capAmount = 1500,
  bool approximate = false,
}) {
  final product = parseCard(v2CardJson('p', capKind: capKind, capAmount: capAmount));
  final owned = parseUserCard(
    userCardJson(
      'uc',
      'p',
      capStates: [
        capStateRowJson(
          'p-cap',
          consumed: 0,
          consumedNative: native,
          capKind: capKind,
          capAmount: capAmount,
          periodStart: '2026-11-01',
          periodEnd: '2026-11-30',
          approximate: approximate,
        ),
      ],
    ),
  );
  return capProgressFor(
    product: product,
    cap: product.capRules.single,
    owned: owned,
    now: _now,
  )!;
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

LinearProgressIndicator _bar(WidgetTester tester) =>
    tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets('shows the native-unit line under the bar', (tester) async {
    await _pump(tester, CapBar(progress: _progress()));
    expect(
      find.text('1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100'),
      findsOneWidget,
    );
    expect(_bar(tester).value, closeTo(1240 / 1500, 1e-9));
  });

  testWidgets('shows the cap\'s label when given one', (tester) async {
    await _pump(tester, CapBar(progress: _progress(), title: 'Dining bonus'));
    expect(find.text('Dining bonus'), findsOneWidget);
  });

  testWidgets('an unknown cap is an empty bar and "Updating…", no numbers', (
    tester,
  ) async {
    await _pump(tester, CapBar(progress: _progress(native: null)));
    expect(find.text('Updating…'), findsOneWidget);
    expect(_bar(tester).value, 0);
    expect(find.textContaining('1,500'), findsNothing);
    expect(find.textContaining('resets'), findsNothing);
  });

  testWidgets('"approx." appears when the window is approximate', (
    tester,
  ) async {
    await _pump(tester, CapBar(progress: _progress(approximate: true)));
    expect(find.textContaining('resets approx. 1 Dec'), findsOneWidget);
  });

  testWidgets('the bar colour tracks the alert line: jade, amber, clay', (
    tester,
  ) async {
    for (final (native, color) in [
      (600, BambooInk.jade),
      (1250, BambooInk.amber), // 83%
      (1400, BambooInk.clay), // 93%
      (1500, BambooInk.clay),
    ]) {
      await _pump(tester, CapBar(progress: _progress(native: native)));
      expect(_bar(tester).color, color, reason: '$native');
    }
  });

  testWidgets('unit wording follows the cap kind', (tester) async {
    await _pump(
      tester,
      CapBar(
        progress: _progress(
          native: 12400,
          capKind: 'eligible_spend',
          capAmount: 20000,
        ),
      ),
    );
    expect(find.textContaining('₹12,400 / ₹20,000 spent'), findsOneWidget);

    await _pump(
      tester,
      CapBar(progress: _progress(native: 2, capKind: 'txn_count', capAmount: 3)),
    );
    expect(find.textContaining('2 / 3 uses'), findsOneWidget);

    await _pump(
      tester,
      CapBar(
        progress: _progress(
          native: 240,
          capKind: 'bonus_cashback',
          capAmount: 500,
        ),
      ),
    );
    expect(find.textContaining('₹240 / ₹500'), findsOneWidget);
  });

  testWidgets('a screen reader gets one sentence for the whole bar', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, CapBar(progress: _progress(), title: 'Dining bonus'));
    expect(
      find.bySemanticsLabel(
        'Dining bonus: 1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  test('fullestCapProgress: the fullest wins, unknown counts as full', () {
    final low = _progress(native: 100);
    final high = _progress(native: 1400);
    final unknown = _progress(native: null);
    expect(fullestCapProgress([low, high]), same(high));
    expect(fullestCapProgress([high, unknown, low]), same(unknown));
    expect(fullestCapProgress(const []), isNull);
  });
}
