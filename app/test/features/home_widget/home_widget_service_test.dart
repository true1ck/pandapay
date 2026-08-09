import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/home_widget/home_widget_service.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// UA-8.2: `home_widget`'s actual native side (does a real widget redraw)
/// can't be exercised in this sandbox — see PROGRESS.md — but the Dart-side
/// contract (which keys get written, with what values, and that a redraw
/// is requested) is genuinely verifiable by intercepting the plugin's
/// MethodChannel, which is exactly what this test does.
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
        rewardRules: [RewardRule(id: '$id-rule', unit: RewardUnit.cashbackPercent, rate: rate)],
      );

  test('writes the recommendation\'s card name/value and triggers an update', () async {
    final engine = RecommendationEngine();
    final rec = engine
        .rank(
          RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe),
          [CardSnapshot(product: card('best-card', 5))],
        )
        .first;

    final service = HomeWidgetService();
    await service.updateBestCardWidget(recommendation: rec, nowIso: '2026-08-06T00:00:00.000Z');

    final saveCalls = calls.where((c) => c.method == 'saveWidgetData').toList();
    final updateCalls = calls.where((c) => c.method == 'updateWidget').toList();

    expect(updateCalls, hasLength(1));

    final saved = <String, dynamic>{
      for (final c in saveCalls) c.arguments['id'] as String: c.arguments['data'],
    };
    expect(saved[HomeWidgetService.cardNameKey], 'best-card');
    expect(saved[HomeWidgetService.cardValueKey], rec.expectedValue.format());
    expect(saved[HomeWidgetService.noCardKey], false);
    expect(saved[HomeWidgetService.updatedAtKey], '2026-08-06T00:00:00.000Z');
  });

  test('writes a "no card" marker when the recommendation is null', () async {
    final service = HomeWidgetService();
    await service.updateBestCardWidget(recommendation: null, nowIso: '2026-08-06T00:00:00.000Z');

    final saveCalls = calls.where((c) => c.method == 'saveWidgetData').toList();
    final saved = <String, dynamic>{
      for (final c in saveCalls) c.arguments['id'] as String: c.arguments['data'],
    };
    expect(saved[HomeWidgetService.noCardKey], true);
    expect(saved[HomeWidgetService.cardNameKey], '');
  });

  test('configures the iOS App Group id exactly once before the first update', () async {
    final service = HomeWidgetService();
    await service.updateBestCardWidget(recommendation: null, nowIso: '2026-08-06T00:00:00.000Z');
    await service.updateBestCardWidget(recommendation: null, nowIso: '2026-08-06T00:01:00.000Z');

    final setAppGroupCalls = calls.where((c) => c.method == 'setAppGroupId').toList();
    expect(setAppGroupCalls, hasLength(1));
    expect(setAppGroupCalls.single.arguments['groupId'], HomeWidgetService.iosAppGroupId);
  });
}
