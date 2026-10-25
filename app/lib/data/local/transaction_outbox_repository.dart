import '../portable_backup/account_recovery_operation_gate.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../user_cards_repository.dart';
import 'app_database.dart';
import 'financial_store.dart';

/// Plain value holder for one queued row — mirrors the
/// transaction_outbox_entries columns 1:1 (see app_database.dart).
class TransactionOutboxEntry {
  final int id;
  final String clientMutationId;
  final String? userCardId;
  final int amountPaise;
  final String? categoryId;
  final String? userCategoryId;
  final String? merchantName;
  final DateTime? occurredAt;
  final String? note;
  final TxnInstrument instrument;
  final TxnEntryKind entryKind;
  final DateTime createdAt;
  final String? lastError;

  const TransactionOutboxEntry({
    required this.id,
    required this.clientMutationId,
    required this.userCardId,
    required this.amountPaise,
    this.categoryId,
    this.userCategoryId,
    this.merchantName,
    this.occurredAt,
    this.note,
    required this.instrument,
    required this.entryKind,
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
  final String namespace;
  final FinancialStore? financialStore;
  TransactionOutboxRepository(
    this._appDb, {
    this.namespace = 'legacy',
    this.financialStore,
  });
  String _sourceKey(String mutationId) {
    final account = namespace.startsWith('user:')
        ? namespace.substring(5)
        : namespace;
    return sha256
        .convert(
          utf8.encode(
            '$account\u0000manual\u0000client-mutation\u0000$mutationId',
          ),
        )
        .toString();
  }

  Future<void> restoreLocalEntries() async {
    for (final entry in await pending()) {
      financialStore?.saveProvisional(
        namespace,
        TransactionEntry(
          id: 'local-outbox:${entry.clientMutationId}',
          sourceKey: _sourceKey(entry.clientMutationId),
          amount: Money.fromPaise(entry.amountPaise),
          occurredAt: entry.occurredAt ?? entry.createdAt,
          userCardId: entry.userCardId,
          categoryId: entry.categoryId ??
              (entry.userCategoryId == null
                  ? null
                  : 'custom:${entry.userCategoryId}'),
          merchantName: entry.merchantName,
          note: entry.note,
          instrument: entry.instrument,
          entryKind: entry.entryKind,
          source: 'manual',
          status: 'active',
        ),
      );
    }
  }

  Future<void> enqueue({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    DateTime? occurredAt,
    String? note,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
  }) async {
    final mutationId = clientMutationId ?? const Uuid().v4();
    final effectiveUserCategoryId = userCategoryId ??
        (categoryId != null && categoryId.startsWith('custom:')
            ? categoryId.substring('custom:'.length)
            : null);
    _appDb.db.execute(
      '''
      INSERT INTO transaction_outbox_entries
        (namespace, user_card_id, client_mutation_id, amount_paise, category_id, user_category_id, merchant_name,
         occurred_at, note, instrument, entry_kind, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        namespace,
        userCardId,
        mutationId,
        amount.paise,
        categoryId,
        effectiveUserCategoryId,
        merchantName,
        occurredAt?.millisecondsSinceEpoch,
        note,
        instrument.wireValue,
        entryKind.wireValue,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    financialStore?.saveProvisional(
      namespace,
      TransactionEntry(
        id: 'local-outbox:$mutationId',
        sourceKey: _sourceKey(mutationId),
        amount: amount,
        occurredAt: occurredAt ?? DateTime.now(),
        userCardId: userCardId,
        categoryId: categoryId,
        merchantName: merchantName,
        note: note,
        instrument: instrument,
        entryKind: entryKind,
        source: 'manual',
        status: 'active',
      ),
    );
  }

  Future<List<TransactionOutboxEntry>> pending() async {
    final rows = _appDb.db.select(
      'SELECT * FROM transaction_outbox_entries WHERE namespace=? ORDER BY created_at ASC',
      [namespace],
    );
    return rows.map((row) {
      return TransactionOutboxEntry(
        id: row['id'] as int,
        clientMutationId: row['client_mutation_id'] as String,
        userCardId: row['user_card_id'] as String?,
        amountPaise: row['amount_paise'] as int,
        categoryId: row['category_id'] as String?,
        userCategoryId: row['user_category_id'] as String?,
        merchantName: row['merchant_name'] as String?,
        occurredAt: row['occurred_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['occurred_at'] as int),
        note: row['note'] as String?,
        instrument: TxnInstrument.fromJson(row['instrument'] as String?),
        entryKind: TxnEntryKind.fromJson(row['entry_kind'] as String?),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
        ),
        lastError: row['last_error'] as String?,
      );
    }).toList();
  }

  /// Attempts every queued entry once. A success removes the row; a
  /// failure records [TransactionOutboxEntry.lastError] and leaves it
  /// queued for the next flush — never silently drops a queued transaction.
  Future<int> flush(UserCardsRepository repo) async {
    try {
      return await AccountRecoveryOperationGate.process.run(() => _flush(repo));
    } on AccountRecoveryBusy {
      return 0;
    }
  }

  Future<int> _flush(UserCardsRepository repo) async {
    var sent = 0;
    for (final entry in await pending()) {
      try {
        final id = await repo.logTransaction(
          userCardId: entry.userCardId,
          amount: Money.fromPaise(entry.amountPaise),
          categoryId: entry.categoryId ??
              (entry.userCategoryId == null
                  ? null
                  : 'custom:${entry.userCategoryId}'),
          userCategoryId: entry.userCategoryId,
          merchantName: entry.merchantName,
          occurredAt: entry.occurredAt,
          note: entry.note,
          instrument: entry.instrument,
          entryKind: entry.entryKind,
          clientMutationId: entry.clientMutationId,
        );
        financialStore?.saveTransactions(namespace, [
          TransactionEntry(
            id: id,
            sourceKey: _sourceKey(entry.clientMutationId),
            amount: Money.fromPaise(entry.amountPaise),
            occurredAt: entry.occurredAt ?? entry.createdAt,
            userCardId: entry.userCardId,
            categoryId: entry.categoryId,
            merchantName: entry.merchantName,
            note: entry.note,
            instrument: entry.instrument,
            entryKind: entry.entryKind,
            source: 'manual',
            status: 'active',
          ),
        ]);
        _appDb.db.execute(
          'DELETE FROM transaction_outbox_entries WHERE id = ?',
          [entry.id],
        );
        sent++;
      } catch (e) {
        _appDb.db.execute(
          'UPDATE transaction_outbox_entries SET last_error = ? WHERE id = ?',
          [e.toString(), entry.id],
        );
      }
    }
    return sent;
  }
}
