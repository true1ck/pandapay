import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/spend_reports_repository.dart';
import '../insights/spending_visuals.dart';
import 'home_widget_renderers.dart';

enum HomeWidgetVariant { combined, spending, recommendation }

/// One card the widgets can show, with what it is best FOR. The widgets rotate
/// through a short list of these instead of repeating the single card Home
/// happens to have selected, which for most wallets was the same card always.
class WidgetCardPick {
  const WidgetCardPick({required this.caption, required this.recommendation});

  /// "Best for Dining" or "Best near Starbucks".
  final String caption;
  final Recommendation recommendation;
}

/// How long one pick stays on screen before the widget moves to the next.
const Duration widgetPickRotation = Duration(minutes: 20);

typedef HomeWidgetRenderer =
    Future<String> Function(
      Widget widget, {
      required String key,
      required Size logicalSize,
    });

/// Keeps the three launcher widgets in sync with the same spending report and
/// ranked recommendation shown on Home. Images are rendered from Flutter so
/// the pie slices and card face keep using the app's own visual components.
class HomeWidgetService {
  HomeWidgetService({HomeWidgetRenderer? renderer, bool? isIos})
    : _renderer = renderer ?? _renderFlutterWidget,
      _isIos = isIos ?? defaultTargetPlatform == TargetPlatform.iOS;

  static const String combinedAndroidWidgetName = 'CombinedHomeWidgetProvider';
  static const String combinedQualifiedAndroidName =
      'app.pandapay.pandapay.CombinedHomeWidgetProvider';
  static const String combinedIosWidgetName = 'PandaPayCombinedWidget';

  static const String spendingAndroidWidgetName = 'SpendingHomeWidgetProvider';
  static const String spendingQualifiedAndroidName =
      'app.pandapay.pandapay.SpendingHomeWidgetProvider';
  static const String spendingIosWidgetName = 'PandaPaySpendingWidget';

  static const String recommendationAndroidWidgetName =
      'BestCardWidgetProvider';
  static const String recommendationQualifiedAndroidName =
      'app.pandapay.pandapay.BestCardWidgetProvider';
  static const String recommendationIosWidgetName = 'PandaPayBestCardWidget';

  // Retained names for call sites that referred to the original card widget.
  static const String androidWidgetName = recommendationAndroidWidgetName;
  static const String qualifiedAndroidName = recommendationQualifiedAndroidName;
  static const String iosWidgetName = recommendationIosWidgetName;

  static const String iosAppGroupId = 'group.app.pandapay.pandapay.homewidget';
  static const String spendChartPathKey = 'spend_chart_path';
  static const String brandMarkPathKey = 'widget_brand_mark_path';
  static const String compactDetailsPathKey = 'compact_details_path';
  static const String compactWideDetailsPathKey = 'compact_wide_details_path';
  static const String spendingCompactDetailsPathKey =
      'spending_compact_details_path';
  static const String spendingCompactWideDetailsPathKey =
      'spending_compact_wide_details_path';
  static const String expandedDetailsPathKey = 'expanded_details_path';
  static const String expandedLandscapeDetailsPathKey =
      'expanded_landscape_details_path';
  static const String expandedTallDetailsPathKey = 'expanded_tall_details_path';
  static const String spendingLandscapeDetailsPathKey =
      'spending_landscape_details_path';
  static const String spendingTallDetailsPathKey = 'spending_tall_details_path';
  static const String expandedPortraitDetailsPathKey =
      'expanded_portrait_details_path';
  static const String expandedWideDetailsPathKey = 'expanded_wide_details_path';
  static const String expandedMediumDetailsPathKey =
      'expanded_medium_details_path';
  static const String expandedLargeDetailsPathKey =
      'expanded_large_details_path';
  static const String spendingDetailsPathKey = 'spending_details_path';
  static const String spendingPortraitDetailsPathKey =
      'spending_portrait_details_path';
  static const String spendingWideDetailsPathKey = 'spending_wide_details_path';
  static const String spendingMediumDetailsPathKey =
      'spending_medium_details_path';
  static const String spendingLargeDetailsPathKey =
      'spending_large_details_path';
  static const String cardArtPathKey = 'best_card_art_path';
  static const String spendTotalKey = 'spend_total_formatted';
  static const String spendPeriodKey = 'spend_period_label';
  static const String spendTopCategoryKey = 'spend_top_category';
  static const String spendTopCategoryValueKey =
      'spend_top_category_value_formatted';
  static const String spendRewardsKey = 'spend_rewards_formatted';
  static const String cardNameKey = 'best_card_name';
  static const String cardValueKey = 'best_card_value_formatted';
  static const String cardReasonKey = 'best_card_reason';
  static const String noCardKey = 'best_card_none';
  static const String updatedAtKey = 'best_card_updated_at';
  static const String cardCaptionKey = 'best_card_caption';
  static const String cardPicksJsonKey = 'card_picks_json';
  static const String spendCategoriesJsonKey = 'spend_categories_json';
  static const String syncMillisKey = 'widget_sync_ms';

  /// Every key this service writes to the shared widget store. Sign-out
  /// clears all of them; a test keeps the list in step with the constants.
  static const List<String> allDataKeys = <String>[
    spendChartPathKey,
    brandMarkPathKey,
    compactDetailsPathKey,
    compactWideDetailsPathKey,
    spendingCompactDetailsPathKey,
    spendingCompactWideDetailsPathKey,
    expandedDetailsPathKey,
    expandedLandscapeDetailsPathKey,
    expandedTallDetailsPathKey,
    spendingLandscapeDetailsPathKey,
    spendingTallDetailsPathKey,
    expandedPortraitDetailsPathKey,
    expandedWideDetailsPathKey,
    expandedMediumDetailsPathKey,
    expandedLargeDetailsPathKey,
    spendingDetailsPathKey,
    spendingPortraitDetailsPathKey,
    spendingWideDetailsPathKey,
    spendingMediumDetailsPathKey,
    spendingLargeDetailsPathKey,
    cardArtPathKey,
    spendTotalKey,
    spendPeriodKey,
    spendTopCategoryKey,
    spendTopCategoryValueKey,
    spendRewardsKey,
    cardNameKey,
    cardValueKey,
    cardReasonKey,
    noCardKey,
    updatedAtKey,
    cardCaptionKey,
    cardPicksJsonKey,
    spendCategoriesJsonKey,
    syncMillisKey,
  ];

  /// Keys whose value is the path of an image rendered for the widgets.
  static const List<String> _imagePathKeys = <String>[
    spendChartPathKey,
    brandMarkPathKey,
    compactDetailsPathKey,
    compactWideDetailsPathKey,
    spendingCompactDetailsPathKey,
    spendingCompactWideDetailsPathKey,
    expandedDetailsPathKey,
    expandedLandscapeDetailsPathKey,
    expandedTallDetailsPathKey,
    spendingLandscapeDetailsPathKey,
    spendingTallDetailsPathKey,
    expandedPortraitDetailsPathKey,
    expandedWideDetailsPathKey,
    expandedMediumDetailsPathKey,
    expandedLargeDetailsPathKey,
    spendingDetailsPathKey,
    spendingPortraitDetailsPathKey,
    spendingWideDetailsPathKey,
    spendingMediumDetailsPathKey,
    spendingLargeDetailsPathKey,
    cardArtPathKey,
  ];

  final HomeWidgetRenderer _renderer;
  final bool _isIos;
  bool _configured = false;

  Future<void> configure() async {
    if (_configured) return;
    await HomeWidget.setAppGroupId(iosAppGroupId);
    _configured = true;
  }

  /// Refreshes the widgets. The spending numbers go first and the widgets are
  /// reloaded straight away, so a freshly opened app shows real figures within
  /// moments; the pictures and card picks follow and reload them again.
  ///
  /// [cardsReady] is false while the card list is still loading or failed:
  /// the card keys and the pictures that contain a card are then left exactly
  /// as they were, rather than being replaced by an "add a card" message.
  Future<void> updateHomeWidgets({
    required SpendReport? report,
    required Recommendation? recommendation,
    required String nowIso,
    List<WidgetCardPick> picks = const <WidgetCardPick>[],
    bool cardsReady = true,
  }) async {
    // Avoid running offscreen image rasterizations if the user has no active
    // home screen widgets placed on their launcher.
    if (!await isWidgetInstalled()) {
      return;
    }
    await configure();
    final watch = Stopwatch()..start();

    final categories = (report?.byCategory ?? const <SpendBreakdownRow>[])
        .where((row) => !row.total.isZero)
        .toList();
    final topCategory = categories.isEmpty ? null : categories.first;

    // Stage 1: numbers only. Cheap, so the widget has the right figures even
    // if the pictures below take a while.
    await HomeWidget.saveWidgetData<String>(
      spendTotalKey,
      report?.spend.total.format(compact: true, hidePaise: true) ?? '₹0',
    );
    await HomeWidget.saveWidgetData<String>(
      spendPeriodKey,
      report?.displayLabel ?? 'This month',
    );
    await HomeWidget.saveWidgetData<String>(
      spendTopCategoryKey,
      topCategory?.label ?? '',
    );
    await HomeWidget.saveWidgetData<String>(
      spendTopCategoryValueKey,
      topCategory?.total.format(compact: true, hidePaise: true) ?? '',
    );
    await HomeWidget.saveWidgetData<String>(
      spendRewardsKey,
      report?.spend.rewards.format(compact: true) ?? '₹0',
    );
    await HomeWidget.saveWidgetData<String>(
      spendCategoriesJsonKey,
      jsonEncode(_categoryRows(report, categories)),
    );
    await HomeWidget.saveWidgetData<String>(updatedAtKey, nowIso);
    await _reloadAll();

    // Stage 2: pictures, then the card data that goes with them.
    final now = DateTime.tryParse(nowIso);
    final bucket = now == null
        ? 0
        : now.millisecondsSinceEpoch ~/ widgetPickRotation.inMilliseconds;
    final active = picks.isEmpty ? null : picks[bucket % picks.length];
    final currentRecommendation =
        active?.recommendation ??
        (recommendation != null && !recommendation.isExcluded
            ? recommendation
            : null);
    final caption = active?.caption;
    final images = _isIos
        ? await _renderIosImages(
            report,
            currentRecommendation,
            caption,
            cardsReady,
          )
        : await _renderAndroidImages(
            report,
            currentRecommendation,
            caption,
            cardsReady,
          );
    final pickJson = cardsReady
        ? await _renderPicks(picks, currentRecommendation)
        : const <Map<String, String>>[];
    for (final entry in images.entries) {
      await HomeWidget.saveWidgetData<String>(entry.key, entry.value);
    }
    if (cardsReady) {
      await HomeWidget.saveWidgetData<bool>(
        noCardKey,
        currentRecommendation == null,
      );
      await HomeWidget.saveWidgetData<String>(
        cardNameKey,
        currentRecommendation?.card.name ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        cardValueKey,
        currentRecommendation?.expectedValue.format(
              compact: true,
              hidePaise: true,
            ) ??
            '',
      );
      await HomeWidget.saveWidgetData<String>(
        cardReasonKey,
        currentRecommendation == null ? '' : pickReason(currentRecommendation),
      );
      await HomeWidget.saveWidgetData<String>(cardCaptionKey, caption ?? '');
      await HomeWidget.saveWidgetData<String>(
        cardPicksJsonKey,
        jsonEncode(pickJson),
      );
    }
    await HomeWidget.saveWidgetData<String>(
      syncMillisKey,
      '${watch.elapsedMilliseconds}',
    );
    await _reloadAll();
  }

  Future<void> _reloadAll() => Future.wait([
    HomeWidget.updateWidget(
      androidName: combinedAndroidWidgetName,
      qualifiedAndroidName: combinedQualifiedAndroidName,
      iOSName: combinedIosWidgetName,
    ),
    HomeWidget.updateWidget(
      androidName: spendingAndroidWidgetName,
      qualifiedAndroidName: spendingQualifiedAndroidName,
      iOSName: spendingIosWidgetName,
    ),
    HomeWidget.updateWidget(
      androidName: recommendationAndroidWidgetName,
      qualifiedAndroidName: recommendationQualifiedAndroidName,
      iOSName: recommendationIosWidgetName,
    ),
  ]);

  /// The few lines the plain (picture-less) widget views draw: the biggest
  /// categories with their share and colour, so a widget whose pictures are not
  /// ready yet still shows the real breakdown instead of an empty ring.
  static List<Map<String, Object>> _categoryRows(
    SpendReport? report,
    List<SpendBreakdownRow> categories,
  ) {
    final total = report?.spend.total.paise ?? 0;
    return <Map<String, Object>>[
      for (final row in categories.take(6))
        {
          'label': row.label,
          'value': row.total.format(compact: true, hidePaise: true),
          'share': total > 0 ? row.total.paise / total : 0.0,
          'color':
              spendingCategoryVisual(row.label).accent.toARGB32() & 0xFFFFFF,
        },
    ];
  }

  /// "5% back" or the engine's own first reason line.
  static String pickReason(Recommendation recommendation) {
    final rate = recommendation.effectiveRatePerRupee;
    if (rate != null && rate > 0) {
      final percent = rate * 100;
      final text = percent == percent.roundToDouble()
          ? percent.toStringAsFixed(0)
          : percent.toStringAsFixed(1);
      return '$text% back';
    }
    return recommendation.reasonLines.isNotEmpty
        ? recommendation.reasonLines.first
        : '';
  }

  /// Draws each pick's card face and returns the list the widgets rotate
  /// through. The first entry is always the pick shown by the pictures.
  Future<List<Map<String, String>>> _renderPicks(
    List<WidgetCardPick> picks,
    Recommendation? current,
  ) async {
    final shown = picks.take(5).toList();
    final arts = await Future.wait([
      for (var i = 0; i < shown.length; i++)
        _renderer(
          WidgetCardArt(product: shown[i].recommendation.card),
          key: 'pandapay_best_card_$i',
          logicalSize: const Size(180, 108),
        ),
    ]);
    return <Map<String, String>>[
      for (var i = 0; i < shown.length; i++)
        {
          'caption': shown[i].caption,
          'name': shown[i].recommendation.card.name,
          'value': shown[i].recommendation.expectedValue.format(
            compact: true,
            hidePaise: true,
          ),
          'reason': pickReason(shown[i].recommendation),
          'art': arts[i],
        },
    ];
  }

  /// Every image the Android launcher widgets pick from, one per widget shape.
  Future<Map<String, String>> _renderAndroidImages(
    SpendReport? report,
    Recommendation? currentRecommendation,
    String? caption,
    bool cardsReady,
  ) async {
    final compactDetailsPath = await _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
      ),
      key: 'pandapay_widget_compact',
      logicalSize: const Size(200, 220),
    );
    final compactWideDetailsPath = await _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
        canvasSize: const Size(360, 144),
      ),
      key: 'pandapay_widget_compact_wide',
      logicalSize: const Size(360, 144),
    );
    final spendingCompactDetailsPath = await _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: null,
        showRecommendation: false,
      ),
      key: 'pandapay_widget_spending_compact',
      logicalSize: const Size(200, 220),
    );
    final spendingCompactWideDetailsPath = await _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: null,
        showRecommendation: false,
        canvasSize: const Size(360, 144),
      ),
      key: 'pandapay_widget_spending_compact_wide',
      logicalSize: const Size(360, 144),
    );
    final chartPath = await _renderer(
      WidgetSpendChart(report: report),
      key: 'pandapay_spend_chart',
      logicalSize: const Size(144, 144),
    );
    final brandMarkPath = await _renderer(
      const WidgetBrandMark(),
      key: 'pandapay_widget_mark',
      logicalSize: const Size(48, 48),
    );
    final expandedDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
      ),
      key: 'pandapay_widget_expanded',
      logicalSize: const Size(320, 320),
    );
    final expandedPortraitDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
        canvasSize: const Size(280, 420),
      ),
      key: 'pandapay_widget_expanded_portrait',
      logicalSize: const Size(280, 420),
    );
    final expandedWideDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
        canvasSize: const Size(840, 220),
      ),
      key: 'pandapay_widget_expanded_wide',
      logicalSize: const Size(840, 220),
    );
    final expandedMediumDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
        canvasSize: const Size(600, 300),
      ),
      key: 'pandapay_widget_expanded_medium',
      logicalSize: const Size(600, 300),
    );
    final expandedLargeDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        recommendationLabel: caption,
        canvasSize: const Size(340, 400),
      ),
      key: 'pandapay_widget_expanded_large',
      logicalSize: const Size(340, 400),
    );
    final spendingDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: null,
        showRecommendation: false,
      ),
      key: 'pandapay_widget_spending_expanded',
      logicalSize: const Size(320, 320),
    );
    final spendingWideDetailsPath = await _renderer(
      WidgetExpandedSpendingDetails(
        report: report,
        canvasSize: const Size(840, 220),
      ),
      key: 'pandapay_widget_spending_wide_expanded',
      logicalSize: const Size(840, 220),
    );
    final spendingPortraitDetailsPath = await _renderer(
      WidgetExpandedSpendingDetails(report: report),
      key: 'pandapay_widget_spending_portrait_expanded',
      logicalSize: const Size(280, 420),
    );
    final spendingMediumDetailsPath = await _renderer(
      WidgetExpandedSpendingDetails(
        report: report,
        canvasSize: const Size(600, 300),
      ),
      key: 'pandapay_widget_spending_medium_expanded',
      logicalSize: const Size(600, 300),
    );
    final spendingLargeDetailsPath = await _renderer(
      WidgetExpandedSpendingDetails(
        report: report,
        canvasSize: const Size(340, 400),
      ),
      key: 'pandapay_widget_spending_large_expanded',
      logicalSize: const Size(340, 400),
    );
    // Match the intermediate launcher shapes as well as the largest sizes.
    // Otherwise fitCenter leaves large blank bands around a mismatched image.
    final extra = <String, String>{};
    for (final profile in <String, Size>{
      'landscape': const Size(400, 300),
      'tall': const Size(220, 440),
    }.entries) {
      for (final combined in [true, false]) {
        final prefix = combined ? 'expanded' : 'spending';
        final path = await _renderer(
          WidgetExpandedDetails(
            report: report,
            recommendation: combined ? currentRecommendation : null,
            recommendationLabel: combined ? caption : null,
            showRecommendation: combined,
            canvasSize: profile.value,
          ),
          key: 'pandapay_widget_${prefix}_${profile.key}',
          logicalSize: profile.value,
        );
        extra['${prefix}_${profile.key}_details_path'] = path;
      }
    }
    final cardPath = currentRecommendation == null
        ? ''
        : await _renderer(
            WidgetCardArt(product: currentRecommendation.card),
            key: 'pandapay_best_card',
            logicalSize: const Size(180, 108),
          );
    final images = <String, String>{
      spendChartPathKey: chartPath,
      compactDetailsPathKey: compactDetailsPath,
      compactWideDetailsPathKey: compactWideDetailsPath,
      spendingCompactDetailsPathKey: spendingCompactDetailsPath,
      spendingCompactWideDetailsPathKey: spendingCompactWideDetailsPath,
      brandMarkPathKey: brandMarkPath,
      expandedDetailsPathKey: expandedDetailsPath,
      expandedPortraitDetailsPathKey: expandedPortraitDetailsPath,
      expandedWideDetailsPathKey: expandedWideDetailsPath,
      expandedMediumDetailsPathKey: expandedMediumDetailsPath,
      expandedLargeDetailsPathKey: expandedLargeDetailsPath,
      spendingDetailsPathKey: spendingDetailsPath,
      spendingPortraitDetailsPathKey: spendingPortraitDetailsPath,
      spendingWideDetailsPathKey: spendingWideDetailsPath,
      spendingMediumDetailsPathKey: spendingMediumDetailsPath,
      spendingLargeDetailsPathKey: spendingLargeDetailsPath,
      cardArtPathKey: cardPath,
      ...extra,
    };
    // Pictures that contain the card panel are left alone while the card list
    // is not available, instead of being redrawn with "add a card".
    if (!cardsReady) {
      images.removeWhere((key, _) => _combinedImageKeys.contains(key));
    }
    return images;
  }

  // iPhone widget sizes in points (the 6.9" iPhones; the others are within a few
  // percent and the image scales to fit). Rendering at the real size, with a
  // larger text scale, is what keeps the type readable: the Android images are
  // drawn on a bigger canvas and shrunk, which leaves iPhone text tiny.
  static const Size _iosSmall = Size(170, 170);
  static const Size _iosMedium = Size(364, 170);
  static const Size _iosLarge = Size(364, 382);

  /// The images the iPhone widgets read, and only those: the three families for
  /// each of the two image-based widgets, plus the chart, brand mark and card
  /// art used by the native views.
  Future<Map<String, String>> _renderIosImages(
    SpendReport? report,
    Recommendation? currentRecommendation,
    String? caption,
    bool cardsReady,
  ) async {
    Future<String> compact(bool combined, String key) => _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: combined ? currentRecommendation : null,
        recommendationLabel: combined ? caption : null,
        showRecommendation: combined,
        canvasSize: _iosSmall,
        textScale: 1.2,
      ),
      key: key,
      logicalSize: _iosSmall,
    );
    Future<String> expanded(
      bool combined,
      Size size,
      double scale,
      String key,
    ) => _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: combined ? currentRecommendation : null,
        recommendationLabel: combined ? caption : null,
        showRecommendation: combined,
        canvasSize: size,
        textScale: scale,
      ),
      key: key,
      logicalSize: size,
    );
    // Everything is drawn at once; drawing them one after another is most of
    // the wait after the app opens.
    final jobs = <String, Future<String>>{
      spendChartPathKey: _renderer(
        WidgetSpendChart(report: report),
        key: 'pandapay_spend_chart',
        logicalSize: const Size(144, 144),
      ),
      brandMarkPathKey: _renderer(
        const WidgetBrandMark(),
        key: 'pandapay_widget_mark',
        logicalSize: const Size(48, 48),
      ),
      spendingCompactDetailsPathKey: compact(
        false,
        'pandapay_widget_spending_compact',
      ),
      spendingMediumDetailsPathKey: expanded(
        false,
        _iosMedium,
        1.2,
        'pandapay_widget_spending_medium_expanded',
      ),
      spendingLargeDetailsPathKey: expanded(
        false,
        _iosLarge,
        1.15,
        'pandapay_widget_spending_large_expanded',
      ),
      if (cardsReady) ...{
        compactDetailsPathKey: compact(true, 'pandapay_widget_compact'),
        expandedMediumDetailsPathKey: expanded(
          true,
          _iosMedium,
          1.2,
          'pandapay_widget_expanded_medium',
        ),
        expandedLargeDetailsPathKey: expanded(
          true,
          _iosLarge,
          1.15,
          'pandapay_widget_expanded_large',
        ),
        cardArtPathKey: currentRecommendation == null
            ? Future<String>.value('')
            : _renderer(
                WidgetCardArt(product: currentRecommendation.card),
                key: 'pandapay_best_card',
                logicalSize: const Size(180, 108),
              ),
      },
    };
    final done = await Future.wait(jobs.values);
    return <String, String>{
      for (final (index, key) in jobs.keys.indexed) key: done[index],
    };
  }

  /// Picture keys whose image includes the card panel.
  static const Set<String> _combinedImageKeys = <String>{
    compactDetailsPathKey,
    compactWideDetailsPathKey,
    expandedDetailsPathKey,
    expandedLandscapeDetailsPathKey,
    expandedTallDetailsPathKey,
    expandedPortraitDetailsPathKey,
    expandedWideDetailsPathKey,
    expandedMediumDetailsPathKey,
    expandedLargeDetailsPathKey,
    cardArtPathKey,
  };

  /// Removes everything the widgets show: deletes the rendered images, empties
  /// every shared key and refreshes the widgets so they go blank. Call it on
  /// sign-out. Failures to refresh a widget never stop the wipe.
  Future<void> clearAll() async {
    await configure();
    for (final key in _imagePathKeys) {
      try {
        final path = await HomeWidget.getWidgetData<String>(key);
        if (path != null && path.endsWith('.png')) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      } catch (_) {
        // A missing or unreadable image must not stop the data wipe below.
      }
    }
    try {
      // Each rotating pick has its own card image; delete those too.
      final raw = await HomeWidget.getWidgetData<String>(cardPicksJsonKey);
      if (raw != null && raw.isNotEmpty) {
        for (final pick in jsonDecode(raw) as List<dynamic>) {
          final path = (pick as Map<String, dynamic>)['art'] as String?;
          if (path != null && path.endsWith('.png')) {
            final file = File(path);
            if (await file.exists()) await file.delete();
          }
        }
      }
    } catch (_) {
      // Unreadable pick data must not stop the wipe below.
    }
    for (final key in allDataKeys) {
      if (key == noCardKey) {
        await HomeWidget.saveWidgetData<bool>(key, null);
      } else {
        await HomeWidget.saveWidgetData<String>(key, null);
      }
    }
    for (final (android, qualified, ios) in const [
      (
        combinedAndroidWidgetName,
        combinedQualifiedAndroidName,
        combinedIosWidgetName,
      ),
      (
        spendingAndroidWidgetName,
        spendingQualifiedAndroidName,
        spendingIosWidgetName,
      ),
      (
        recommendationAndroidWidgetName,
        recommendationQualifiedAndroidName,
        recommendationIosWidgetName,
      ),
    ]) {
      try {
        await HomeWidget.updateWidget(
          androidName: android,
          qualifiedAndroidName: qualified,
          iOSName: ios,
        );
      } catch (_) {
        // The widget may not be installed.
      }
    }
  }

  Future<void> updateBestCardWidget({
    required Recommendation? recommendation,
    required String nowIso,
  }) => updateHomeWidgets(
    report: null,
    recommendation: recommendation,
    nowIso: nowIso,
  );

  Future<bool> isPinWidgetSupported() async =>
      await HomeWidget.isRequestPinWidgetSupported() ?? false;

  Future<void> pinWidget(HomeWidgetVariant variant) async {
    await configure();
    final (androidName, qualifiedAndroidName) = switch (variant) {
      HomeWidgetVariant.combined => (
        combinedAndroidWidgetName,
        combinedQualifiedAndroidName,
      ),
      HomeWidgetVariant.spending => (
        spendingAndroidWidgetName,
        spendingQualifiedAndroidName,
      ),
      HomeWidgetVariant.recommendation => (
        recommendationAndroidWidgetName,
        recommendationQualifiedAndroidName,
      ),
    };
    await HomeWidget.requestPinWidget(
      androidName: androidName,
      qualifiedAndroidName: qualifiedAndroidName,
    );
  }

  Future<void> pinBestCardWidget() =>
      pinWidget(HomeWidgetVariant.recommendation);

  Future<bool> isWidgetInstalled() async {
    try {
      final widgets = await HomeWidget.getInstalledWidgets();
      const providerNames = [
        combinedAndroidWidgetName,
        spendingAndroidWidgetName,
        recommendationAndroidWidgetName,
      ];
      // iOS reports a WidgetKit `kind` (and no class name), Android reports
      // the provider class. Checking only the Android field made this return
      // false on iPhone, so updateHomeWidgets() never wrote any data there.
      const iosKinds = [
        combinedIosWidgetName,
        spendingIosWidgetName,
        recommendationIosWidgetName,
      ];
      return widgets.any(
        (widget) =>
            iosKinds.contains(widget.iOSKind) ||
            providerNames.any(
              (name) => widget.androidClassName?.contains(name) ?? false,
            ),
      );
    } catch (_) {
      return false;
    }
  }

  static Future<String> _renderFlutterWidget(
    Widget widget, {
    required String key,
    required Size logicalSize,
  }) async {
    final path = await HomeWidget.renderFlutterWidget(
      widget,
      key: key,
      logicalSize: logicalSize,
      pixelRatio: defaultTargetPlatform == TargetPlatform.iOS ? 3 : 2,
    );
    return path as String;
  }
}
