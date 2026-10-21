import 'dart:async';
import 'dart:convert';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../user_cards_repository.dart';
import 'app_database.dart';

/// DLT SMS sender IDs split one bank's alerts across channel variants
/// ("AD-" advertising, "AX-" activity, "VM-"/"PD-" operator packs, "-S"/"-T"
/// channel suffixes). The account identity is the *bank code*, not the
/// channel, so a real account must not show up as one row per sender ID.
String canonicalBankSender(Object? sender) {
  var text = (sender ?? '').toString().trim().toLowerCase();
  if (text.isEmpty) return 'unknown';
  text = text.replaceFirst(RegExp(r'^[a-z0-9]{2}-'), '');
  while (text.contains('-') && RegExp(r'-[a-z]$').hasMatch(text)) {
    text = text.replaceFirst(RegExp(r'-[a-z]$'), '');
  }
  text = text.replaceAll('-', '');
  if (text.isEmpty) return 'unknown';
  final alias = _bankTokenAliases[text];
  if (alias != null) return alias;
  for (final prefix in _bankCodePrefixes) {
    if (text.startsWith(prefix)) return prefix;
  }
  return text;
}

/// Sender tokens that collapse to a shorter canonical bank code.
const _bankTokenAliases = <String, String>{
  'canbnk': 'canara',
  'canbk': 'canara',
  'hdfcbk': 'hdfc',
  'kotakb': 'kotak',
  'icicib': 'icici',
  'unionb': 'union',
  'sbibnk': 'sbi',
  'sbibk': 'sbi',
  'axisbnk': 'axis',
  'axisb': 'axis',
  'idbibk': 'idbi',
  'yesbnk': 'yes',
  'yesbank': 'yes',
  'ucob': 'uco',
  'eqt': 'equitas',
  'pytm': 'paytm',
};

/// Longest-prefix matches for sender tokens that *start with* the bank name.
const _bankCodePrefixes = [
  'canara',
  'hdfc',
  'kotak',
  'icici',
  'union',
  'sbi',
  'axis',
  'equitas',
  'aubank',
  'indus',
  'idbi',
  'federal',
  'paytm',
  'citi',
  'hsbc',
  'dbs',
  'scb',
  'rbl',
  'uco',
  'bob',
  'boi',
  'pnb',
  'yes',
];

/// Human label per canonical bank code; unknown codes render capitalized.
const _bankDisplayLabels = <String, String>{
  'sbi': 'SBI',
  'hdfc': 'HDFC Bank',
  'icici': 'ICICI Bank',
  'axis': 'Axis Bank',
  'canara': 'Canara Bank',
  'kotak': 'Kotak Bank',
  'union': 'Union Bank',
  'pnb': 'Punjab National Bank',
  'bob': 'Bank of Baroda',
  'boi': 'Bank of India',
  'rbl': 'RBL Bank',
  'yes': 'Yes Bank',
  'idbi': 'IDBI Bank',
  'indus': 'IndusInd Bank',
  'aubank': 'AU Small Finance Bank',
  'equitas': 'Equitas Bank',
  'federal': 'Federal Bank',
  'paytm': 'Paytm Bank',
  'citi': 'Citi Bank',
  'hsbc': 'HSBC Bank',
  'dbs': 'DBS Bank',
  'scb': 'Standard Chartered',
  'uco': 'UCO Bank',
  'eqt': 'Equitas Bank',
};

String bankDisplayLabel(String canonicalCode) =>
    _bankDisplayLabels[canonicalCode] ?? canonicalCode.toUpperCase();

/// One query contract for online fetches, local reads and coverage tracking.
class TransactionQuery {
  final DateTime? from, to;
  final String? cardId, categoryId, userCategoryId, source, query;
  const TransactionQuery({
    this.from,
    this.to,
    this.cardId,
    this.categoryId,
    this.userCategoryId,
    this.source,
    this.query,
  });

  bool get unfiltered =>
      from == null &&
      to == null &&
      cardId == null &&
      categoryId == null &&
      userCategoryId == null &&
      source == null &&
      (query?.trim().isEmpty ?? true);
  String get key => jsonEncode([
    from?.toIso8601String(),
    to?.toIso8601String(),
    cardId,
    categoryId,
    userCategoryId,
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
      userCategoryId: parts.length > 6 ? parts[4] as String? : null,
      source: parts.length > 6 ? parts[5] as String? : parts[4] as String?,
      query: parts.length > 6 ? parts[6] as String? : parts[5] as String?,
    );
  }
  bool covers(TransactionQuery other) =>
      (from == null || other.from != null && !from!.isAfter(other.from!)) &&
      (to == null || other.to != null && !to!.isBefore(other.to!)) &&
      (cardId == null || cardId == other.cardId) &&
      (categoryId == null || categoryId == other.categoryId) &&
      (userCategoryId == null || userCategoryId == other.userCategoryId) &&
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
    if (categoryId != null &&
        row.categoryId != categoryId &&
        row.parentCategoryId != categoryId) {
      return false;
    }
    if (userCategoryId != null &&
        row.userCategoryId != userCategoryId &&
        row.parentUserCategoryId != userCategoryId) {
      return false;
    }
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
    onEntityChanged?.call(FinancialChange(ns, entity));
    onChanged?.call(ns);
    if (!_statusChanges.isClosed) _statusChanges.add(ns);
  }

  void notifyPendingChange(String ns) => _notify(ns, entity: 'all');
  void notifyExternalChanges(String ns, Iterable<String> entities) {
    for (final entity in entities.toSet()) {
      _notify(ns, entity: entity);
    }
  }

  bool hasPendingTransactions(String ns) => database.db.select(
    "SELECT 1 FROM financial_entities WHERE namespace=? AND entity='transactions' AND pending=1 LIMIT 1",
    [ns],
  ).isNotEmpty;

  final void Function(String namespace)? onChanged;
  final void Function(FinancialChange change)? onEntityChanged;
  FinancialStore(this.database, {this.onChanged, this.onEntityChanged}) {
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
      CREATE INDEX IF NOT EXISTS financial_observed_at
        ON financial_entities(namespace, entity, observed_at);
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

  bool _upsert(
    String ns,
    String entity,
    String id,
    Map<String, dynamic> body,
    int at, {
    bool pending = false,
    String? sourceKey,
  }) {
    final payload = jsonEncode(body);
    final previous = database.db.select(
      'SELECT payload, observed_at, pending FROM financial_entities WHERE namespace=? AND entity=? AND id=?',
      [ns, entity, id],
    );
    final changed =
        previous.isEmpty ||
        (at >= (previous.single['observed_at'] as int) &&
            (previous.single['payload'] != payload ||
                previous.single['pending'] != (pending ? 1 : 0)));
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
        payload,
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
    return changed;
  }

  List<Map<String, dynamic>> entities(
    String ns,
    String entity, {
    TransactionQuery? query,
    String? id,
  }) {
    final args = <Object?>[ns, entity];
    var range = '';
    if (id != null) {
      range = ' AND id=?';
      args.add(id);
    }
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
      range +=
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
      'SELECT entity_id, op, payload_json FROM sync_pending_changes WHERE namespace=? AND entity=?${id == null ? '' : ' AND entity_id=?'} ORDER BY client_seq',
      [ns, entity == 'cards' ? 'user_cards' : entity, ?id],
    );
    final indexes = <Object?, int>{
      for (var index = 0; index < rows.length; index++)
        rows[index]['id']: index,
    };
    for (final edit in edits) {
      final index = indexes[edit['entity_id']];
      if (index == null) continue;
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
    final stored =
        database.db.select(
              "SELECT MAX(observed_at) AS latest FROM financial_entities WHERE namespace=? AND entity='transactions'",
              [ns],
            ).single['latest']
            as int?;
    if (stored == null && coverage.isEmpty) return null;
    final rows =
        entities(ns, 'transactions', query: query)
            .map(TransactionEntry.fromJson)
            .where((r) => r.status == 'active' && query.matches(r))
            .toList()
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final latest = coverage.isNotEmpty
        ? coverage.first['fetched_at'] as int
        : stored!;
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
    var changed = false;
    final timestamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    _transaction(() {
      if (completeQuery != null) {
        final ids = rows.map((r) => r.id).toSet();
        final existing = database.db.select(
          "SELECT id, payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND pending=0 AND observed_at <= ? AND NOT EXISTS (SELECT 1 FROM sync_pending_changes p WHERE p.namespace=financial_entities.namespace AND p.entity='transactions' AND p.entity_id=financial_entities.id)",
          [ns, timestamp],
        );
        for (final old in existing) {
          // Most complete refreshes return the same IDs. Decode only absent
          // rows whose query membership must be checked before deletion.
          if (ids.contains(old['id'])) continue;
          final row = TransactionEntry.fromJson(
            jsonDecode(old['payload'] as String) as Map<String, dynamic>,
          );
          if (!ids.contains(row.id) && completeQuery.matches(row)) {
            if (row.sourceKey != null) _receipt(ns, row.sourceKey!, row.id);
            database.db.execute(
              "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
              [ns, row.id],
            );
            changed = database.db.updatedRows > 0 || changed;
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
          changed = database.db.updatedRows > 0 || changed;
        }
        final rowChanged = _upsert(
          ns,
          'transactions',
          row.id,
          row.toJson(),
          timestamp,
          sourceKey: row.sourceKey,
        );
        changed = rowChanged || changed;
      }
    });
    if (changed) _notify(ns);
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
    final cardSuffixes = <String>{
      for (final row in observations)
        if (row['card_last4'] is String) row['card_last4'] as String,
    };
    final byAccount = <String, List<Map<String, dynamic>>>{};
    for (final row in observations) {
      final account = row['account_last4'] as String?;
      final sender = (row['sender_bank'] as String? ?? '').toLowerCase();
      // New captures carry an explicit classification. For pre-upgrade rows
      // there is no raw SMS left to inspect, so exclude the known non-bank
      // sender families and require a bank-like sender before re-surfacing a
      // legacy row. This keeps unknown investment/wallet senders out.
      final legacyBankSender = RegExp(
        r'(?:bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)',
      ).hasMatch(sender);
      final bankAccount = row['is_bank_account'] == true ||
          (row['is_bank_account'] == null &&
              legacyBankSender &&
              !RegExp(
                r'(lic|licind|dhan|dhanhq|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel|paytm\s*money)',
              ).hasMatch(sender));
      // UPI-platform senders (SBIUPI & friends) quote the counterparty's
      // masked account, never the user's — they must not mint account rows.
      // ponytail: gate here; full parser-side family fix when a corpus shows
      // more UPI-tagged senders.
      final upiServiceSender = RegExp(r'upi').hasMatch(sender);
      if (account != null &&
          RegExp(r'^\d{4}$').hasMatch(account) &&
          bankAccount &&
          !upiServiceSender &&
          !cardSuffixes.contains(account)) {
        final canonical = canonicalBankSender(row['sender_bank']);
        byAccount
            .putIfAbsent('$canonical:$account', () => [])
            .add(row);
      }
    }
    DateTime? latestBalanceAt(List<Map<String, dynamic>> rows) {
      for (final row in rows) {
        if (row['balance_paise'] != null) {
          return DateTime.parse(row['received_at'] as String);
        }
      }
      return null;
    }
    return [
      for (final entry in byAccount.entries)
        BankAccountSummary(
          accountLast4: entry.value.first['account_last4'] as String,
          issuerSlug: canonicalBankSender(entry.value.first['sender_bank']),
          issuerShortName: bankDisplayLabel(
            canonicalBankSender(entry.value.first['sender_bank']),
          ),
          availableBalance:
              entry.value.where((o) => o['balance_paise'] != null).isEmpty
              ? null
              : Money.fromPaise(
                  entry.value.firstWhere(
                        (o) => o['balance_paise'] != null,
                      )['balance_paise']
                      as int,
                ),
          latestBalanceSmsAt: latestBalanceAt(entry.value),
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
    if (database.db.updatedRows > 0) _notify(ns);
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

  /// Applies a small optimistic card mutation to the durable display
  /// snapshot. Card writes can succeed (or be queued offline) before the
  /// next full wallet refresh; keeping this snapshot current prevents the
  /// cache-first wallet from immediately resurrecting the old card state.
  void patchCard(
    String ns,
    String cardId,
    Map<String, dynamic> patch, {
    DateTime? at,
  }) {
    if (patch.isEmpty) return;
    final rows = database.db.select(
      "SELECT payload, observed_at FROM financial_entities "
      "WHERE namespace=? AND entity='cards' AND id=?",
      [ns, cardId],
    );
    if (rows.isEmpty) return;
    final body =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    final observedAt = rows.single['observed_at'] as int;
    final requestedAt = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final timestamp = requestedAt > observedAt ? requestedAt : observedAt + 1;
    final changed = _upsert(ns, 'cards', cardId, {
      ...body,
      ...patch,
    }, timestamp);
    if (changed) _notify(ns, entity: 'cards');
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
