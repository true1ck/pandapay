import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/env.dart';
import '../../../app/providers.dart';
import '../../../data/user_cards_repository.dart' show TransactionEntry;
import '../data/shared_commands.dart';
import '../data/shared_http_transport.dart';
import '../storage/shared_store.dart';
import 'shared_runtime.dart';
import 'split_share_entries.dart';

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
        throw const SharedRuntimeUnavailable('disabled');
      }
      final namespace = ref.watch(cacheNamespaceProvider);
      if (!namespace.startsWith('user:') ||
          !sharedUuid(namespace.substring(5))) {
        throw const SharedRuntimeUnavailable('account');
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
      // Opening Splits never waits on the network: the saved flags are a local
      // read, and the live flags, the queue flush and the change pull all run
      // in the background refresh (screens rebuild when the flags arrive).
      await runtime.useSavedCapabilities();
      if (!current()) throw const SharedRuntimeUnavailable();
      unawaited(runtime.refresh());
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

/// The Split runtime once the app shell has started it, else null. Readers that
/// only want to look (the share rows in Activity and spending) watch this
/// instead of [sharedExpensesRuntimeProvider], which would create the runtime
/// and start its network refresh earlier than the shell does.
final sharedRuntimeLiveProvider = StateProvider<SharedExpensesRuntime?>(
  (ref) => null,
);

/// Keeps the immutable queue scheduled during normal signed-in app use. No
/// whole-history traversal, extra database or unbounded background retry loop.
final sharedExpensesLifecycleProvider = Provider.autoDispose<void>((ref) {
  if (!ref.watch(sharedExpensesEnabledProvider)) return;
  final value = ref.watch(sharedExpensesRuntimeProvider);
  final runtime = value.valueOrNull;
  if (runtime == null) return;
  final live = ref.read(sharedRuntimeLiveProvider.notifier);
  void publish(SharedExpensesRuntime? next) => Future.microtask(() {
    try {
      if (next != null || identical(live.state, runtime)) live.state = next;
    } catch (_) {}
  });
  publish(runtime);
  ref.onDispose(() => publish(null));
  void refresh() => unawaited(runtime.refresh());
  // Coming back to the app or the network must not wait out a backoff earned
  // while it was away; `reconnect` never throws. The timer below does not do
  // this: it keeps honouring the backoff.
  void reconnect() => unawaited(runtime.reconnect());
  final observer = _SharedResumeObserver(reconnect);
  WidgetsBinding.instance.addObserver(observer);
  final subscription = Connectivity().onConnectivityChanged.listen((values) {
    if (!values.contains(ConnectivityResult.none)) reconnect();
  });
  // Retry backoff is durable; this only schedules a small bounded attempt.
  final timer = Timer.periodic(const Duration(seconds: 45), (_) {
    if ((runtime.store.waitingCount > 0 || runtime.syncLag) &&
        !runtime.backingOff) {
      refresh();
    }
  });
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(observer);
    unawaited(subscription.cancel());
    timer.cancel();
  });
});

/// How many saved Split changes the server refused or kept failing on. Quietly
/// 0 whenever it cannot be read. The Split hub shows it as "not synced".
final sharedAttentionCountProvider = StreamProvider.autoDispose<int>((ref) {
  if (!ref.watch(sharedExpensesEnabledProvider)) return Stream.value(0);
  final runtime = ref.watch(sharedExpensesRuntimeProvider).valueOrNull;
  if (runtime == null) return Stream.value(0);
  final counts = StreamController<int>();
  void changed() {
    try {
      counts.add(runtime.attentionCount);
    } catch (_) {
      counts.add(0);
    }
  }

  runtime.addListener(changed);
  changed();
  ref.onDispose(() {
    runtime.removeListener(changed);
    unawaited(counts.close());
  });
  return counts.stream;
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

/// What Splits adds to the person's spending view: their share of splits
/// somebody else paid, and their share of splits they paid for from a payment of
/// their own (see [applySplitOverlay]). Empty when Splits is off, signed out or
/// not ready. Re-read (at most every 1.5 s) when the phone's copy of Splits
/// changes; rows whose content did not change keep their instance, so consumers
/// that compare by identity (the ledger model) rebuild only when something
/// really changed.
final splitOverlayProvider = StreamProvider<SplitOverlay>((ref) {
  if (!ref.watch(sharedExpensesEnabledProvider)) {
    return Stream.value(SplitOverlay.empty);
  }
  final runtime = ref.watch(sharedRuntimeLiveProvider);
  if (runtime == null) return Stream.value(SplitOverlay.empty);
  final controller = StreamController<SplitOverlay>();
  final reader = SplitShareReader(runtime.store, runtime.accountId);
  final previousRows = <String, (String, TransactionEntry)>{};
  final previousLinked = <String, (String, SplitLinkedShare)>{};
  SplitOverlay? last;
  Timer? timer;
  String key(TransactionEntry e) => jsonEncode(e.toJson());
  void compute() {
    if (controller.isClosed) return;
    try {
      final next = splitOverlay(reader.read());
      final keptRows = <String, (String, TransactionEntry)>{};
      final rows = <TransactionEntry>[
        for (final entry in next.rows)
          () {
            final k = key(entry);
            final old = previousRows[entry.id];
            final row = old != null && old.$1 == k ? old.$2 : entry;
            keptRows[entry.id] = (k, row);
            return row;
          }(),
      ];
      final keptLinked = <String, (String, SplitLinkedShare)>{};
      final linked = <SplitLinkedShare>[
        for (final link in next.linked)
          () {
            final k = '${key(link.row)}|${link.paidMinor}|${link.day}';
            final old = previousLinked[link.row.id];
            final out = old != null && old.$1 == k ? old.$2 : link;
            keptLinked[link.row.id] = (k, out);
            return out;
          }(),
      ];
      previousRows
        ..clear()
        ..addAll(keptRows);
      previousLinked
        ..clear()
        ..addAll(keptLinked);
      bool same<T>(List<T> a, List<T> b) =>
          a.length == b.length &&
          [
            for (var i = 0; i < a.length; i++) identical(a[i], b[i]),
          ].every((x) => x);
      final before = last;
      if (before == null ||
          !same(before.rows, rows) ||
          !same(before.linked, linked)) {
        last = SplitOverlay(rows: rows, linked: linked);
        controller.add(last!);
      }
    } catch (_) {
      if (last == null) controller.add(SplitOverlay.empty);
    }
  }

  void changed() {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 1500), compute);
  }

  runtime.addListener(changed);
  compute();
  ref.onDispose(() {
    timer?.cancel();
    runtime.removeListener(changed);
    unawaited(controller.close());
  });
  return controller.stream;
});

/// The share rows alone (see [splitOverlayProvider]).
final splitShareEntriesProvider = Provider<AsyncValue<List<TransactionEntry>>>(
  (ref) => ref.watch(splitOverlayProvider).whenData((o) => o.rows),
);
