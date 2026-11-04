import 'dart:convert';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Account-scoped ledger. Local category context is stripped from wire JSON,
/// just as InstrumentStore strips local limit history.
class LedgerStore {
  LedgerStore(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  void replaceForEvent(
    String eventId,
    Iterable<LedgerEntry> entries, {
    bool dirty = true,
    CategoryDecision? category,
  }) {
    final rows = entries.toList();
    if (rows.any((e) => e.eventId != eventId)) {
      throw ArgumentError('event id mismatch');
    }
    for (final e in rows) {
      final result = e.validate();
      if (!result.ok) throw ContractException(result.errors);
    }
    db.execute('SAVEPOINT v2_ledger_write');
    try {
      final keep = rows.map((e) => e.entryId).toSet();
      for (final old in db.select(
        'SELECT entry_id FROM v2_ledger WHERE namespace=? AND event_id=?',
        [namespace, eventId],
      )) {
        if (!keep.contains(old['entry_id'])) {
          db.execute('DELETE FROM v2_ledger WHERE namespace=? AND entry_id=?', [
            namespace,
            old['entry_id'],
          ]);
        }
      }
      for (final row in rows) {
        final payload = jsonEncode({
          ...row.toJson(),
          if (category != null)
            '_categoryDecision': {
              'slug': category.slug,
              'source': category.source.wire,
              'ruleId': category.ruleId,
              'confidence': category.confidence,
            },
        });
        db.execute(
          '''INSERT INTO v2_ledger(namespace,entry_id,event_id,occurred_at,payload,dirty) VALUES(?,?,?,?,?,?)
ON CONFLICT(namespace,entry_id) DO UPDATE SET event_id=excluded.event_id,occurred_at=excluded.occurred_at,
payload=excluded.payload,dirty=excluded.dirty WHERE v2_ledger.payload != excluded.payload''',
          [
            namespace,
            row.entryId,
            eventId,
            row.occurredAt.toUtc().toIso8601String(),
            payload,
            dirty ? 1 : 0,
          ],
        );
      }
      db.execute('RELEASE v2_ledger_write');
    } catch (_) {
      db.execute('ROLLBACK TO v2_ledger_write');
      db.execute('RELEASE v2_ledger_write');
      rethrow;
    }
  }

  LedgerEntry? get(String id) {
    final rows = db.select(
      'SELECT payload FROM v2_ledger WHERE namespace=? AND entry_id=?',
      [namespace, id],
    );
    return rows.isEmpty ? null : _decode(rows.single['payload'] as String);
  }

  List<LedgerEntry> list({DateTime? from, DateTime? to}) => _rows()
      .map((r) => _decode(r['payload'] as String))
      .where(
        (e) =>
            (from == null || !e.occurredAt.isBefore(from)) &&
            (to == null || e.occurredAt.isBefore(to)),
      )
      .toList();
  List<LedgerEntry> forEvent(String eventId) => [
    for (final row in db.select(
      'SELECT payload FROM v2_ledger WHERE namespace=? AND event_id=? ORDER BY entry_id',
      [namespace, eventId],
    ))
      _decode(row['payload'] as String),
  ];
  List<LedgerEntry> dirty() =>
      _rows(dirty: true).map((r) => _decode(r['payload'] as String)).toList();
  void markClean(Iterable<String> ids) => _mark(ids, 0);
  void markDirty(Iterable<String> ids) => _mark(ids, 1);
  void _mark(Iterable<String> ids, int value) {
    for (final id in ids) {
      db.execute(
        'UPDATE v2_ledger SET dirty=? WHERE namespace=? AND entry_id=?',
        [value, namespace, id],
      );
    }
  }

  Map<String, CategoryDecision> categoryDecisions({Set<String>? eventIds}) {
    final result = <String, CategoryDecision>{};
    for (final r in _rows(eventIds: eventIds)) {
      final j = jsonDecode(r['payload'] as String) as Map;
      final c = j['_categoryDecision'] as Map?;
      if (c != null) {
        result[r['event_id'] as String] = CategoryDecision(
          slug: c['slug'] as String,
          source: CategorySource.fromWire(c['source'] as String),
          ruleId: c['ruleId'] as String?,
          confidence: (c['confidence'] as num).toDouble(),
        );
      }
    }
    return Map.unmodifiable(result);
  }

  Iterable<Row> _rows({bool dirty = false, Set<String>? eventIds}) sync* {
    final groups = eventIds == null
        ? [<String>[]]
        : [
            for (var start = 0; start < eventIds.length; start += 400)
              eventIds.skip(start).take(400).toList(),
          ];
    for (final ids in groups) {
      final filter = eventIds == null
          ? ''
          : ' AND event_id IN (${List.filled(ids.length, '?').join(',')})';
      yield* db.select(
        'SELECT event_id,payload FROM v2_ledger WHERE namespace=?${dirty ? ' AND dirty=1' : ''}$filter ORDER BY occurred_at,entry_id',
        [namespace, ...ids],
      );
    }
  }

  LedgerEntry _decode(String payload) => LedgerEntry.fromJson(
    (jsonDecode(payload) as Map).cast<String, Object?>()
      ..remove('_categoryDecision'),
  );
}
