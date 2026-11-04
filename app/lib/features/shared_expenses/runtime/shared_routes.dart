import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import '../ui/shared_expenses_screen.dart';
import '../ui/shared_group_screen.dart';
import '../ui/shared_presentation.dart';
import 'shared_providers.dart';
import 'shared_runtime.dart';

/// Production-backed screen adapter. App router supplies destinations; this
/// layer never adds an app dock, invents balances or writes bank transactions.
class SharedExpensesRoute extends ConsumerStatefulWidget {
  final ValueChanged<String> onOpenContext;
  const SharedExpensesRoute({super.key, required this.onOpenContext});
  @override
  ConsumerState<SharedExpensesRoute> createState() =>
      _SharedExpensesRouteState();
}

class _SharedExpensesRouteState extends ConsumerState<SharedExpensesRoute> {
  Future<SharedHubPresentation>? _view;
  SharedExpensesRuntime? _runtime;
  final _history = {
    for (final tab in SharedHubTab.values) tab: <String?>[null],
  };
  final _searches = <SharedHubTab, String>{};
  Timer? _searchDebounce;
  @override
  void dispose() {
    _searchDebounce?.cancel();
    _runtime?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_runtime?.busy == false) _reload();
  }

  Future<SharedHubPresentation> _load() => _runtime!.loadHub(
    after: {for (final entry in _history.entries) entry.key: entry.value.last},
    searches: Map.of(_searches),
  );
  void _reload() {
    if (mounted && _runtime != null) {
      setState(() {
        _view = _load();
      });
    }
  }

  Future<void> _create(SharedExpensesRuntime runtime) async {
    var draftName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Create group', style: BambooFonts.heading(20)),
        content: TextField(
          onChanged: (value) => draftName = value,
          maxLength: 120,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final value = draftName.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    try {
      await runtime.submit('context.create', {
        'contextId': const Uuid().v4(),
        'contextKind': 'group',
        'name': name,
      });
      _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Group could not be confirmed. Check pending work before trying again.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sharedExpensesRuntimeProvider);
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => _Unavailable(
        onRetry: () => ref.invalidate(sharedExpensesRuntimeProvider),
      ),
      data: (runtime) {
        if (_runtime != runtime) {
          _runtime?.removeListener(_changed);
          _searchDebounce?.cancel();
          _searches.clear();
          for (final tab in SharedHubTab.values) {
            _history[tab] = [null];
          }
          _runtime = runtime;
          runtime.addListener(_changed);
          _view = _load();
        }
        return FutureBuilder<SharedHubPresentation>(
          key: ValueKey(
            '${runtime.store.namespace}:${runtime.accessGeneration}',
          ),
          future: _view,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _Unavailable(
                onRetry: () async {
                  await runtime.refresh();
                  _reload();
                },
              );
            }
            if (!snapshot.hasData) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return SharedExpensesScreen(
              key: ValueKey(runtime.store.namespace),
              data: snapshot.data!,
              onOpenFriend: widget.onOpenContext,
              onOpenGroup: widget.onOpenContext,
              onOpenActivity: widget.onOpenContext,
              onCreateGroup: runtime.proposalsEnabled
                  ? () => _create(runtime)
                  : null,
              onRetry: (_) => _reload(),
              onLoadMore: (tab) {
                final view = snapshot.data!;
                final next = switch (tab) {
                  SharedHubTab.friends => view.friends.nextCursor,
                  SharedHubTab.groups => view.groups.nextCursor,
                  SharedHubTab.activity => view.activity.nextCursor,
                };
                if (next != null) {
                  _history[tab]!.add(next);
                  _reload();
                }
              },
              onPreviousPage: (tab) {
                if (_history[tab]!.length > 1) {
                  _history[tab]!.removeLast();
                  _reload();
                }
              },
              onSearchChanged: (tab, value) {
                _searchDebounce?.cancel();
                _searches[tab] = value.length > 128
                    ? value.substring(0, 128)
                    : value;
                _history[tab] = [null];
                _searchDebounce = Timer(
                  const Duration(milliseconds: 300),
                  _reload,
                );
              },
            );
          },
        );
      },
    );
  }
}

class SharedContextRoute extends ConsumerStatefulWidget {
  final String contextId;
  final ValueChanged<String>? onOpenExpense;
  const SharedContextRoute({
    super.key,
    required this.contextId,
    this.onOpenExpense,
  });
  @override
  ConsumerState<SharedContextRoute> createState() => _SharedContextRouteState();
}

class _SharedContextRouteState extends ConsumerState<SharedContextRoute> {
  Future<SharedGroupPresentation>? _view;
  SharedExpensesRuntime? _runtime;
  final _history = {
    for (final tab in [SharedGroupTab.expenses, SharedGroupTab.balances])
      tab: <String?>[null],
  };
  @override
  void dispose() {
    _runtime?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_runtime?.busy == false) _reload();
  }

  @override
  void didUpdateWidget(covariant SharedContextRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contextId != widget.contextId) {
      for (final tab in _history.keys) {
        _history[tab] = [null];
      }
      if (_runtime != null) _view = _load();
    }
  }

  Future<SharedGroupPresentation> _load() => _runtime!.loadGroup(
    widget.contextId,
    expenseAfter: _history[SharedGroupTab.expenses]!.last,
    balanceAfter: _history[SharedGroupTab.balances]!.last,
  );
  void _reload() {
    if (mounted && _runtime != null) {
      setState(() {
        _view = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(sharedExpensesRuntimeProvider)
      .when(
        loading: () =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (_, _) => _Unavailable(
          onRetry: () => ref.invalidate(sharedExpensesRuntimeProvider),
        ),
        data: (runtime) {
          if (_runtime != runtime) {
            _runtime?.removeListener(_changed);
            for (final tab in _history.keys) {
              _history[tab] = [null];
            }
            _runtime = runtime;
            runtime.addListener(_changed);
            _view = _load();
          }
          return FutureBuilder<SharedGroupPresentation>(
            key: ValueKey(
              '${runtime.store.namespace}:${widget.contextId}:${runtime.accessGeneration}',
            ),
            future: _view,
            builder: (context, snapshot) {
              if (snapshot.hasError) return _Unavailable(onRetry: _reload);
              if (!snapshot.hasData) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              return SharedGroupScreen(
                key: ValueKey('${runtime.store.namespace}:${widget.contextId}'),
                data: snapshot.data!,
                onRetry: (_) => _reload(),
                onLoadMore: (tab) {
                  final view = snapshot.data!;
                  final next = switch (tab) {
                    SharedGroupTab.expenses => view.expenses.nextCursor,
                    SharedGroupTab.balances => view.balances.nextCursor,
                    SharedGroupTab.totals => null,
                  };
                  if (next != null) {
                    _history[tab]!.add(next);
                    _reload();
                  }
                },
                onPreviousPage: (tab) {
                  if ((_history[tab]?.length ?? 0) > 1) {
                    _history[tab]!.removeLast();
                    _reload();
                  }
                },
                onOpenExpense: widget.onOpenExpense,
              );
            },
          );
        },
      );
}

class _Unavailable extends StatelessWidget {
  final VoidCallback onRetry;
  const _Unavailable({required this.onRetry});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BambooInk.paper,
    appBar: AppBar(title: Text('Splits', style: BambooFonts.heading(17))),
    body: AppBackground(
      child: ErrorState(
        message:
            'Shared expenses are not available yet. Existing transactions and private splits are still available.',
        onRetry: onRetry,
      ),
    ),
  );
}
