import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';
import 'foreign_payment.dart';
import 'foreign_money.dart';
import 'local/app_database.dart';
import 'local/local_first_schema.dart';
import 'connectivity/server_backoff.dart';
import 'local/queue_retry_policy.dart';

final _initializedForeignStores = <Object>{};
void ensureForeignPaymentsSchema(AppDatabase database) {
  if (!_initializedForeignStores.add(database.db)) return;
  database.db.execute('''
    CREATE TABLE IF NOT EXISTS foreign_payments_local (
      namespace TEXT NOT NULL, source_key TEXT NOT NULL, payload TEXT NOT NULL,
      PRIMARY KEY(namespace, source_key)
    );
    CREATE TABLE IF NOT EXISTS foreign_payments_outbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
      source_key TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
      last_error TEXT, attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT 0, parked INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS foreign_payments_pending_account
      ON foreign_payments_outbox(namespace, seq);
    CREATE TABLE IF NOT EXISTS foreign_payments_sync_state (
      namespace TEXT PRIMARY KEY, audit_cursor TEXT, audit_scanned INTEGER NOT NULL DEFAULT 0,
      audit_completed_at INTEGER, audit_summary TEXT
    );
    CREATE TABLE IF NOT EXISTS foreign_payments_source_aliases (
      namespace TEXT NOT NULL, source_key TEXT NOT NULL, canonical_source_key TEXT NOT NULL,
      PRIMARY KEY(namespace, source_key)
    );
  ''');
  // A table created by an earlier version has none of the retry columns.
  for (final column in ['attempts', 'next_attempt_at', 'parked']) {
    LocalFirstSchema.addColumnIfMissing(
      database.db,
      'foreign_payments_outbox',
      column,
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
  LocalFirstSchema.addColumnIfMissing(
    database.db,
    'foreign_payments_outbox',
    'last_error',
    'TEXT',
  );
}

/// Synchronous ingestion is used in the same SQLite savepoint as SMS capture,
/// including the background isolate. Raw body never enters this table/outbox.
bool captureLocalForeignPayment(
  AppDatabase database,
  String namespace,
  ForeignPayment payment,
) {
  ensureForeignPaymentsSchema(database);
  final db = database.db;
  if (db.select(
    'SELECT 1 FROM foreign_payments_source_aliases WHERE namespace=? AND source_key=?',
    [namespace, payment.sourceKey],
  ).isNotEmpty) {
    return false;
  }
  if (db.select(
    'SELECT 1 FROM foreign_payments_local WHERE namespace=? AND source_key=?',
    [namespace, payment.sourceKey],
  ).isNotEmpty) {
    return false;
  }
  db.execute(
    'INSERT INTO foreign_payments_local(namespace,source_key,payload) VALUES(?,?,?)',
    [namespace, payment.sourceKey, jsonEncode(payment.toJson())],
  );
  db.execute(
    'INSERT INTO foreign_payments_outbox(namespace,source_key,kind,payload) VALUES(?,?,?,?)',
    [
      namespace,
      payment.sourceKey,
      'create',
      jsonEncode(_createPayload(payment)),
    ],
  );
  return true;
}

Map<String, dynamic> _createPayload(ForeignPayment payment) => {
  'source_key': payment.sourceKey,
  'original_currency': payment.originalCurrency,
  'original_amount': payment.originalAmount,
  'occurred_at': payment.occurredAt.toUtc().toIso8601String(),
  'merchant_name': payment.merchantName,
  'card_last4': payment.cardLast4,
  'account_last4': payment.accountLast4,
  'user_card_id': payment.userCardId,
  'category_id': payment.categoryId,
  'user_category_id': payment.userCategoryId,
  'category_name': payment.categoryName,
  'direction': payment.direction,
  'instrument': payment.instrument,
  'reference': payment.reference,
  if (payment.billedInr != null && payment.confirmationSource == 'sms') ...{
    'billed_inr': moneyDecimal(payment.billedInr),
    'confirmation_source': 'sms',
    // A local ledger id (`v2:<event>`) is not a server id: the server links
    // the SMS to its transaction by source key.
    if (payment.transactionId != null &&
        _uuid.hasMatch(payment.transactionId!))
      'transaction_id': payment.transactionId,
  },
};

final _uuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  caseSensitive: false,
);

/// A later alert that states the billed INR settles an earlier alert that
/// stated only the foreign price (CCR-004). Both describe one purchase, so the
/// earlier, unvalued record is dismissed and the billed one stays: the INR
/// counts once, in the ledger, through the billed alert's own transaction.
///
/// A pair matches only on exact evidence: the same direction, currency and
/// original amount, the same card (saved card, else last four digits, else the
/// same merchant when neither names a card), both cash withdrawals or both
/// not, and within [window]. A record that
/// the user edited is left alone. A weak match, where one record could settle
/// with several, is not made. Synchronous like [captureLocalForeignPayment].
/// Returns how many records were settled.
int settleAwaitingForeignPayments(
  AppDatabase database,
  String namespace, {
  Duration window = const Duration(days: 7),
}) {
  ensureForeignPaymentsSchema(database);
  final db = database.db;
  final rows = [
    for (final r in db.select(
      'SELECT payload FROM foreign_payments_local WHERE namespace=?',
      [namespace],
    ))
      ForeignPayment.fromJson(
        jsonDecode(r['payload'] as String) as Map<String, dynamic>,
      ),
  ];
  final awaiting = [
    for (final p in rows)
      if (p.isPending &&
          p.billedInr == null &&
          !p.userModified &&
          p.originalCurrency != null &&
          p.originalAmount != null)
        p,
  ];
  final billed = [
    for (final p in rows)
      if (!p.isIgnored && p.billedInr != null && p.originalCurrency != null)
        p,
  ];
  String merchantKey(String? name) =>
      (name ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  bool sameCard(ForeignPayment a, ForeignPayment b) {
    if (a.userCardId != null && b.userCardId != null) {
      return a.userCardId == b.userCardId;
    }
    if (a.cardLast4 != null && b.cardLast4 != null) {
      return a.cardLast4 == b.cardLast4;
    }
    if (a.cardLast4 != null || b.cardLast4 != null) return false;
    final m = merchantKey(a.merchantName);
    return m.isNotEmpty && m == merchantKey(b.merchantName);
  }

  bool matches(ForeignPayment a, ForeignPayment b) =>
      a.direction == b.direction &&
      a.originalCurrency == b.originalCurrency &&
      a.originalAmount == b.originalAmount &&
      a.isCashWithdrawal == b.isCashWithdrawal &&
      a.occurredAt.difference(b.occurredAt).abs() <= window &&
      sameCard(a, b);

  final forAwaiting = {
    for (final a in awaiting) a.sourceKey: [for (final b in billed) if (matches(a, b)) b],
  };
  final forBilled = <String, int>{};
  for (final candidates in forAwaiting.values) {
    for (final b in candidates) {
      forBilled.update(b.sourceKey, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  var settled = 0;
  for (final a in awaiting) {
    final candidates = forAwaiting[a.sourceKey]!;
    if (candidates.length != 1 || forBilled[candidates.single.sourceKey] != 1) {
      continue;
    }
    final next = a.withPatch({
      'valuation_status': 'ignored',
      'locally_pending': true,
      'sync_error': null,
    });
    db.execute(
      'UPDATE foreign_payments_local SET payload=? WHERE namespace=? AND source_key=?',
      [jsonEncode(next.toJson()), namespace, a.sourceKey],
    );
    db.execute(
      'INSERT INTO foreign_payments_outbox(namespace,source_key,kind,payload) VALUES(?,?,?,?)',
      [
        namespace,
        a.sourceKey,
        'edit',
        jsonEncode({'valuation_status': 'ignored'}),
      ],
    );
    settled++;
  }
  return settled;
}

/// Offline-first, account-scoped foreign payment evidence and durable edits.
/// Only confirmed INR is submitted to the canonical ledger by the backend.
class ForeignPaymentsRepository {
  final Future<AppDatabase> database;
  final String namespace;
  final String apiBaseUrl;
  final http.Client client;
  final String? Function() accessToken;
  final bool Function() accountIsCurrent;
  final void Function()? onChanged;
  final void Function()? onLedgerChanged;
  final DateTime Function() _now;
  Future<void>? _syncFuture;
  DateTime? _lastRateRefresh;

  ForeignPaymentsRepository({
    required this.database,
    required this.namespace,
    required this.apiBaseUrl,
    required this.client,
    required this.accessToken,
    bool Function()? accountIsCurrent,
    this.onChanged,
    this.onLedgerChanged,
    DateTime Function()? now,
  }) : accountIsCurrent = accountIsCurrent ?? (() => true),
       _now = now ?? DateTime.now;

  /// Changes the service refused for good. They stay saved (the payment keeps
  /// showing its local edit) but are not retried until [retryParked].
  Future<int> parkedCount() async {
    final db = await _db();
    return db.db.select(
          'SELECT COUNT(*) AS n FROM foreign_payments_outbox WHERE namespace=? AND parked=1',
          [namespace],
        ).single['n']
        as int;
  }

  /// True when at least one queued change is ready to send now. Lets a caller
  /// that only wants to drain the outbox (the sync engine) skip [sync], which
  /// also refreshes exchange rates over the network.
  Future<bool> hasDueChanges() async {
    final db = await _db();
    return db.db.select(
      'SELECT 1 FROM foreign_payments_outbox WHERE namespace=? AND parked=0 AND next_attempt_at<=? LIMIT 1',
      [namespace, _now().millisecondsSinceEpoch],
    ).isNotEmpty;
  }

  /// Makes every change waiting out a backoff due again (the connection came
  /// back). Parked changes stay parked.
  Future<void> resetBackoff() async {
    final db = await _db();
    db.db.execute(
      'UPDATE foreign_payments_outbox SET next_attempt_at=0 '
      'WHERE namespace=? AND parked=0 AND next_attempt_at>0',
      [namespace],
    );
  }

  /// Puts every parked change back in the queue (an explicit retry).
  Future<void> retryParked() async {
    final db = await _db();
    db.db.execute(
      'UPDATE foreign_payments_outbox SET parked=0, attempts=0, next_attempt_at=0, last_error=NULL '
      'WHERE namespace=? AND parked=1',
      [namespace],
    );
  }

  Future<AppDatabase> _db() async {
    final db = await database;
    ensureForeignPaymentsSchema(db);
    return db;
  }

  Future<List<ForeignPayment>> fetchAll({bool refresh = true}) async {
    if (refresh && accessToken() != null && accountIsCurrent()) {
      try {
        await sync();
      } catch (error) {
        if (isAuthenticationFailure(error)) rethrow;
        // The durable account snapshot remains readable while offline or
        // while this coordinated backend release is still unavailable.
      }
    }
    if (!accountIsCurrent()) return const [];
    return _readAll(await _db());
  }

  List<ForeignPayment> _readAll(AppDatabase db) =>
      db.db
          .select(
            'SELECT payload FROM foreign_payments_local WHERE namespace=?',
            [namespace],
          )
          .map(
            (r) => ForeignPayment.fromJson(
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ),
          )
          .toList()
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  Future<ForeignPayment?> find(String id) async {
    final db = await _db();
    if (!accountIsCurrent()) return null;
    final key = id.startsWith('fx:') ? id.substring(3) : id;
    final aliases = db.db.select(
      'SELECT canonical_source_key FROM foreign_payments_source_aliases WHERE namespace=? AND source_key=?',
      [namespace, key],
    );
    if (aliases.isNotEmpty) {
      id = aliases.single['canonical_source_key'] as String;
    }
    final rows = _readAll(db);
    for (final row in rows) {
      if (row.id == id || 'fx:${row.sourceKey}' == id || row.sourceKey == id) {
        return row;
      }
    }
    return null;
  }

  Future<ForeignPayment?> findBySourceKey(String sourceKey) => find(sourceKey);

  Future<ForeignPayment> editOriginal(
    String id, {
    String? currency,
    String? amount,
    String? merchantName,
    String? categoryId,
    String? userCategoryId,
    String? userCardId,
  }) async {
    final current = await find(id);
    if (current == null) {
      throw StateError('This payment is no longer available.');
    }
    final code = currency?.trim().toUpperCase() ?? current.originalCurrency;
    if (code != null && !isForeignCurrency(code)) {
      throw StateError('Enter a supported foreign currency code, such as USD.');
    }
    final decimal =
        amount?.trim().replaceAll(',', '') ?? current.originalAmount;
    if (decimal != null && canonicalForeignAmount(decimal, code) == null) {
      throw StateError('Enter the positive amount printed for this purchase.');
    }
    return _mutate(
      current,
      'edit',
      {
        if (currency != null) 'original_currency': code,
        if (amount != null) 'original_amount': decimal,
        if (merchantName != null) 'merchant_name': merchantName.trim(),
        'category_id': ?categoryId,
        if (categoryId != null) 'user_category_id': null,
        'user_category_id': ?userCategoryId,
        if (userCategoryId != null) 'category_id': null,
        'user_card_id': ?userCardId,
      },
      localPatch: {
        if (!current.isConfirmed && (currency != null || amount != null)) ...{
          'valuation_status': code == null || decimal == null
              ? 'awaiting_amount'
              : 'awaiting_rate',
          'estimated_inr': null,
          'rate': null,
          'rate_date': null,
          'rate_source': null,
        },
        'user_modified': true,
      },
    );
  }

  Future<ForeignPayment> confirmBilled(
    String id, {
    required Money billedInr,
    String? transactionId,
    String? userCardId,
  }) async {
    if (billedInr.paise <= 0 || billedInr.paise > 999999999999) {
      throw StateError('Enter the positive INR amount billed by your bank.');
    }
    final current = await find(id);
    if (current == null) {
      throw StateError('This payment is no longer available.');
    }
    if (current.isConfirmed) return current;
    // Local intent is visible, but it is not confirmed until the server has
    // atomically recorded or linked the real ledger transaction.
    return _mutate(
      current,
      'confirm',
      {
        'billed_inr': moneyDecimal(billedInr),
        'confirmation_source': 'user',
        'transaction_id': ?transactionId,
        'user_card_id': ?userCardId,
      },
      localPatch: {'user_modified': true},
    );
  }

  Future<ForeignPayment> ignore(String id) async {
    final current = await find(id);
    if (current == null) {
      throw StateError('This payment is no longer available.');
    }
    if (current.isConfirmed) {
      throw StateError(
        'Use the recorded transaction to change confirmed spending.',
      );
    }
    return _mutate(
      current,
      'edit',
      {'valuation_status': 'ignored'},
      localPatch: {'user_modified': true},
    );
  }

  Future<ForeignPayment> restore(String id) async {
    final current = await find(id);
    if (current == null) {
      throw StateError('This payment is no longer available.');
    }
    return _mutate(
      current,
      'edit',
      {'valuation_status': 'awaiting_amount'},
      localPatch: {'user_modified': true},
    );
  }

  Future<ForeignPayment> retry(String id) async {
    await refresh();
    final current = await find(id);
    if (current == null) {
      throw StateError('This payment is no longer available.');
    }
    return current;
  }

  Future<ForeignPayment> _mutate(
    ForeignPayment current,
    String kind,
    Map<String, dynamic> payload, {
    Map<String, dynamic> localPatch = const {},
  }) async {
    if (!accountIsCurrent()) {
      throw StateError('Sign in again to edit this payment.');
    }
    final db = await _db();
    final edited = current.withPatch({
      ...payload,
      ...localPatch,
      'locally_pending': true,
      'sync_error': null,
    });
    db.db.execute('SAVEPOINT foreign_payment_edit');
    try {
      _save(db, edited);
      db.db.execute(
        'INSERT INTO foreign_payments_outbox(namespace,source_key,kind,payload) VALUES(?,?,?,?)',
        [namespace, current.sourceKey, kind, jsonEncode(payload)],
      );
      db.db.execute('RELEASE SAVEPOINT foreign_payment_edit');
    } catch (_) {
      db.db.execute('ROLLBACK TO SAVEPOINT foreign_payment_edit');
      db.db.execute('RELEASE SAVEPOINT foreign_payment_edit');
      rethrow;
    }
    onChanged?.call();
    if (accessToken() != null) {
      try {
        await sync();
      } catch (error) {
        if (error is ApiException &&
            (error.statusCode ?? 500) < 500 &&
            error.statusCode != 404) {
          rethrow;
        }
      }
    }
    return (await find(current.id)) ?? edited;
  }

  void _save(AppDatabase db, ForeignPayment payment) {
    final before = db.db.select(
      'SELECT payload FROM foreign_payments_local WHERE namespace=? AND source_key=?',
      [namespace, payment.sourceKey],
    );
    final wasConfirmed =
        before.isNotEmpty &&
        (jsonDecode(before.single['payload'] as String)
                as Map)['valuation_status'] ==
            'confirmed';
    final encoded = jsonEncode(payment.toJson());
    if (before.isNotEmpty && before.single['payload'] == encoded) return;
    db.db.execute(
      'INSERT INTO foreign_payments_local(namespace,source_key,payload) VALUES(?,?,?) ON CONFLICT(namespace,source_key) DO UPDATE SET payload=excluded.payload',
      [namespace, payment.sourceKey, encoded],
    );
    if (payment.isConfirmed || payment.isIgnored) {
      db.db.execute(
        'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
        [namespace, payment.sourceKey],
      );
    }
    if (payment.isConfirmed != wasConfirmed) onLedgerChanged?.call();
    onChanged?.call();
  }

  /// Server audit sees typed facts that may no longer have a local SMS copy.
  /// It independently rechecks each candidate inside its repair transaction.
  Future<int> repairServerAmountRoles() async {
    if (accessToken() == null || !accountIsCurrent()) return 0;
    final db = await _db();
    final state = db.db.select(
      'SELECT audit_cursor,audit_scanned,audit_completed_at FROM foreign_payments_sync_state WHERE namespace=?',
      [namespace],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (state.isNotEmpty &&
        state.single['audit_completed_at'] is int &&
        now - (state.single['audit_completed_at'] as int) <
            const Duration(hours: 12).inMilliseconds) {
      return 0;
    }
    var cursor = state.isEmpty ? null : state.single['audit_cursor'] as String?;
    var scanned = state.isEmpty ? 0 : state.single['audit_scanned'] as int;
    var repairedCount = 0;
    final clock = Stopwatch()..start();
    for (
      var page = 0;
      page < 10 && clock.elapsed < const Duration(seconds: 20);
      page++
    ) {
      final audit = await _request(
        'GET',
        '/transactions/amount-audit?limit=200${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}',
      );
      if (!accountIsCurrent()) return repairedCount;
      final items = audit['items'] as List? ?? const [];
      final ids = [
        for (final raw in items)
          if (raw is Map && raw['disposition'] == 'candidate')
            raw['transaction_id'],
      ].whereType<String>().toList();
      for (var offset = 0; offset < ids.length; offset += 50) {
        final result = await _request(
          'POST',
          '/transactions/amount-audit/repair',
          {'transaction_ids': ids.skip(offset).take(50).toList()},
        );
        if (!accountIsCurrent()) return repairedCount;
        final repaired = (result['repaired'] as List? ?? const [])
            .whereType<String>()
            .toList();
        repairedCount += repaired.length;
        final hasEntities = db.db
            .select(
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name='financial_entities'",
            )
            .isNotEmpty;
        if (hasEntities)
          for (final id in repaired) {
            final rows = db.db.select(
              "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=? AND pending=0",
              [namespace, id],
            );
            if (rows.isEmpty) continue;
            final payload =
                jsonDecode(rows.single['payload'] as String)
                    as Map<String, dynamic>;
            payload['status'] = 'ignored';
            payload['note'] =
                '[ignored: wrong_transaction] [amount-role-audit:v1]';
            db.db.execute(
              "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=? AND pending=0",
              [jsonEncode(payload), namespace, id],
            );
          }
      }
      scanned += items.length;
      cursor = audit['next_cursor'] as String?;
      db.db.execute(
        'INSERT INTO foreign_payments_sync_state(namespace,audit_cursor,audit_scanned,audit_completed_at,audit_summary) VALUES(?,?,?,?,?) ON CONFLICT(namespace) DO UPDATE SET audit_cursor=excluded.audit_cursor,audit_scanned=excluded.audit_scanned,audit_completed_at=excluded.audit_completed_at,audit_summary=excluded.audit_summary',
        [
          namespace,
          cursor,
          cursor == null ? 0 : scanned,
          cursor == null ? now : null,
          jsonEncode(audit['summary']),
        ],
      );
      if (cursor == null) break;
    }
    if (repairedCount > 0) {
      onChanged?.call();
      onLedgerChanged?.call();
    }
    return repairedCount;
  }

  Future<void> refresh() async {
    await sync();
    if (accessToken() == null || !accountIsCurrent()) return;
    await _request('POST', '/foreign-payments/refresh', {});
    await _download(await _db());
    onChanged?.call();
  }

  Future<void> sync() =>
      _syncFuture ??= _syncPass().whenComplete(() => _syncFuture = null);

  Future<void> _syncPass() async {
    final db = await _db();
    if (accessToken() == null || !accountIsCurrent()) return;
    final stopwatch = Stopwatch()..start();
    // Only changes that are due. A change also waits while an earlier change
    // of the same payment is parked or in backoff: edits are patches, so
    // sending a later one first would let the older one overwrite it.
    final nowMs = _now().millisecondsSinceEpoch;
    final pending = db.db.select(
      'SELECT * FROM foreign_payments_outbox AS o '
      'WHERE o.namespace=? AND o.parked=0 AND o.next_attempt_at<=? '
      'AND NOT EXISTS (SELECT 1 FROM foreign_payments_outbox AS e '
      'WHERE e.namespace=o.namespace AND e.source_key=o.source_key AND e.seq<o.seq '
      'AND (e.parked=1 OR e.next_attempt_at>?)) '
      'ORDER BY o.seq LIMIT 100',
      [namespace, nowMs, nowMs],
    );
    final blockedSources = <String>{};
    Object? firstError;
    for (final row in pending) {
      if (!accountIsCurrent() ||
          ServerBackoff.process.isPaused ||
          stopwatch.elapsed > const Duration(seconds: 25)) {
        break;
      }
      final sourceKey = row['source_key'] as String;
      if (blockedSources.contains(sourceKey)) continue;
      final current = (await find(sourceKey))!;
      final kind = row['kind'] as String;
      final payload =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      try {
        Map<String, dynamic> response;
        if (kind == 'create') {
          response = await _request('POST', '/foreign-payments', payload);
        } else {
          if (current.id.startsWith('fx:')) {
            blockedSources.add(sourceKey);
            continue;
          }
          response = await _request(
            kind == 'confirm' ? 'POST' : 'PATCH',
            '/foreign-payments/${Uri.encodeComponent(current.id)}${kind == 'confirm' ? '/confirm' : ''}',
            payload,
          );
        }
        if (!accountIsCurrent()) return;
        final raw =
            (response['item'] ?? response['payment'] ?? response) as Map;
        final remote = ForeignPayment.fromJson(Map<String, dynamic>.from(raw));
        if (remote.sourceKey != sourceKey) {
          db.db.execute(
            'INSERT INTO foreign_payments_source_aliases(namespace,source_key,canonical_source_key) VALUES(?,?,?) ON CONFLICT(namespace,source_key) DO UPDATE SET canonical_source_key=excluded.canonical_source_key',
            [namespace, sourceKey, remote.sourceKey],
          );
          db.db.execute(
            'DELETE FROM foreign_payments_local WHERE namespace=? AND source_key=?',
            [namespace, sourceKey],
          );
          db.db.execute(
            'UPDATE foreign_payments_outbox SET source_key=? WHERE namespace=? AND source_key=?',
            [remote.sourceKey, namespace, sourceKey],
          );
          db.db.execute(
            'DELETE FROM local_needs_review WHERE namespace=? AND id=?',
            [namespace, sourceKey],
          );
        }
        db.db.execute(
          'DELETE FROM foreign_payments_outbox WHERE namespace=? AND seq=?',
          [namespace, row['seq']],
        );
        // Preserve later durable edits while replacing the temporary id and
        // the server-owned valuation fields. Replay applies each intent once.
        final later = db.db.select(
          'SELECT kind,payload FROM foreign_payments_outbox WHERE namespace=? AND source_key=? ORDER BY seq',
          [namespace, remote.sourceKey],
        );
        var merged = remote;
        for (final queued in later) {
          final patch =
              jsonDecode(queued['payload'] as String) as Map<String, dynamic>;
          merged = merged.withPatch({
            ...patch,
            'user_modified': true,
            'locally_pending': true,
          });
        }
        _save(db, merged.withPatch({'locally_pending': later.isNotEmpty}));
        onChanged?.call();
      } catch (error) {
        if (isAuthenticationFailure(error)) rethrow;
        firstError ??= error;
        blockedSources.add(sourceKey);
        // A 409 here means "needs review", which the person clears by
        // retrying, so it backs off instead of parking.
        final failure = classifyQueueFailure(
          error,
          retryableStatuses: const {409},
        );
        if (accountIsCurrent()) {
          final lastError = error is ApiException
              ? 'http_${error.statusCode ?? 0}'
              : 'unavailable';
          final attempts = (row['attempts'] as int? ?? 0) + 1;
          switch (failure) {
            case QueueFailure.network:
              db.db.execute(
                'UPDATE foreign_payments_outbox SET last_error=? WHERE namespace=? AND seq=?',
                [lastError, namespace, row['seq']],
              );
            case QueueFailure.retryable:
              db.db.execute(
                'UPDATE foreign_payments_outbox SET last_error=?, attempts=?, next_attempt_at=? '
                'WHERE namespace=? AND seq=?',
                [
                  lastError,
                  attempts,
                  _now().add(queueBackoffJittered(attempts)).millisecondsSinceEpoch,
                  namespace,
                  row['seq'],
                ],
              );
            case QueueFailure.permanent:
              db.db.execute(
                'UPDATE foreign_payments_outbox SET last_error=?, attempts=?, parked=1 '
                'WHERE namespace=? AND seq=?',
                [lastError, attempts, namespace, row['seq']],
              );
          }
        }
        if (accountIsCurrent()) {
          _save(
            db,
            current.withPatch({
              'sync_error': error is ApiException && error.statusCode == 409
                  ? 'This payment needs review before the saved change can sync. Retry or check its billed transaction.'
                  : 'This change is saved on your device and will retry when the service is available.',
              'locally_pending': true,
            }),
          );
        }
        // Could not reach the service: the remaining changes would each wait
        // out their own timeout. Leave them for the next trigger.
        if (failure == QueueFailure.network) break;
      }
    }
    if (accountIsCurrent()) {
      final now = DateTime.now();
      if (_lastRateRefresh == null ||
          now.difference(_lastRateRefresh!) > const Duration(minutes: 5)) {
        _lastRateRefresh = now;
        try {
          await _request('POST', '/foreign-payments/refresh', {});
        } catch (error) {
          if (isAuthenticationFailure(error)) rethrow;
        }
      }
      await _download(db);
    }
    if (firstError != null) throw firstError;
  }

  Future<void> _download(AppDatabase db) async {
    String? cursor;
    for (var page = 0; page < 50; page++) {
      final result = await _request(
        'GET',
        '/foreign-payments?limit=200&include_ignored=true${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}',
      );
      if (!accountIsCurrent()) return;
      for (final item in (result['items'] as List? ?? const [])) {
        final remote = ForeignPayment.fromJson(
          Map<String, dynamic>.from(item as Map),
        );
        final hasPending = db.db.select(
          'SELECT 1 FROM foreign_payments_outbox WHERE namespace=? AND source_key=? LIMIT 1',
          [namespace, remote.sourceKey],
        ).isNotEmpty;
        if (!hasPending) _save(db, remote);
      }
      final next = result['next_cursor'] as String?;
      if (next == null || next == cursor) break;
      cursor = next;
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (!accountIsCurrent()) throw StateError('The active account changed.');
    final token = accessToken();
    if (token == null) throw const AuthenticationUnavailableException();
    final request =
        http.Request(
            method,
            Uri.parse('${apiBaseUrl.replaceFirst(RegExp(r'/$'), '')}$path'),
          )
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(request),
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        '$method /foreign-payments failed: ${response.statusCode} ${response.body}',
      );
    }
    final value = jsonDecode(response.body);
    if (value is! Map) {
      throw StateError('The payment service returned an invalid response.');
    }
    return Map<String, dynamic>.from(value);
  }
}
