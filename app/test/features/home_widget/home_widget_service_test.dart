import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/home_widget/home_widget_service.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('home_widget');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'saveWidgetData') return true;
          if (call.method == 'updateWidget') return true;
          if (call.method == 'isRequestPinWidgetSupported') return true;
          if (call.method == 'requestPinWidget') return null;
          if (call.method == 'getInstalledWidgets') {
            return [
              {
                'widgetId': 1,
                'androidClassName': '.BestCardWidgetProvider',
                'label': 'PandaPay',
              },
            ];
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  CardProduct card(String id, double rate) => CardProduct(
    id: id,
    name: id,
    network: CardNetwork.rupay,
    isUpiLinkable: true,
    rewardRules: [
      RewardRule(id: '$id-rule', unit: RewardUnit.cashbackPercent, rate: rate),
    ],
  );

  HomeWidgetService service() => HomeWidgetService(
    renderer: (widget, {required key, required logicalSize}) async =>
        '/test/$key.png',
  );

  test('writes card assets and refreshes all three provider types', () async {
    final rec = RecommendationEngine().rank(
      RecommendationContext(
        amount: Money.fromRupees(1000),
        rail: TxnRail.swipe,
      ),
      [CardSnapshot(product: card('best-card', 5))],
    ).first;

    await service().updateBestCardWidget(
      recommendation: rec,
      nowIso: '2026-08-06T00:00:00.000Z',
    );

    final saveCalls = calls.where((call) => call.method == 'saveWidgetData');
    final updateCalls = calls.where((call) => call.method == 'updateWidget');
    expect(updateCalls, hasLength(3));
    expect(
      updateCalls.map((call) => call.arguments['qualifiedAndroidName']),
      containsAll([
        HomeWidgetService.combinedQualifiedAndroidName,
        HomeWidgetService.spendingQualifiedAndroidName,
        HomeWidgetService.recommendationQualifiedAndroidName,
      ]),
    );

    final saved = <String, dynamic>{
      for (final call in saveCalls)
        call.arguments['id'] as String: call.arguments['data'],
    };
    expect(saved[HomeWidgetService.cardNameKey], 'best-card');
    expect(
      saved[HomeWidgetService.cardValueKey],
      rec.expectedValue.format(compact: true, hidePaise: true),
    );
    expect(
      saved[HomeWidgetService.cardArtPathKey],
      '/test/pandapay_best_card.png',
    );
    expect(
      saved[HomeWidgetService.spendChartPathKey],
      '/test/pandapay_spend_chart.png',
    );
    expect(
      saved[HomeWidgetService.brandMarkPathKey],
      '/test/pandapay_widget_mark.png',
    );
    expect(
      saved[HomeWidgetService.compactDetailsPathKey],
      '/test/pandapay_widget_compact.png',
    );
    expect(
      saved[HomeWidgetService.compactWideDetailsPathKey],
      '/test/pandapay_widget_compact_wide.png',
    );
    expect(
      saved[HomeWidgetService.spendingCompactDetailsPathKey],
      '/test/pandapay_widget_spending_compact.png',
    );
    expect(
      saved[HomeWidgetService.spendingCompactWideDetailsPathKey],
      '/test/pandapay_widget_spending_compact_wide.png',
    );
    expect(
      saved[HomeWidgetService.expandedDetailsPathKey],
      '/test/pandapay_widget_expanded.png',
    );
    expect(
      saved[HomeWidgetService.expandedPortraitDetailsPathKey],
      '/test/pandapay_widget_expanded_portrait.png',
    );
    expect(
      saved[HomeWidgetService.expandedWideDetailsPathKey],
      '/test/pandapay_widget_expanded_wide.png',
    );
    expect(
      saved[HomeWidgetService.expandedMediumDetailsPathKey],
      '/test/pandapay_widget_expanded_medium.png',
    );
    expect(
      saved[HomeWidgetService.expandedLargeDetailsPathKey],
      '/test/pandapay_widget_expanded_large.png',
    );
    expect(
      saved[HomeWidgetService.spendingDetailsPathKey],
      '/test/pandapay_widget_spending_expanded.png',
    );
    expect(
      saved[HomeWidgetService.spendingPortraitDetailsPathKey],
      '/test/pandapay_widget_spending_portrait_expanded.png',
    );
    expect(
      saved[HomeWidgetService.spendingWideDetailsPathKey],
      '/test/pandapay_widget_spending_wide_expanded.png',
    );
    expect(
      saved[HomeWidgetService.spendingMediumDetailsPathKey],
      '/test/pandapay_widget_spending_medium_expanded.png',
    );
    expect(
      saved[HomeWidgetService.spendingLargeDetailsPathKey],
      '/test/pandapay_widget_spending_large_expanded.png',
    );
    expect(saved[HomeWidgetService.noCardKey], false);
    expect(saved[HomeWidgetService.updatedAtKey], '2026-08-06T00:00:00.000Z');
  });

  test('writes a no-card marker when the recommendation is null', () async {
    await service().updateBestCardWidget(
      recommendation: null,
      nowIso: '2026-08-06T00:00:00.000Z',
    );

    final saved = <String, dynamic>{
      for (final call in calls.where((call) => call.method == 'saveWidgetData'))
        call.arguments['id'] as String: call.arguments['data'],
    };
    expect(saved[HomeWidgetService.noCardKey], true);
    expect(saved[HomeWidgetService.cardNameKey], '');
    expect(saved[HomeWidgetService.cardArtPathKey], '');
  });

  test('configures the iOS App Group once before writing', () async {
    final widgetService = service();
    await widgetService.updateBestCardWidget(
      recommendation: null,
      nowIso: '2026-08-06T00:00:00.000Z',
    );
    await widgetService.updateBestCardWidget(
      recommendation: null,
      nowIso: '2026-08-06T00:01:00.000Z',
    );

    final callsToSetAppGroup = calls.where(
      (call) => call.method == 'setAppGroupId',
    );
    expect(callsToSetAppGroup, hasLength(1));
    expect(
      callsToSetAppGroup.single.arguments['groupId'],
      HomeWidgetService.iosAppGroupId,
    );
  });

  test('checks pin support and pins the selected variant', () async {
    final widgetService = service();
    expect(await widgetService.isPinWidgetSupported(), isTrue);

    await widgetService.pinWidget(HomeWidgetVariant.spending);
    final pinCall = calls.singleWhere(
      (call) => call.method == 'requestPinWidget',
    );
    expect(
      pinCall.arguments['qualifiedAndroidName'],
      HomeWidgetService.spendingQualifiedAndroidName,
    );
  });

  test('detects an installed PandaPay widget', () async {
    expect(await service().isWidgetInstalled(), isTrue);
  });
}
