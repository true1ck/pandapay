import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart'
    show Instrument, InstrumentKind, InstrumentStatus, LimitChangeRecord;
import 'package:sqlite3/sqlite3.dart';

import 'row_decode_cache.dart';

/// Two stored instruments would share an identity key
/// (`kind`, `issuerSlug`, `maskDigits`) in one account.
class InstrumentKeyConflict implements Exception {
  const InstrumentKeyConflict(this.existingId, this.incomingId);
  final String existingId;
  final String incomingId;

  @override
  String toString() =>
      'InstrumentKeyConflict(existing $existingId, incoming $incomingId): resolve the mention first and update the existing instrument';
}

/// Phone storage for instruments, on the WP-01 `v2_instruments` table.
///
/// Every query is scoped to [namespace], the signed-in account. The row's
/// `payload` is the instrument's contract JSON, plus an optional
/// `limitHistory` list the contract has no field for; it never reaches the
/// server and [get] strips it.
///
/// Identity: rows are unique by `(namespace, kind, issuer_slug, mask_digits)`
/// when the mask is set. Instruments without a mask (wallets, brokers, and
/// cards seeded without last 4 digits) are told apart by id only, because
/// SQLite treats NULLs as distinct in a unique index.
class InstrumentStore {
  InstrumentStore(this._db, {required this.namespace});

  final Database _db;

  /// The account namespace (for example `user:<uuid>`).
  final String namespace;

  /// Inserts or updates [instrument], and marks the row dirty so sync picks it
  /// up (pass `dirty: false` for rows that came from the server).
  ///
  /// The row is found by instrument id first, then by identity key. A row with
  /// the same key but another id throws [InstrumentKeyConflict]: the caller
  /// should have resolved to the stored instrument. [limitHistory] replaces
  /// the stored history when given; otherwise the stored one is kept.
  void upsert(
    Instrument instrument, {
    List<LimitChangeRecord>? limitHistory,
    bool dirty = true,
  }) {
    final byKey = instrument.maskDigits == null
        ? null
        : findByKey(
            instrument.kind,
            instrument.issuerSlug,
            instrument.maskDigits,
          );
    if (byKey != null && byKey.instrumentId != instrument.instrumentId) {
      throw InstrumentKeyConflict(byKey.instrumentId, instrument.instrumentId);
    }
    final history = limitHistory ?? this.limitHistory(instrument.instrumentId);
    final payload = jsonEncode({
      ...instrument.toJson(),
      if (history.isNotEmpty)
        'limitHistory': [for (final r in history) r.toJson()],
    });
    _db.execute(
      '''
INSERT INTO v2_instruments (namespace, instrument_id, kind, issuer_slug, mask_digits, status, payload, dirty)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(namespace, instrument_id) DO UPDATE SET
  kind = excluded.kind,
  issuer_slug = excluded.issuer_slug,
  mask_digits = excluded.mask_digits,
  status = excluded.status,
  payload = excluded.payload,
  dirty = excluded.dirty
''',
      [
        namespace,
        instrument.instrumentId,
        instrument.kind.wire,
        instrument.issuerSlug,
        instrument.maskDigits,
        instrument.status.wire,
        payload,
        dirty ? 1 : 0,
      ],
    );
  }

  /// The instrument with [id], or null.
  Instrument? get(String id) {
    final rows = _db.select(
      'SELECT payload FROM v2_instruments WHERE namespace = ? AND instrument_id = ?',
      [namespace, id],
    );
    return rows.isEmpty ? null : _decode(rows.first['payload'] as String);
  }

  /// The instrument with this identity key, or null. Matches a null mask
  /// against rows without a mask, but those are not unique (see the class
  /// comment), so the first by id is returned.
  Instrument? findByKey(
    InstrumentKind kind,
    String issuerSlug,
    String? maskDigits,
  ) {
    final rows = _db.select(
      'SELECT payload FROM v2_instruments WHERE namespace = ? AND kind = ? AND issuer_slug = ? AND mask_digits IS ? ORDER BY instrument_id LIMIT 1',
      [namespace, kind.wire, issuerSlug, maskDigits],
    );
    return rows.isEmpty ? null : _decode(rows.first['payload'] as String);
  }

  /// The instrument linked to the `user_cards` row [userCardId], or null.
  Instrument? findByUserCardId(String userCardId) {
    for (final i in list()) {
      if (i.userCardId == userCardId) return i;
    }
    return null;
  }

  /// All instruments, newest `lastSeenAt` first, optionally narrowed by
  /// [status] and [kind].
  List<Instrument> list({InstrumentStatus? status, InstrumentKind? kind}) {
    final where = StringBuffer('namespace = ?');
    final args = <Object?>[namespace];
    if (status != null) {
      where.write(' AND status = ?');
      args.add(status.wire);
    }
    if (kind != null) {
      where.write(' AND kind = ?');
      args.add(kind.wire);
    }
    final rows = _db.select(
      'SELECT instrument_id,payload FROM v2_instruments WHERE $where',
      args,
    );
    // Instruments are immutable values; an unchanged payload reuses its
    // decoded Instrument (the ledger read model lists them on every rebuild).
    final pass = RowDecodeCache.of<Instrument>(
      _db,
      'v2_instruments',
    ).begin(namespace);
    final out = [
      for (final r in rows)
        pass.resolve(
          r['instrument_id'] as String,
          r['payload'] as String,
          _decode,
        ),
    ];
    pass.finish(complete: status == null && kind == null);
    out.sort((a, b) {
      final c = b.lastSeenAt.compareTo(a.lastSeenAt);
      return c != 0 ? c : a.instrumentId.compareTo(b.instrumentId);
    });
    return out;
  }

  /// Instruments with [status].
  List<Instrument> listByStatus(InstrumentStatus status) =>
      list(status: status);

  /// Instruments of [kind].
  List<Instrument> listByKind(InstrumentKind kind) => list(kind: kind);

  /// Instruments changed since the last sync.
  List<Instrument> dirty() {
    final rows = _db.select(
      'SELECT payload FROM v2_instruments WHERE namespace = ? AND dirty = 1',
      [namespace],
    );
    return [for (final r in rows) _decode(r['payload'] as String)];
  }

  /// Flags [ids] as changed since the last sync.
  void markDirty(Iterable<String> ids) => _setDirty(ids, 1);

  /// Flags [ids] as synced.
  void markClean(Iterable<String> ids) => _setDirty(ids, 0);

  /// The recorded limit changes of [id], oldest first.
  List<LimitChangeRecord> limitHistory(String id) {
    final rows = _db.select(
      'SELECT payload FROM v2_instruments WHERE namespace = ? AND instrument_id = ?',
      [namespace, id],
    );
    if (rows.isEmpty) return const [];
    final json =
        jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
    return [
      for (final r in (json['limitHistory'] as List? ?? const []))
        LimitChangeRecord.fromJson((r as Map).cast<String, Object?>()),
    ];
  }

  /// How many instruments this account has.
  int count() {
    final rows = _db.select(
      'SELECT COUNT(*) AS n FROM v2_instruments WHERE namespace = ?',
      [namespace],
    );
    return rows.first['n'] as int;
  }

  void _setDirty(Iterable<String> ids, int value) {
    for (final id in ids) {
      _db.execute(
        'UPDATE v2_instruments SET dirty = ? WHERE namespace = ? AND instrument_id = ?',
        [value, namespace, id],
      );
    }
  }

  Instrument _decode(String payload) {
    final json = (jsonDecode(payload) as Map).cast<String, Object?>()
      ..remove('limitHistory');
    return Instrument.fromJson(json);
  }
}
