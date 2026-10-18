import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/geofence/background_alerts_controller.dart';
import 'package:pandapay/features/geofence/geofence_monitor_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('app lifecycle restores saved monitoring without opening the nearby screen', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('user:a:nearby_background_alerts_v1', true);
    final monitor = _Monitor();
    final controller = BackgroundAlertsController(monitor: monitor, namespace: 'user:a');
    final container = ProviderContainer(overrides: [
      backgroundAlertsControllerProvider.overrideWith((ref) => controller),
    ]);
    addTearDown(container.dispose);
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    container.read(backgroundAlertsLifecycleProvider);
    await Future<void>.delayed(Duration.zero);
    expect(monitor.starts, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(monitor.starts, 2);
    expect(monitor.prompts, 0);
  });

  test(
    'enabled choice survives a new controller and restarts without prompting',
    () async {
      final firstMonitor = _Monitor();
      final first = BackgroundAlertsController(
        monitor: firstMonitor,
        namespace: 'user:a',
      );
      await first.restore();
      expect(first.enabled, isFalse);
      await first.setEnabled(true);
      expect(firstMonitor.prompts, 1);
      expect(firstMonitor.isMonitoring, isTrue);
      first.dispose();

      final nextMonitor = _Monitor();
      final next = BackgroundAlertsController(
        monitor: nextMonitor,
        namespace: 'user:a',
      );
      addTearDown(next.dispose);
      await next.restore();
      expect(next.enabled, isTrue);
      expect(nextMonitor.isMonitoring, isTrue);
      expect(nextMonitor.prompts, 0);
    },
  );

  test('disabled choice stays disabled after restart', () async {
    final first = BackgroundAlertsController(
      monitor: _Monitor(),
      namespace: 'user:a',
    );
    await first.setEnabled(true);
    await first.setEnabled(false);
    first.dispose();
    final monitor = _Monitor();
    final next = BackgroundAlertsController(
      monitor: monitor,
      namespace: 'user:a',
    );
    addTearDown(next.dispose);
    await next.restore();
    expect(next.enabled, isFalse);
    expect(monitor.starts, 0);
  });

  test(
    'permission loss preserves opt-in and recovery on resume starts monitoring',
    () async {
      final monitor = _Monitor()
        ..available = GeofenceMonitorStatus.permissionRequired;
      final controller = BackgroundAlertsController(
        monitor: monitor,
        namespace: 'user:a',
      );
      addTearDown(controller.dispose);
      await controller.setEnabled(true);
      expect(controller.enabled, isTrue);
      expect(controller.description, contains('Allow all the time'));
      expect(monitor.isMonitoring, isFalse);
      monitor.available = GeofenceMonitorStatus.monitoring;
      await controller.restore();
      expect(controller.status, GeofenceMonitorStatus.monitoring);
      expect(monitor.prompts, 1);
    },
  );

  test(
    'preferences are isolated across accounts and signed-out cannot opt in',
    () async {
      final first = BackgroundAlertsController(
        monitor: _Monitor(),
        namespace: 'user:a',
      );
      await first.setEnabled(true);
      first.dispose();
      for (final namespace in ['user:b', 'signed-out']) {
        final monitor = _Monitor();
        final controller = BackgroundAlertsController(
          monitor: monitor,
          namespace: namespace,
        );
        await controller.restore();
        expect(controller.enabled, isFalse);
        expect(monitor.starts, 0);
        if (namespace == 'signed-out') {
          await controller.setEnabled(true);
          expect(controller.enabled, isFalse);
          expect(monitor.prompts, 0);
        }
        controller.dispose();
      }
    },
  );

  test(
    'live service failures update the display without clearing the choice',
    () async {
      final monitor = _Monitor();
      final controller = BackgroundAlertsController(
        monitor: monitor,
        namespace: 'user:a',
      );
      addTearDown(controller.dispose);
      await controller.setEnabled(true);
      var updates = 0;
      controller.addListener(() => updates++);
      monitor.status.value = GeofenceMonitorStatus.unavailable;
      expect(updates, 1);
      expect(controller.enabled, isTrue);
      expect(controller.description, contains('temporarily unavailable'));
      monitor.status.value = GeofenceMonitorStatus.locationOff;
      expect(controller.description, contains('turn on device location'));
      monitor.status.value = GeofenceMonitorStatus.notificationsOff;
      expect(controller.description, contains('allow PandaPay notifications'));
    },
  );

  test(
    'an in-flight start cannot leave monitoring active after disposal',
    () async {
      final started = Completer<void>();
      final monitor = _Monitor()..startBarrier = started.future;
      final controller = BackgroundAlertsController(
        monitor: monitor,
        namespace: 'user:a',
      );
      final enabling = controller.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(monitor.starts, 1);
      controller.dispose();
      started.complete();
      await enabling;
      expect(monitor.isMonitoring, isFalse);
    },
  );

  test('queued disable wins over an earlier startup restore', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('user:a:nearby_background_alerts_v1', true);
    final monitor = _Monitor();
    final controller = BackgroundAlertsController(
      monitor: monitor,
      namespace: 'user:a',
    );
    addTearDown(controller.dispose);
    await Future.wait([controller.restore(), controller.setEnabled(false)]);
    expect(controller.enabled, isFalse);
    expect(monitor.isMonitoring, isFalse);
    expect(prefs.getBool(controller.preferenceKey), isFalse);
  });
}

class _Monitor implements BackgroundMerchantMonitor {
  @override
  final ValueNotifier<GeofenceMonitorStatus> status = ValueNotifier(
    GeofenceMonitorStatus.off,
  );
  GeofenceMonitorStatus available = GeofenceMonitorStatus.monitoring;
  int prompts = 0;
  int starts = 0;
  Future<void>? startBarrier;

  @override
  bool get isMonitoring => status.value == GeofenceMonitorStatus.monitoring;
  @override
  Future<bool> requestPermissions() async {
    prompts++;
    return true;
  }

  @override
  Future<void> start() async {
    starts++;
    await startBarrier;
    status.value = available;
  }

  @override
  Future<void> stop() async {
    status.value = GeofenceMonitorStatus.off;
  }
}
