import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../similar/fact_keys.dart';

/// Immutable extracted facts in the signed-in account's local database.
class FactStore {
  FactStore(this._db, {required this.namespace});

  static final _caches = Expando<Map<String, Fact>>();
  Map<String, Fact> get _cache => _caches[_db] ??= <String, Fact>{};
  String _key(String id) => '$namespace|$id';
  final Database _db;
  final String namespace;

  /// Returns false when a retry encounters an already stored fact.
  bool insert(Fact fact, {String? instrumentId}) {
    final validation = fact.validate();
    if (!validation.ok) throw ContractException(validation.errors);

    _db.execute(
      '''
INSERT INTO v2_facts
  (namespace, fact_id, source_key, fact_type, observed_at, instrument_id, payload,
   merchant_key, rule_id, keyed)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
ON CONFLICT(namespace, fact_id) DO NOTHING
''',
      [
        namespace,
        fact.factId,
        fact.sourceKey,
        fact.factType.wire,
        _timestamp(fact.observedAt),
        instrumentId,
        jsonEncode(fact.toJson()),
        FactKeys.of(fact).merchantKey,
        FactKeys.of(fact).ruleId,
      ],
    );
    final inserted = _db.updatedRows != 0;
    if (inserted) _cache[_key(fact.factId)] = fact;
    return inserted;
  }

  List<Fact> forSource(String sourceKey) =>
      // Pinned to the source index: with ORDER BY observed_at, SQLite can pick
      // the observed_at index instead and scan the account's whole fact
      // history for every lookup (seen as ~100% UI-thread CPU on the review
      // list).
      _read('source_key = ?', [sourceKey], indexedBy: 'idx_v2_facts_source');

  /// Every fact of the account, in no particular order. Facts are immutable,
  /// so ones already decoded (and schema-validated) by an earlier read are
  /// reused rather than parsed again; the ledger read model rebuilds on every
  /// revision bump and used to re-decode and re-validate the whole history.
  List<Fact> all() => [
    for (final row in _db.select(
      'SELECT fact_id,payload FROM v2_facts WHERE namespace = ?',
      [namespace],
    ))
      _cache[_key(row['fact_id'] as String)] ??= Fact.fromJson(
        (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
      ),
  ];

  List<Fact> since(DateTime from) =>
      _read('observed_at >= ?', [_timestamp(from)]);

  /// Bill statements and reminders seen since [from], oldest first. Pinned to the
  /// observed-time index so the read stays bounded by the window, not the history.
  List<BillDueFact> billDuesSince(DateTime from) => [
    for (final f in _read(
      "fact_type = 'bill_due' AND observed_at >= ?",
      [_timestamp(from)],
      indexedBy: 'idx_v2_facts_observed',
    ))
      if (f is BillDueFact) f,
  ];

  /// Money movements seen since [from], oldest first (the observed-time index
  /// bounds the read to the window).
  List<MovementFact> movementsSince(DateTime from) => [
    for (final f in _read(
      "fact_type = 'movement' AND observed_at >= ?",
      [_timestamp(from)],
      indexedBy: 'idx_v2_facts_observed',
    ))
      if (f is MovementFact) f,
  ];

  Fact? get(String factId) => _read('fact_id = ?', [factId]).firstOrNull;

  Map<String, String> instrumentIdsSince(DateTime from) => {
    for (final row in _db.select(
      'SELECT fact_id, instrument_id FROM v2_facts '
      'WHERE namespace = ? AND observed_at >= ? AND instrument_id IS NOT NULL',
      [namespace, _timestamp(from)],
    ))
      row['fact_id'] as String: row['instrument_id'] as String,
  };

  /// Info facts stay on the phone and are never eligible for upload.
  List<Fact> pendingUpload({required int limit}) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    return _read('uploaded_at IS NULL AND fact_type != ?', [
      FactType.info.wire,
    ], limit: limit);
  }

  void markUploaded(String factId, DateTime at) {
    _db.execute(
      '''
UPDATE v2_facts SET uploaded_at = ?
WHERE namespace = ? AND fact_id = ? AND uploaded_at IS NULL
''',
      [_timestamp(at), namespace, factId],
    );
  }

  List<Fact> _read(
    String condition,
    List<Object?> args, {
    int? limit,
    String? indexedBy,
  }) => [
    for (final row in _db.select(
      'SELECT fact_id,payload FROM v2_facts${indexedBy == null ? '' : ' INDEXED BY $indexedBy'} WHERE namespace = ? AND $condition '
      'ORDER BY observed_at, fact_id${limit == null ? '' : ' LIMIT ?'}',
      [namespace, ...args, ?limit],
    ))
      _cache[_key(row['fact_id'] as String)] ??= Fact.fromJson(
        (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
      ),
  ];

  // Fixed-width fractions keep indexed TEXT range scans chronological.
  static String _timestamp(DateTime value) {
    final utc = value.toUtc();
    final iso = utc.toIso8601String();
    return utc.microsecond == 0
        ? '${iso.substring(0, iso.length - 1)}000Z'
        : iso;
  }
}
