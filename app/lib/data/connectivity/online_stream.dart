import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The platform connectivity object, injectable for tests (WP-C1).
final connectivityProvider = Provider<Connectivity>((ref) => Connectivity());

/// How long the initial `checkConnectivity()` may take before the seed is
/// skipped and only the change stream is used.
const Duration connectivitySeedTimeout = Duration(seconds: 2);

/// The stream behind `isOnlineProvider`.
///
/// 1. First emits the *current* state (`checkConnectivity`), so a listener that
///    subscribes late, or on a platform that does not replay the current state
///    on first listen, still starts from the truth instead of "unknown".
/// 2. Then follows `onConnectivityChanged`.
///
/// Consecutive equal values are dropped, so the seed plus the platform's own
/// first event (Android/iOS replay the current state) is one emission, and a
/// device that starts online does not produce a spurious offline->online (or
/// "came online") transition. Listeners that detect reconnects with
/// `previous == false && next == true` therefore see exactly one transition per
/// real reconnect.
///
/// [toOnline] maps the platform result list to online/offline. [onValue] is
/// called for every raw value (before de-duplication), e.g. to keep
/// `KnownConnectivity` current. A failing or hanging seed is skipped: the
/// stream must still work, exactly as it did before seeding existed.
Stream<bool> connectivityOnlineStream(
  Connectivity connectivity, {
  required bool Function(List<ConnectivityResult>) toOnline,
  void Function(bool online)? onValue,
}) {
  // A controller (not `async*`) so cancelling the subscription releases the
  // platform subscription immediately instead of at the next event.
  late final StreamController<bool> controller;
  StreamSubscription<List<ConnectivityResult>>? changes;
  var cancelled = false;
  bool? last;

  void handle(List<ConnectivityResult> results) {
    final online = toOnline(results);
    onValue?.call(online);
    if (last == online) return;
    last = online;
    if (!controller.isClosed) controller.add(online);
  }

  Future<void> start() async {
    try {
      final seed = await connectivity.checkConnectivity().timeout(
        connectivitySeedTimeout,
      );
      if (cancelled) return;
      handle(seed);
    } catch (_) {
      // No seed available (plugin missing in a test, platform hiccup,
      // timeout): follow the change stream alone, as before seeding existed.
    }
    if (cancelled) return;
    changes = connectivity.onConnectivityChanged.listen(
      handle,
      onError: (Object error, StackTrace stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      },
    );
  }

  controller = StreamController<bool>(
    onListen: () => unawaited(start()),
    onCancel: () {
      cancelled = true;
      return changes?.cancel();
    },
  );
  return controller.stream;
}
