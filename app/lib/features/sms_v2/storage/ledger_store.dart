import 'dart:convert';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import 'row_decode_cache.dart';

/// Account-scoped ledger. Local category context is stripped from wire JSON,
/// just as InstrumentStore strips local limit history.
///
/// Refund rows (external to own) persist their category in the wire `category`
/// and `categorySource` fields (CCR-003), so it syncs. Rows written before that
/// carry the decision as local `_categoryDecision` metadata, which is still
/// read and is dropped the next time the row is written.
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
    // A refund row stores its category on the wire fields (CCR-003).
    final rows = [
      for (final e in entries)
        if (e.isRefundShaped && category != null)
          e.withCategory(category.slug, category.source)
        else
          e,
    ];
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
          if (category != null && !row.isRefundShaped)
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
      // Pinned to the event index: with ORDER BY entry_id SQLite may walk the
      // primary key and scan the whole ledger for every event.
      'SELECT payload FROM v2_ledger INDEXED BY idx_v2_ledger_event WHERE namespace=? AND event_id=? ORDER BY entry_id',
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
      if (c == null && j['category'] != null) {
        // CCR-003: a refund row's wire category is its decision. Spend rows
        // keep using local metadata, which also holds the rule id.
        final e = _decode(r['payload'] as String);
        if (e.isRefundShaped && e.categorySource != null) {
          result[r['event_id'] as String] = CategoryDecision(
            slug: e.category!,
            source: e.categorySource!,
            confidence: 1,
          );
        }
      }
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

  /// Every entry plus the per-event category decisions, i.e. exactly
  /// `(list(), categoryDecisions())`, in one pass over the table.
  ///
  /// Entries are immutable, so a row whose payload text is unchanged since the
  /// previous call reuses its already-decoded entry and decision (the very
  /// same instances); only new or edited rows are parsed. The ledger read
  /// model calls this on every revision bump.
  (List<LedgerEntry>, Map<String, CategoryDecision>) readAllCached() {
    final pass = RowDecodeCache.of<_DecodedRow>(
      db,
      'v2_ledger',
    ).begin(namespace);
    final entries = <LedgerEntry>[];
    final decisions = <String, CategoryDecision>{};
    for (final r in db.select(
      'SELECT entry_id,event_id,payload FROM v2_ledger WHERE namespace=? ORDER BY occurred_at,entry_id',
      [namespace],
    )) {
      final row = pass.resolve(
        r['entry_id'] as String,
        r['payload'] as String,
        _decodeRow,
      );
      entries.add(row.entry);
      final decision = row.decision;
      if (decision != null) decisions[r['event_id'] as String] = decision;
    }
    pass.finish();
    return (entries, Map.unmodifiable(decisions));
  }

  static _DecodedRow _decodeRow(String payload) {
    final j = (jsonDecode(payload) as Map).cast<String, Object?>();
    final c = j['_categoryDecision'] as Map?;
    final entry = LedgerEntry.fromJson({...j}..remove('_categoryDecision'));
    CategoryDecision? decision;
    if (c == null && j['category'] != null) {
      // CCR-003: a refund row's wire category is its decision. Spend rows
      // keep using local metadata, which also holds the rule id.
      if (entry.isRefundShaped && entry.categorySource != null) {
        decision = CategoryDecision(
          slug: entry.category!,
          source: entry.categorySource!,
          confidence: 1,
        );
      }
    }
    if (c != null) {
      decision = CategoryDecision(
        slug: c['slug'] as String,
        source: CategorySource.fromWire(c['source'] as String),
        ruleId: c['ruleId'] as String?,
        confidence: (c['confidence'] as num).toDouble(),
      );
    }
    return _DecodedRow(entry, decision);
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

class _DecodedRow {
  const _DecodedRow(this.entry, this.decision);
  final LedgerEntry entry;
  final CategoryDecision? decision;
}
