import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../app/providers.dart';
import '../../data/local/queue_registry.dart';
import '../account/account_commands.dart';
import '../import/statement_import_continuation_provider.dart';
import '../shared_expenses/runtime/shared_providers.dart';
import '../sms_v2/providers/runtime_provider.dart';
import '../sync/split_sync.dart';
import '../sync/sync_engine.dart';
import 'account_sign_out.dart';

/// Sign-out counting and flushing, read from [QueueRegistry] (WP-C3, L-02,
/// Q-11) so a queue added to the registry is counted and flushed here without
/// a second hand-kept list.

/// Words for each queue, in the order they appear in the warning. Queues that
/// share a label are added together ("Split changes" is two queues).
const Map<String, (String, String)> signOutQueueLabels = {
  'sync_pending_changes': ('edit', 'edits'),
  'transaction_outbox_entries': ('new expense', 'new expenses'),
  'duplicate_resolution_outbox': ('duplicate decision', 'duplicate decisions'),
  'command_outbox': ('queued change', 'queued changes'),
  'transaction_tag_outbox': ('tag change', 'tag changes'),
  'foreign_payments_outbox': ('foreign payment update', 'foreign payment updates'),
  'statement_import': ('statement upload', 'statement uploads'),
  'shared_commands': ('Split change', 'Split changes'),
  'split_documents': ('Split change', 'Split changes'),
  'v2_outbox': ('SMS update', 'SMS updates'),
  'sms_intake': ('message waiting to be read', 'messages waiting to be read'),
};

/// What is still queued for the server in one account.
class SignOutQueueScan {
  const SignOutQueueScan({
    required this.unsent,
    required this.pending,
    required this.kinds,
  });

  /// Every entry that signing out would lose: waiting, in backoff, parked or
  /// blocked. Entries the server already applied are not in any queue count.
  final int unsent;

  /// The part of [unsent] that is only waiting (will go without anyone acting):
  /// after a flush, what is left here failed to send just now.
  final int pending;

  final List<PendingKind> kinds;
}

/// Counts every send queue of [registry] for [namespace].
SignOutQueueScan scanSignOutQueues(QueueRegistry registry, String namespace) {
  final merged = <String, PendingKind>{};
  var unsent = 0;
  var pending = 0;
  for (final spec in registry.queues) {
    if (spec.kind != QueueKind.outbox) continue;
    final counts = registry.countsFor(spec.name, namespace);
    if (counts.isEmpty) continue;
    unsent += counts.total;
    pending += counts.pending;
    final label = signOutQueueLabels[spec.name] ?? (spec.name, spec.name);
    final existing = merged[label.$1];
    merged[label.$1] = PendingKind(
      singular: label.$1,
      plural: label.$2,
      count: (existing?.count ?? 0) + counts.total,
    );
  }
  return SignOutQueueScan(
    unsent: unsent,
    pending: pending,
    kinds: merged.values.toList(),
  );
}

/// Unsent changes of every account other than [current] in the same database
/// (H1-6). A rejected session keeps account A's queue; signing out of account
/// B later deletes the whole file, so A's work is lost and must be named.
int unsentInOtherAccounts(QueueRegistry registry, Database db, String current) {
  final others = <String>{};
  for (final spec in registry.queues) {
    if (spec.kind != QueueKind.outbox) continue;
    try {
      final columns = db.select('PRAGMA table_info(${spec.table})');
      if (!columns.any((c) => c['name'] == spec.namespaceColumn)) continue;
      for (final row in db.select(
        'SELECT DISTINCT ${spec.namespaceColumn} AS ns FROM ${spec.table}',
      )) {
        final ns = row['ns'];
        if (ns is String && ns != current && ns != 'signed-out') others.add(ns);
      }
    } catch (_) {
      // A table that is not there (yet) holds nothing.
    }
  }
  var total = 0;
  for (final ns in others) {
    total += scanSignOutQueues(registry, ns).unsent;
  }
  return total;
}

/// Queues that are always flushed on sign-out, as before WP-C3 (the sync
/// engine, the SMS runtime, the transaction and duplicate outboxes), even when
/// they look empty: a sync also pulls, the SMS runtime also reads new messages.
/// Every other queue is flushed only when it has something waiting, so that
/// signing out of a healthy account never starts the Split runtime or the
/// statement import continuation just to find them empty.
const Set<String> signOutAlwaysFlushed = {
  'sync_pending_changes',
  'v2_outbox',
  'transaction_outbox_entries',
  'duplicate_resolution_outbox',
};

/// Sends everything that can be sent, queue by queue. A failing queue never
/// stops the others; the report says which failed.
Future<QueueFlushReport> flushSignOutQueues(
  Ref ref, {
  required QueueRegistry registry,
  required String namespace,
}) async {
  Future<int> drain(Future<int> Function() once, {int rounds = 10}) async {
    var total = 0;
    for (var i = 0; i < rounds; i++) {
      final sent = await once();
      total += sent;
      if (sent == 0) break;
    }
    return total;
  }

  // The SMS runtime serves two queues; run it once per flush.
  Future<void>? smsRun;
  Future<int> sms() async {
    smsRun ??= () async {
      final runtime = await ref.read(smsV2RuntimeProvider.future);
      await runtime?.sync();
    }();
    await smsRun;
    return 0;
  }

  registry
    ..attachFlush('sync_pending_changes', () async {
      final result = await ref.read(syncEngineProvider).sync();
      // A cycle that did not finish (offline, server error) is a failure.
      if (!result.ranToCompletion) throw StateError('sync did not finish');
      return result.pushed;
    })
    ..attachFlush('transaction_outbox_entries', () async {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) return 0;
      final outbox = await ref.read(outboxRepositoryProvider.future);
      return drain(() => outbox.flush(repo));
    })
    ..attachFlush('duplicate_resolution_outbox', () async {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) return 0;
      final duplicates = await ref.read(
        duplicateResolutionOutboxRepositoryProvider.future,
      );
      return drain(() => duplicates.flush(repo));
    })
    ..attachFlush('command_outbox', () async {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) return 0;
      final commands = await ref.read(commandOutboxProvider.future);
      // The same handlers the background outbox uses (ignore, restore,
      // budgets, subscriptions, notifications ...).
      final handlers = commandHandlersFor(
        repo,
        spend: ref.read(spendReportsRepositoryProvider),
        notificationPrefs: ref.read(notificationPreferencesRepositoryProvider),
        accountHandlers: accountCommandHandlers(ref),
      );
      return drain(() => commands.flush(handlers));
    })
    ..attachFlush('transaction_tag_outbox', () async {
      await ref.read(transactionTagsProvider)?.sync();
      return 0;
    })
    ..attachFlush('foreign_payments_outbox', () async {
      await ref.read(foreignPaymentsRepositoryProvider).sync();
      return 0;
    })
    ..attachFlush('shared_commands', () async {
      final runtime = await ref.read(sharedExpensesRuntimeProvider.future);
      await runtime.refresh();
      return 0;
    })
    ..attachFlush('split_documents', () async {
      // Awaited here (the sync engine starts it without waiting), so the
      // sign-out really waits for the documents to be saved.
      final repository = await ref.read(splitRepositoryProvider.future);
      await repository.sync(reconnect: true);
      return 0;
    })
    ..attachFlush('statement_import', () async {
      final continuation = await ref.read(
        statementImportContinuationProvider.future,
      );
      if (continuation == null) return 0;
      await continuation.resume();
      return 0;
    })
    ..attachFlush('v2_outbox', sms)
    ..attachFlush('sms_intake', sms);

  final names = <String>{
    ...signOutAlwaysFlushed,
    for (final spec in registry.queues)
      if (spec.kind == QueueKind.outbox &&
          !registry.countsFor(spec.name, namespace).isEmpty)
        spec.name,
  };
  // Reading the messages first (as sign-out always did): what they produce is
  // then sent by the passes after it.
  const smsQueues = {'v2_outbox', 'sms_intake'};
  final first = await registry.flushAll(only: names.intersection(smsQueues));
  final rest = await registry.flushAll(only: names.difference(smsQueues));
  return QueueFlushReport(
    {...first.delivered, ...rest.delivered},
    {...first.failures, ...rest.failures},
  );
}
