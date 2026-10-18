import 'dart:async';
import 'dart:convert';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../user_cards_repository.dart';
import 'app_database.dart';

/// One query contract for online fetches, local reads and coverage tracking.
class TransactionQuery {
  final DateTime? from, to;
  final String? cardId, categoryId, source, query;
  const TransactionQuery({
    this.from,
    this.to,
    this.cardId,
    this.categoryId,
    this.source,
    this.query,
  });

  bool get unfiltered =>
      from == null &&
      to == null &&
      cardId == null &&
      categoryId == null &&
      source == null &&
      (query?.trim().isEmpty ?? true);
  String get key => jsonEncode([
    from?.toIso8601String(),
    to?.toIso8601String(),
    cardId,
    categoryId,
    source,
    query == null || query!.trim().isEmpty ? null : query!.trim().toLowerCase(),
  ]);
  factory TransactionQuery.fromKey(String key) {
    final parts = jsonDecode(key) as List;
    return TransactionQuery(
      from: parts[0] == null ? null : DateTime.parse(parts[0] as String),
      to: parts[1] == null ? null : DateTime.parse(parts[1] as String),
      cardId: parts[2] as String?,
      categoryId: parts[3] as String?,
      source: parts[4] as String?,
      query: parts[5] as String?,
    );
  }
  bool covers(TransactionQuery other) =>
      (from == null || other.from != null && !from!.isAfter(other.from!)) &&
      (to == null || other.to != null && !to!.isBefore(other.to!)) &&
      (cardId == null || cardId == other.cardId) &&
      (categoryId == null || categoryId == other.categoryId) &&
      (source == null || source == other.source) &&
      ((query?.trim().isEmpty ?? true) ||
          query!.trim().toLowerCase() == other.query?.trim().toLowerCase());

  bool matches(TransactionEntry row) {
    if (from != null && row.occurredAt.isBefore(from!)) return false;
    if (to != null &&
        !row.occurredAt.isBefore(DateTime(to!.year, to!.month, to!.day + 1))) {
      return false;
    }
    if (cardId != null && row.userCardId != cardId) return false;
    if (categoryId != null && row.categoryId != categoryId) return false;
    if (source != null && row.source != source) return false;
    final needle = query?.trim().toLowerCase();
    return needle == null ||
        needle.isEmpty ||
        (row.merchantName ?? '').toLowerCase().contains(needle) ||
        (row.note ?? '').toLowerCase().contains(needle);
  }
}

class LocalTransactionSnapshot {
  final List<TransactionEntry> rows;
  final DateTime fetchedAt;
  final bool complete;
  const LocalTransactionSnapshot(this.rows, this.fetchedAt, this.complete);
}

class FinancialChange {
  final String namespace, entity;
  const FinancialChange(this.namespace, this.entity);
}

/// Durable account-scoped entity store. Endpoint blobs are migration inputs,
/// never competing transaction histories. A complete response replaces only
/// its query scope; provisional device records survive until acknowledged.
class FinancialStore {
  final AppDatabase database;
  final _changes = StreamController<FinancialChange>.broadcast();
  final _statusChanges = StreamController<String>.broadcast();
  final _transientStatus = <String, String>{};
  int _batchDepth = 0;
  final _batchedChanges = <(String, String)>{};
  void batch(void Function() work) {
    _batchDepth++;
    var completed = false;
    try {
      work();
      completed = true;
    } finally {
      _batchDepth--;
      if (_batchDepth == 0) {
        final changes = _batchedChanges.toList();
        _batchedChanges.clear();
        if (completed) {
          for (final change in changes) {
            _notify(change.$1, entity: change.$2);
          }
        }
      }
    }
  }

  Stream<FinancialChange> get changes => _changes.stream;
  Stream<String> get statusChanges => _statusChanges.stream;
  void dispose() {
    _changes.close();
    _statusChanges.close();
  }

  void _notify(String ns, {String entity = 'transactions'}) {
    if (_batchDepth > 0) {
      _batchedChanges.add((ns, entity));
      return;
    }
    if (!_changes.isClosed) _changes.add(FinancialChange(ns, entity));
    onChanged?.call(ns);
    if (!_statusChanges.isClosed) _statusChanges.add(ns);
  }

  void notifyPendingChange(String ns) => _notify(ns, entity: 'all');
  bool hasPendingTransactions(String ns) => database.db.select(
    "SELECT 1 FROM financial_entities WHERE namespace=? AND entity='transactions' AND pending=1 LIMIT 1",
    [ns],
  ).isNotEmpty;

  final void Function(String namespace)? onChanged;
  FinancialStore(this.database, {this.onChanged}) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS financial_entities (
        namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
        payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
        pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
        occurred_at INTEGER, amount_paise INTEGER,
        PRIMARY KEY(namespace, entity, id)
      );
      CREATE INDEX IF NOT EXISTS financial_source_identity
        ON financial_entities(namespace, source_key);
      CREATE INDEX IF NOT EXISTS financial_transaction_date
        ON financial_entities(namespace, entity, occurred_at);
      CREATE TABLE IF NOT EXISTS financial_coverage (
        namespace TEXT NOT NULL, query_key TEXT NOT NULL, fetched_at INTEGER NOT NULL,
        PRIMARY KEY(namespace, query_key)
      );
      CREATE TABLE IF NOT EXISTS financial_migrations (
        namespace TEXT PRIMARY KEY
      );
      CREATE TABLE IF NOT EXISTS financial_sync_status (
        namespace TEXT PRIMARY KEY, state TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS financial_source_receipts (
        namespace TEXT NOT NULL, source_key TEXT NOT NULL, transaction_id TEXT NOT NULL,
        PRIMARY KEY(namespace,source_key)
      );
    ''');
  }

  void _transaction(void Function() work) {
    database.db.execute('SAVEPOINT financial_write');
    try {
      work();
      database.db.execute('RELEASE SAVEPOINT financial_write');
    } catch (_) {
      database.db.execute('ROLLBACK TO SAVEPOINT financial_write');
      database.db.execute('RELEASE SAVEPOINT financial_write');
      rethrow;
    }
  }

  void _upsert(
    String ns,
    String entity,
    String id,
    Map<String, dynamic> body,
    int at, {
    bool pending = false,
    String? sourceKey,
  }) {
    database.db.execute(
      '''
      INSERT INTO financial_entities(namespace, entity, id, payload, observed_at, pending, source_key, occurred_at, amount_paise)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(namespace, entity, id) DO UPDATE SET
        payload=excluded.payload, observed_at=excluded.observed_at,
        pending=excluded.pending, source_key=excluded.source_key,
        occurred_at=excluded.occurred_at, amount_paise=excluded.amount_paise
      WHERE excluded.observed_at >= financial_entities.observed_at
    ''',
      [
        ns,
        entity,
        id,
        jsonEncode(body),
        at,
        pending ? 1 : 0,
        sourceKey,
        entity == 'transactions'
            ? DateTime.parse(
                body['occurred_at'] as String,
              ).millisecondsSinceEpoch
            : null,
        entity == 'transactions'
            ? TransactionEntry.fromJson(body).amount.paise
            : null,
      ],
    );
  }

  List<Map<String, dynamic>> entities(
    String ns,
    String entity, {
    TransactionQuery? query,
  }) {
    final args = <Object?>[ns, entity];
    var range = '';
    if (query != null && (query.from != null || query.to != null)) {
      final conditions = <String>[];
      if (query.from != null) {
        conditions.add('occurred_at>=?');
        args.add(query.from!.millisecondsSinceEpoch);
      }
      if (query.to != null) {
        conditions.add('occurred_at<?');
        args.add(
          DateTime(
            query.to!.year,
            query.to!.month,
            query.to!.day + 1,
          ).millisecondsSinceEpoch,
        );
      }
      range =
          " AND ((${conditions.join(' AND ')}) OR EXISTS (SELECT 1 FROM sync_pending_changes p WHERE p.namespace=financial_entities.namespace AND p.entity='transactions' AND p.entity_id=financial_entities.id))";
    }
    final rows = database.db
        .select(
          'SELECT payload FROM financial_entities WHERE namespace=? AND entity=?$range ORDER BY '
          r"CASE WHEN entity='cards' THEN json_extract(payload, '$._local_order') END, id",
          args,
        )
        .map((r) => jsonDecode(r['payload'] as String) as Map<String, dynamic>)
        .toList();
    final edits = database.db.select(
      'SELECT entity_id, op, payload_json FROM sync_pending_changes WHERE namespace=? AND entity=? ORDER BY client_seq',
      [ns, entity == 'cards' ? 'user_cards' : entity],
    );
    for (final edit in edits) {
      final index = rows.indexWhere((r) => r['id'] == edit['entity_id']);
      if (index < 0) continue;
      if (edit['op'] == 'delete') {
        rows[index] = {
          ...rows[index],
          if (entity == 'cards') 'is_archived': true else 'status': 'ignored',
        };
      } else {
        rows[index] = {
          ...rows[index],
          ...jsonDecode(edit['payload_json'] as String) as Map<String, dynamic>,
        };
      }
    }
    return rows;
  }

  LocalTransactionSnapshot? transactions(String ns, TransactionQuery query) {
    final coverage = database.db
        .select(
          'SELECT query_key, fetched_at FROM financial_coverage WHERE namespace=? ORDER BY fetched_at DESC',
          [ns],
        )
        .where(
          (r) =>
              TransactionQuery.fromKey(r['query_key'] as String).covers(query),
        )
        .toList();
    final stored = database.db.select(
      "SELECT payload, observed_at FROM financial_entities WHERE namespace=? AND entity='transactions'",
      [ns],
    );
    if (stored.isEmpty && coverage.isEmpty) return null;
    final rows =
        entities(ns, 'transactions', query: query)
            .map(TransactionEntry.fromJson)
            .where((r) => r.status == 'active' && query.matches(r))
            .toList()
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final latest = coverage.isNotEmpty
        ? coverage.first['fetched_at'] as int
        : stored
              .map((r) => r['observed_at'] as int)
              .reduce((a, b) => a > b ? a : b);
    return LocalTransactionSnapshot(
      rows,
      DateTime.fromMillisecondsSinceEpoch(latest),
      coverage.isNotEmpty,
    );
  }

  void saveTransactions(
    String ns,
    List<TransactionEntry> rows, {
    TransactionQuery? completeQuery,
    DateTime? at,
  }) {
    final before = jsonEncode(entities(ns, 'transactions'));
    final timestamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    _transaction(() {
      if (completeQuery != null) {
        final ids = rows.map((r) => r.id).toSet();
        final existing = database.db.select(
          "SELECT id, payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND pending=0 AND observed_at <= ? AND NOT EXISTS (SELECT 1 FROM sync_pending_changes p WHERE p.namespace=financial_entities.namespace AND p.entity='transactions' AND p.entity_id=financial_entities.id)",
          [ns, timestamp],
        );
        for (final old in existing) {
          final row = TransactionEntry.fromJson(
            jsonDecode(old['payload'] as String) as Map<String, dynamic>,
          );
          if (!ids.contains(row.id) && completeQuery.matches(row)) {
            if (row.sourceKey != null) _receipt(ns, row.sourceKey!, row.id);
            database.db.execute(
              "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
              [ns, row.id],
            );
          }
        }
        database.db.execute(
          'INSERT INTO financial_coverage VALUES (?, ?, ?) ON CONFLICT(namespace,query_key) DO UPDATE SET fetched_at=excluded.fetched_at WHERE excluded.fetched_at>=financial_coverage.fetched_at',
          [ns, completeQuery.key, timestamp],
        );
      }
      for (final row in rows) {
        if (row.sourceKey != null) {
          _receipt(ns, row.sourceKey!, row.id);
          database.db.execute(
            "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' AND source_key=? AND pending=1",
            [ns, row.sourceKey],
          );
        }
        _upsert(
          ns,
          'transactions',
          row.id,
          row.toJson(),
          timestamp,
          sourceKey: row.sourceKey,
        );
      }
    });
    if (before != jsonEncode(entities(ns, 'transactions'))) _notify(ns);
  }

  void saveProvisional(String ns, TransactionEntry row) {
    if (row.sourceKey != null && hasReceipt(ns, row.sourceKey!)) return;
    // An inbox replay must never create a provisional copy of an already
    // reconciled transaction with the same stable SMS identity.
    if (database.db.select(
      'SELECT 1 FROM financial_entities WHERE namespace=? AND source_key=?',
      [ns, row.sourceKey],
    ).isNotEmpty) {
      return;
    }
    _upsert(
      ns,
      'transactions',
      row.id,
      row.toJson(),
      DateTime.now().millisecondsSinceEpoch,
      pending: true,
      sourceKey: row.sourceKey,
    );
    _notify(ns);
  }

  void saveObservation(String ns, String id, Map<String, dynamic> body) {
    final existing = database.db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='sms_observations' AND id=?",
      [ns, id],
    );
    if (existing.isNotEmpty && existing.single['payload'] == jsonEncode(body)) {
      return;
    }
    _upsert(
      ns,
      'sms_observations',
      id,
      body,
      DateTime.now().millisecondsSinceEpoch,
    );
    _notify(ns, entity: 'observations');
  }

  List<BankAccountSummary> bankAccounts(String ns) {
    final observations = entities(ns, 'sms_observations')
      ..sort(
        (a, b) =>
            (b['received_at'] as String).compareTo(a['received_at'] as String),
      );
    final byAccount = <String, List<Map<String, dynamic>>>{};
    for (final row in observations) {
      final account = row['account_last4'] as String?;
      if (account != null) {
        byAccount
            .putIfAbsent(
              '${row['sender_bank'] ?? 'unknown'}:$account',
              () => [],
            )
            .add(row);
      }
    }
    return [
      for (final entry in byAccount.entries)
        BankAccountSummary(
          accountLast4: entry.value.first['account_last4'] as String,
          issuerSlug: entry.value.first['sender_bank'] as String?,
          issuerShortName: entry.value.first['sender_bank'] as String?,
          availableBalance:
              entry.value.where((o) => o['balance_paise'] != null).isEmpty
              ? null
              : Money.fromPaise(
                  entry.value.firstWhere(
                        (o) => o['balance_paise'] != null,
                      )['balance_paise']
                      as int,
                ),
          latestSmsAt: DateTime.parse(
            entry.value.first['received_at'] as String,
          ),
          smsCount: entry.value.length,
        ),
    ];
  }

  bool hasReceipt(String ns, String key) => database.db.select(
    'SELECT 1 FROM financial_source_receipts WHERE namespace=? AND source_key=?',
    [ns, key],
  ).isNotEmpty;
  void _receipt(String ns, String key, String id) => database.db.execute(
    'INSERT OR REPLACE INTO financial_source_receipts VALUES (?,?,?)',
    [ns, key, id],
  );
  void discardProvisional(String ns, String sourceKey, {String? confirmedId}) {
    if (confirmedId != null) _receipt(ns, sourceKey, confirmedId);
    database.db.execute(
      'DELETE FROM financial_entities WHERE namespace=? AND source_key=? AND pending=1',
      [ns, sourceKey],
    );
    _notify(ns);
  }

  void markInactive(String ns, String id) {
    final rows = database.db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
      [ns, id],
    );
    if (rows.isEmpty) return;
    final body =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    _upsert(
      ns,
      'transactions',
      id,
      {...body, 'status': 'ignored'},
      DateTime.now().millisecondsSinceEpoch,
      sourceKey: body['source_key'] as String?,
    );
    _notify(ns);
  }

  void replaceCards(
    String ns,
    List<UserCard> cards, {
    bool archived = false,
    DateTime? at,
  }) {
    final before = jsonEncode(entities(ns, 'cards'));
    final timestamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    _transaction(() {
      for (final old in entities(ns, 'cards')) {
        if ((old['is_archived'] == true) == archived) {
          database.db.execute(
            "DELETE FROM financial_entities WHERE namespace=? AND entity='cards' AND id=? AND observed_at<=?",
            [ns, old['id'], timestamp],
          );
        }
      }
      for (final (index, card) in cards.indexed) {
        _upsert(ns, 'cards', card.id, {
          ...card.toJson(),
          '_local_order': index,
        }, timestamp);
      }
    });
    if (before != jsonEncode(entities(ns, 'cards'))) {
      _notify(ns, entity: 'cards');
    }
  }

  void setSyncStatus(String ns, String state) {
    if (syncStatus(ns) == state) return;
    _transientStatus[ns] = state;
    try {
      database.db.execute(
        'INSERT OR REPLACE INTO financial_sync_status VALUES (?, ?)',
        [ns, state],
      );
    } catch (_) {
      _transientStatus[ns] = 'storage_error';
    }
    if (!_statusChanges.isClosed) _statusChanges.add(ns);
  }

  String syncStatus(String ns) {
    if (_transientStatus.containsKey(ns)) return _transientStatus[ns]!;
    try {
      final rows = database.db.select(
        'SELECT state FROM financial_sync_status WHERE namespace=?',
        [ns],
      );
      return rows.isEmpty ? 'idle' : rows.single['state'] as String;
    } catch (_) {
      return 'storage_error';
    }
  }

  /// Import old snapshots once, oldest first. Only the canonical unfiltered
  /// endpoint establishes full coverage; visiting a report does not.
  void migrateLegacy(String ns) {
    if (database.db.select(
      'SELECT 1 FROM financial_migrations WHERE namespace=?',
      [ns],
    ).isNotEmpty) {
      return;
    }
    final snapshots = database.db.select(
      "SELECT key, raw_json, fetched_at FROM cached_responses WHERE substr(key,1,length(?))=? ORDER BY fetched_at, CASE WHEN key LIKE '%:transactions:all' THEN 0 ELSE 1 END, key",
      ['$ns:', '$ns:'],
    );
    for (final snapshot in snapshots) {
      final key = (snapshot['key'] as String).substring(ns.length + 1);
      try {
        final body =
            jsonDecode(snapshot['raw_json'] as String) as Map<String, dynamic>;
        final at = DateTime.fromMillisecondsSinceEpoch(
          snapshot['fetched_at'] as int,
        );
        if ((key.startsWith('transactions:') ||
                key.startsWith('spend_detail:') ||
                key.startsWith('insights_transactions:')) &&
            body['transactions'] is List) {
          saveTransactions(
            ns,
            (body['transactions'] as List)
                .map(
                  (r) => TransactionEntry.fromJson(
                    Map<String, dynamic>.from(r as Map),
                  ),
                )
                .toList(),
            completeQuery: key == 'transactions:all'
                ? const TransactionQuery()
                : null,
            at: at,
          );
        } else if (key == 'user_cards' || key == 'user_cards_with_archived') {
          replaceCards(
            ns,
            (body['userCards'] as List)
                .map(
                  (r) => UserCard.fromJson(Map<String, dynamic>.from(r as Map)),
                )
                .toList(),
            archived: key.endsWith('_with_archived'),
            at: at,
          );
        }
      } catch (_) {
        /* One corrupt legacy snapshot cannot block migration. */
      }
    }
    database.db.execute('INSERT INTO financial_migrations VALUES (?)', [ns]);
  }

  void clear(String ns) {
    _transientStatus.remove(ns);
    _transaction(() {
      for (final table in [
        'financial_entities',
        'financial_coverage',
        'financial_migrations',
        'financial_sync_status',
        'financial_source_receipts',
      ]) {
        database.db.execute('DELETE FROM $table WHERE namespace=?', [ns]);
      }
    });
    _notify(ns, entity: 'all');
  }
}
