import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The platform connectivity object, injectable for tests (WP-C1).
final connectivityProvider = Provider<Connectivity>((ref) => Connectivity());

/// The stream behind `isOnlineProvider`.
///
/// It follows `onConnectivityChanged` and, in parallel, asks
/// `checkConnectivity()` for the *current* state and emits that first when no
/// change event has beaten it. A listener that subscribes late, or on a
/// platform that does not replay the current state on first listen, therefore
/// starts from the truth instead of "unknown".
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
/// `KnownConnectivity` current. A failing or hanging seed is ignored: the
/// stream must still work, exactly as it did before seeding existed. (There is
/// deliberately no timeout timer: it would be a pending timer in every widget
/// test that reads the provider without overriding it.)
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
  var sawEvent = false;
  bool? last;

  void handle(List<ConnectivityResult> results) {
    final online = toOnline(results);
    onValue?.call(online);
    if (last == online) return;
    last = online;
    if (!controller.isClosed) controller.add(online);
  }

  Future<void> seed() async {
    try {
      final current = await connectivity.checkConnectivity();
      // A change event that arrived first is newer than the seed.
      if (cancelled || sawEvent) return;
      handle(current);
    } catch (_) {
      // No seed available (plugin missing in a test, platform hiccup): follow
      // the change stream alone, as before seeding existed. A hanging seed is
      // harmless for the same reason, and no timer is needed to bound it.
    }
  }

  controller = StreamController<bool>(
    onListen: () {
      // Subscribe first, then ask for the current state, so no change can slip
      // between the two. Android and iOS also replay the current state on
      // first listen; the de-duplication below makes that and the seed one
      // emission.
      changes = connectivity.onConnectivityChanged.listen(
        (results) {
          sawEvent = true;
          handle(results);
        },
        onError: (Object error, StackTrace stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        },
      );
      unawaited(seed());
    },
    onCancel: () {
      cancelled = true;
      return changes?.cancel();
    },
  );
  return controller.stream;
}
