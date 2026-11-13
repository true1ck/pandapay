import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design/app_theme.dart';
import '../../sync/split_sync.dart';
import '../runtime/shared_runtime.dart';
import '../storage/shared_store.dart';
import 'shared_components.dart';

/// Plain-language name of a saved change that did not sync. Never shows ids or
/// queue vocabulary; the wording uses what the person typed.
String sharedAttentionTitle(SharedQueuedCommand queued) {
  final payload = (queued.command.toJson()['payload'] as Map);
  String quoted(String key) {
    final value = payload[key];
    return value is String && value.trim().isNotEmpty ? '“$value”' : '';
  }

  return switch (queued.command.kind) {
    'context.create' =>
      payload['contextKind'] == 'direct'
          ? 'Add friend ${quoted('name')}'.trim()
          : 'Create group ${quoted('name')}'.trim(),
    'member.invite' => 'Add ${quoted('displayName')} to a split'.replaceAll(
      '  ',
      ' ',
    ),
    'member.rename' => 'Rename someone to ${quoted('displayName')}'.trim(),
    'membership.respond' => 'Answer a request to join',
    'expense.propose' => 'Add expense ${quoted('title')}'.trim(),
    'expense.respond' =>
      payload['decision'] == 'reject'
          ? 'Reject an expense'
          : 'Approve an expense',
    'settlement.report' => 'Report a payment',
    'settlement.respond' =>
      payload['decision'] == 'reject'
          ? 'Reject a payment report'
          : 'Confirm a payment report',
    _ => 'A change to a split',
  };
}

/// Why the server did not take it, in words that say what to do next.
String sharedAttentionReason(SharedQueuedCommand queued) {
  final code = queued.errorCode ?? '';
  if (code.startsWith('retry_limit')) {
    return 'We could not get this through after several tries. Try again when '
        'your connection is steady.';
  }
  final name = SharedNameException.fromStored(code);
  if (name != null) {
    return switch (name.code) {
      'friend_name_taken' => 'You already have a friend split with that name.',
      'member_name_taken' => 'Someone in that split already has that name.',
      _ => 'That name cannot be used.',
    };
  }
  if (queued.state == SharedCommandState.conflict ||
      code.startsWith('http_409')) {
    return 'It clashed with a newer change made somewhere else.';
  }
  if (code.startsWith('http_403')) {
    return 'You no longer have permission to do this.';
  }
  if (code.startsWith('http_404')) {
    return 'The split or person it was for no longer exists.';
  }
  return 'The server could not accept this change.';
}

/// A name that was refused will be refused again, so only Discard makes sense.
bool sharedAttentionCanRetry(SharedQueuedCommand queued) =>
    SharedNameException.fromStored(queued.errorCode) == null;

/// "N need attention": one slim row on the Split hub. No space at all when
/// every saved change has gone through.
class SharedNeedsAttentionRow extends ConsumerWidget {
  final SharedExpensesRuntime runtime;
  const SharedNeedsAttentionRow({super.key, required this.runtime});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blockedSplitCountProvider).valueOrNull ?? 0;
    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        var shared = 0;
        try {
          shared = runtime.attentionCount;
        } catch (_) {}
        final total = shared + blocked;
        if (total == 0) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final title = total == 1
            ? '1 needs attention'
            : '$total need attention';
        const detail = 'Saved on this phone, but not accepted by the server.';
        void open() => unawaited(
          SharedNeedsAttentionSheet.show(
            context,
            runtime: runtime,
            blockedPrivate: blocked,
          ),
        );
        return Semantics(
          container: true,
          button: true,
          label: '$title. $detail. Review',
          excludeSemantics: true,
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: InkWell(
                key: const Key('needs-attention-row'),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                onTap: open,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Row(
                    children: [
                      Icon(
                        Icons.sync_problem_outlined,
                        size: 20,
                        color: scheme.error,
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: BambooFonts.heading(
                                15,
                              ).copyWith(color: scheme.onSurface),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: BambooFonts.ui(
                                12.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      ExcludeSemantics(
                        child: TextButton.icon(
                          onPressed: open,
                          iconAlignment: IconAlignment.end,
                          icon: const Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                          ),
                          label: const Text('Review'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What was saved on this phone but never accepted, with the reason and a
/// choice for each: Retry (send it again) or Discard (forget it).
class SharedNeedsAttentionSheet extends StatefulWidget {
  final SharedExpensesRuntime runtime;

  /// Private per-transaction splits that are blocked; those are resolved on
  /// their own transaction, so this sheet only says they exist.
  final int blockedPrivate;
  const SharedNeedsAttentionSheet({
    super.key,
    required this.runtime,
    this.blockedPrivate = 0,
  });

  static Future<void> show(
    BuildContext context, {
    required SharedExpensesRuntime runtime,
    int blockedPrivate = 0,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BambooInk.paper,
    builder: (_) => SharedNeedsAttentionSheet(
      runtime: runtime,
      blockedPrivate: blockedPrivate,
    ),
  );

  @override
  State<SharedNeedsAttentionSheet> createState() =>
      _SharedNeedsAttentionSheetState();
}

class _SharedNeedsAttentionSheetState extends State<SharedNeedsAttentionSheet> {
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _act(String id, Future<void> Function(String) action) async {
    if (!_busy.add(id)) return;
    setState(() {});
    try {
      await action(id);
    } catch (_) {
      // The command stays where it was; the list below is read again.
    } finally {
      _busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    List<SharedQueuedCommand> items = const [];
    try {
      items = widget.runtime.store.readAttention();
    } catch (_) {}
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Not synced', style: BambooFonts.heading(20)),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const SharedNotice(
                    'These were saved on this phone, but the server did not '
                    'accept them. Nothing was lost.',
                  ),
                  if (items.isEmpty && widget.blockedPrivate == 0)
                    const SharedNotice('Everything is up to date.'),
                  for (final item in items)
                    SharedPanel(
                      child: Column(
                        key: ValueKey(item.command.operationId),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            sharedAttentionTitle(item),
                            style: BambooFonts.heading(16),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            sharedAttentionReason(item),
                            style: BambooFonts.ui(13, color: BambooInk.ink700),
                          ),
                          const SizedBox(height: AppSpace.md),
                          if (_busy.contains(item.command.operationId))
                            const LinearProgressIndicator(
                              color: BambooInk.slate,
                            )
                          else
                            Row(
                              children: [
                                if (sharedAttentionCanRetry(item)) ...[
                                  Expanded(
                                    child: SharedAction(
                                      label: 'Retry',
                                      primary: true,
                                      onTap: () => unawaited(
                                        _act(
                                          item.command.operationId,
                                          widget.runtime.retryRefused,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpace.md),
                                ],
                                SharedTextAction(
                                  label: 'Discard',
                                  onTap: () => unawaited(
                                    _act(
                                      item.command.operationId,
                                      widget.runtime.discardRefused,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  if (widget.blockedPrivate > 0)
                    SharedNotice(
                      widget.blockedPrivate == 1
                          ? 'A private split on one of your transactions could '
                                'not be saved. Open that transaction to choose '
                                'which version to keep.'
                          : '${widget.blockedPrivate} private splits on your '
                                'transactions could not be saved. Open each '
                                'transaction to choose which version to keep.',
                      icon: Icons.call_split_rounded,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
