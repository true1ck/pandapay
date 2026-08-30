import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/scan/card_text_matcher.dart';
import 'package:pandapay/features/scan/scan_card_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Regression guard for the "scanned, but the result panel is mangled" bug:
/// the app-wide `filledButtonTheme` forces `Size.fromHeight(52)` (full
/// width) onto every [FilledButton]. When the per-match "Use this" button
/// was a `ListTile.trailing`, that full-width demand squeezed the match
/// name/reason text down to roughly one character per line and left the
/// button itself sprawling across the panel.
void main() {
  final catalogue = [
    CardProduct(id: 'c1', name: 'HDFC Bank Millennia', network: CardNetwork.visa),
    CardProduct(id: 'c2', name: 'SBI Cashback', network: CardNetwork.rupay),
  ];

  Future<void> pumpPanel(WidgetTester tester, {required double width}) async {
    final matches = matchCardText(
      const ExtractedCardText('HDFC BANK MILLENNIA VISA 4242 1234'),
      catalogue,
    );
    expect(matches, isNotEmpty, reason: 'test needs at least one match to render');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 400,
              child: ScanResultPanel(
                extracted: const ExtractedCardText('HDFC BANK MILLENNIA VISA 4242 1234'),
                matches: matches,
                showRawText: true,
                onConfirm: (_) {},
                onRescan: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lays out without overflow at a phone-panel width', (tester) async {
    await pumpPanel(tester, width: 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('match name is not crushed to a sliver by the "Use this" button', (tester) async {
    await pumpPanel(tester, width: 360);

    final nameFinder = find.text('HDFC Bank Millennia');
    expect(nameFinder, findsOneWidget);

    // The bug rendered this text in a ~10px column (one glyph per line).
    // A healthy layout gives it the lion's share of the row.
    final nameWidth = tester.getSize(nameFinder).width;
    expect(nameWidth, greaterThan(150));
  });

  testWidgets('"Use this" button stays compact, not full-width', (tester) async {
    await pumpPanel(tester, width: 360);

    final useThis = find.widgetWithText(FilledButton, 'Use this');
    expect(useThis, findsWidgets);
    final buttonWidth = tester.getSize(useThis.first).width;
    // Panel is 360 wide minus 16*2 padding = 328. The button must not eat it.
    expect(buttonWidth, lessThan(180));
  });

  testWidgets('"Scan again" is present and full-width', (tester) async {
    await pumpPanel(tester, width: 360);
    expect(find.widgetWithText(OutlinedButton, 'Scan again'), findsOneWidget);
  });
}
