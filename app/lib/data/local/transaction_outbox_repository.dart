import '../portable_backup/account_recovery_operation_gate.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../user_cards_repository.dart';
import 'app_database.dart';
import 'financial_store.dart';
import '../connectivity/server_backoff.dart';
import 'queue_retry_policy.dart';
import '../local_first/provisional_cards.dart';

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

  /// Delivery attempts that counted (a pure network failure does not count).
  final int attempts;

  /// Earliest time the next automatic attempt may run; null when due now.
  final DateTime? nextAttemptAt;

  /// True once the server permanently rejected the entry. A parked entry is
  /// kept (and its provisional row stays visible) but never retried
  /// automatically; see [TransactionOutboxRepository.retryParked].
  final bool parked;

  /// Optional contract wire value (payment_methods_v1.json); null for every
  /// row queued before the column existed and whenever the user chose none.
  final String? paymentMethod;

  /// Set only by a payment-sent "log it" (reward matching needs them).
  final String? merchantVpa;
  final String? mcc;
  final String? rail;

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
    this.paymentMethod,
    this.merchantVpa,
    this.mcc,
    this.rail,
    this.attempts = 0,
    this.nextAttemptAt,
    this.parked = false,
  });
}

/// B6 offline queue (GAP_ANALYSIS.md §2/§7) — a quick-add save that fails
/// while offline lands here instead of just erroring out, and is sent for
/// real the next time [flush] runs (wired to isOnlineProvider transitioning
/// to true — see providers.dart's outboxFlushProvider).
class TransactionOutboxRepository {
  /// Keep one foreground/lifecycle flush bounded. The next scheduler pass
  /// resumes from the oldest remaining row, so a large offline backlog cannot
  /// monopolise the UI isolate or hold the recovery gate for an unbounded
  /// amount of time.
  static const defaultFlushBatchSize = 20;

  final AppDatabase _appDb;
  final String namespace;
  final FinancialStore? financialStore;
  final DateTime Function() _now;
  TransactionOutboxRepository(
    this._appDb, {
    this.namespace = 'legacy',
    this.financialStore,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
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

  TransactionEntry _provisional(TransactionOutboxEntry entry) =>
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
        paymentMethod: entry.paymentMethod,
        entryKind: entry.entryKind,
        source: 'manual',
        status: 'active',
      );

  Future<void> restoreLocalEntries() async {
    // Every queued entry, including parked ones and ones waiting out a
    // backoff: the person still sees what they saved until it is delivered.
    for (final entry in await all()) {
      financialStore?.saveProvisional(namespace, _provisional(entry));
    }
  }

  static const _editableColumns = {
    'amount_paise',
    'occurred_at',
    'category_id',
    'user_category_id',
    'merchant_name',
    'user_card_id',
    'instrument',
    'entry_kind',
    'payment_method',
    'rail',
  };

  /// Rewrites fields of an entry that has not been sent yet (the person edited
  /// a transaction they just quick-added, offline). [columns] maps outbox
  /// column names to new values (null clears). The list row is rewritten too.
  /// Returns false when the entry is no longer queued (it was delivered).
  Future<bool> updateQueued(
    String clientMutationId,
    Map<String, Object?> columns,
  ) async {
    if (columns.isEmpty) return true;
    assert(columns.keys.every(_editableColumns.contains));
    _appDb.db.execute(
      'UPDATE transaction_outbox_entries SET '
      '${columns.keys.map((c) => '$c=?').join(', ')} '
      'WHERE namespace=? AND client_mutation_id=?',
      [...columns.values, namespace, clientMutationId],
    );
    if (_appDb.db.updatedRows == 0) return false;
    for (final entry in await all()) {
      if (entry.clientMutationId == clientMutationId) {
        financialStore?.saveProvisional(namespace, _provisional(entry));
      }
    }
    return true;
  }

  /// Changes the category and/or card of an entry that has not been sent yet
  /// (a bulk edit that includes a row saved offline). [categoryId] may be a
  /// `custom:<id>` value. Returns false when the entry is no longer queued, i.e.
  /// it has been delivered and the caller should edit the server row instead.
  Future<bool> editQueued(
    String clientMutationId, {
    String? categoryId,
    String? userCardId,
  }) async {
    final custom = categoryId != null && categoryId.startsWith('custom:');
    if (categoryId != null) {
      _appDb.db.execute(
        'UPDATE transaction_outbox_entries SET category_id=?, user_category_id=? '
        'WHERE namespace=? AND client_mutation_id=?',
        [
          custom ? null : categoryId,
          custom ? categoryId.substring('custom:'.length) : null,
          namespace,
          clientMutationId,
        ],
      );
      if (_appDb.db.updatedRows == 0) return false;
    }
    if (userCardId != null) {
      _appDb.db.execute(
        'UPDATE transaction_outbox_entries SET user_card_id=? '
        'WHERE namespace=? AND client_mutation_id=?',
        [userCardId, namespace, clientMutationId],
      );
      if (_appDb.db.updatedRows == 0) return false;
    }
    for (final entry in await all()) {
      if (entry.clientMutationId == clientMutationId) {
        financialStore?.saveProvisional(namespace, _provisional(entry));
      }
    }
    return true;
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
    String? paymentMethod,
    String? merchantVpa,
    String? mcc,
    String? rail,
  }) async {
    final mutationId = clientMutationId ?? const Uuid().v4();
    final effectiveUserCategoryId = userCategoryId ??
        (categoryId != null && categoryId.startsWith('custom:')
            ? categoryId.substring('custom:'.length)
            : null);
    // OR IGNORE: the same clientMutationId queued twice (a retried Save) is
    // one entry. The server also dedupes on the id if the first was delivered.
    _appDb.db.execute(
      '''
      INSERT OR IGNORE INTO transaction_outbox_entries
        (namespace, user_card_id, client_mutation_id, amount_paise, category_id, user_category_id, merchant_name,
         occurred_at, note, instrument, entry_kind, created_at, payment_method,
         merchant_vpa, mcc, rail)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        paymentMethod,
        merchantVpa,
        mcc,
        rail,
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
        paymentMethod: paymentMethod,
        entryKind: entryKind,
        source: 'manual',
        status: 'active',
      ),
    );
  }

  /// Takes a queued entry back before it was sent (Undo right after saving).
  /// Returns false when it is no longer queued, i.e. it has already reached the
  /// server; use [syncedTransactionId] to find the real transaction then.
  bool cancel(String clientMutationId) {
    _appDb.db.execute(
      'DELETE FROM transaction_outbox_entries WHERE namespace=? AND client_mutation_id=?',
      [namespace, clientMutationId],
    );
    if (_appDb.db.updatedRows == 0) return false;
    financialStore?.markInactive(namespace, 'local-outbox:$clientMutationId');
    return true;
  }

  /// The server id of an entry that has been delivered, found through the
  /// source key the delivered row was stored under; null when not delivered.
  String? syncedTransactionId(String clientMutationId) {
    final rows = _appDb.db.select(
      "SELECT id FROM financial_entities WHERE namespace=? AND entity='transactions' "
      "AND json_extract(payload, '\$.source_key')=? AND id NOT LIKE 'local-outbox:%' LIMIT 1",
      [namespace, _sourceKey(clientMutationId)],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  /// Entries due for delivery now: not parked and past their backoff, ordered
  /// by `(parked, next_attempt_at, created_at)` so a row that keeps failing
  /// never sits in front of a row that has not been tried yet.
  Future<List<TransactionOutboxEntry>> pending({int? limit}) async {
    return _select(
      'parked = 0 AND next_attempt_at <= ?',
      [_now().millisecondsSinceEpoch],
      limit: limit,
    );
  }

  /// Every queued entry of this account in the same order, whatever its state
  /// (due, waiting out a backoff or parked). Use this for counts and for
  /// rebuilding the provisional rows; use [pending] to decide what to send.
  Future<List<TransactionOutboxEntry>> all({int? limit}) async {
    return _select('1 = 1', const [], limit: limit);
  }

  /// Entries the server permanently rejected. They stay queued (and visible)
  /// until [retryParked] or [cancel].
  Future<List<TransactionOutboxEntry>> parked() async {
    return _select('parked = 1', const []);
  }

  /// Puts a parked entry back in the queue, due now, with a fresh attempt
  /// count. Returns false when no parked entry has [id].
  Future<bool> retryParked(int id) async {
    _appDb.db.execute(
      'UPDATE transaction_outbox_entries '
      'SET parked = 0, attempts = 0, next_attempt_at = 0, last_error = NULL '
      'WHERE namespace = ? AND id = ? AND parked = 1',
      [namespace, id],
    );
    return _appDb.db.updatedRows > 0;
  }

  /// Makes every entry waiting out a backoff due again. Called when the
  /// connection comes back: the delay was about a server problem that may
  /// well have passed, and offline time should not be waited out twice.
  /// Parked entries stay parked.
  Future<void> resetBackoff() async {
    _appDb.db.execute(
      'UPDATE transaction_outbox_entries SET next_attempt_at = 0 '
      'WHERE namespace = ? AND parked = 0 AND next_attempt_at > 0',
      [namespace],
    );
  }

  List<TransactionOutboxEntry> _select(
    String where,
    List<Object?> parameters, {
    int? limit,
  }) {
    final boundedLimit = limit?.clamp(1, 200);
    final limitClause = boundedLimit == null ? '' : ' LIMIT $boundedLimit';
    final rows = _appDb.db.select(
      'SELECT * FROM transaction_outbox_entries WHERE namespace=? AND $where '
      'ORDER BY parked ASC, next_attempt_at ASC, created_at ASC, id ASC'
      '$limitClause',
      [namespace, ...parameters],
    );
    return rows.map((row) {
      final nextAttemptAt = row['next_attempt_at'] as int? ?? 0;
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
        paymentMethod: row['payment_method'] as String?,
        merchantVpa: row['merchant_vpa'] as String?,
        mcc: row['mcc'] as String?,
        rail: row['rail'] as String?,
        attempts: row['attempts'] as int? ?? 0,
        nextAttemptAt: nextAttemptAt == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(nextAttemptAt),
        parked: (row['parked'] as int? ?? 0) != 0,
      );
    }).toList();
  }

  /// Attempts every entry that is due, once. A success removes the row; a
  /// failure records [TransactionOutboxEntry.lastError] and leaves it queued,
  /// never silently dropping a queued transaction. What happens next depends
  /// on [classifyQueueFailure]: a network failure changes nothing and ends the
  /// pass; a retryable server failure counts an attempt and backs off; a
  /// permanent rejection parks the row so it cannot starve newer ones.
  Future<int> flush(
    UserCardsRepository repo, {
    int maxEntries = defaultFlushBatchSize,
    Set<String> holdCardIds = const {},
  }) async {
    try {
      return await AccountRecoveryOperationGate.process.run(
        () => _flush(repo, maxEntries: maxEntries, holdCardIds: holdCardIds),
      );
    } on AccountRecoveryBusy {
      return 0;
    }
  }

  Future<int> _flush(
    UserCardsRepository repo, {
    required int maxEntries,
    required Set<String> holdCardIds,
  }) async {
    var sent = 0;
    // An entry naming a card whose queued add has not reached the server yet
    // is held back: sent now it would be answered 404 and parked for good
    // (WP-Q1). It goes once the add succeeded (its card id is remapped then).
    final due = holdCardIds.isEmpty
        ? await pending(limit: maxEntries)
        : [
            for (final e in await pending())
              if (e.userCardId == null || !holdCardIds.contains(e.userCardId))
                e,
          ].take(maxEntries).toList();
    // H3-2: a card that is only on the phone is not on the server yet.
    final provisional = provisionalCardIds(_appDb.db, namespace);
    for (final entry in due) {
      if (ServerBackoff.process.isPaused) break; // the server asked us to wait
      final card = entry.userCardId;
      if (card != null && provisional.contains(card)) {
        if (cardAddParked(_appDb.db, namespace, card)) {
          _appDb.db.execute(
            'UPDATE transaction_outbox_entries SET last_error = ?, parked = 1 WHERE id = ?',
            [
              'The card this was added for could not be saved. Fix or remove the card, then retry.',
              entry.id,
            ],
          );
        }
        continue; // waits for the remap; no attempt counted
      }
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
          paymentMethod: entry.paymentMethod,
          merchantVpa: entry.merchantVpa,
          mcc: entry.mcc,
          rail: entry.rail,
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
            paymentMethod: entry.paymentMethod,
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
        final failure = classifyQueueFailure(e);
        _recordFailure(entry, e, failure);
        // The connection itself is down: the rest would only each wait out
        // their own timeout. Leave them for the next trigger.
        if (failure == QueueFailure.network) break;
      }
      // Let Flutter service pending input and paint work between network/DB
      // items when this is called from a lifecycle or connectivity callback.
      await Future<void>.delayed(Duration.zero); // perf-ok: bounded 20-row outbox batch
    }
    return sent;
  }

  void _recordFailure(
    TransactionOutboxEntry entry,
    Object error,
    QueueFailure failure,
  ) {
    switch (failure) {
      case QueueFailure.network:
        _appDb.db.execute(
          'UPDATE transaction_outbox_entries SET last_error = ? WHERE id = ?',
          [error.toString(), entry.id],
        );
      case QueueFailure.retryable:
        final attempts = entry.attempts + 1;
        final next = _now().add(queueBackoffJittered(attempts));
        _appDb.db.execute(
          'UPDATE transaction_outbox_entries '
          'SET last_error = ?, attempts = ?, next_attempt_at = ? WHERE id = ?',
          [error.toString(), attempts, next.millisecondsSinceEpoch, entry.id],
        );
      case QueueFailure.permanent:
        _appDb.db.execute(
          'UPDATE transaction_outbox_entries '
          'SET last_error = ?, attempts = ?, parked = 1 WHERE id = ?',
          [error.toString(), entry.attempts + 1, entry.id],
        );
    }
  }
}
