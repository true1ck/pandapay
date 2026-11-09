import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart' show Event, EventLeg, EventStatus;
import 'package:sqlite3/sqlite3.dart';

import 'row_decode_cache.dart';

/// Phone storage for linked events, on the WP-01 `v2_events` table.
///
/// Every query is scoped to [namespace], the signed-in account. The row's
/// `payload` is the event's contract JSON.
///
/// The store enforces the linker's promises even if a caller slips:
/// - automatic links only grow; explicit user corrections replace wrong legs;
/// - a `user_confirmed` event changes only through `fromUser: true` (the
///   person's own edit, or the same edit synced back from the server).
class EventStore {
  EventStore(this._db, {required this.namespace});

  final Database _db;

  /// The account namespace (for example `user:<uuid>`).
  final String namespace;

  /// Inserts or updates [event] by `eventId` and returns what is stored.
  ///
  /// Marks the row dirty so sync picks it up (pass `dirty: false` for rows
  /// that came from the server). A stored `user_confirmed` event is returned
  /// unchanged unless [fromUser] is true. Explicit user edits replace legs.
  Event upsert(Event event, {bool dirty = true, bool fromUser = false}) {
    final stored = get(event.eventId);
    var next = event;
    if (stored != null) {
      if (stored.status == EventStatus.userConfirmed && !fromUser) {
        return stored;
      }
      final have = {for (final l in event.legs) l.factId};
      final kept = <EventLeg>[
        for (final l in stored.legs)
          if (!have.contains(l.factId)) l,
      ];
      if (!fromUser && kept.isNotEmpty) {
        next = event.copyWith(legs: [...event.legs, ...kept]);
      }
    }
    _db.execute(
      '''
INSERT INTO v2_events (namespace, event_id, type, status, payload, dirty)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(namespace, event_id) DO UPDATE SET
  type = excluded.type,
  status = excluded.status,
  payload = excluded.payload,
  dirty = excluded.dirty
''',
      [
        namespace,
        next.eventId,
        next.type.wire,
        next.status.wire,
        jsonEncode(next.toJson()),
        dirty ? 1 : 0,
      ],
    );
    return next;
  }

  /// [upsert] for each event, in one transaction.
  void upsertAll(Iterable<Event> events, {bool dirty = true}) {
    _db.execute('SAVEPOINT v2_events_upsert');
    try {
      for (final e in events) {
        upsert(e, dirty: dirty);
      }
      _db.execute('RELEASE v2_events_upsert');
    } catch (_) {
      _db.execute('ROLLBACK TO v2_events_upsert');
      _db.execute('RELEASE v2_events_upsert');
      rethrow;
    }
  }

  /// The event with [eventId], or null.
  Event? get(String eventId) {
    final rows = _db.select(
      'SELECT payload FROM v2_events WHERE namespace = ? AND event_id = ?',
      [namespace, eventId],
    );
    return rows.isEmpty ? null : _decode(rows.first['payload'] as String);
  }

  /// Every event that has [factId] as a leg (a purchase is the money leg of
  /// its own event and the `original` of its refunds, so there can be more
  /// than one), by event id.
  List<Event> findByFactId(String factId) => findByFactIds([factId]);

  /// Every event that has any of [factIds] as a leg, by event id.
  List<Event> findByFactIds(Iterable<String> factIds) {
    final ids = factIds.toSet().toList();
    final out = <String, Event>{};
    const chunk = 500;
    if (ids.length > chunk) {
      // There is no index on the legs' fact ids, so every chunked query below
      // scans the whole event table. For a big instrument that is
      // ceil(N / 500) full scans; read the table once and match in Dart.
      final wanted = ids.toSet();
      final rows = _db.select(
        '''
SELECT e.event_id AS event_id, e.payload AS payload,
       json_extract(j.value, '\$.factId') AS fact_id
FROM v2_events e, json_each(e.payload, '\$.legs') j
WHERE e.namespace = ?
''',
        [namespace],
      );
      for (final r in rows) {
        final eventId = r['event_id'] as String;
        if (out.containsKey(eventId)) continue;
        if (wanted.contains(r['fact_id'])) {
          out[eventId] = _decode(r['payload'] as String);
        }
      }
      return out.values.toList()..sort((a, b) => a.eventId.compareTo(b.eventId));
    }
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(
        i,
        i + chunk > ids.length ? ids.length : i + chunk,
      );
      final marks = List.filled(part.length, '?').join(', ');
      final rows = _db.select(
        '''
SELECT DISTINCT e.event_id AS event_id, e.payload AS payload
FROM v2_events e, json_each(e.payload, '\$.legs') j
WHERE e.namespace = ? AND json_extract(j.value, '\$.factId') IN ($marks)
''',
        [namespace, ...part],
      );
      for (final r in rows) {
        out[r['event_id'] as String] = _decode(r['payload'] as String);
      }
    }
    final list = out.values.toList()
      ..sort((a, b) => a.eventId.compareTo(b.eventId));
    return list;
  }

  /// Link context for recent facts in one indexed join, including events
  /// whose printed date is older than their message receipt time.
  List<Event> contextSince(DateTime observedAt) => [
    for (final row in _db.select(
      // json_each must run before the fact lookup. Letting SQLite start
      // from the date index multiplies every recent fact by every event.
      "SELECT e.payload FROM v2_events e WHERE e.namespace=? AND EXISTS ("
      "SELECT 1 FROM json_each(e.payload, '\$.legs') leg "
      "CROSS JOIN v2_facts f ON f.namespace=e.namespace "
      "AND f.fact_id=json_extract(leg.value,'\$.factId') "
      "WHERE f.observed_at>=?)",
      [namespace, _factTimestamp(observedAt)],
    ))
      _decode(row['payload'] as String),
  ];

  /// Open (`awaiting_leg`) events whose `occurredAt` is inside
  /// `[from, to]` (either may be null), oldest first.
  List<Event> listOpen({DateTime? from, DateTime? to}) => _list(
    where: 'status = ?',
    args: [EventStatus.awaitingLeg.wire],
    from: from,
    to: to,
  );

  /// Every event whose `occurredAt` is at or after [from], oldest first: the
  /// `knownEvents` of a `RuleLinkContext` over the last 120 days of facts.
  List<Event> listSince(DateTime from) => _list(from: from);

  /// Events changed since the last sync.
  List<Event> dirty() => _list(where: 'dirty = 1');

  /// Flags [eventIds] as changed since the last sync.
  void markDirty(Iterable<String> eventIds) => _setDirty(eventIds, 1);

  /// Flags [eventIds] as synced.
  void markClean(Iterable<String> eventIds) => _setDirty(eventIds, 0);

  /// How many events this account has.
  int count() {
    final rows = _db.select(
      'SELECT COUNT(*) AS n FROM v2_events WHERE namespace = ?',
      [namespace],
    );
    return rows.first['n'] as int;
  }

  List<Event> _list({
    String? where,
    List<Object?> args = const [],
    DateTime? from,
    DateTime? to,
  }) {
    final rows = _db.select(
      'SELECT event_id,payload FROM v2_events WHERE namespace = ?${where == null ? '' : ' AND $where'}',
      [namespace, ...args],
    );
    // Events are immutable values: a row whose payload text is unchanged
    // since the last read reuses its decoded (and validated) Event. The ledger
    // read model re-reads every event on each revision bump.
    final pass = RowDecodeCache.of<Event>(_db, 'v2_events').begin(namespace);
    final decoded = <Event>[
      for (final r in rows)
        pass.resolve(
          r['event_id'] as String,
          r['payload'] as String,
          _decode,
        ),
    ];
    pass.finish(complete: where == null);
    final out = decoded
        .where((e) {
          if (from != null && e.occurredAt.isBefore(from)) return false;
          if (to != null && e.occurredAt.isAfter(to)) return false;
          return true;
        })
        .toList();
    out.sort((a, b) {
      final c = a.occurredAt.compareTo(b.occurredAt);
      return c != 0 ? c : a.eventId.compareTo(b.eventId);
    });
    return out;
  }

  void _setDirty(Iterable<String> ids, int value) {
    for (final id in ids) {
      _db.execute(
        'UPDATE v2_events SET dirty = ? WHERE namespace = ? AND event_id = ?',
        [value, namespace, id],
      );
    }
  }

  static String _factTimestamp(DateTime value) {
    final utc = value.toUtc();
    final iso = utc.toIso8601String();
    return utc.microsecond == 0
        ? '${iso.substring(0, iso.length - 1)}000Z'
        : iso;
  }

  Event _decode(String payload) =>
      Event.fromJson((jsonDecode(payload) as Map).cast<String, Object?>());
}
