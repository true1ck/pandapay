import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/spend_trends_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// The payment-method rows are cards in their own right, exactly like the
/// category rows above them. They must not sit inside a second wrapping card,
/// which squeezed them narrower than the categories.
void main() {
  testWidgets('payment method rows are as wide as category rows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    BambooFonts.useSystemFontsForTests = true;
    addTearDown(() => BambooFonts.useSystemFontsForTests = false);
    tester.view.physicalSize = const Size(460, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final shotPath = Platform.environment['PAYMENT_SHOT'];
    if (shotPath != null) {
      final loader = FontLoader('SegoeUI')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/segoeui.ttf').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
    }

    final report = SpendReport(
      period: SpendPeriod.month,
      periodStart: DateTime(2026, 8, 1),
      periodEnd: DateTime(2026, 9, 1),
      elapsedFraction: 0.5,
      spend: EntryKindTotals(
        total: Money.fromRupees(2150000),
        txnCount: 972,
        rewards: const Money.zero(),
      ),
      income: const EntryKindTotals(
        total: Money.zero(),
        txnCount: 0,
        rewards: Money.zero(),
      ),
      investment: const EntryKindTotals(
        total: Money.zero(),
        txnCount: 0,
        rewards: Money.zero(),
      ),
      previousSpend: EntryKindTotals(
        total: Money.fromRupees(1900000),
        txnCount: 900,
        rewards: const Money.zero(),
      ),
      byCategory: [
        SpendBreakdownRow(
          label: 'Groceries',
          total: Money.fromRupees(12484.81),
          txnCount: 43,
          categoryId: 'groceries',
        ),
        SpendBreakdownRow(
          label: 'Bills & Utilities',
          total: Money.fromRupees(6879.78),
          txnCount: 12,
          categoryId: 'bills',
        ),
        SpendBreakdownRow(
          label: 'Fuel',
          total: Money.fromRupees(4721.81),
          txnCount: 9,
          categoryId: 'fuel',
        ),
      ],
      byMerchant: const [],
      byCard: const [],
      byInstrument: [
        InstrumentSpendRow(
          instrument: 'credit_card',
          total: Money.fromRupees(601448.97),
          txnCount: 582,
        ),
        InstrumentSpendRow(
          instrument: 'wallet',
          total: Money.fromRupees(14536.30),
          txnCount: 169,
        ),
        InstrumentSpendRow(
          instrument: 'other',
          total: Money.fromRupees(63750.30),
          txnCount: 42,
        ),
        InstrumentSpendRow(
          instrument: 'upi_bank',
          total: Money.fromRupees(1448131.88),
          txnCount: 179,
        ),
      ],
      series: const [],
    );

    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (ref) => const SpendReportQuery.preset(SpendPeriod.month),
          ),
          spendReportProvider.overrideWith((ref, q) async => report),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, q) async => const [],
          ),
          bankAccountSummariesProvider.overrideWith((ref) async => const []),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: shotPath != null ? 'SegoeUI' : null,
              scaffoldBackgroundColor: Colors.white,
            ),
            debugShowCheckedModeBanner: false,
            home: const SpendTrendsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final label = find.text('PAYMENT METHOD');
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    expect(label, findsOneWidget);

    // Compare the outer card of a category row with a payment-method row.
    double cardWidth(String text) {
      final box = find
          .ancestor(of: find.text(text), matching: find.byType(DecoratedBox))
          .evaluate()
          .map((e) => (e.renderObject! as RenderBox).size.width)
          .reduce((a, b) => a > b ? a : b);
      return box;
    }

    final category = cardWidth('Groceries');
    final payment = cardWidth('Credit cards');
    expect(payment, category, reason: 'payment rows must match category width');

    if (shotPath != null) {
      await tester.runAsync(() async {
        final ro =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await ro.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(shotPath).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
