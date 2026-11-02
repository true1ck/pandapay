import 'dart:convert';

import 'local/financial_store.dart';
import 'needs_review_repository.dart';
import 'sms_amount_evidence.dart';
import 'user_cards_repository.dart';
import 'api_exception.dart';

/// Recover server-imported balance/limit expenses through the domain route,
/// which reverses rewards/card state. Original transactions remain recoverable.
Future<int> repairSyncedSmsAmounts({
  required FinancialStore store,
  required String namespace,
  required bool Function() accountIsCurrent,
  required Future<TransactionEntry> Function(String id) fetch,
  required Future<void> Function(String id) ignoreWrongTransaction,
  void Function(String stage)? observe,
}) async {
  var count = 0;
  observe?.call('checking');
  final repairDb = store.database.db;
  repairDb.execute(
    'CREATE TABLE IF NOT EXISTS sms_amount_repair_attempts(namespace TEXT NOT NULL,transaction_id TEXT NOT NULL,last_attempt INTEGER NOT NULL,PRIMARY KEY(namespace,transaction_id))',
  );
  final attempted = {
    for (final row in repairDb.select(
      'SELECT transaction_id,last_attempt FROM sms_amount_repair_attempts WHERE namespace=?',
      [namespace],
    ))
      row['transaction_id'] as String: row['last_attempt'] as int,
  };
  final allCandidates = store.invalidSmsAmountCandidates(namespace)
    ..sort(
      (a, b) => (attempted[a['id']] ?? 0).compareTo(attempted[b['id']] ?? 0),
    );
  final candidates = allCandidates.take(50).toList();
  observe?.call('candidates_${candidates.length}');
  for (final candidate in candidates) {
    if (!accountIsCurrent()) break;
    repairDb.execute(
      'INSERT INTO sms_amount_repair_attempts(namespace,transaction_id,last_attempt) VALUES(?,?,?) ON CONFLICT(namespace,transaction_id) DO UPDATE SET last_attempt=excluded.last_attempt',
      [namespace, candidate['id'], DateTime.now().millisecondsSinceEpoch],
    );
    try {
      final before = TransactionEntry.fromJson(
        jsonDecode(candidate['payload'] as String) as Map<String, dynamic>,
      );
      // Explicit user annotations are not automatic-repair candidates.
      if (before.note?.isNotEmpty == true ||
          before.tags.isNotEmpty ||
          before.userCategoryId != null) {
        observe?.call('skip_annotated');
        continue;
      }
      observe?.call('fetching');
      final current = await fetch(before.id);
      if (!accountIsCurrent()) break;
      final recoveredIgnore =
          current.status == 'ignored' &&
          current.note == '[ignored: wrong_transaction]';
      final sourceMatches =
          current.sourceKey == before.sourceKey ||
          current.observations.any(
            (o) =>
                const ['sms', 'sms_bulk'].contains(o.source) &&
                o.sourceKey == before.sourceKey,
          ) ||
          // Older detail responses omit source_key. A previously committed
          // receipt still binds this SMS to this exact server row; require the
          // remaining stable ledger identity rather than treating null as a
          // changed source. A conflicting non-null key never takes this path.
          (current.sourceKey == null &&
              candidate['has_source_receipt'] == 1 &&
              current.id == before.id &&
              current.occurredAt == before.occurredAt &&
              current.userCardId == before.userCardId);
      if (!sourceMatches ||
          current.amount != before.amount ||
          !const ['sms', 'sms_bulk'].contains(current.source) ||
          (current.note?.isNotEmpty == true && !recoveredIgnore) ||
          current.tags.isNotEmpty ||
          current.userCategoryId != null ||
          !const ['active', 'ignored'].contains(current.status)) {
        observe?.call(
          !sourceMatches
              ? (current.sourceKey == null
                    ? 'skip_source_missing'
                    : 'skip_source_changed')
              : current.amount != before.amount
              ? 'skip_amount_changed'
              : 'skip_record_changed',
        );
        continue;
      }
      if (current.status == 'active') {
        observe?.call('ignoring');
        await ignoreWrongTransaction(current.id);
        if (!accountIsCurrent()) break;
      }
      final body = candidate['body'] as String;
      store.batch(() {
        final db = store.database.db;
        db.execute('SAVEPOINT sms_synced_amount_repair');
        try {
          store.saveTransactions(namespace, [
            current.copyWith(
              status: 'ignored',
              note: '[ignored: wrong_transaction]',
            ),
          ]);
          addNeedsReviewSync(
            store.database,
            namespace,
            NeedsReviewItem(
              id: candidate['source_key'] as String,
              sender: candidate['sender'] as String,
              body: body,
              receivedAt: DateTime.fromMillisecondsSinceEpoch(
                candidate['received_at'] as int,
              ),
              reason: SmsAmountEvidence.reviewReason(body),
            ),
            existingTransactions: const [],
          );
          db.execute('RELEASE SAVEPOINT sms_synced_amount_repair');
        } catch (_) {
          db.execute('ROLLBACK TO SAVEPOINT sms_synced_amount_repair');
          db.execute('RELEASE SAVEPOINT sms_synced_amount_repair');
          rethrow;
        }
      });
      count++;
      observe?.call('repaired_$count');
    } catch (error) {
      observe?.call(
        error is ApiException
            ? 'failed_http_${error.statusCode ?? 0}'
            : 'failed_${error.runtimeType}',
      );
      // One unavailable transaction must not block other source-backed fixes.
      // The untouched candidate is retried on the next authenticated pass.
      continue;
    }
  }
  observe?.call('done_$count');
  return count;
}
