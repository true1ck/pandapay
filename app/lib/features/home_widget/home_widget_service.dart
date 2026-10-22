import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/spend_reports_repository.dart';
import 'home_widget_renderers.dart';

enum HomeWidgetVariant { combined, spending, recommendation }

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
  HomeWidgetService({HomeWidgetRenderer? renderer})
    : _renderer = renderer ?? _renderFlutterWidget;

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

  final HomeWidgetRenderer _renderer;
  bool _configured = false;

  Future<void> configure() async {
    if (_configured) return;
    await HomeWidget.setAppGroupId(iosAppGroupId);
    _configured = true;
  }

  Future<void> updateHomeWidgets({
    required SpendReport? report,
    required Recommendation? recommendation,
    required String nowIso,
  }) async {
    await configure();

    final categories = (report?.byCategory ?? const <SpendBreakdownRow>[])
        .where((row) => !row.total.isZero)
        .toList();
    final topCategory = categories.isEmpty ? null : categories.first;
    final currentRecommendation =
        recommendation != null && !recommendation.isExcluded
        ? recommendation
        : null;
    final compactDetailsPath = await _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: currentRecommendation,
      ),
      key: 'pandapay_widget_compact',
      logicalSize: const Size(200, 220),
    );
    final compactWideDetailsPath = await _renderer(
      WidgetCompactDetails(
        report: report,
        recommendation: currentRecommendation,
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
      ),
      key: 'pandapay_widget_expanded',
      logicalSize: const Size(320, 320),
    );
    final expandedPortraitDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        canvasSize: const Size(280, 420),
      ),
      key: 'pandapay_widget_expanded_portrait',
      logicalSize: const Size(280, 420),
    );
    final expandedWideDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        canvasSize: const Size(840, 220),
      ),
      key: 'pandapay_widget_expanded_wide',
      logicalSize: const Size(840, 220),
    );
    final expandedMediumDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
        canvasSize: const Size(600, 300),
      ),
      key: 'pandapay_widget_expanded_medium',
      logicalSize: const Size(600, 300),
    );
    final expandedLargeDetailsPath = await _renderer(
      WidgetExpandedDetails(
        report: report,
        recommendation: currentRecommendation,
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
            showRecommendation: combined,
            canvasSize: profile.value,
          ),
          key: 'pandapay_widget_${prefix}_${profile.key}',
          logicalSize: profile.value,
        );
        await HomeWidget.saveWidgetData<String>(
          '${prefix}_${profile.key}_details_path',
          path,
        );
      }
    }
    final cardPath = currentRecommendation == null
        ? ''
        : await _renderer(
            WidgetCardArt(product: currentRecommendation.card),
            key: 'pandapay_best_card',
            logicalSize: const Size(180, 108),
          );

    await HomeWidget.saveWidgetData<String>(spendChartPathKey, chartPath);
    await HomeWidget.saveWidgetData<String>(
      compactDetailsPathKey,
      compactDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      compactWideDetailsPathKey,
      compactWideDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingCompactDetailsPathKey,
      spendingCompactDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingCompactWideDetailsPathKey,
      spendingCompactWideDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(brandMarkPathKey, brandMarkPath);
    await HomeWidget.saveWidgetData<String>(
      expandedDetailsPathKey,
      expandedDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      expandedPortraitDetailsPathKey,
      expandedPortraitDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      expandedWideDetailsPathKey,
      expandedWideDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      expandedMediumDetailsPathKey,
      expandedMediumDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      expandedLargeDetailsPathKey,
      expandedLargeDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingDetailsPathKey,
      spendingDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingPortraitDetailsPathKey,
      spendingPortraitDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingWideDetailsPathKey,
      spendingWideDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingMediumDetailsPathKey,
      spendingMediumDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(
      spendingLargeDetailsPathKey,
      spendingLargeDetailsPath,
    );
    await HomeWidget.saveWidgetData<String>(cardArtPathKey, cardPath);
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
      currentRecommendation != null
          ? currentRecommendation.expectedValue.format(
              compact: true,
              hidePaise: true,
            )
          : '',
    );
    await HomeWidget.saveWidgetData<String>(
      cardReasonKey,
      currentRecommendation != null &&
              currentRecommendation.reasonLines.isNotEmpty
          ? currentRecommendation.reasonLines.first
          : '',
    );
    await HomeWidget.saveWidgetData<String>(updatedAtKey, nowIso);

    await Future.wait([
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
      return widgets.any(
        (widget) => providerNames.any(
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
      pixelRatio: 2,
    );
    return path as String;
  }
}
