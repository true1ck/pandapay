import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/app_status_repository.dart';
import 'package:pandapay/data/connectivity/connectivity_bootstrap.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/connectivity/online_stream.dart';
import 'package:pandapay/data/connectivity/reachability.dart';

class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.seed);
  List<ConnectivityResult> seed;
  final controller = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => seed;
}

/// Fails (like an unreachable server) until [fail] is false, then returns a
/// normal status. Counts fetches.
class _FlakyStatusRepository implements AppStatusRepository {
  bool fail = true;
  AppStatus next = const AppStatus(minSupportedVersion: '1.0.0', maintenanceMode: false);
  int fetches = 0;

  @override
  Future<AppStatus> fetchStatus() async {
    fetches++;
    if (fail) throw TimeoutException('offline');
    return next;
  }
}

const _wifi = [ConnectivityResult.wifi];
const _none = [ConnectivityResult.none];

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(KnownConnectivity.reset);

  late _FakeConnectivity connectivity;
  late _FlakyStatusRepository status;
  late ServerReachability reachability;
  late bool serverUp;
  late int probes;
  late ProviderContainer container;

  setUp(() {
    connectivity = _FakeConnectivity(_none);
    status = _FlakyStatusRepository();
    serverUp = true;
    probes = 0;
    reachability = ServerReachability(
      probe: () async {
        probes++;
        return serverUp;
      },
    );
    container = ProviderContainer(
      overrides: [
        connectivityProvider.overrideWithValue(connectivity),
        appStatusRepositoryProvider.overrideWithValue(status),
        serverReachabilityProvider.overrideWithValue(reachability),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await connectivity.controller.close();
  });

  test('reading the bootstrap subscribes isOnlineProvider (seeded)', () async {
    container.read(connectivityBootstrapProvider);
    // The router listens to appStatusProvider for the whole process.
    container.listen(appStatusProvider, (_, _) {});
    await _settle();
    expect(container.read(isOnlineProvider).valueOrNull, false);
    expect(KnownConnectivity.knownOffline, isTrue);
  });

  test(
    'appStatus failed open while offline is re-checked on reconnect',
    () async {
      container.read(connectivityBootstrapProvider);
      // The router listens to appStatusProvider for the whole process.
      container.listen(appStatusProvider, (_, _) {});
      // The router reads this at startup; offline it fails open to null.
      expect(await container.read(appStatusProvider.future), isNull);
      expect(status.fetches, 1);

      // Back online, the server answers: a forced-upgrade/maintenance flag set
      // while the app was offline must now be seen.
      status
        ..fail = false
        ..next = const AppStatus(minSupportedVersion: '1.0.0', maintenanceMode: true);
      connectivity.controller.add(_wifi);
      await _settle();

      expect(probes, 1);
      expect(status.fetches, 2);
      expect((await container.read(appStatusProvider.future))?.maintenanceMode,
          isTrue);
    },
  );

  test('no re-check when the server is not reachable after reconnect', () async {
    container.read(connectivityBootstrapProvider);
    // The router listens to appStatusProvider for the whole process.
    container.listen(appStatusProvider, (_, _) {});
    await container.read(appStatusProvider.future);
    serverUp = false; // captive Wi-Fi: radio up, no server
    connectivity.controller.add(_wifi);
    await _settle();
    expect(probes, 1);
    expect(status.fetches, 1);
  });

  test('a start that is already online never re-checks appStatus', () async {
    connectivity.seed = _wifi;
    status.fail = false;
    container.read(connectivityBootstrapProvider);
    // The router listens to appStatusProvider for the whole process.
    container.listen(appStatusProvider, (_, _) {});
    await container.read(appStatusProvider.future);
    connectivity.controller.add(_wifi); // platform replays the current state
    await _settle();
    expect(status.fetches, 1);
    expect(probes, 0);
  });

  test('maintenance stays fail-open: a failing re-check yields null', () async {
    container.read(connectivityBootstrapProvider);
    // The router listens to appStatusProvider for the whole process.
    container.listen(appStatusProvider, (_, _) {});
    await container.read(appStatusProvider.future);
    // Server is reachable for the probe but the status call then fails.
    connectivity.controller.add(_wifi);
    await _settle();
    expect(status.fetches, 2);
    expect(await container.read(appStatusProvider.future), isNull);
    expect(container.read(appStatusProvider).hasError, isFalse);
  });

  test('connectivity changes drop the cached reachability answer', () async {
    connectivity.seed = _wifi;
    container.read(connectivityBootstrapProvider);
    // The router listens to appStatusProvider for the whole process.
    container.listen(appStatusProvider, (_, _) {});
    await _settle();
    await reachability.check();
    expect(reachability.serverReachable, isTrue);
    connectivity.controller.add(_none);
    await _settle();
    expect(reachability.serverReachable, false); // radio down => unreachable
    connectivity.controller.add(_wifi);
    await _settle();
    // came online: forced probe ran again and refreshed the cache
    expect(probes, greaterThanOrEqualTo(2));
  });

  testWidgets('resume with a failed-open appStatus re-checks it once reachable',
      (tester) async {
    connectivity.seed = _wifi;
    await tester.runAsync(() async {
      container.read(connectivityBootstrapProvider);
      // The router listens to appStatusProvider for the whole process.
      container.listen(appStatusProvider, (_, _) {});
      expect(await container.read(appStatusProvider.future), isNull);
      expect(status.fetches, 1);
      status.fail = false;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle();

      expect(status.fetches, 2);
    });
  });
}
