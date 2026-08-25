import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart'
    show notificationPreferencesProvider, notificationPreferencesRepositoryProvider, recordAppNotification;
import '../../data/notification_preferences_repository.dart';

/// Userappimplementation_plan.md UA-8.3: "Quiet hours + daily frequency cap
/// enforced centrally in a NotificationGate that every notification path
/// must pass through — no bypass route exists in code." That class never
/// got built — GeofenceMonitorService's own `_notify()` called
/// flutter_local_notifications directly, skipping every preference
/// (including category_location, which exists for exactly this path).
///
/// What this adds on top of what POST /notifications already does
/// server-side (category-gating and dedupe-by-upsert — see that route's own
/// doc-comment in api/src/index.js): quiet hours and the daily cap, neither
/// of which the server enforces, plus actually showing a real OS-level
/// notification — POST /notifications only ever writes an inbox row, it has
/// no channel to the device. The category check below is intentionally
/// redone client-side even though the server repeats it: it is what decides
/// whether to show the OS banner at all, which the server's 204 (muted)
/// response can't retroactively cancel.
class NotificationGate {
  final Ref ref;
  final FlutterLocalNotificationsPlugin notifications;

  bool _pluginInitialized = false;

  NotificationGate({required this.ref, required this.notifications});

  /// Pure — same "testable without a real plugin/ref" split
  /// GeofenceMonitorService.shouldNotify already established for its own
  /// cooldown logic.
  static bool categoryEnabled(NotificationPreferences prefs, String category) {
    switch (category) {
      case 'location':
        return prefs.categoryLocation;
      case 'caps':
        return prefs.categoryCaps;
      case 'milestones':
        return prefs.categoryMilestones;
      case 'fee_waivers':
        return prefs.categoryFeeWaivers;
      case 'bills':
        return prefs.categoryBills;
      case 'expiry':
        return prefs.categoryExpiry;
      case 'monthly_report':
        return prefs.categoryMonthlyReport;
      case 'needs_review':
        return prefs.categoryNeedsReview;
      case 'budget_warning':
        return prefs.categoryBudgetWarning;
      case 'budget_exceeded':
        return prefs.categoryBudgetExceeded;
      default:
        // 'streak'/'card_added' etc. have no preference column — they're
        // in-app consequences of the user's own action, not push-style
        // interruptions. Matches POST /notifications' own PREFERENCE_COLUMN
        // map exactly (api/src/index.js).
        return true;
    }
  }

  static bool inQuietHours(NotificationPreferences prefs, DateTime now) {
    final start = _minutesOf(prefs.quietHoursStart);
    final end = _minutesOf(prefs.quietHoursEnd);
    if (start == null || end == null || start == end) return false;
    final nowMinutes = now.hour * 60 + now.minute;
    return start < end
        ? (nowMinutes >= start && nowMinutes < end)
        // Wraps past midnight, e.g. 22:00 -> 07:00.
        : (nowMinutes >= start || nowMinutes < end);
  }

  static int? _minutesOf(String? hhmmss) {
    if (hhmmss == null) return null;
    final parts = hhmmss.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  static bool dailyCapReached(int firedToday, int dailyCap) => firedToday >= dailyCap;

  Future<void> _ensurePluginInitialized() async {
    if (_pluginInitialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await notifications.initialize(const InitializationSettings(android: androidInit, iOS: iosInit));
    _pluginInitialized = true;
  }

  /// Attempts to deliver [category]'s notification. Returns true if it was
  /// actually shown (OS banner + inbox row written), false if a preference
  /// suppressed it (category off, quiet hours, daily cap reached, already
  /// fired for this [dedupeKey], or — for [merchantId]-scoped ones — that
  /// merchant muted) or the user is signed out (guest mode has no
  /// server-side preferences to check, so this no-ops rather than guessing
  /// what a signed-out user would want).
  Future<bool> fire({
    required String category,
    required String title,
    required String body,
    required String dedupeKey,
    String? merchantId,
    String severity = 'info',
    String? deepLink,
    DateTime? now,
  }) async {
    final prefs = await ref.read(notificationPreferencesProvider.future);
    if (prefs == null) return false;

    final effectiveNow = now ?? DateTime.now();
    if (!categoryEnabled(prefs, category)) return false;
    if (merchantId != null && await _merchantMuted(merchantId)) return false;
    if (inQuietHours(prefs, effectiveNow)) return false;
    if (await _alreadyFired(dedupeKey)) return false;
    if (dailyCapReached(await _todayCount(effectiveNow), prefs.dailyCap)) return false;

    await _markFired(dedupeKey);
    await _incrementTodayCount(effectiveNow);

    await recordAppNotification(
      ref,
      category: category,
      title: title,
      body: body,
      severity: severity,
      deepLink: deepLink,
      dedupeKey: dedupeKey,
    );

    // Everything from here down is best-effort, same "must never fail the
    // action that earned it" posture as recordAppNotification above — the
    // inbox row already landed either way, so a platform-channel failure
    // (initialize() included: it throws on a plugin with no real platform
    // behind it, e.g. in a widget test) means a missed banner, not a
    // missed record, and fire() still honestly reports success.
    try {
      await _ensurePluginInitialized();
      const androidDetails = AndroidNotificationDetails(
        'pandapay_alerts',
        'PandaPay alerts',
        channelDescription: 'Cap, milestone, bill, and other card alerts you\'ve opted into',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      const details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
      await notifications.show(dedupeKey.hashCode, title, body, details);
    } catch (_) {
      // See the comment above.
    }
    return true;
  }

  Future<bool> _merchantMuted(String merchantId) async {
    final repo = ref.read(notificationPreferencesRepositoryProvider);
    if (repo == null) return false;
    try {
      final muted = await repo.fetchMutedMerchants();
      return muted.any((m) => m.merchantId == merchantId);
    } catch (_) {
      return false; // a failed check must never block an otherwise-valid notification
    }
  }

  static const _dedupeKeyStoreKey = 'notification_gate_dedupe_keys_v1';
  static const _dedupeKeyStoreCap = 500;

  Future<bool> _alreadyFired(String dedupeKey) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList(_dedupeKeyStoreKey) ?? const [];
    return seen.contains(dedupeKey);
  }

  Future<void> _markFired(String dedupeKey) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList(_dedupeKeyStoreKey) ?? const [];
    final updated = [...seen, dedupeKey];
    // Bounded FIFO — an install that runs for years must not grow this list
    // forever. Dropping the oldest keys just means a long-since-resolved
    // condition could in principle re-notify, which is harmless.
    final trimmed = updated.length > _dedupeKeyStoreCap
        ? updated.sublist(updated.length - _dedupeKeyStoreCap)
        : updated;
    await prefs.setStringList(_dedupeKeyStoreKey, trimmed);
  }

  String _todayCountKey(DateTime now) =>
      'notification_gate_daily_count_v1:${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  Future<int> _todayCount(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_todayCountKey(now)) ?? 0;
  }

  Future<void> _incrementTodayCount(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _todayCountKey(now);
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + 1);
  }
}
