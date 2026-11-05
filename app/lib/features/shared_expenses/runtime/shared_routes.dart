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
import '../ui/shared_invite_inbox.dart';
import '../ui/shared_settlements_sheet.dart';

/// Production-backed screen adapter. App router supplies destinations; this
/// layer never adds an app dock, invents balances or writes bank transactions.
class SharedExpensesRoute extends ConsumerStatefulWidget {
  final ValueChanged<String> onOpenContext;
  final VoidCallback onAddExpense;
  const SharedExpensesRoute({
    super.key,
    required this.onOpenContext,
    required this.onAddExpense,
  });
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
  bool _creatingFriend = false;
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
    if (_creatingFriend) return;
    _creatingFriend = true;
    try {
      final id = await runAddFriendFlow(context, runtime);
      if (id != null && mounted) _reload();
    } finally {
      _creatingFriend = false;
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
              header: SharedInviteInbox(runtime: runtime, onJoined: _reload),
              onOpenFriend: widget.onOpenContext,
              onOpenGroup: widget.onOpenContext,
              onOpenActivity: widget.onOpenContext,
              onAddExpense: widget.onAddExpense,
              onCreateGroup: runtime.proposalsEnabled
                  ? () => _create(runtime)
                  : null,
              onAddFriend: runtime.proposalsEnabled
                  ? () => _createFriend(runtime)
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
  final VoidCallback onAddExpense;
  final ValueChanged<String>? onOpenExpense;
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
    VoidCallback open,
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
    if (mounted) open();
  }

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
    // A split this person left is gone from their device; do not reload it.
    if (_runtime?.store.isContextRevoked(widget.contextId) == true) return;
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
                onAddExpense: widget.onAddExpense,
                onMembers: () => unawaited(
                  SharedMembersSheet.show(
                    context,
                    runtime: runtime,
                    contextId: widget.contextId,
                    groupName: snapshot.data!.title,
                  ).then((left) {
                    // Left the split: this screen has nothing left to show.
                    if (left == true && mounted) {
                      Navigator.of(context).maybePop();
                    }
                  }),
                ),
                onOpenBalance: !runtime.settlementsEnabled
                    ? null
                    : (memberId) {
                        final row = snapshot.data!.balances.items.firstWhere(
                          (row) => row.id == memberId,
                        );
                        // Opposite obligations can coexist. Prefill one gross
                        // direction rather than offsetting debts or choosing
                        // the same member on both sides of the payment.
                        final paying = !row.balance.youOwe.isZero;
                        return unawaited(
                          _settleIfPossible(
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
                        );
                      },
                onSettleUp: !runtime.settlementsEnabled
                    ? null
                    : () => unawaited(
                        _settleIfPossible(
                          runtime,
                          () => SharedSettleSheet.show(
                            context,
                            runtime: runtime,
                            contextId: widget.contextId,
                            upi: ref.read(upiPaymentServiceProvider),
                          ),
                        ),
                      ),
                onViewSettlements: () => unawaited(
                  SharedSettlementsSheet.show(
                    context,
                    runtime: runtime,
                    contextId: widget.contextId,
                    groupName: snapshot.data!.title,
                  ),
                ),
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
                onOpenExpense:
                    widget.onOpenExpense ??
                    (id) => unawaited(
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: BambooInk.paper,
                        builder: (_) => SharedExpenseReviewSheet(
                          runtime: runtime,
                          contextId: widget.contextId,
                          expenseId: id,
                        ),
                      ),
                    ),
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
