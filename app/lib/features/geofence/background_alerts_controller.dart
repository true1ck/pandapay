import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geofence_monitor_service.dart';

/// Saved intent belongs to one signed-in profile. Runtime status is separate:
/// permission loss must not silently erase the user's saved choice.
class BackgroundAlertsController extends ChangeNotifier {
  final BackgroundMerchantMonitor monitor;
  final String namespace;
  final Future<SharedPreferences> preferences;
  Future<void> _pending = Future.value();
  bool _disposed = false;
  bool _initialized = false;
  bool enabled = false;
  bool busy = true;
  String? error;

  BackgroundAlertsController({
    required this.monitor,
    required this.namespace,
    Future<SharedPreferences>? preferences,
  }) : preferences = preferences ?? SharedPreferences.getInstance() {
    monitor.status.addListener(_changed);
  }

  String get preferenceKey => '$namespace:nearby_background_alerts_v1';
  GeofenceMonitorStatus get status => monitor.status.value;

  String get description {
    if (busy) return 'Checking background alerts…';
    if (error != null) return error!;
    if (!enabled) return 'Off — checks only run when you tap the button below.';
    return switch (status) {
      GeofenceMonitorStatus.monitoring =>
        'On — watching for published PandaPay merchants within 300 m.',
      GeofenceMonitorStatus.locationOff =>
        'Saved as On · paused — turn on device location.',
      GeofenceMonitorStatus.permissionRequired =>
        'Saved as On · paused — set location access to "Allow all the time".',
      GeofenceMonitorStatus.notificationsOff =>
        'Saved as On · paused — allow PandaPay notifications in Settings.',
      GeofenceMonitorStatus.unavailable =>
        'Saved as On · temporarily unavailable. Retry or reopen the app.',
      _ => 'Saved as On · starting location monitoring…',
    };
  }

  Future<void> _run(Future<void> Function() action) {
    return _pending = _pending.then((_) async {
      if (_disposed) return;
      busy = true;
      error = null;
      _changed();
      try {
        await action();
      } catch (_) {
        if (!_disposed) {
          error = 'Background alerts could not be updated. Please retry.';
        }
      } finally {
        if (!_disposed) {
          busy = false;
          _changed();
        }
      }
    });
  }

  Future<void> _load() async {
    if (_initialized) return;
    final prefs = await preferences;
    if (_disposed) return;
    enabled =
        namespace != 'signed-out' && (prefs.getBool(preferenceKey) ?? false);
    _initialized = true;
  }

  /// Startup/resume never opens a permission prompt. Only an explicit user
  /// action may request permissions; missing grants remain a visible pause.
  Future<void> restore() => _run(() async {
    await _load();
    if (_disposed) return;
    if (enabled) {
      await monitor.start();
      if (_disposed) await monitor.stop();
    } else {
      await monitor.stop();
    }
  });

  Future<void> setEnabled(bool value) => _run(() async {
    await _load();
    if (_disposed) return;
    final prefs = await preferences;
    if (_disposed) return;
    if (namespace == 'signed-out' && value) {
      error = 'Sign in to enable background alerts.';
      return;
    }
    if (!await prefs.setBool(preferenceKey, value)) {
      throw StateError('Could not save background alerts');
    }
    if (_disposed) return;
    enabled = value;
    if (value) {
      await monitor.requestPermissions();
      if (_disposed) return;
      await monitor.start();
      if (_disposed) await monitor.stop();
    } else {
      await monitor.stop();
    }
  });

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    monitor.status.removeListener(_changed);
    unawaited(monitor.stop());
    super.dispose();
  }
}
