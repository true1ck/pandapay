import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/split_repository.dart';

final splitRepositoryProvider = FutureProvider<SplitRepository>((ref) async {
  final namespace = ref.watch(cacheNamespaceProvider);
  final database = await ref.watch(appDatabaseProvider.future);
  final repository = SplitRepository(
    database,
    namespace: namespace,
    now: ref.read(clockProvider).now,
    remote: () => ref.read(userCardsRepositoryProvider),
    canSync: () =>
        ref.read(cacheNamespaceProvider) == namespace &&
        ref.read(isOnlineProvider).valueOrNull != false,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

final pendingSplitCountProvider = StreamProvider<int>((ref) {
  final repository = ref.watch(splitRepositoryProvider).valueOrNull;
  if (repository == null) return Stream.value(0);
  final counts = StreamController<int>();
  void changed() => counts.add(repository.pendingCount);
  repository.addListener(changed);
  changed();
  ref.onDispose(() {
    repository.removeListener(changed);
    unawaited(counts.close());
  });
  return counts.stream;
});

class _SplitResumeObserver extends WidgetsBindingObserver {
  final SplitRepository repository;
  _SplitResumeObserver(this.repository);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(repository.sync(reconnect: true));
    }
  }
}

/// No periodic reads: start/reconnect/resume drain the durable pending set.
final splitSyncLifecycleProvider = Provider<void>((ref) {
  final repository = ref.watch(splitRepositoryProvider).valueOrNull;
  if (repository == null) return;
  final observer = _SplitResumeObserver(repository);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  unawaited(repository.sync());
  ref.listen<AsyncValue<bool>>(isOnlineProvider, (before, after) {
    if (before?.valueOrNull == false && after.valueOrNull == true) {
      unawaited(repository.sync(reconnect: true));
    }
  });
});
