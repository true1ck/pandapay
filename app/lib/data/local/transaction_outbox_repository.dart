import 'package:pandapay_domain/pandapay_domain.dart';

import '../user_cards_repository.dart';
import 'app_database.dart';

/// Plain value holder for one queued row — mirrors the
/// transaction_outbox_entries columns 1:1 (see app_database.dart).
class TransactionOutboxEntry {
  final int id;
  final String userCardId;
  final int amountPaise;
  final String? categoryId;
  final String? merchantName;
  final DateTime? occurredAt;
  final String? note;
  final DateTime createdAt;
  final String? lastError;

  const TransactionOutboxEntry({
    required this.id,
    required this.userCardId,
    required this.amountPaise,
    this.categoryId,
    this.merchantName,
    this.occurredAt,
    this.note,
    required this.createdAt,
    this.lastError,
  });
}

/// B6 offline queue (GAP_ANALYSIS.md §2/§7) — a quick-add save that fails
/// while offline lands here instead of just erroring out, and is sent for
/// real the next time [flush] runs (wired to isOnlineProvider transitioning
/// to true — see providers.dart's outboxFlushProvider).
class TransactionOutboxRepository {
  final AppDatabase _appDb;
  TransactionOutboxRepository(this._appDb);

  Future<void> enqueue({
    required String userCardId,
    required Money amount,
    String? categoryId,
    String? merchantName,
    DateTime? occurredAt,
    String? note,
  }) async {
    _appDb.db.execute(
      '''
      INSERT INTO transaction_outbox_entries
        (user_card_id, amount_paise, category_id, merchant_name, occurred_at, note, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        userCardId,
        amount.paise,
        categoryId,
        merchantName,
        occurredAt?.millisecondsSinceEpoch,
        note,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<List<TransactionOutboxEntry>> pending() async {
    final rows = _appDb.db.select('SELECT * FROM transaction_outbox_entries ORDER BY created_at ASC');
    return rows.map((row) {
      return TransactionOutboxEntry(
        id: row['id'] as int,
        userCardId: row['user_card_id'] as String,
        amountPaise: row['amount_paise'] as int,
        categoryId: row['category_id'] as String?,
        merchantName: row['merchant_name'] as String?,
        occurredAt: row['occurred_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['occurred_at'] as int),
        note: row['note'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        lastError: row['last_error'] as String?,
      );
    }).toList();
  }

  /// Attempts every queued entry once. A success removes the row; a
  /// failure records [TransactionOutboxEntry.lastError] and leaves it
  /// queued for the next flush — never silently drops a queued transaction.
  Future<int> flush(UserCardsRepository repo) async {
    var sent = 0;
    for (final entry in await pending()) {
      try {
        await repo.logTransaction(
          userCardId: entry.userCardId,
          amount: Money.fromPaise(entry.amountPaise),
          categoryId: entry.categoryId,
          merchantName: entry.merchantName,
          occurredAt: entry.occurredAt,
          note: entry.note,
        );
        _appDb.db.execute('DELETE FROM transaction_outbox_entries WHERE id = ?', [entry.id]);
        sent++;
      } catch (e) {
        _appDb.db.execute('UPDATE transaction_outbox_entries SET last_error = ? WHERE id = ?', [
          e.toString(),
          entry.id,
        ]);
      }
    }
    return sent;
  }
}
