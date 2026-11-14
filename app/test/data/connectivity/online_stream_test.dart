import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/connectivity/online_stream.dart';

class FakeConnectivity implements Connectivity {
  FakeConnectivity({
    this.seed,
    this.seedError,
    this.seedNever = false,
    this.seedDelay,
  });

  Duration? seedDelay;

  List<ConnectivityResult>? seed;
  Object? seedError;
  bool seedNever;
  final _controller = StreamController<List<ConnectivityResult>>.broadcast();

  void emit(List<ConnectivityResult> v) => _controller.add(v);

  bool get hasListener => _controller.hasListener;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    if (seedNever) return Completer<List<ConnectivityResult>>().future;
    if (seedError != null) return Future.error(seedError!);
    final delay = seedDelay;
    if (delay != null) return Future.delayed(delay, () => seed!);
    return Future.value(seed);
  }

  Future<void> close() => _controller.close();
}

const _wifi = [ConnectivityResult.wifi];
const _none = [ConnectivityResult.none];

/// The exact predicate sync_engine.dart, the display-refresh listener, the
/// outbox flush and sms_v2 use to decide "the device just came online".
bool _cameOnline(AsyncValue<bool>? previous, AsyncValue<bool> next) =>
    previous?.valueOrNull == false && next.valueOrNull == true;

ProviderContainer _container(FakeConnectivity fake) {
  final container = ProviderContainer(
    overrides: [connectivityProvider.overrideWithValue(fake)],
  );
  addTearDown(container.dispose);
  addTearDown(fake.close);
  return container;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  tearDown(KnownConnectivity.reset);

  group('connectivityOnlineStream', () {
    test('seeds the current state before any change event', () async {
      final fake = FakeConnectivity(seed: _none);
      addTearDown(fake.close);
      final values = <bool>[];
      final sub = connectivityOnlineStream(
        fake,
        toOnline: connectivityResultToIsOnline,
      ).listen(values.add);
      await _settle();
      expect(values, [false]);
      fake.emit(_wifi);
      await _settle();
      expect(values, [false, true]);
      await sub.cancel();
    });

    test('platform replay of the seeded value is de-duplicated', () async {
      final fake = FakeConnectivity(seed: _wifi);
      addTearDown(fake.close);
      final values = <bool>[];
      final raw = <bool>[];
      final sub = connectivityOnlineStream(
        fake,
        toOnline: connectivityResultToIsOnline,
        onValue: raw.add,
      ).listen(values.add);
      await _settle();
      fake.emit(_wifi); // first-listen replay of the same state
      fake.emit([ConnectivityResult.mobile]); // wifi -> mobile, still online
      await _settle();
      expect(values, [true]);
      // onValue still saw every raw value (keeps KnownConnectivity current).
      expect(raw, [true, true, true]);
      await sub.cancel();
    });

    test('a failing or hanging seed is ignored', () async {
      final failing = FakeConnectivity(seedError: StateError('no plugin'));
      addTearDown(failing.close);
      final values = <bool>[];
      final sub = connectivityOnlineStream(
        failing,
        toOnline: connectivityResultToIsOnline,
      ).listen(values.add);
      await _settle();
      failing.emit(_none);
      await _settle();
      expect(values, [false]);
      await sub.cancel();

      final hanging = FakeConnectivity(seedNever: true);
      addTearDown(hanging.close);
      final values2 = <bool>[];
      final sub2 = connectivityOnlineStream(
        hanging,
        toOnline: connectivityResultToIsOnline,
      ).listen(values2.add);
      await _settle();
      expect(values2, isEmpty);
      // The change stream still works while the seed never answers.
      hanging.emit(_wifi);
      await _settle();
      expect(values2, [true]);
      await sub2.cancel();
    });

    test(
      'a change event that beats the seed wins over the stale seed',
      () async {
        final fake = FakeConnectivity(
          seed: _none,
          seedDelay: const Duration(milliseconds: 20),
        );
        addTearDown(fake.close);
        final values = <bool>[];
        final sub = connectivityOnlineStream(
          fake,
          toOnline: connectivityResultToIsOnline,
        ).listen(values.add);
        // The platform replays "online" synchronously on listen, before the
        // asynchronous checkConnectivity() answers with an older "offline".
        fake.emit(_wifi);
        await _settle();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(values, [true]);
        await sub.cancel();
      },
    );

    test('cancelling releases the platform subscription', () async {
      final fake = FakeConnectivity(seed: _wifi);
      addTearDown(fake.close);
      final sub = connectivityOnlineStream(
        fake,
        toOnline: connectivityResultToIsOnline,
      ).listen((_) {});
      await _settle();
      expect(fake.hasListener, isTrue);
      await sub.cancel();
      expect(fake.hasListener, isFalse);
    });
  });

  group('isOnlineProvider transitions', () {
    test(
      'seeded offline then first online event fires exactly one trigger',
      () async {
        final fake = FakeConnectivity(seed: _none);
        final container = _container(fake);
        var triggers = 0;
        container.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
          if (_cameOnline(previous, next)) triggers++;
        }, fireImmediately: true);

        await _settle();
        expect(container.read(isOnlineProvider).valueOrNull, false);
        expect(KnownConnectivity.knownOffline, isTrue);
        expect(triggers, 0);

        fake.emit(_wifi);
        await _settle();
        expect(container.read(isOnlineProvider).valueOrNull, true);
        expect(KnownConnectivity.online, isTrue);
        expect(triggers, 1);

        // Same state repeated, and a Wi-Fi -> mobile hand-over: nothing new.
        fake.emit(_wifi);
        fake.emit([ConnectivityResult.mobile]);
        await _settle();
        expect(triggers, 1);
      },
    );

    test('seeded online fires no spurious came-online trigger', () async {
      final fake = FakeConnectivity(seed: _wifi);
      final container = _container(fake);
      var triggers = 0;
      container.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
        if (_cameOnline(previous, next)) triggers++;
      });

      await _settle();
      expect(container.read(isOnlineProvider).valueOrNull, true);
      fake.emit(_wifi); // platform replays the current state on first listen
      await _settle();
      expect(triggers, 0);
      expect(KnownConnectivity.knownOffline, isFalse);
    });

    test(
      'a real offline -> online cycle after a seeded start fires once each',
      () async {
        final fake = FakeConnectivity(seed: _wifi);
        final container = _container(fake);
        var triggers = 0;
        container.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
          if (_cameOnline(previous, next)) triggers++;
        });
        await _settle();
        fake.emit(_none);
        await _settle();
        expect(KnownConnectivity.knownOffline, isTrue);
        fake.emit(_wifi);
        await _settle();
        expect(triggers, 1);
        fake.emit(_none);
        fake.emit(_wifi);
        await _settle();
        expect(triggers, 2);
      },
    );

    test('nothing observed yet counts as online', () {
      expect(KnownConnectivity.knownOffline, isFalse);
    });

    test('test overrides of isOnlineProvider keep working', () async {
      final container = ProviderContainer(
        overrides: [
          isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(isOnlineProvider, (_, _) {});
      await _settle();
      expect(container.read(isOnlineProvider).valueOrNull, false);
    });
  });
}
