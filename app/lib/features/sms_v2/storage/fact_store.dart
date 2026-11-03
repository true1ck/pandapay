import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Immutable extracted facts in the signed-in account's local database.
class FactStore {
  FactStore(this._db, {required this.namespace});

  final Database _db;
  final String namespace;

  /// Returns false when a retry encounters an already stored fact.
  bool insert(Fact fact, {String? instrumentId}) {
    final validation = fact.validate();
    if (!validation.ok) throw ContractException(validation.errors);

    _db.execute(
      '''
INSERT INTO v2_facts
  (namespace, fact_id, source_key, fact_type, observed_at, instrument_id, payload)
VALUES (?, ?, ?, ?, ?, ?, ?)
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
      ],
    );
    return _db.updatedRows != 0;
  }

  List<Fact> forSource(String sourceKey) =>
      _read('source_key = ?', [sourceKey]);

  List<Fact> since(DateTime from) =>
      _read('observed_at >= ?', [_timestamp(from)]);

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

  List<Fact> _read(String condition, List<Object?> args, {int? limit}) => [
    for (final row in _db.select(
      'SELECT payload FROM v2_facts WHERE namespace = ? AND $condition '
      'ORDER BY observed_at, fact_id${limit == null ? '' : ' LIMIT ?'}',
      [namespace, ...args, ?limit],
    ))
      Fact.fromJson(
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
