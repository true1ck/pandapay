
import '../../data/catalogue_repository.dart'
    show SpendCategory, categoryIdForServer, userCategoryIdForServer;
import '../../data/local/financial_store.dart';
import '../../data/local/sync_queue.dart';
import '../../data/local/transaction_outbox_repository.dart';
import '../../data/local_first/command_outbox.dart';
import '../../data/user_cards_repository.dart' show TransactionEntry;

/// Command kind of "ignore this transaction"; same string as
/// `OutboxCommand.ignoreTransaction` (kept here so this file does not import
/// the providers hotspot; the test pins the equality).
const bulkIgnoreCommandKind = 'ignore_transaction';

/// WP-C5: result of one bulk action. A row that fails is listed in [failed]
/// and never stops the others.
class BulkOutcome {
  const BulkOutcome({this.done = 0, this.failed = const [], this.skipped = 0});
  final int done;
  final List<String> failed;

  /// Rows the action does not apply to (SMS rows for a card change).
  final int skipped;
}

const _localPrefix = 'local-outbox:';

/// Bulk categorize / assign card / delete on the Activity screen, saved on the
/// phone first. The selection is split by id kind:
///
/// * `v2:` SMS rows live on this phone (the server has no such id): category
///   and delete go through [smsSetCategory] / [smsHide]; a card change is
///   skipped (done in Needs review or the row's Edit screen).
/// * `local-outbox:` rows were saved offline and have no server row yet: the
///   queued entry is edited, or cancelled for a delete.
/// * every other id is a server row: a field edit through the [SyncQueue]
///   (category/card columns are on the sync allowlist) or an ignore command
///   in the [CommandOutbox], with the phone's copy updated at once.
///
/// The caller bumps the flush request / invalidates providers afterwards.
class BulkTransactionActions {
  BulkTransactionActions({
    required this.namespace,
    required this.store,
    required this.queue,
    required this.commands,
    required this.outbox,
    this.smsSetCategory,
    this.smsHide,
  });

  final String namespace;
  final FinancialStore store;
  final SyncQueue queue;
  final CommandOutbox commands;
  final TransactionOutboxRepository outbox;
  final void Function(List<TransactionEntry> rows, String slug)? smsSetCategory;
  final void Function(TransactionEntry row)? smsHide;

  static bool isSms(TransactionEntry e) => e.pipelineVersion == 2;
  static bool isQueued(TransactionEntry e) => e.id.startsWith(_localPrefix);

  Future<BulkOutcome> setCategory(
    List<TransactionEntry> selected,
    String categoryId, {
    String? slug,
    Iterable<SpendCategory> categories = const [],
  }) async {
    var done = 0;
    final failed = <String>[];
    final sms = selected.where(isSms).toList();
    if (sms.isNotEmpty) {
      try {
        if (slug == null || smsSetCategory == null) {
          throw ArgumentError('Choose a supported category for SMS transactions');
        }
        smsSetCategory!(sms, slug);
        done += sms.length;
      } catch (_) {
        failed.addAll(sms.map((e) => e.id));
      }
    }
    final fields = <String, Object?>{
      'category_id': categoryIdForServer(categoryId, categories),
      'user_category_id': userCategoryIdForServer(categoryId),
    };
    for (final e in selected.where((e) => !isSms(e))) {
      try {
        if (isQueued(e)) {
          if (!await outbox.editQueued(
            e.id.substring(_localPrefix.length),
            categoryId: categoryId,
          )) {
            throw StateError('already sent');
          }
        } else {
          queue.enqueueUpdate(
            entity: 'transactions',
            entityId: e.id,
            fields: fields,
          );
        }
        done++;
      } catch (_) {
        failed.add(e.id);
      }
    }
    return BulkOutcome(done: done, failed: failed);
  }

  Future<BulkOutcome> assignCard(
    List<TransactionEntry> selected,
    String userCardId,
  ) async {
    var done = 0;
    final failed = <String>[];
    final skipped = selected.where(isSms).length;
    for (final e in selected.where((e) => !isSms(e))) {
      try {
        if (isQueued(e)) {
          if (!await outbox.editQueued(
            e.id.substring(_localPrefix.length),
            userCardId: userCardId,
          )) {
            throw StateError('already sent');
          }
        } else {
          queue.enqueueUpdate(
            entity: 'transactions',
            entityId: e.id,
            fields: {'user_card_id': userCardId},
          );
        }
        done++;
      } catch (_) {
        failed.add(e.id);
      }
    }
    return BulkOutcome(done: done, failed: failed, skipped: skipped);
  }

  Future<BulkOutcome> delete(List<TransactionEntry> selected) async {
    var done = 0;
    final failed = <String>[];
    store.batch(() {
      for (final e in selected) {
        try {
          if (isSms(e)) {
            final hide = smsHide;
            if (hide == null) throw StateError('SMS actions unavailable');
            hide(e);
          } else if (isQueued(e)) {
            outbox.cancel(e.id.substring(_localPrefix.length));
          } else {
            commands.enqueue(
              kind: bulkIgnoreCommandKind,
              target: e.id,
              payload: {'id': e.id, 'reason': 'manual'},
              cancels: const ['restore_transaction'],
            );
          }
          store.markInactive(namespace, e.id, reason: 'manual');
          done++;
        } catch (_) {
          failed.add(e.id);
        }
      }
    });
    return BulkOutcome(done: done, failed: failed);
  }
}
