import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/user_cards_repository.dart';
import '../sms_v2/ui/review_controller.dart';

/// Whether [entry] can be left out of spending: a settled spend row that has a
/// server or phone record to carry the choice. A quick-add that has not reached
/// the server yet has neither, so it is not offered.
bool canExcludeFromSpend(TransactionEntry entry) =>
    entry.entryKind == TxnEntryKind.spend &&
    entry.status == 'active' &&
    !entry.id.startsWith('local-outbox:');

/// Counts each of [entries] in, or leaves it out of, the person's spending
/// ("Don't count in spending"). Returns how many were changed.
///
/// Only spending totals, breakdowns and budgets read this choice. The row stays
/// in Activity and in Money out, and its rewards, caps and card state are not
/// touched, so nothing is reversed on the server (unlike Refund or Delete).
///
/// An SMS transaction lives only on the phone, so the choice is stored there,
/// like its notes and tags. Any other transaction is written to the phone first
/// so the totals change at once, then sent through the command outbox, which
/// retries until the server accepts it. The server is told the value, never
/// "toggle", so a repeated send cannot flip it back.
Future<int> setSpendExclusion(
  WidgetRef ref,
  Iterable<TransactionEntry> entries, {
  required bool excluded,
}) async {
  final targets = entries
      .where(canExcludeFromSpend)
      .where((entry) => entry.excludeFromSpend != excluded)
      .toList();
  if (targets.isEmpty) return 0;
  final namespace = ref.read(cacheNamespaceProvider);
  final sms = targets.where((entry) => entry.pipelineVersion == 2).toList();
  final server = targets.where((entry) => entry.pipelineVersion != 2).toList();

  if (sms.isNotEmpty) {
    final controller = await smsReviewController(ref);
    if (namespace != ref.read(cacheNamespaceProvider)) return 0;
    // One notification for the whole selection, not one per row (each would
    // rebuild the ledger read model). The loop is bounded by the selection and
    // every lookup is a single-row primary-key read.
    controller.financial.batch(() {
      for (final entry in sms) {
        controller.financial.setExcludeFromSpend(
          namespace,
          entry.id,
          excluded,
        );
      }
    });
  }
  if (server.isNotEmpty) {
    final cache = await ref.read(responseCacheProvider.future);
    final commands = await ref.read(commandOutboxProvider.future);
    if (namespace != ref.read(cacheNamespaceProvider)) return 0;
    cache.financialStore.batch(() {
      for (final entry in server) {
        cache.financialStore.setExcludeFromSpend(
          namespace,
          entry.id,
          excluded,
        );
        commands.enqueue(
          kind: OutboxCommand.setSpendExclusion,
          target: entry.id,
          payload: {'id': entry.id, 'excluded': excluded},
        );
      }
    });
    ref.read(outboxFlushRequestProvider.notifier).state++;
    ref.invalidate(pendingOutboxCountProvider);
  }

  ref.invalidate(transactionsProvider);
  ref.invalidate(homeSummaryProvider);
  ref.invalidate(categorySpendProvider);
  ref.invalidate(spendReportProvider);
  ref.invalidate(budgetsProvider);
  return targets.length;
}
