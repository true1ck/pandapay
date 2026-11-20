import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/home_widget/home_widget_service.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('home_widget');
  final calls = <MethodCall>[];
  var lastRendered = <String, Size>{};

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
    // Two reloads of the three widgets: numbers first, then pictures and card.
    expect(updateCalls, hasLength(6));
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

  group('card picks and staged refresh', () {
    Recommendation recFor(String id, double rate) =>
        RecommendationEngine().rank(
          RecommendationContext(
            amount: Money.fromRupees(1000),
            rail: TxnRail.swipe,
          ),
          [CardSnapshot(product: card(id, rate))],
        ).first;

    Map<String, dynamic> saved() => {
      for (final call in calls.where((c) => c.method == 'saveWidgetData'))
        call.arguments['id'] as String: call.arguments['data'],
    };

    test(
      'writes each pick with what it is best for and its own card image',
      () async {
        await service().updateHomeWidgets(
          report: null,
          recommendation: null,
          picks: [
            WidgetCardPick(
              caption: 'Best for Dining',
              recommendation: recFor('a', 5),
            ),
            WidgetCardPick(
              caption: 'Best for Fuel',
              recommendation: recFor('b', 3),
            ),
          ],
          nowIso: '2026-11-21T00:00:00.000',
        );
        final data = saved();
        final picks =
            jsonDecode(data[HomeWidgetService.cardPicksJsonKey] as String)
                as List<dynamic>;
        expect(picks.map((p) => (p as Map)['caption']), [
          'Best for Dining',
          'Best for Fuel',
        ]);
        expect(
          picks.map((p) => (p as Map)['art']),
          everyElement(startsWith('/test/pandapay_best_card_')),
        );
        expect((picks.first as Map)['reason'], '5% back');
      },
    );

    test('the pick on screen follows the 20 minute slot', () async {
      final first = DateTime.utc(2026, 11, 21, 0, 0);
      final picks = [
        WidgetCardPick(caption: 'one', recommendation: recFor('a', 5)),
        WidgetCardPick(caption: 'two', recommendation: recFor('b', 3)),
      ];
      Future<String> shownAt(DateTime at) async {
        calls.clear();
        await service().updateHomeWidgets(
          report: null,
          recommendation: null,
          picks: picks,
          nowIso: at.toIso8601String(),
        );
        return saved()[HomeWidgetService.cardCaptionKey] as String;
      }

      final a = await shownAt(first);
      final b = await shownAt(first.add(widgetPickRotation));
      expect(a, isNot(b));
    });

    test(
      'numbers are written and the widgets reloaded before the pictures',
      () async {
        await service().updateHomeWidgets(
          report: null,
          recommendation: null,
          nowIso: '2026-11-21T00:00:00.000',
        );
        final firstReload = calls.indexWhere((c) => c.method == 'updateWidget');
        final firstPicture = calls.indexWhere(
          (c) =>
              c.method == 'saveWidgetData' &&
              (c.arguments['id'] as String).endsWith('details_path'),
        );
        final totalWrite = calls.indexWhere(
          (c) =>
              c.method == 'saveWidgetData' &&
              c.arguments['id'] == HomeWidgetService.spendTotalKey,
        );
        expect(totalWrite, lessThan(firstReload));
        expect(firstReload, lessThan(firstPicture));
      },
    );

    test(
      'cards not ready leaves the card keys and card pictures alone',
      () async {
        await service().updateHomeWidgets(
          report: null,
          recommendation: null,
          cardsReady: false,
          nowIso: '2026-11-21T00:00:00.000',
        );
        final data = saved();
        for (final key in [
          HomeWidgetService.cardNameKey,
          HomeWidgetService.cardValueKey,
          HomeWidgetService.cardPicksJsonKey,
          HomeWidgetService.noCardKey,
          HomeWidgetService.compactDetailsPathKey,
          HomeWidgetService.expandedMediumDetailsPathKey,
        ]) {
          expect(data.containsKey(key), isFalse, reason: key);
        }
        // The spending side still updates.
        expect(data[HomeWidgetService.spendTotalKey], isNotNull);
        expect(
          data[HomeWidgetService.spendingMediumDetailsPathKey],
          startsWith('/test/'),
        );
      },
    );
  });

  group('iPhone images', () {
    Future<Map<String, String>> savedAfterUpdate({required bool ios}) async {
      final rendered = <String, Size>{};
      final widgetService = HomeWidgetService(
        isIos: ios,
        renderer: (widget, {required key, required logicalSize}) async {
          rendered[key] = logicalSize;
          return '/test/$key.png';
        },
      );
      await widgetService.updateHomeWidgets(
        report: null,
        recommendation: null,
        nowIso: '2026-11-21T00:00:00.000',
      );
      lastRendered = rendered;
      return {
        for (final call in calls.where((c) => c.method == 'saveWidgetData'))
          call.arguments['id'] as String: '${call.arguments['data']}',
      };
    }

    test(
      'renders only the six images iPhone reads, at real point sizes',
      () async {
        final saved = await savedAfterUpdate(ios: true);
        expect(
          lastRendered['pandapay_widget_expanded_medium'],
          const Size(364, 170),
        );
        expect(
          lastRendered['pandapay_widget_expanded_large'],
          const Size(364, 382),
        );
        expect(lastRendered['pandapay_widget_compact'], const Size(170, 170));
        for (final key in [
          HomeWidgetService.compactDetailsPathKey,
          HomeWidgetService.spendingCompactDetailsPathKey,
          HomeWidgetService.expandedMediumDetailsPathKey,
          HomeWidgetService.expandedLargeDetailsPathKey,
          HomeWidgetService.spendingMediumDetailsPathKey,
          HomeWidgetService.spendingLargeDetailsPathKey,
        ]) {
          expect(saved[key], startsWith('/test/'), reason: key);
        }
        // The Android-only shapes are not drawn on an iPhone.
        expect(
          saved.containsKey(HomeWidgetService.expandedWideDetailsPathKey),
          isFalse,
        );
        expect(
          saved.containsKey(HomeWidgetService.compactWideDetailsPathKey),
          isFalse,
        );
      },
    );

    test('Android still gets its full set of shapes', () async {
      final saved = await savedAfterUpdate(ios: false);
      expect(
        saved[HomeWidgetService.expandedWideDetailsPathKey],
        startsWith('/test/'),
      );
      expect(
        saved[HomeWidgetService.compactWideDetailsPathKey],
        startsWith('/test/'),
      );
      expect(
        lastRendered['pandapay_widget_expanded_medium'],
        const Size(600, 300),
      );
    });
  });

  group('iOS installed widgets (WidgetKit kind, no Android class name)', () {
    void reportIosWidgets(List<Map<String, String>> widgets) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getInstalledWidgets') return widgets;
            return true;
          });
    }

    test('each PandaPay kind counts as installed', () async {
      for (final kind in const [
        'PandaPayCombinedWidget',
        'PandaPaySpendingWidget',
        'PandaPayBestCardWidget',
      ]) {
        reportIosWidgets([
          {'family': 'systemSmall', 'kind': kind},
        ]);
        expect(await service().isWidgetInstalled(), isTrue, reason: kind);
      }
    });

    test('an unrelated kind does not count', () async {
      reportIosWidgets([
        {'family': 'systemSmall', 'kind': 'SomeOtherWidget'},
      ]);
      expect(await service().isWidgetInstalled(), isFalse);
    });

    test(
      'updateHomeWidgets writes data when only an iOS widget exists',
      () async {
        reportIosWidgets([
          {'family': 'systemMedium', 'kind': 'PandaPaySpendingWidget'},
        ]);
        await service().updateHomeWidgets(
          report: null,
          recommendation: null,
          nowIso: '2026-11-21T00:00:00.000',
        );
        expect(calls.where((c) => c.method == 'saveWidgetData'), isNotEmpty);
        expect(
          calls
              .where((c) => c.method == 'updateWidget')
              .map((c) => (c.arguments as Map)['ios'])
              .toSet(),
          containsAll(<String>[
            'PandaPayCombinedWidget',
            'PandaPaySpendingWidget',
            'PandaPayBestCardWidget',
          ]),
        );
      },
    );
  });

  group('clearAll', () {
    late Directory temp;
    late Map<String, Object?> stored;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('widget');
      stored = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getWidgetData') {
              return stored[call.arguments['id']];
            }
            return true;
          });
    });
    tearDown(() => temp.delete(recursive: true));

    test(
      'every data key is cleared, rendered files deleted, widgets refreshed',
      () async {
        final chart = File('${temp.path}/chart.png')..writeAsBytesSync([1]);
        final card = File('${temp.path}/card.png')..writeAsBytesSync([1]);
        final unrelated = File('${temp.path}/keep.txt')..writeAsStringSync('x');
        stored[HomeWidgetService.spendChartPathKey] = chart.path;
        stored[HomeWidgetService.cardArtPathKey] = card.path;
        stored[HomeWidgetService.cardNameKey] = unrelated.path;

        await service().clearAll();

        final cleared = <String, Object?>{
          for (final call in calls.where((c) => c.method == 'saveWidgetData'))
            call.arguments['id'] as String: call.arguments['data'],
        };
        for (final key in HomeWidgetService.allDataKeys) {
          expect(
            cleared.containsKey(key),
            isTrue,
            reason: '$key was not cleared',
          );
          expect(cleared[key], isNull, reason: '$key was saved with data');
        }
        expect(chart.existsSync(), isFalse);
        expect(card.existsSync(), isFalse);
        expect(
          unrelated.existsSync(),
          isTrue,
          reason: 'only rendered png paths are ever deleted',
        );
        final lastSave = calls.lastIndexWhere(
          (c) => c.method == 'saveWidgetData',
        );
        final firstUpdate = calls.indexWhere((c) => c.method == 'updateWidget');
        expect(firstUpdate, greaterThan(lastSave));
        expect(calls.where((c) => c.method == 'updateWidget'), hasLength(3));
      },
    );

    test('allDataKeys lists every *Key constant of the service', () {
      final source = File(
        'lib/features/home_widget/home_widget_service.dart',
      ).readAsStringSync();
      final declared = RegExp(
        r"static const String (\w+Key) =\s*'([^']+)'",
      ).allMatches(source).map((m) => m.group(2)!).toSet();
      expect(declared, isNotEmpty);
      expect(HomeWidgetService.allDataKeys.toSet(), declared);
    });

    test('a failing widget refresh does not stop the wipe', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'updateWidget') {
              throw PlatformException(code: 'x');
            }
            return null;
          });
      await service().clearAll();
      expect(calls.where((c) => c.method == 'saveWidgetData'), isNotEmpty);
    });
  });
}
