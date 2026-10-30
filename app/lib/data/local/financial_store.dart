import 'dart:async';
import 'dart:convert';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../user_cards_repository.dart';
import 'app_database.dart';
import '../local_sms_parser.dart';
import '../merchant_identity.dart';
import '../commitments_repository.dart';

/// DLT SMS sender IDs split one bank's alerts across channel variants
/// ("AD-" advertising, "AX-" activity, "VM-"/"PD-" operator packs, "-S"/"-T"
/// channel suffixes). The account identity is the *bank code*, not the
/// channel, so a real account must not show up as one row per sender ID.
/// Sender families that bill SMS use, mapped to distinctive tokens they name
/// in the registered card's display name.
const billFamilyCardTokens = <String, List<String>>{};

bool familyNamesCardDisplayName(String? family, String cardDisplayName) {
  if (family == null || family.isEmpty) return false;
  final tokens = billFamilyCardTokens[canonicalBankSender(family)];
  if (tokens == null) return false;
  final lower = cardDisplayName.toLowerCase();
  return tokens.every(lower.contains);
}

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
  'sbyono': 'sbi',
  'sbiyon': 'sbi',
  'yonosb': 'sbi',
  'sbiinb': 'sbi',
  'sbiupi': 'sbi',
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
  'sbyono': 'SBI',
  'sbiyon': 'SBI',
  'yonosb': 'SBI',
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
    repairAutoPayArtifacts(ns);
    if (entity == 'transactions') _repairProvisionalMerchantNames(ns);
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
    if (entity == 'transactions') {
      _enrichDisplayedRecipients(ns, rows, edits);
    }
    return rows;
  }

  /// Show a recipient from the original device SMS while a confirmed server
  /// row awaits the versioned replay. This changes only returned snapshots.
  void _enrichDisplayedRecipients(
    String ns,
    List<Map<String, dynamic>> rows,
    List<Map<String, Object?>> edits,
  ) {
    final editedIds = edits.map((edit) => edit['entity_id']).toSet();
    for (final row in rows) {
      try {
        if (editedIds.contains(row['id']) ||
            row['source'] != 'sms' ||
            row['status'] != 'active' ||
            !MerchantIdentity.isWeakName(row['merchant_name'] as String?)) {
          continue;
        }
        final sourceKey = row['source_key'] as String?;
        if (sourceKey == null) {
          continue;
        }
        final stored = database.db.select(
          "SELECT pending FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=? LIMIT 1",
          [ns, row['id']],
        );
        if (stored.isEmpty || stored.single['pending'] != 0) continue;
        if (database.db.select(
          'SELECT 1 FROM local_auto_resolved_history '
          'WHERE namespace=? AND source_key=? AND is_user_modified=1 LIMIT 1',
          [ns, sourceKey],
        ).isNotEmpty) continue;
        final captures = database.db.select(
          'SELECT sender, body, received_at FROM sms_captured_messages '
          'WHERE namespace=? AND id=? LIMIT 1',
          [ns, sourceKey],
        );
        if (captures.isEmpty) continue;
        final capture = captures.single;
        final receivedMs = capture['received_at'];
        final receivedAt = receivedMs is int
            ? DateTime.fromMillisecondsSinceEpoch(receivedMs)
            : DateTime.tryParse(receivedMs?.toString() ?? '');
        if (receivedAt == null) continue;
        final parsed = LocalSmsParser.parse(
          namespace: ns,
          sender: capture['sender'] as String,
          body: capture['body'] as String,
          receivedAt: receivedAt,
        );
        final proposed = parsed?.transaction;
        final name = MerchantIdentity.cleanName(proposed?.merchantName);
        if (proposed == null ||
            proposed.sourceKey != sourceKey ||
            name == null ||
            proposed.entryKind.wireValue != row['entry_kind'] ||
            proposed.amount.paise !=
                Money.fromRupees(row['amount_inr'] as num).paise) {
          continue;
        }
        row['merchant_name'] = name;
      } catch (_) {
        // A malformed historical row must not interrupt transaction reads.
      }
    }
  }

  static const _provisionalMerchantRepairPrefix = 'local-sms:';

  // Confirmed names lack reliable manual-edit provenance and must not be rewritten.
  void _repairProvisionalMerchantNames(String ns) {
    try {
      final hasCaptures = database.db
          .select(
            "SELECT 1 FROM sqlite_master WHERE type='table' "
            "AND name='sms_captured_messages'",
          )
          .isNotEmpty;
      if (!hasCaptures) return;
      _ensureLocalRepairsTable();
      final hasAutoResolution = database.db
          .select(
            "SELECT 1 FROM sqlite_master WHERE type='table' "
            "AND name='local_auto_resolved_history'",
          )
          .isNotEmpty;
      final rows = database.db.select(
        'SELECT e.id, e.payload, e.source_key, m.sender, m.body, '
        'm.received_at FROM financial_entities e '
        'JOIN sms_captured_messages m '
        'ON m.namespace=e.namespace AND m.id=e.source_key '
        "WHERE e.namespace=? AND e.entity='transactions' AND e.pending=1 "
        "AND e.id LIKE 'local-sms:%'",
        [ns],
      );
      for (final row in rows) {
        final id = row['id'] as String;
        final sourceKey = row['source_key'] as String?;
        if (sourceKey == null ||
            id != '$_provisionalMerchantRepairPrefix$sourceKey') {
          continue;
        }
        final marker = _provisionalMerchantRepairMarker(sourceKey);
        if (database.db.select(
          'SELECT 1 FROM local_repairs WHERE namespace=? AND repair_key=?',
          [ns, marker],
        ).isNotEmpty) {
          continue;
        }
        final decoded = jsonDecode(row['payload'] as String);
        if (decoded is! Map<String, dynamic>) continue;
        if (!_isEligibleWeakProvisionalMerchant(
          database,
          ns,
          id,
          sourceKey,
          decoded,
          hasAutoResolution: hasAutoResolution,
        )) {
          continue;
        }
        try {
          final receivedMs = row['received_at'];
          final receivedAt = receivedMs is int
              ? DateTime.fromMillisecondsSinceEpoch(receivedMs)
              : DateTime.tryParse(receivedMs?.toString() ?? '');
          if (receivedAt == null) continue;
          final parsed = LocalSmsParser.parse(
            namespace: ns,
            sender: row['sender'] as String,
            body: row['body'] as String,
            receivedAt: receivedAt,
          );
          final transaction = parsed?.transaction;
          final amount = decoded['amount_inr'];
          if (transaction == null ||
              amount is! num ||
              transaction.id != id ||
              transaction.sourceKey != sourceKey ||
              transaction.amount.paise != Money.fromRupees(amount).paise ||
              decoded['instrument'] != transaction.instrument.wireValue ||
              decoded['entry_kind'] != transaction.entryKind.wireValue) {
            _markProvisionalMerchantRepair(ns, marker);
            continue;
          }
          final cleaned = MerchantIdentity.cleanName(
            transaction.merchantName,
          );
          if (cleaned == null || MerchantIdentity.isWeakName(cleaned)) {
            _markProvisionalMerchantRepair(ns, marker);
            continue;
          }
          if (_updateProvisionalMerchant(
            database,
            ns,
            id,
            sourceKey,
            decoded,
            cleaned,
          )) {
            _markProvisionalMerchantRepair(ns, marker);
          }
        } catch (_) {
          // One malformed capture must not stop the rest of the pass.
        }
      }
    } catch (_) {
      // Best-effort local repair; reading must never fail because of it.
    }
  }

  static bool enrichProvisionalReceiptMerchant(
    AppDatabase database,
    String namespace,
    String transactionId,
    String merchantName,
  ) {
    try {
      final cleaned = MerchantIdentity.cleanName(merchantName);
      if (cleaned == null || MerchantIdentity.isWeakName(cleaned)) {
        return false;
      }
      final rows = database.db.select(
        'SELECT id, payload, source_key FROM financial_entities '
        "WHERE namespace=? AND entity='transactions' AND id=? AND pending=1",
        [namespace, transactionId],
      );
      if (rows.length != 1) return false;
      final row = rows.single;
      final id = row['id'] as String;
      final sourceKey = row['source_key'] as String?;
      if (sourceKey == null ||
          id != '$_provisionalMerchantRepairPrefix$sourceKey') {
        return false;
      }
      final decoded = jsonDecode(row['payload'] as String);
      if (decoded is! Map<String, dynamic>) return false;
      final hasAutoResolution = database.db
          .select(
            "SELECT 1 FROM sqlite_master WHERE type='table' "
            "AND name='local_auto_resolved_history'",
          )
          .isNotEmpty;
      if (!_isEligibleWeakProvisionalMerchant(
        database,
        namespace,
        id,
        sourceKey,
        decoded,
        hasAutoResolution: hasAutoResolution,
      )) {
        return false;
      }
      return _updateProvisionalMerchant(
        database,
        namespace,
        id,
        sourceKey,
        decoded,
        cleaned,
      );
    } catch (_) {
      return false;
    }
  }

  static bool _updateProvisionalMerchant(
    AppDatabase database,
    String ns,
    String id,
    String sourceKey,
    Map<String, dynamic> payload,
    String merchantName,
  ) {
    database.db.execute(
      "UPDATE financial_entities SET payload=? "
      "WHERE namespace=? AND entity='transactions' AND id=? "
      'AND pending=1 AND source_key=? AND payload=? '
      'AND NOT EXISTS (SELECT 1 FROM sync_pending_changes p '
      "WHERE p.namespace=? AND p.entity='transactions' AND p.entity_id=?) "
      'AND NOT EXISTS (SELECT 1 FROM financial_source_receipts r '
      'WHERE r.namespace=? AND r.source_key=?)',
      [
        jsonEncode({...payload, 'merchant_name': merchantName}),
        ns,
        id,
        sourceKey,
        jsonEncode(payload),
        ns,
        id,
        ns,
        sourceKey,
      ],
    );
    return database.db.updatedRows > 0;
  }

  static bool _isEligibleWeakProvisionalMerchant(
    AppDatabase database,
    String ns,
    String id,
    String sourceKey,
    Map<String, dynamic> payload, {
    required bool hasAutoResolution,
  }) {
    if (payload['id'] != id ||
        payload['source_key'] != sourceKey ||
        payload['source'] != 'sms' ||
        payload['status'] != 'active') {
      return false;
    }
    final currentName = payload['merchant_name'];
    if (currentName is String) {
      if (!MerchantIdentity.isWeakName(currentName)) return false;
    } else if (currentName != null) {
      return false;
    }
    if (database.db.select(
      'SELECT 1 FROM financial_source_receipts '
      'WHERE namespace=? AND source_key=? LIMIT 1',
      [ns, sourceKey],
    ).isNotEmpty) {
      return false;
    }
    if (database.db.select(
      "SELECT 1 FROM sync_pending_changes WHERE namespace=? "
      "AND entity='transactions' AND entity_id=? LIMIT 1",
      [ns, id],
    ).isNotEmpty) {
      return false;
    }
    if (hasAutoResolution &&
        database.db.select(
          'SELECT 1 FROM local_auto_resolved_history '
          'WHERE namespace=? AND source_key=? AND is_user_modified=1 LIMIT 1',
          [ns, sourceKey],
        ).isNotEmpty) {
      return false;
    }
    return true;
  }

  static String _provisionalMerchantRepairMarker(String sourceKey) =>
      'provisional_merchant_v1:${LocalSmsParser.version}:$sourceKey';

  void _markProvisionalMerchantRepair(String ns, String marker) {
    database.db.execute(
      'INSERT OR REPLACE INTO local_repairs VALUES (?, ?)',
      [ns, marker],
    );
  }

  void _ensureLocalRepairsTable() => database.db.execute('''
        CREATE TABLE IF NOT EXISTS local_repairs (
          namespace TEXT NOT NULL,
          repair_key TEXT NOT NULL,
          PRIMARY KEY(namespace, repair_key)
        );
      ''');

  static bool _isDisplayable(TransactionEntry r) =>
      r.status == 'active' ||
      (r.status == 'ignored' &&
          (r.note?.contains('[ignored: refund]') == true ||
              r.note?.contains('[ignored: reversal]') == true));

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
            .where((r) => _isDisplayable(r) && query.matches(r))
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
      "SELECT 1 FROM financial_entities WHERE namespace=? AND source_key=? AND entity='transactions' AND pending=0",
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

  void removeCardBillAssignment(String ns, String observationId) {
    database.db.execute(
      "DELETE FROM financial_entities WHERE namespace=? AND entity='bill_card_assignments' AND id=?",
      [ns, observationId],
    );
    _notify(ns, entity: 'observations');
  }

  void deleteObservation(String ns, String id) {
    database.db.execute(
      "DELETE FROM financial_entities WHERE namespace=? AND entity='sms_observations' AND id=?",
      [ns, id],
    );
    _notify(ns, entity: 'observations');
  }

  void deleteTransaction(String ns, String id) {
    database.db.execute(
      "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
      [ns, id],
    );
    _notify(ns, entity: 'transactions');
  }

  Map<String, Map<String, dynamic>> cardBillAssignments(String ns) => {
    for (final row in entities(ns, 'bill_card_assignments'))
      if (row['observation_id'] is String)
        row['observation_id'] as String: row,
  };

  /// User corrections live separately from captured SMS so re-importing a
  /// message cannot erase the chosen card or edited bill fields.
  void saveCardBillAssignment(
    String ns,
    String observationId, {
    required String? userCardId,
    required int? amountDuePaise,
    required DateTime? dueDate,
    DateTime? statementDate,
  }) {
    final body = <String, dynamic>{
      'observation_id': observationId,
      'user_card_id': userCardId,
      'amount_due_paise': amountDuePaise,
      'due_date': dueDate?.toIso8601String(),
      'statement_date': statementDate?.toIso8601String(),
    };
    _upsert(
      ns,
      'bill_card_assignments',
      observationId,
      body,
      DateTime.now().millisecondsSinceEpoch,
    );
    _notify(ns, entity: 'observations');
  }

  Map<String, ({Money balance, DateTime updatedAt})> manualBankBalances(
    String ns,
  ) {
    final rows = database.db.select(
      "SELECT id, payload FROM financial_entities WHERE namespace=? AND entity='manual_bank_balances'",
      [ns],
    );
    return {
      for (final result in rows)
        result['id'] as String: (() {
          final row =
              jsonDecode(result['payload'] as String) as Map<String, dynamic>;
          return (
            balance: Money.fromPaise(row['balance_paise'] as int),
            updatedAt: DateTime.parse(row['updated_at'] as String),
          );
        })(),
    };
  }

  void setManualBankBalance(
    String ns, {
    required String issuer,
    required String accountLast4,
    required Money balance,
  }) {
    final id = '${canonicalBankSender(issuer)}:$accountLast4';
    final now = DateTime.now();
    _upsert(ns, 'manual_bank_balances', id, {
      'id': id,
      'balance_paise': balance.paise,
      'updated_at': now.toIso8601String(),
    }, now.millisecondsSinceEpoch);
    _notify(ns, entity: 'manual_bank_balances');
  }

  void clearManualBankBalance(
    String ns, {
    required String issuer,
    required String accountLast4,
  }) {
    final id = '${canonicalBankSender(issuer)}:$accountLast4';
    database.db.execute(
      "DELETE FROM financial_entities WHERE namespace=? AND entity='manual_bank_balances' AND id=?",
      [ns, id],
    );
    if (database.db.updatedRows > 0) {
      _notify(ns, entity: 'manual_bank_balances');
    }
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
      final bankAccount =
          row['is_bank_account'] == true ||
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
      // Existing observations created before the Pay Later classifier fix can
      // still carry is_bank_account=true. Axio is a lender, so reject those
      // stale rows at the account projection boundary as well.
      final nonDepositSender = RegExp(r'axio').hasMatch(sender);
      if (account != null &&
          RegExp(r'^\d{4}$').hasMatch(account) &&
          bankAccount &&
          !upiServiceSender &&
          !nonDepositSender &&
          (!cardSuffixes.contains(account) || row['is_bank_account'] == true)) {
        final canonical = canonicalBankSender(row['sender_bank']);
        byAccount.putIfAbsent('$canonical:$account', () => []).add(row);
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

  void markInactive(String ns, String id, {String? reason}) {
    final rows = database.db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
      [ns, id],
    );
    if (rows.isEmpty) return;
    final body =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    final existingNote = body['note'] as String?;
    final cleanOldNote = existingNote
        ?.replaceFirst(
          RegExp(
            r'^\[(?:deleted|ignored(?::\s*[^ \]]+)?)\]\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    final noteTag = reason == null ? '[ignored]' : '[ignored: $reason]';
    final newNote = cleanOldNote != null && cleanOldNote.isNotEmpty
        ? '$noteTag $cleanOldNote'
        : noteTag;
    _upsert(
      ns,
      'transactions',
      id,
      {...body, 'status': 'ignored', 'note': newNote},
      DateTime.now().millisecondsSinceEpoch,
      sourceKey: body['source_key'] as String?,
    );
    _notify(ns);
  }

  void markActive(String ns, String id) {
    final rows = database.db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
      [ns, id],
    );
    if (rows.isEmpty) return;
    final body =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    final rawNote = body['note'] as String?;
    final restoredNote = rawNote
        ?.replaceFirst(
          RegExp(
            r'^\[(?:deleted|ignored(?::\s*[^ \]]+)?)\]\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    _upsert(
      ns,
      'transactions',
      id,
      {
        ...body,
        'status': 'active',
        'note': (restoredNote != null && restoredNote.isNotEmpty)
            ? restoredNote
            : null,
      },
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
    syncCardDatesFromObservations(ns);
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

  void repairAutoPayArtifacts(String ns) {
    try {
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS local_repairs (
          namespace TEXT NOT NULL,
          repair_key TEXT NOT NULL,
          PRIMARY KEY(namespace, repair_key)
        );
      ''');
      database.db.execute('''
        CREATE TABLE IF NOT EXISTS local_commitments (
          namespace TEXT NOT NULL,
          id TEXT NOT NULL,
          payload TEXT NOT NULL,
          PRIMARY KEY (namespace, id)
        );
      ''');
      final balanceApplied = database.db.select(
        'SELECT 1 FROM local_repairs WHERE namespace=? AND repair_key=?',
        [ns, 'bank_balance_repair_v1'],
      );
      if (balanceApplied.isEmpty) {
        _repairHistoricalBalanceObservations(ns);
        database.db.execute(
          'INSERT OR REPLACE INTO local_repairs VALUES (?, ?)',
          [ns, 'bank_balance_repair_v1'],
        );
      }
      final applied = database.db.select(
        'SELECT 1 FROM local_repairs WHERE namespace=? AND repair_key=?',
        [ns, 'bill_and_autopay_repair_v6'],
      );
      if (applied.isNotEmpty) return;

      var changed = false;
      final messages = database.db.select(
        'SELECT id, sender, body, received_at FROM sms_captured_messages WHERE namespace=?',
        [ns],
      );
      for (final msg in messages) {
        final sourceKey = msg['id'] as String;
        final sender = msg['sender'] as String;
        final body = msg['body'] as String;
        final receivedAtMs = msg['received_at'];
        final receivedAt = receivedAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(receivedAtMs)
            : DateTime.tryParse(receivedAtMs.toString());
        if (receivedAt == null) continue;

        final isCandidate = RegExp(
          r'\b(?:autopay|mandate|standing\s+instruction|sihub|e-?nach|auto[- ]?(?:deducted|debited)|will\s+be\s+(?:auto[- ]?)?(?:deducted|debited)|bill\b[\s\S]{0,100}\b(?:ready|due|generated)|statement\b[\s\S]{0,100}\b(?:ready|due|generated))\b',
          caseSensitive: false,
        ).hasMatch(body);
        if (!isCandidate) continue;

        final obs = LocalSmsParser.parse(
          namespace: ns,
          sender: sender,
          body: body,
          receivedAt: receivedAt,
        );
        if (obs == null) continue;

        final isAutopayOrMandate =
            obs.isAutopay ||
            obs.eventType == LocalSmsEventType.autopay ||
            obs.disposition == LocalSmsDisposition.localCommitment ||
            obs.reasonCodes.contains('autopay_notice') ||
            obs.reasonCodes.contains('mandate_notice');
        final isBillOrMandate =
            obs.eventType == LocalSmsEventType.bill || isAutopayOrMandate;

        if (isBillOrMandate) {
          database.db.execute(
            "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' AND source_key=? AND pending=1",
            [ns, sourceKey],
          );
          if (isAutopayOrMandate && obs.transaction == null) {
            database.db.execute(
              "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' AND source_key=?",
              [ns, sourceKey],
            );
          }

          // The repair re-parses historical captured SMS with built-in rules.
          // A freshly captured observation may have come from a newer
          // downloaded rule; never replace that decision with the fallback.
          final existingObservation = database.db.select(
            "SELECT payload FROM financial_entities WHERE namespace=? AND entity='sms_observations' AND id=?",
            [ns, sourceKey],
          );
          final existingPayload = existingObservation.isEmpty
              ? null
              : jsonDecode(existingObservation.single['payload'] as String);
          final currentParserVersion = existingPayload is Map
              ? existingPayload['parser_version']
              : null;
          if (currentParserVersion is! num ||
              currentParserVersion < LocalSmsParser.version) {
            saveObservation(ns, sourceKey, {
              'id': sourceKey,
              'sender_bank': sender
                  .toUpperCase()
                  .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
                  .replaceFirst(RegExp(r'-[A-Z]$'), ''),
              'parser_version': LocalSmsParser.version,
              'received_at': receivedAt.toUtc().toIso8601String(),
              'account_last4': obs.accountLast4,
              'is_bank_account': false,
              'card_last4': obs.cardLast4,
              'biller_name': obs.billerName,
              'cadence_hint': obs.cadenceHint,
              'balance_paise': obs.availableBalance?.paise,
              'amount_due_paise': obs.amountDue?.paise,
              'minimum_due_paise': obs.minimumDue?.paise,
              'autopay_limit_paise': obs.autopayLimit?.paise,
              'due_date': obs.dueDate?.toIso8601String(),
              'statement_date': obs.statementDate?.toIso8601String(),
              'statement_date_explicit': obs.statementDateExplicit,
              'event_type': obs.eventType.wireValue,
              'disposition': obs.disposition.wireValue,
              'reason_codes': [
                ...obs.reasonCodes,
                if (isAutopayOrMandate) 'autopay_notice',
              ],
              'confidence': obs.confidence,
              if (isAutopayOrMandate) 'is_autopay': true,
            });
          }

          if (isAutopayOrMandate &&
              obs.billerName != null &&
              obs.billerName!.trim().isNotEmpty) {
            final billerLower = obs.billerName!.toLowerCase();
            final isCardBill =
                billerLower.contains('credit card') ||
                billerLower.contains('card bill');
            if (!isCardBill) {
              final existingForBiller = database.db.select(
                "SELECT id FROM local_commitments WHERE namespace=? AND payload LIKE ?",
                [ns, '%"title":"${obs.billerName}"%'],
              );
              if (existingForBiller.isEmpty) {
                final limitOrDue =
                    (obs.autopayLimit != null && !obs.autopayLimit!.isZero)
                    ? obs.autopayLimit!
                    : (obs.amountDue != null && !obs.amountDue!.isZero
                          ? obs.amountDue!
                          : Money.zero());
                final cadence = CommitmentCadence.values.firstWhere(
                  (value) => value.name == obs.cadenceHint,
                  orElse: () =>
                      LocalSmsParser.isActionableInsuranceRenewal(body)
                      ? CommitmentCadence.oneTime
                      : CommitmentCadence.monthly,
                );
                final cat = CommitmentCategory.fromText(obs.billerName!);
                final category = cat == CommitmentCategory.other
                    ? CommitmentCategory.subscription
                    : cat;
                final c = Commitment(
                  id: 'commitment:$sourceKey',
                  title: obs.billerName!,
                  category: category,
                  amount: limitOrDue,
                  dueOn: obs.dueDate ?? receivedAt,
                  cadence: cadence,
                  anchorDay: (obs.dueDate ?? receivedAt).day,
                  status: CommitmentStatus.due,
                  source: CommitmentSource.sms,
                  confidence: 1.0,
                );
                database.db.execute(
                  'INSERT OR REPLACE INTO local_commitments (namespace, id, payload) VALUES (?, ?, ?)',
                  [ns, c.id, jsonEncode(c.toJson())],
                );
              }
            }
          }

          changed = true;
        }
      }

      final genericCommitments = database.db.select(
        "SELECT id, payload FROM local_commitments WHERE namespace=? AND payload LIKE '%Subscription / Mandate%'",
        [ns],
      );
      for (final g in genericCommitments) {
        final gid = g['id'] as String;
        final rawSourceKey = gid.startsWith('commitment:')
            ? gid.substring(11)
            : gid;
        final msgRow = database.db.select(
          'SELECT sender, body, received_at FROM sms_captured_messages WHERE namespace=? AND id=?',
          [ns, rawSourceKey],
        );
        if (msgRow.isNotEmpty) {
          final s = msgRow.first['sender'] as String;
          final b = msgRow.first['body'] as String;
          final rAt = msgRow.first['received_at'];
          final dt = rAt is int
              ? DateTime.fromMillisecondsSinceEpoch(rAt)
              : DateTime.tryParse(rAt.toString());
          if (dt != null) {
            final reParsed = LocalSmsParser.parse(
              namespace: ns,
              sender: s,
              body: b,
              receivedAt: dt,
            );
            if (reParsed?.billerName != null &&
                reParsed!.billerName!.trim().isNotEmpty) {
              final cat = CommitmentCategory.fromText(reParsed.billerName!);
              final payload =
                  jsonDecode(g['payload'] as String) as Map<String, dynamic>;
              payload['title'] = reParsed.billerName!;
              payload['category'] =
                  (cat == CommitmentCategory.other
                          ? CommitmentCategory.subscription
                          : cat)
                      .name;
              if (payload['amount_paise'] == 0 &&
                  reParsed.autopayLimit != null) {
                payload['amount_paise'] = reParsed.autopayLimit!.paise;
              }
              database.db.execute(
                'UPDATE local_commitments SET payload=? WHERE namespace=? AND id=?',
                [jsonEncode(payload), ns, gid],
              );
              changed = true;
            }
          }
        }
      }

      // Use the same matching, date-evidence and user-source safeguards as a
      // wallet refresh instead of patching every card sharing a suffix here.
      syncCardDatesFromObservations(ns);
      database.db.execute(
        'INSERT OR REPLACE INTO local_repairs VALUES (?, ?)',
        [ns, 'bill_and_autopay_repair_v6'],
      );
      if (changed) {
        _notify(ns, entity: 'cards');
        _notify(ns, entity: 'observations');
        _notify(ns, entity: 'transactions');
        _notify(ns, entity: 'commitments');
      }
    } catch (_) {
      // Best-effort local repair
    }
  }

  /// Historical captures from before the balance-observing pipeline kept only
  /// transaction receipts, so their bank-account balances were never stored.
  /// Re-parse each bank-shaped capture once and mint the missing observation.
  /// Transactions are left untouched; only the observation layer is backfilled.
  /// Bump `bank_balance_repair_v1` in repairAutoPayArtifacts when the parser
  /// version jumps so older installs re-derive their balances.
  void _repairHistoricalBalanceObservations(String ns) {
    final messages = database.db.select(
      'SELECT id, sender, body, received_at FROM sms_captured_messages WHERE namespace=?',
      [ns],
    );
    for (final msg in messages) {
      final sourceKey = msg['id'] as String;
      final sender = msg['sender'] as String;
      final body = msg['body'] as String;
      final receivedAtMs = msg['received_at'];
      final receivedAt = receivedAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(receivedAtMs)
          : DateTime.tryParse(receivedAtMs.toString());
      if (receivedAt == null) continue;
      if (!LocalSmsParser.isBankAccountMessage(body, sender)) continue;
      final existingObservation = database.db.select(
        "SELECT payload FROM financial_entities WHERE namespace=? AND entity='sms_observations' AND id=?",
        [ns, sourceKey],
      );
      final existingPayload = existingObservation.isEmpty
          ? null
          : jsonDecode(existingObservation.single['payload'] as String);
      final currentParserVersion = existingPayload is Map
          ? existingPayload['parser_version']
          : null;
      // Same policy as the bill branch: a freshly captured observation may
      // have come from a newer downloaded rule; never replace that decision
      // with the fallback.
      if (currentParserVersion is num &&
          currentParserVersion >= LocalSmsParser.version) {
        continue;
      }
      final obs = LocalSmsParser.parse(
        namespace: ns,
        sender: sender,
        body: body,
        receivedAt: receivedAt,
      );
      // Without a last-4 the balance cannot be grouped into an account row.
      if (obs == null ||
          obs.availableBalance == null ||
          obs.accountLast4 == null) {
        continue;
      }
      saveObservation(ns, sourceKey, {
        'id': sourceKey,
        'sender_bank': sender
            .toUpperCase()
            .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
            .replaceFirst(RegExp(r'-[A-Z]$'), ''),
        'parser_version': LocalSmsParser.version,
        'received_at': receivedAt.toUtc().toIso8601String(),
        'account_last4': obs.accountLast4,
        'is_bank_account': true,
        'card_last4': obs.cardLast4,
        'biller_name': obs.billerName,
        'cadence_hint': obs.cadenceHint,
        'balance_paise': obs.availableBalance!.paise,
        'amount_due_paise': obs.amountDue?.paise,
        'minimum_due_paise': obs.minimumDue?.paise,
        'autopay_limit_paise': obs.autopayLimit?.paise,
        'due_date': obs.dueDate?.toIso8601String(),
        'statement_date': obs.statementDate?.toIso8601String(),
        'statement_date_explicit': obs.statementDateExplicit,
        'event_type': obs.eventType.wireValue,
        'disposition': obs.disposition.wireValue,
        'reason_codes': [...obs.reasonCodes],
        'confidence': obs.confidence,
      });
    }
  }

  /// Bank credit alerts that older parser builds could only label with the
  /// generic 'Money received' fallback although they are EMI/loan
  /// repayments ("... credited with Rs.X towards the payment of EMI ...").
  /// The raw SMS bodies persist locally in sms_captured_messages; the caller
  /// replays the (few) matches once through the normal idempotent batch
  /// import so the updated server parser re-classes them and refreshes the
  /// stored merchant label. Filter mirrors the parser's loan-repayment
  /// credit branch, both word orders.
  List<Map<String, Object?>> emiRepaymentReplayCandidates(String ns) {
    final creditMarker = RegExp(
      r'\b(?:credited|received|deposited)\b',
      caseSensitive: false,
    );
    final keywordFirst = RegExp(
      r'\b(?:loan|emi|equated\s+monthly\s+installment|instalment)\b[\s\S]{0,90}\b(?:paid|payment|repaid|repayment)\b',
      caseSensitive: false,
    );
    final paymentFirst = RegExp(
      r'\b(?:payment|repayment|repaid)\b[\s\S]{0,60}\b(?:of|towards?|for)\b[\s\S]{0,20}\b(?:the\s+)?(?:loan|emi|equated\s+monthly\s+installment|instalment)\b',
      caseSensitive: false,
    );
    final rows = <Map<String, Object?>>[];
    try {
      final messages = database.db.select(
        'SELECT sender, body, received_at FROM sms_captured_messages WHERE namespace=?',
        [ns],
      );
      for (final msg in messages) {
        final body = msg['body'] as String;
        if (!creditMarker.hasMatch(body)) continue;
        if (!keywordFirst.hasMatch(body) && !paymentFirst.hasMatch(body)) {
          continue;
        }
        final receivedMs = msg['received_at'];
        final receivedAt = receivedMs is int
            ? DateTime.fromMillisecondsSinceEpoch(receivedMs)
            : DateTime.tryParse(receivedMs?.toString() ?? '');
        if (receivedAt == null) continue;
        rows.add({
          'sender': msg['sender'] as String,
          'body': body,
          'occurredAt': receivedAt,
        });
      }
    } catch (_) {
      // The captures table may not exist on fresh installs; a missing
      // replay must never block startup.
    }
    return rows;
  }

  /// Re-import only captured SMS whose confirmed transaction still lacks a
  /// useful recipient. Source-key identity makes this replay idempotent.
  List<Map<String, Object?>> recipientReplayCandidates(String ns) {
    final result = <Map<String, Object?>>[];
    final rows = database.db.select(
      'SELECT e.payload, e.source_key, m.sender, m.body, m.received_at '
      'FROM financial_entities e JOIN sms_captured_messages m '
      'ON m.namespace=e.namespace AND m.id=e.source_key '
      "WHERE e.namespace=? AND e.entity='transactions' AND e.pending=0",
      [ns],
    );
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload'] as String);
        if (payload is! Map<String, dynamic> ||
            payload['source'] != 'sms' ||
            payload['status'] != 'active' ||
            !MerchantIdentity.isWeakName(payload['merchant_name'] as String?)) {
          continue;
        }
        final receivedMs = row['received_at'];
        final receivedAt = receivedMs is int
            ? DateTime.fromMillisecondsSinceEpoch(receivedMs)
            : DateTime.tryParse(receivedMs?.toString() ?? '');
        if (receivedAt == null) continue;
        final parsed = LocalSmsParser.parse(
          namespace: ns,
          sender: row['sender'] as String,
          body: row['body'] as String,
          receivedAt: receivedAt,
        );
        final parsedTransaction = parsed?.transaction;
        if (parsedTransaction == null ||
            parsedTransaction.sourceKey != row['source_key'] ||
            MerchantIdentity.cleanName(parsedTransaction.merchantName) == null ||
            parsedTransaction.amount.paise !=
                Money.fromRupees(payload['amount_inr'] as num).paise) {
          continue;
        }
        result.add({
          'sender': row['sender'] as String,
          'body': row['body'] as String,
          'occurredAt': receivedAt,
        });
      } catch (_) {
        // A malformed historical capture must not block the remaining rows.
      }
    }
    return result;
  }

  void syncCardDatesFromObservations(String ns) {
    try {
      final cardRows = database.db.select(
        "SELECT id, payload FROM financial_entities WHERE namespace=? AND entity='cards'",
        [ns],
      );
      if (cardRows.isEmpty) return;
      final eligibleCards = cardRows
          .map(
            (row) =>
                jsonDecode(row['payload'] as String) as Map<String, dynamic>,
          )
          .where(
            (card) =>
                card['is_archived'] != true && card['card_type'] != 'debit',
          )
          .toList();
      final obsRows = database.db.select(
        "SELECT payload FROM financial_entities WHERE namespace=? AND entity='sms_observations'",
        [ns],
      );
      var changed = false;
      for (final card in eligibleCards) {
        final currentDueDay = card['due_day'] as int?;
        final currentStmtDay = card['statement_day'] as int?;

        final cardLast4 = card['last4'] as String?;
        final cardName = (card['card_name'] as String? ?? '').toLowerCase();

        final matchingBills = <Map<String, dynamic>>[];
        for (final obsRow in obsRows) {
          final obs =
              jsonDecode(obsRow['payload'] as String) as Map<String, dynamic>;
          if (obs['event_type'] != 'bill') continue;

          final obsLast4 = obs['card_last4'] as String?;
          final sender = (obs['sender_bank'] as String? ?? '').toLowerCase();
          final biller = (obs['biller_name'] as String? ?? '').toLowerCase();

          final matchesLast4 = obsLast4 != null && obsLast4 == cardLast4;
          final matchesFamily =
              obsLast4 == null &&
              (familyNamesCardDisplayName(sender, cardName) ||
                  familyNamesCardDisplayName(biller, cardName));

          if (!matchesLast4 && !matchesFamily) continue;
          final matches = eligibleCards.where((candidate) {
            if (obsLast4 != null) {
              return candidate['last4'] == obsLast4;
            }
            final name = (candidate['card_name'] as String? ?? '')
                .toLowerCase();
            return familyNamesCardDisplayName(sender, name) ||
                familyNamesCardDisplayName(biller, name);
          });
          if (matches.length != 1) continue;
          matchingBills.add(obs);
        }

        if (matchingBills.isEmpty) continue;

        matchingBills.sort((a, b) {
          final aDate =
              (a['received_at'] ?? a['statement_date'] ?? '') as String;
          final bDate =
              (b['received_at'] ?? b['statement_date'] ?? '') as String;
          return bDate.compareTo(aDate);
        });

        int? newDueDay;
        int? newStmtDay;
        for (final obs in matchingBills) {
          final isExplicit = obs['statement_date_explicit'] == true;
          final isAutopay =
              obs['is_autopay'] == true ||
              (obs['reason_codes'] as List?)?.any(
                    (reason) =>
                        reason == 'autopay_notice' ||
                        reason == 'mandate_notice',
                  ) ==
                  true;
          final hasStatementAlert = obs['statement_date'] != null;
          // Only trust dates attached to a statement generation notice, an explicit
          // statement date, or an established AutoPay schedule. A mere payment reminder
          // carries no statement date and must not claim recurring card-cycle days.
          if (!hasStatementAlert && !isExplicit && !isAutopay) continue;
          if (newDueDay == null && obs['due_date'] != null) {
            final dt = DateTime.tryParse(obs['due_date'] as String);
            if (dt != null) newDueDay = dt.day;
          }
          if (newStmtDay == null &&
              obs['statement_date'] != null &&
              (!isAutopay || isExplicit)) {
            final dt = DateTime.tryParse(obs['statement_date'] as String);
            if (dt != null) newStmtDay = dt.day;
          }
          if (newDueDay != null && newStmtDay != null) break;
        }

        final patch = <String, dynamic>{};
        if (newDueDay != null &&
            newDueDay != currentDueDay &&
            card['due_day_source'] != 'user' &&
            (currentDueDay == null || card['due_day_source'] == 'sms')) {
          patch['due_day'] = newDueDay;
          patch['due_day_source'] = 'sms';
        }
        if (newStmtDay != null &&
            newStmtDay != currentStmtDay &&
            card['statement_day_source'] != 'user' &&
            (currentStmtDay == null || card['statement_day_source'] == 'sms')) {
          patch['statement_day'] = newStmtDay;
          patch['statement_day_source'] = 'sms';
        }
        if (patch.isNotEmpty) {
          patchCard(ns, card['id'] as String, patch);
          changed = true;
        }
      }
      if (changed) {
        _notify(ns, entity: 'cards');
      }
    } catch (_) {
      // Best-effort local heal
    }
  }

  /// Import old snapshots once, oldest first. Only the canonical unfiltered
  /// endpoint establishes full coverage; visiting a report does not.
  void migrateLegacy(String ns) {
    repairAutoPayArtifacts(ns);
    syncCardDatesFromObservations(ns);
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
