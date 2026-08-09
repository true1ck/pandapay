import 'package:home_widget/home_widget.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// UA-8.2: writes the "single best card to use right now" to the native
/// home-screen widget's shared storage, and asks the OS to redraw it.
///
/// **What this class does is genuinely exercised**: it's a thin, directly
/// unit-testable wrapper around `home_widget`'s two calls
/// (`saveWidgetData`/`updateWidget`) driven by a real `Recommendation` from
/// `BestCardForWidget.pickBestCard` (packages/pandapay_domain). **What is
/// NOT verified**: whether an actual native Android/iOS widget provider
/// picks up `flutter.$_cardNameKey` etc. and redraws on a real home screen
/// — this sandbox has no device/simulator to confirm that. See
/// android/app/src/main/kotlin/.../BestCardWidgetProvider.kt and
/// ios/HomeWidgetExtension/ for the native-side skeletons, and PROGRESS.md
/// for the explicit "structurally present, unverified" callout.
class HomeWidgetService {
  /// Must match the Android `<receiver>` name / iOS widget kind wired up in
  /// the (unverified) native skeletons — see PROGRESS.md.
  static const String androidWidgetName = 'BestCardWidgetProvider';
  static const String iosWidgetName = 'PandaPayBestCardWidget';

  static const String cardNameKey = 'best_card_name';
  static const String cardValueKey = 'best_card_value_formatted';
  static const String updatedAtKey = 'best_card_updated_at';
  static const String noCardKey = 'best_card_none';

  /// The App Group `HomeWidgetExtension.swift`/Runner.entitlements/
  /// HomeWidgetExtension.entitlements all share — must match all three
  /// exactly. iOS-only concept (`setAppGroupId` is a no-op on Android,
  /// where `home_widget` uses SharedPreferences instead), but calling it
  /// unconditionally on every platform is simpler and harmless than
  /// branching on Platform.isIOS here.
  static const String iosAppGroupId = 'group.app.pandapay.pandapay.homewidget';

  bool _configured = false;

  /// Idempotent, called automatically by [updateBestCardWidget] — without
  /// this, `home_widget`'s iOS side has no UserDefaults suite to write
  /// into and every saveWidgetData call silently fails to reach the
  /// widget extension. Folded into the update call rather than requiring
  /// a separate startup call site, so there's no "someone forgot to wire
  /// this up" failure mode.
  Future<void> configure() async {
    if (_configured) return;
    await HomeWidget.setAppGroupId(iosAppGroupId);
    _configured = true;
  }

  /// Writes [recommendation] (or a "no usable card" marker when null) to
  /// the widget's shared storage and asks the OS to trigger a redraw.
  /// [nowIso] is passed in rather than read via `DateTime.now()` directly,
  /// matching this codebase's `no_datetime_now_outside_clock` custom_lint
  /// rule — callers should pass `clock.now().toIso8601String()`.
  Future<void> updateBestCardWidget({
    required Recommendation? recommendation,
    required String nowIso,
  }) async {
    await configure();
    if (recommendation == null) {
      await HomeWidget.saveWidgetData<bool>(noCardKey, true);
      await HomeWidget.saveWidgetData<String>(cardNameKey, '');
      await HomeWidget.saveWidgetData<String>(cardValueKey, '');
    } else {
      await HomeWidget.saveWidgetData<bool>(noCardKey, false);
      await HomeWidget.saveWidgetData<String>(cardNameKey, recommendation.card.name);
      await HomeWidget.saveWidgetData<String>(
        cardValueKey,
        recommendation.expectedValue.format(),
      );
    }
    await HomeWidget.saveWidgetData<String>(updatedAtKey, nowIso);

    await HomeWidget.updateWidget(
      androidName: androidWidgetName,
      iOSName: iosWidgetName,
    );
  }
}
