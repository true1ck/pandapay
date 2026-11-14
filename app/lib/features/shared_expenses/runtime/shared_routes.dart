import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import '../ui/shared_expenses_screen.dart';
import '../ui/shared_group_screen.dart';
import '../ui/shared_presentation.dart';
import '../../../app/providers.dart' show upiPaymentServiceProvider;
import 'shared_providers.dart';
import 'shared_runtime.dart';
import 'shared_expense_review.dart';
import '../ui/shared_settle_sheet.dart';
import '../ui/shared_members_sheet.dart';
import '../ui/shared_name_sheet.dart';
import '../ui/shared_add_friend_sheet.dart';
import '../ui/shared_attention_sheet.dart';
import '../ui/shared_invite_inbox.dart';
import '../ui/shared_join_requests_page.dart';
import '../ui/shared_settlements_sheet.dart';
import '../ui/shared_tap_gate.dart';

/// Production-backed screen adapter. App router supplies destinations; this
/// layer never adds an app dock, invents balances or writes bank transactions.
class SharedExpensesRoute extends ConsumerStatefulWidget {
  /// The openers may return the page's future (go_router's `push` does); the
  /// hub keeps its buttons single-flight until that page is closed again.
  final FutureOr<void> Function(String) onOpenContext;
  final FutureOr<void> Function() onAddExpense;

  /// Opens the join-requests page.
  final Future<void> Function()? onOpenRequests;
  const SharedExpensesRoute({
    super.key,
    required this.onOpenContext,
    required this.onAddExpense,
    this.onOpenRequests,
  });
  @override
  ConsumerState<SharedExpensesRoute> createState() =>
      _SharedExpensesRouteState();
}

class _SharedExpensesRouteState extends ConsumerState<SharedExpensesRoute> {
  static final _loadingHub = SharedHubPresentation(
    friends: SharedPage(state: SharedLoadState.loading),
    groups: SharedPage(state: SharedLoadState.loading),
    activity: SharedPage(state: SharedLoadState.loading),
  );

  /// The last screen we could build. Once there is one, a failed refresh
  /// never replaces it with an error: the person keeps what they were seeing.
  SharedHubPresentation? _data;
  Object? _error;
  int _seq = 0, _seenVersion = 0;
  SharedExpensesRuntime? _runtime;
  final _history = {
    for (final tab in SharedHubTab.values) tab: <String?>[null],
  };
  final _searches = <SharedHubTab, String>{};
  Timer? _searchDebounce;

  /// One page, sheet or dialog at a time: repeated taps must not stack copies.
  final _gate = SharedTapGate();
  @override
  void dispose() {
    _searchDebounce?.cancel();
    _runtime?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final runtime = _runtime;
    if (!mounted || runtime == null) return;
    // Reload only when the server's data really changed; an idle refresh
    // used to re-fetch every page each time it finished. Flags (add friend,
    // create group) can arrive mid-refresh, so a plain rebuild is always safe.
    if (!runtime.busy && runtime.dataVersion != _seenVersion) {
      _seenVersion = runtime.dataVersion;
      _reload();
    } else {
      setState(() {}); // flags (e.g. add friend) may have arrived
    }
  }

  Future<SharedHubPresentation> _load() => _runtime!.loadHub(
    after: {for (final entry in _history.entries) entry.key: entry.value.last},
    searches: Map.of(_searches),
  );

  /// Paints the saved screen at once (when there is one), then loads live data
  /// behind it. Newer calls win; an older failure is ignored.
  Future<void> _run({bool cacheFirst = false}) async {
    final runtime = _runtime;
    if (runtime == null) return;
    final seq = ++_seq;
    if (cacheFirst && _data == null) {
      try {
        final saved = await runtime.runCacheOnly(_load);
        if (mounted && seq == _seq && _data == null) {
          setState(() => _data = saved);
        }
      } catch (_) {}
      // Just loaded live and nothing changed since: ask the server nothing.
      if (_data != null &&
          runtime.hubFresh() &&
          _searches.isEmpty &&
          _history.values.every((pages) => pages.length == 1)) {
        return;
      }
    }
    try {
      final fresh = await _load();
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = fresh;
        _error = null;
      });
    } catch (error) {
      debugPrint('shared hub load failed: ${sharedErrorCode(error)}');
      if (!mounted || seq != _seq) return;
      if (_data == null) setState(() => _error = error);
    }
  }

  void _reload() {
    if (mounted && _runtime != null) unawaited(_run());
  }

  Future<void> _create(SharedExpensesRuntime runtime) async {
    final name = await SharedNameSheet.show(
      context,
      title: 'Create group',
      label: 'Group name',
      hint: 'You can add people to the group afterwards.',
      action: 'Create group',
    );
    if (name == null || !mounted) return;
    try {
      final id = const Uuid().v4();
      await runtime.submit('context.create', {
        'contextId': id,
        'contextKind': 'group',
        'name': name,
      });
      _reload();
      // Offline the group is only saved on this phone for now, and people are
      // added from the server's copy of it: say so instead of opening a sheet
      // that cannot load.
      if (mounted && runtime.isCurrent() && runtime.offline) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Group saved on this phone. It will be created when you are '
              'online; then you can add people.',
            ),
          ),
        );
        return;
      }
      // A group is only useful with people in it: go straight to adding them.
      if (mounted && runtime.isCurrent()) {
        await SharedMembersSheet.show(
          context,
          runtime: runtime,
          contextId: id,
          groupName: name,
        );
        if (mounted) _reload();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save the group yet. Try again in a moment.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _createFriend(SharedExpensesRuntime runtime) async {
    final id = await runAddFriendFlow(context, runtime);
    if (id != null && mounted) _reload();
  }

  void _open(String id) =>
      unawaited(_gate.run(() => widget.onOpenContext(id)));

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sharedExpensesRuntimeProvider);
    return state.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) {
        debugPrint('shared runtime failed: ${sharedErrorCode(error)}');
        return _Unavailable(
          error: error,
          onRetry: () => ref.invalidate(sharedExpensesRuntimeProvider),
        );
      },
      data: (runtime) {
        if (_runtime != runtime) {
          _runtime?.removeListener(_changed);
          _searchDebounce?.cancel();
          _searches.clear();
          for (final tab in SharedHubTab.values) {
            _history[tab] = [null];
          }
          _runtime = runtime;
          _data = null;
          _error = null;
          _seenVersion = runtime.dataVersion;
          runtime.addListener(_changed);
          unawaited(_run(cacheFirst: true));
        }
        return Builder(
          builder: (context) {
            final data = _data;
            if (data == null) {
              if (_error != null) {
                return _Unavailable(
                  error: _error,
                  onRetry: () {
                    setState(() => _error = null);
                    unawaited(
                      runtime.refresh().whenComplete(() {
                        if (mounted) _reload();
                      }),
                    );
                  },
                );
              }
            }
            // Nothing saved yet (first launch after install): open the page
            // at once with each tab loading, and let the live data fill in.
            return SharedExpensesScreen(
              key: ValueKey(runtime.store.namespace),
              data: data ?? _loadingHub,
              header: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SharedInviteInbox(
                    runtime: runtime,
                    onJoined: _reload,
                    onReviewRequests: widget.onOpenRequests == null
                        ? null
                        : () => _gate.run(widget.onOpenRequests!),
                  ),
                  SharedNeedsAttentionRow(runtime: runtime),
                ],
              ),
              onOpenFriend: _open,
              onOpenGroup: _open,
              onOpenActivity: _open,
              onAddExpense: () => unawaited(_gate.run(widget.onAddExpense)),
              onCreateGroup: runtime.canQueueProposals
                  ? () => unawaited(_gate.run(() => _create(runtime)))
                  : null,
              onAddFriend: runtime.canQueueProposals
                  ? () => unawaited(_gate.run(() => _createFriend(runtime)))
                  : null,
              onRetry: (_) => _reload(),
              onLoadMore: (tab) {
                final view = data ?? _loadingHub;
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

/// Page of everyone waiting to join, reached from the Splits summary row.
class SharedJoinRequestsRoute extends ConsumerWidget {
  final VoidCallback onShareGroupLink;
  const SharedJoinRequestsRoute({super.key, required this.onShareGroupLink});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(sharedExpensesRuntimeProvider);
    return runtime.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => Scaffold(
        appBar: AppBar(title: const Text('Join requests')),
        body: const Center(child: Text('Shared expenses are not ready yet.')),
      ),
      data: (value) => SharedJoinRequestsPage(
        runtime: value,
        onShareGroupLink: onShareGroupLink,
      ),
    );
  }
}

class SharedContextRoute extends ConsumerStatefulWidget {
  final String contextId;
  final FutureOr<void> Function() onAddExpense;
  final FutureOr<void> Function(String)? onOpenExpense;
  const SharedContextRoute({
    super.key,
    required this.contextId,
    required this.onAddExpense,
    this.onOpenExpense,
  });
  @override
  ConsumerState<SharedContextRoute> createState() => _SharedContextRouteState();
}

class _SharedContextRouteState extends ConsumerState<SharedContextRoute> {
  /// Payments need two people who have actually joined. If the other person is
  /// still only invited, say so instead of opening a sheet that cannot work.
  Future<void> _settleIfPossible(
    SharedExpensesRuntime runtime,
    Future<void> Function() open,
  ) async {
    try {
      final roster = await runtime.contextRoster(widget.contextId);
      if (roster.members.where((m) => m.canSettle).length < 2) {
        final waiting = roster.members
            .where((m) => m.state == 'invited' && m.profileId == null)
            .firstOrNull;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                waiting != null
                    ? 'Waiting for ${waiting.name} to join. You can record payments once they have joined.'
                    : 'Add someone to this split before recording a payment.',
              ),
            ),
          );
        }
        return;
      }
    } catch (_) {
      // Fall through: the settle sheet shows its own recoverable error.
    }
    if (mounted) await open();
  }

  /// One page, sheet or dialog at a time: repeated taps must not stack copies.
  final _gate = SharedTapGate();

  SharedGroupPresentation? _data;
  Object? _error;
  int _seq = 0, _seenVersion = 0;
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
    // A split this person left is gone from their device; do not reload it.
    final runtime = _runtime;
    if (!mounted || runtime == null) return;
    if (runtime.store.isContextRevoked(widget.contextId)) return;
    if (!runtime.busy && runtime.dataVersion != _seenVersion) {
      _seenVersion = runtime.dataVersion;
      _reload();
    } else {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant SharedContextRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contextId != widget.contextId) {
      for (final tab in _history.keys) {
        _history[tab] = [null];
      }
      if (_runtime != null) {
        _data = null;
        _error = null;
        unawaited(_run(cacheFirst: true));
      }
    }
  }

  Future<SharedGroupPresentation> _load() => _runtime!.loadGroup(
    widget.contextId,
    expenseAfter: _history[SharedGroupTab.expenses]!.last,
    balanceAfter: _history[SharedGroupTab.balances]!.last,
  );
  Future<void> _run({bool cacheFirst = false}) async {
    final runtime = _runtime;
    if (runtime == null) return;
    final seq = ++_seq;
    if (cacheFirst && _data == null) {
      try {
        final saved = await runtime.runCacheOnly(_load);
        if (mounted && seq == _seq && _data == null) {
          setState(() => _data = saved);
        }
      } catch (_) {}
      if (_data != null &&
          runtime.groupFresh(widget.contextId) &&
          _history.values.every((pages) => pages.length == 1)) {
        return;
      }
    }
    try {
      final fresh = await _load();
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = fresh;
        _error = null;
      });
    } catch (error) {
      debugPrint('shared group load failed: ${sharedErrorCode(error)}');
      if (!mounted || seq != _seq) return;
      if (_data == null) setState(() => _error = error);
    }
  }

  void _reload() {
    if (mounted && _runtime != null) unawaited(_run());
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(sharedExpensesRuntimeProvider)
      .when(
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (error, _) {
          debugPrint('shared runtime failed: ${sharedErrorCode(error)}');
          return _Unavailable(
            error: error,
            onRetry: () => ref.invalidate(sharedExpensesRuntimeProvider),
          );
        },
        data: (runtime) {
          if (_runtime != runtime) {
            _runtime?.removeListener(_changed);
            for (final tab in _history.keys) {
              _history[tab] = [null];
            }
            _runtime = runtime;
            _data = null;
            _error = null;
            _seenVersion = runtime.dataVersion;
            runtime.addListener(_changed);
            unawaited(_run(cacheFirst: true));
          }
          return Builder(
            builder: (context) {
              final data = _data;
              if (data == null) {
                if (_error != null) {
                  return _Unavailable(
                    error: _error,
                    onRetry: () {
                      setState(() => _error = null);
                      unawaited(
                        runtime.refresh().whenComplete(() {
                          if (mounted) _reload();
                        }),
                      );
                    },
                  );
                }
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              return SharedGroupScreen(
                key: ValueKey('${runtime.store.namespace}:${widget.contextId}'),
                data: data,
                onAddExpense: () => unawaited(_gate.run(widget.onAddExpense)),
                onMembers: () => unawaited(
                  _gate.run(() async {
                    final navigator = Navigator.of(context);
                    final left = await SharedMembersSheet.show(
                      context,
                      runtime: runtime,
                      contextId: widget.contextId,
                      groupName: data.title,
                    );
                    // Left the split: this screen has nothing left to show.
                    if (left == true && mounted) unawaited(navigator.maybePop());
                  }),
                ),
                onOpenBalance: !runtime.settlementsEnabled
                    ? null
                    : (memberId) {
                        // The list may have reloaded since the tap was drawn.
                        final row = data.balances.items
                            .where((row) => row.id == memberId)
                            .firstOrNull;
                        if (row == null) return;
                        // Opposite obligations can coexist. Prefill one gross
                        // direction rather than offsetting debts or choosing
                        // the same member on both sides of the payment.
                        final paying = !row.balance.youOwe.isZero;
                        unawaited(
                          _gate.run(
                            () => _settleIfPossible(
                              runtime,
                              () => SharedSettleSheet.show(
                                context,
                                runtime: runtime,
                                contextId: widget.contextId,
                                upi: ref.read(upiPaymentServiceProvider),
                                initialPayerId: paying ? null : memberId,
                                initialReceiverId: paying ? memberId : null,
                                initialAmount: paying
                                    ? row.balance.youOwe
                                    : row.balance.owedToYou,
                              ),
                            ),
                          ),
                        );
                      },
                onSettleUp: !runtime.settlementsEnabled
                    ? null
                    : () => unawaited(
                        _gate.run(
                          () => _settleIfPossible(
                            runtime,
                            () => SharedSettleSheet.show(
                              context,
                              runtime: runtime,
                              contextId: widget.contextId,
                              upi: ref.read(upiPaymentServiceProvider),
                            ),
                          ),
                        ),
                      ),
                onViewSettlements: () => unawaited(
                  _gate.run(
                    () => SharedSettlementsSheet.show(
                      context,
                      runtime: runtime,
                      contextId: widget.contextId,
                      groupName: data.title,
                    ),
                  ),
                ),
                onRetry: (_) => _reload(),
                onLoadMore: (tab) {
                  final view = data;
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
                onOpenExpense: (id) => unawaited(
                  _gate.run(() async {
                    final open = widget.onOpenExpense;
                    if (open != null) return open(id);
                    await showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: BambooInk.paper,
                      builder: (_) => SharedExpenseReviewSheet(
                        runtime: runtime,
                        contextId: widget.contextId,
                        expenseId: id,
                      ),
                    );
                  }),
                ),
              );
            },
          );
        },
      );
}

class _Unavailable extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error;
  const _Unavailable({required this.onRetry, this.error});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BambooInk.paper,
    appBar: AppBar(title: Text('Splits', style: BambooFonts.heading(17))),
    body: AppBackground(
      child: ErrorState(
        message: sharedUnavailableMessage(error),
        onRetry: onRetry,
      ),
    ),
  );
}
