import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/providers.dart' as app;
import '../../../data/user_cards_repository.dart';
import '../providers/ai_status_provider.dart';
import '../providers/data_providers.dart';
import '../storage/schema.dart';
import '../ledger/providers.dart';
import 'screen_parts.dart';

/// How far back the Auto-resolved and History lists reach, and how many rows
/// each shows. Both read the in-memory ledger model, never the whole history.
const settledWindow = Duration(days: 90);
const settledMaxRows = 200;

/// One transaction the app settled, and who settled it.
class SettledItem {
  const SettledItem({
    required this.entry,
    required this.byUser,
    required this.how,
    this.confidence,
  });

  final TransactionEntry entry;

  /// True when the person confirmed or edited it; false when the rules or the
  /// AI read it and no one was asked.
  final bool byUser;

  /// A plain-words line: "Read by a rule", "Read by an AI rule", "You edited".
  final String how;
  final double? confidence;
}

class SettledLists {
  const SettledLists({this.auto = const [], this.history = const []});

  /// Read by rules or the AI without asking, newest first.
  final List<SettledItem> auto;

  /// Settled or changed by the person, newest first.
  final List<SettledItem> history;
}

/// Splits the recent stored SMS transactions into those the engine settled by
/// itself and those the person settled or edited by hand.
SettledLists settledLists(
  Iterable<TransactionEntry> transactions,
  Map<String, List<Fact>> factsBySource, {
  required DateTime now,
}) {
  final cutoff = now.subtract(settledWindow);
  final auto = <SettledItem>[];
  final history = <SettledItem>[];
  for (final entry in transactions) {
    if (entry.pipelineVersion != 2) continue;
    final source = entry.sourceKey;
    if (source == null || entry.eventId == null) continue;
    if (entry.occurredAt.isBefore(cutoff)) continue;
    final facts = factsBySource[source] ?? const <Fact>[];
    if (facts.isEmpty) continue;
    final byUser = facts.any((f) => f.provenance.engine == Engine.user);
    final machine = facts.firstWhere(
      (f) => f.provenance.engine != Engine.user,
      orElse: () => facts.first,
    );
    final usedAi = facts.any((f) => f.provenance.engine == Engine.ai);
    final item = SettledItem(
      entry: entry,
      byUser: byUser,
      confidence: machine.confidence,
      how: byUser
          ? 'You confirmed or edited this'
          : usedAi
          ? 'Read by an AI rule'
          : 'Read by a rule',
    );
    (byUser ? history : auto).add(item);
  }
  int newest(SettledItem a, SettledItem b) =>
      b.entry.occurredAt.compareTo(a.entry.occurredAt);
  auto.sort(newest);
  history.sort(newest);
  return SettledLists(
    auto: auto.take(settledMaxRows).toList(growable: false),
    history: history.take(settledMaxRows).toList(growable: false),
  );
}

final settledListsProvider = FutureProvider<SettledLists>((ref) async {
  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
  return settledLists(
    model.transactions,
    model.factsBySource,
    now: DateTime.now(),
  );
});

/// Puts a settled transaction back on the Needs review list as an open
/// question. The transaction itself is not changed; answering the question
/// (Looks right, Fix) goes through the same correction service as any other.
Future<void> reopenForReview(WidgetRef ref, TransactionEntry entry) async {
  final source = entry.sourceKey;
  final eventId = entry.eventId;
  if (source == null || eventId == null) {
    throw ArgumentError('This transaction has no message to review');
  }
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  final store = cache.financialStore;
  final db = store.database.db;
  SmsV2Schema.ensure(db);
  store.batch(() {
    db.execute(
      'INSERT INTO v2_review_items (namespace, review_id, kind, payload, status) '
      "VALUES (?, ?, 'event', ?, 'open') "
      "ON CONFLICT(namespace, review_id) DO UPDATE SET status='open', payload=excluded.payload",
      [
        namespace,
        'reopen:$eventId',
        jsonEncode({
          'sourceKey': source,
          'eventId': eventId,
          'reason': 'reopened',
          'hasReading': true,
        }),
      ],
    );
    store.notifyExternalChanges(namespace, const ['needs_review']);
  });
  ref.invalidate(reviewItemsProvider);
}

/// How many message formats the AI could not turn into a rule (failed, or its
/// draft was turned down by a reviewer). Read from the phone's own sync state.
final aiUnreadCountProvider = FutureProvider<int>((ref) async {
  // Re-read whenever the AI status itself changes.
  await ref.watch(aiReviewStatusProvider.future);
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final row = db.select(
    "SELECT count(*) AS n FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' "
    "AND json_extract(value, '\$.status') IN ('failed', 'rejected')",
    [namespace],
  );
  return (row.first['n'] as num).toInt();
});

/// The Auto-resolved and History tabs share this list.
class SettledList extends ConsumerWidget {
  const SettledList({super.key, required this.history});

  /// True for the History tab, false for Auto-resolved.
  final bool history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(settledListsProvider);
    return lists.when(
      skipLoadingOnReload: true,
      loading: () => const SmsLoading(),
      error: (_, _) =>
          SmsError(onRetry: () => ref.invalidate(settledListsProvider)),
      data: (value) {
        final items = history ? value.history : value.auto;
        if (items.isEmpty) {
          return SmsEmpty(
            history
                ? 'Nothing settled by you yet. Messages you confirm or fix appear here, so you can change them again.'
                : 'Nothing read automatically yet. Messages the app understood without asking appear here, so you can check them.',
            icon: history ? Icons.history_rounded : Icons.auto_awesome_outlined,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(settledListsProvider);
            await ref.read(settledListsProvider.future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.xxl,
            ),
            itemCount: items.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
            itemBuilder: (context, i) => i == 0
                ? BambooNote(
                    history
                        ? 'Things you confirmed or fixed, last 90 days. Open one to change it again.'
                        : 'Read by the app without asking you, last 90 days. Open one if it is wrong.',
                    icon: Icons.info_outline_rounded,
                  )
                : SettledCard(item: items[i - 1]),
          ),
        );
      },
    );
  }
}

final _money = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

class SettledCard extends ConsumerWidget {
  const SettledCard({super.key, required this.item});
  final SettledItem item;

  Future<void> _reopen(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await reopenForReview(ref, item.entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Moved back to review')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not move this one back')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = item.entry;
    final title = (e.merchantName ?? '').trim().isEmpty
        ? 'Transaction'
        : e.merchantName!.trim();
    final category = e.categoryName ?? e.subcategoryName;
    final date = DateFormat('d MMM y').format(e.occurredAt.toLocal());
    void edit() => context.push('/activity/${e.id}/edit', extra: e);
    return BambooPanel(
      key: Key('settled-${e.id}'),
      onTap: edit,
      semanticLabel: 'Open $title',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.heading(16, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [date, ?category].join(' · '),
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                _money.format(e.amount.paise / 100),
                style: BambooFonts.heading(16, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Icon(
                item.byUser
                    ? Icons.person_outline_rounded
                    : Icons.auto_awesome_outlined,
                size: 16,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.how,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          BambooActionBar(
            secondary: [
              OutlinedButton(
                key: Key('edit-${e.id}'),
                style: BambooButtons.secondary,
                onPressed: edit,
                child: const Text('Edit'),
              ),
            ],
            quiet: [
              TextButton(
                key: Key('reopen-${e.id}'),
                style: BambooButtons.quiet,
                onPressed: () => _reopen(context, ref),
                child: const Text('Move back to review'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the AI check is doing right now, over the Needs review list: how many
/// message formats were sent, how many are waiting, how many were read.
class AiProgressHeader extends ConsumerWidget {
  const AiProgressHeader({super.key, required this.openItems});
  final int openItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(aiReviewStatusProvider).valueOrNull;
    if (status == null) return const SizedBox.shrink();
    final waiting = status.checkingTemplates.length;
    final read = status.resolved.length;
    final unread = ref.watch(aiUnreadCountProvider).valueOrNull ?? 0;
    if (waiting == 0 && read == 0 && unread == 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const Key('ai-progress-header'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              waiting > 0
                  ? 'AI is checking $waiting message format${waiting == 1 ? '' : 's'}'
                  : 'AI review finished',
              style: BambooFonts.ui(
                13.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              [
                '$waiting waiting',
                '$read read by AI',
                if (unread > 0) '$unread could not be read',
                '$openItems still need you',
              ].join(' · '),
              style: BambooFonts.ui(12.5, color: BambooInk.ink700),
            ),
            if (waiting > 0) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }
}
