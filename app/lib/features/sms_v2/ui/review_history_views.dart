import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/design/app_theme.dart';
import '../../../data/user_cards_repository.dart';
import '../providers/ai_status_provider.dart';
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
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                history
                    ? 'Nothing you settled by hand in the last 90 days.'
                    : 'Nothing was read automatically in the last 90 days.',
                textAlign: TextAlign.center,
                style: BambooFonts.ui(14, color: BambooInk.ink700),
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(settledListsProvider);
            await ref.read(settledListsProvider.future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: items.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) => i == 0
                ? _SettledNote(history: history, count: items.length)
                : SettledCard(item: items[i - 1]),
          ),
        );
      },
    );
  }
}

class _SettledNote extends StatelessWidget {
  const _SettledNote({required this.history, required this.count});
  final bool history;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      history
          ? '$count you settled by hand. Open one to change it again.'
          : '$count read without asking you. Open one if it is wrong.',
      style: BambooFonts.ui(13, color: BambooInk.ink700),
    ),
  );
}

final _money = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

class SettledCard extends StatelessWidget {
  const SettledCard({super.key, required this.item});
  final SettledItem item;

  @override
  Widget build(BuildContext context) {
    final e = item.entry;
    final title = (e.merchantName ?? '').trim().isEmpty
        ? 'Transaction'
        : e.merchantName!.trim();
    final category = e.categoryName ?? e.subcategoryName;
    final date = DateFormat('d MMM y').format(e.occurredAt.toLocal());
    return Card(
      key: Key('settled-${e.id}'),
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => context.push('/activity/${e.id}/edit', extra: e),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
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
                      style: BambooFonts.heading(15, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [date, ?category].join(' · '),
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.how,
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _money.format(e.amount.paise / 100),
                    style: BambooFonts.heading(15, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Edit',
                    style: BambooFonts.ui(12, color: BambooInk.slate),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    if (waiting == 0 && read == 0) return const SizedBox.shrink();
    return Padding(
      key: const Key('ai-progress-header'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              waiting > 0
                  ? 'AI is checking $waiting message format${waiting == 1 ? '' : 's'}'
                  : 'AI review finished',
              style: BambooFonts.heading(14, color: BambooInk.ink900),
            ),
            const SizedBox(height: 4),
            Text(
              '$waiting waiting · $read read by AI · $openItems still need you',
              style: BambooFonts.ui(12, color: BambooInk.ink700),
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
