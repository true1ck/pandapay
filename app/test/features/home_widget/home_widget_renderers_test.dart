import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/home_widget/home_widget_renderers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const amounts = <String, double>{
    'Other': 342000,
    'Online Shopping': 101000,
    'Groceries': 19640,
    'Travel': 17650,
    'Fuel': 2100,
    'Dining': 1190,
    'Health & Pharmacy': 1250,
    'Bills & Utilities': 1100,
    'Other spending': 499,
  };
  final report = SpendReport(
    period: SpendPeriod.month,
    periodStart: DateTime(2026, 10),
    periodEnd: DateTime(2026, 11),
    elapsedFraction: .7,
    spend: EntryKindTotals(
      total: Money.fromRupees(amounts.values.reduce((a, b) => a + b)),
      txnCount: 42,
      rewards: Money.fromRupees(53.85),
    ),
    income: EntryKindTotals.zero,
    investment: EntryKindTotals.zero,
    previousSpend: EntryKindTotals.zero,
    byCategory: [
      for (final entry in amounts.entries)
        SpendBreakdownRow(
          label: entry.key,
          total: Money.fromRupees(entry.value),
          txnCount: 1,
        ),
    ],
    byMerchant: const [],
    byCard: const [],
    byInstrument: const [],
    series: const [],
  );
  final recommendation = RecommendationEngine().rank(
    RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe),
    [
      CardSnapshot(
        product: CardProduct(
          id: 'hdfc-millennia',
          name: 'HDFC Millennia',
          issuerName: 'HDFC Bank',
          network: CardNetwork.visa,
          rewardRules: const [
            RewardRule(
              id: 'cashback',
              unit: RewardUnit.cashbackPercent,
              rate: 5,
            ),
          ],
        ),
      ),
    ],
  ).first;

  setUpAll(() async {
    BambooFonts.useSystemFontsForTests = true;
    final fontPath = Platform.environment['PANDAPAY_WIDGET_PREVIEW_FONT'];
    if (fontPath != null) {
      final font = FontLoader('WidgetPreview')
        ..addFont(
          File(
            fontPath,
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await font.load();
      final icons = File(
        '${File(fontPath).parent.path}/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        final material = FontLoader('MaterialIcons')
          ..addFont(
            icons.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await material.load();
      }
    }
  });
  tearDownAll(() => BambooFonts.useSystemFontsForTests = false);

  Future<void> render(
    WidgetTester tester,
    Widget child,
    Size size,
    String name,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'WidgetPreview'),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('preview'),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [child],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/logo/pandapay_mark.png'),
        tester.element(find.byType(Scaffold)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$name must fit its canvas');
    final output = Platform.environment['PANDAPAY_WIDGET_PREVIEW_DIR'];
    if (output != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('preview')),
        );
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  }

  for (final profile in <String, Size>{
    'portrait': const Size(280, 420),
    'large': const Size(340, 400),
    'square': const Size(320, 320),
    'landscape': const Size(400, 300),
    'tall': const Size(220, 440),
    'medium': const Size(600, 300),
    'wide': const Size(840, 220),
  }.entries) {
    testWidgets(
      '${profile.key} keeps every category and real rewards visible',
      (tester) async {
        await render(
          tester,
          WidgetExpandedDetails(
            report: report,
            recommendation: recommendation,
            canvasSize: profile.value,
          ),
          profile.value,
          profile.key,
        );
        expect(find.text('₹53.85'), findsOneWidget);
        expect(find.text('HDFC Millennia'), findsOneWidget);
        for (final row in report.byCategory) {
          expect(find.textContaining('${row.label} ·'), findsOneWidget);
          expect(
            find.text(row.total.format(compact: true, hidePaise: true)),
            findsOneWidget,
          );
        }
        if (profile.value.aspectRatio < 1.6) {
          final label = find.textContaining('Online Shopping ·');
          final value = find.text('₹1.01L');
          expect(
            (tester.getCenter(label).dy - tester.getCenter(value).dy).abs(),
            lessThan(1),
            reason: 'Category and amount share one row',
          );
        }
      },
    );
  }

  for (final showCard in [true, false]) {
    for (final size in [const Size(200, 220), const Size(360, 144)]) {
      testWidgets('compact $size shows top categories, card=$showCard', (
        tester,
      ) async {
        await render(
          tester,
          WidgetCompactDetails(
            report: report,
            recommendation: recommendation,
            showRecommendation: showCard,
            canvasSize: size,
          ),
          size,
          'compact_${showCard ? 'combined' : 'spending'}_${size.width.toInt()}',
        );
        expect(find.text('₹53.85'), findsOneWidget);
        expect(find.textContaining('Online Shopping'), findsOneWidget);
        expect(find.text('Health & Pharmacy'), findsNothing);
        expect(
          find.text('HDFC Millennia'),
          showCard ? findsOneWidget : findsNothing,
        );
      });
    }
  }

  testWidgets('standalone card fits the native renderer height', (
    tester,
  ) async {
    await render(
      tester,
      WidgetCardArt(product: recommendation.card),
      const Size(180, 108),
      'card',
    );
  });

  testWidgets('empty report and absent recommendation render useful states', (
    tester,
  ) async {
    const size = Size(340, 400);
    await render(
      tester,
      const WidgetExpandedDetails(
        report: null,
        recommendation: null,
        canvasSize: size,
      ),
      size,
      'empty',
    );
    expect(
      find.text('Add a transaction to see your categories'),
      findsOneWidget,
    );
    expect(find.text('Add a card to get your best pick'), findsOneWidget);
  });
}
