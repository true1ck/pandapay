import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'known_connectivity.dart';
import 'reachability.dart';

/// App-root connectivity wiring (WP-C1). Watched once from `PandaPayApp.build`
/// so it lives for the whole process, signed in or not. It has no UI and no
/// state; it only does three things.
///
/// 1. **Subscribes `isOnlineProvider` early.** The provider is seeded with the
///    current connectivity, but nothing used to read it before the signed-in
///    shell's lifecycle providers started (500 ms after the first frame).
///    Reading it here means `_isKnownOffline()` and `KnownConnectivity` are
///    populated from the first moments of the process. The shell's own
///    `ref.listen`s still see exactly the same transitions: a provider that is
///    already alive hands a late listener its current value, never a
///    `false -> true` pair.
/// 2. **Keeps the reachability cache honest.** Any connectivity change and any
///    resume drops the cached `/app-status` probe result.
/// 3. **Re-checks `appStatusProvider`** (finding C-05). That provider fails
///    open to `null` and is cached for the process lifetime, so a
///    maintenance/forced-upgrade flag raised while the app was offline would
///    never be seen. On offline -> online, once the server answers a probe, the
///    provider is invalidated; on resume, a `null` (failed-open) status is
///    re-checked the same way. A re-check that fails is still fail-open
///    (`null`) and never blocks the app.
final connectivityBootstrapProvider = Provider<void>((ref) {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final reachability = ref.watch(serverReachabilityProvider);

  Future<void> recheckAppStatus({required bool force}) async {
    final reachable = await reachability.check(force: force);
    if (disposed || !reachable) return;
    ref.invalidate(appStatusProvider);
  }

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
    reachability.invalidate();
    final cameOnline =
        previous?.valueOrNull == false && next.valueOrNull == true;
    if (cameOnline) unawaited(recheckAppStatus(force: true));
  });

  final lifecycle = AppLifecycleListener(
    onResume: () {
      reachability.invalidate();
      if (KnownConnectivity.knownOffline || !ref.exists(appStatusProvider)) {
        return;
      }
      final status = ref.read(appStatusProvider);
      if (!status.isLoading && status.valueOrNull == null) {
        unawaited(recheckAppStatus(force: false));
      }
    },
  );
  ref.onDispose(lifecycle.dispose);
});
