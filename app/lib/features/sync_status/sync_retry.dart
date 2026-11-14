import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../sync/sync_engine.dart';
import '../../data/local/sync_queue.dart';
import 'queue_totals.dart';

/// Puts one queue's parked rows back in line (explicit "Retry" from the Sync
/// status sheet). Never throws on "nothing parked".
typedef ParkedRetry = Future<void> Function();

/// Retry actions by [QueueRegistry] queue name. Queues without an entry (SMS
/// uploads, duplicate reviews, Split, statement import) cannot be retried from
/// here: Split has its own sheet, the others retry by themselves.
final syncRetryActionsProvider = Provider<Map<String, ParkedRetry>>(
  buildSyncRetryActions,
);

Map<String, ParkedRetry> buildSyncRetryActions(Ref ref) => {
  'sync_pending_changes': () async {
    final namespace = ref.read(cacheNamespaceProvider);
    final database = await ref.read(appDatabaseProvider.future);
    // `in_flight = 2` is "the server applied it": never parked, never retried.
    database.db.execute(
      'UPDATE sync_pending_changes SET attempts = 0, last_error = NULL '
      'WHERE namespace = ? AND attempts >= ? AND in_flight != 2',
      [namespace, SyncQueue.maxAttempts],
    );
  },
  'transaction_outbox_entries': () async {
    final outbox = await ref.read(outboxRepositoryProvider.future);
    for (final entry in await outbox.parked()) {
      await outbox.retryParked(entry.id);
    }
  },
  'command_outbox': () async {
    final commands = await ref.read(commandOutboxProvider.future);
    for (final parked in commands.parked()) {
      commands.retryParked(parked.id);
    }
  },
  'transaction_tag_outbox': () async {
    ref.read(transactionTagsProvider)?.retryParked();
  },
  'foreign_payments_outbox': () async {
    await ref.read(foreignPaymentsRepositoryProvider).retryParked();
  },
};

/// Gives up on one queue's parked rows (the "Discard" next to Retry): the
/// server's own copy then shows. Only for queues where dropping is safe.
final syncDiscardActionsProvider = Provider<Map<String, ParkedRetry>>(
  (ref) => {
    // A refused edit: drop it so the server's own copy shows (F-4).
    'sync_pending_changes': () async {
      final namespace = ref.read(cacheNamespaceProvider);
      final database = await ref.read(appDatabaseProvider.future);
      database.db.execute(
        'DELETE FROM sync_pending_changes '
        'WHERE namespace = ? AND attempts >= ? AND in_flight != 2',
        [namespace, SyncQueue.maxAttempts],
      );
      ref.read(commandOutboxRevisionProvider.notifier).state++;
      ref.invalidate(transactionsProvider);
      ref.invalidate(homeSummaryProvider);
      ref.invalidate(pendingSyncCountProvider);
    },
    'command_outbox': () async {
      final commands = await ref.read(commandOutboxProvider.future);
      for (final parked in commands.parked()) {
        commands.discardParked(parked.id);
      }
      ref.read(commandOutboxRevisionProvider.notifier).state++;
      ref.invalidate(transactionsProvider);
      ref.invalidate(homeSummaryProvider);
      ref.invalidate(userCardsProvider);
    },
  },
);

/// Asks the normal machinery to send what was just put back: the outbox flush
/// (transactions, commands, duplicates), the sync engine (edits, tags,
/// foreign payments, Split documents) and a recount for the strip. Override in
/// tests.
final syncNudgeProvider = Provider<void Function()>((ref) {
  return () {
    ref.read(outboxFlushRequestProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;
    try {
      unawaited(ref.read(syncEngineProvider).sync());
    } catch (_) {
      // Signed out or the engine is not available: the next trigger will send.
    }
  };
});
