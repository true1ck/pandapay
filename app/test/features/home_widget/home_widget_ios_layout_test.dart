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
    'Other': 3250,
    'Dining': 2910,
    'Online Shopping': 629.59,
    'Groceries': 330,
    'Entertainment': 149,
    'Fuel': 1,
  };
  final report = SpendReport(
    period: SpendPeriod.month,
    periodStart: DateTime(2026, 11),
    periodEnd: DateTime(2026, 12),
    elapsedFraction: .7,
    spend: EntryKindTotals(
      total: Money.fromRupees(7260),
      txnCount: 42,
      rewards: Money.fromRupees(30.5),
    ),
    income: EntryKindTotals.zero,
    investment: EntryKindTotals.zero,
    previousSpend: EntryKindTotals.zero,
    byCategory: [
      for (final e in amounts.entries)
        SpendBreakdownRow(
          label: e.key,
          total: Money.fromRupees(e.value),
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
          id: 'scapia',
          name: 'Scapia Federal Bank Credit Card',
          issuerName: 'Federal Bank',
          network: CardNetwork.visa,
          rewardRules: const [
            RewardRule(
              id: 'cashback',
              unit: RewardUnit.cashbackPercent,
              rate: 2,
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

  // iPhone widget sizes in points (iPhone 16 Pro Max): small, medium, large.
  const small = Size(170, 170);
  const medium = Size(364, 170);
  const large = Size(364, 382);

  for (final combined in [true, false]) {
    final tag = combined ? 'combined' : 'spending';
    testWidgets('$tag small', (tester) async {
      await render(
        tester,
        WidgetCompactDetails(
          report: report,
          recommendation: combined ? recommendation : null,
          showRecommendation: combined,
          canvasSize: small,
          textScale: 1.2,
        ),
        small,
        'ios_${tag}_small',
      );
    });
    testWidgets('$tag medium', (tester) async {
      await render(
        tester,
        WidgetExpandedDetails(
          report: report,
          recommendation: combined ? recommendation : null,
          showRecommendation: combined,
          canvasSize: medium,
          textScale: 1.2,
        ),
        medium,
        'ios_${tag}_medium',
      );
    });
    testWidgets('$tag large', (tester) async {
      await render(
        tester,
        WidgetExpandedDetails(
          report: report,
          recommendation: combined ? recommendation : null,
          showRecommendation: combined,
          canvasSize: large,
          textScale: 1.15,
        ),
        large,
        'ios_${tag}_large',
      );
    });
  }
}
