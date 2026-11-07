import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/env.dart';
import '../../../app/providers.dart';
import '../data/shared_commands.dart';
import '../data/shared_http_transport.dart';
import '../storage/shared_store.dart';
import 'shared_runtime.dart';

/// Independent rollout gate: never enables or changes the SMS v2 cutover.
final sharedExpensesEnabledProvider = Provider<bool>(
  (ref) => const bool.fromEnvironment(
    'PANDAPAY_SHARED_EXPENSES_ENABLED',
    defaultValue: true,
  ),
);

final sharedExpensesRuntimeProvider =
    FutureProvider.autoDispose<SharedExpensesRuntime>((ref) async {
      if (!ref.watch(sharedExpensesEnabledProvider)) {
        throw const SharedRuntimeUnavailable();
      }
      final namespace = ref.watch(cacheNamespaceProvider);
      if (!namespace.startsWith('user:') ||
          !sharedUuid(namespace.substring(5))) {
        throw const SharedRuntimeUnavailable();
      }
      var active = true;
      ref.onDispose(() => active = false);
      bool current() => active && ref.read(cacheNamespaceProvider) == namespace;
      final db = await ref.watch(appDatabaseProvider.future),
          cache = await ref.watch(responseCacheProvider.future);
      if (!current()) throw const SharedRuntimeUnavailable();
      late SharedExpensesRuntime runtime;
      final store = SharedExpensesStore(
        db,
        namespace: namespace,
        isCurrent: current,
      );
      final remote = SharedExpensesHttpTransport(
        apiBaseUrl: Env.apiBaseUrl,
        namespace: namespace,
        client: ref.read(authenticatedHttpClientProvider),
        accessToken: () => ref.read(accessTokenProvider),
        isCurrent: current,
        onContextRevoked: (id) async {
          if (current()) await runtime.revokeContext(id);
        },
      );
      runtime = SharedExpensesRuntime(
        store: store,
        remote: remote,
        cache: cache,
        isCurrent: current,
      );
      ref.onDispose(runtime.dispose);
      await runtime.refresh();
      return runtime;
    });

class _SharedResumeObserver extends WidgetsBindingObserver {
  final VoidCallback refresh;
  _SharedResumeObserver(this.refresh);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }
}

/// Keeps the immutable queue scheduled during normal signed-in app use. No
/// whole-history traversal, extra database or unbounded background retry loop.
final sharedExpensesLifecycleProvider = Provider.autoDispose<void>((ref) {
  if (!ref.watch(sharedExpensesEnabledProvider)) return;
  final value = ref.watch(sharedExpensesRuntimeProvider);
  final runtime = value.valueOrNull;
  if (runtime == null) return;
  void refresh() => unawaited(runtime.refresh());
  final observer = _SharedResumeObserver(refresh);
  WidgetsBinding.instance.addObserver(observer);
  final subscription = Connectivity().onConnectivityChanged.listen((values) {
    if (!values.contains(ConnectivityResult.none)) refresh();
  });
  // Retry backoff is durable; this only schedules a small bounded attempt.
  final timer = Timer.periodic(const Duration(seconds: 45), (_) {
    if (runtime.store.waitingCount > 0 || runtime.syncLag) refresh();
  });
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(observer);
    unawaited(subscription.cancel());
    timer.cancel();
  });
});

/// Invites for me plus join requests waiting on me, shown as a badge on the
/// Splits row. Quietly 0 whenever it cannot be read.
final sharedWaitingCountProvider = FutureProvider.autoDispose<int>((ref) async {
  if (!ref.watch(sharedExpensesEnabledProvider)) return 0;
  try {
    final runtime = await ref.watch(sharedExpensesRuntimeProvider.future);
    if (!runtime.proposalsEnabled) return 0;
    final invites = await runtime.inviteInbox();
    final requests = await runtime.joinRequests();
    return invites.length + requests.length;
  } catch (_) {
    return 0;
  }
});
