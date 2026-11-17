import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/instrument_store.dart';
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';

/// Makes [local] the server's instrument [serverId]: the server already holds
/// the same card or account (same kind, issuer and last digits) under another
/// id, so this phone takes that id everywhere it used its own (the instrument,
/// its facts, child instruments, personal rules, ledger entries and anything
/// still queued). Used when a pull brings the server's copy, and when an upload
/// is refused with `instrument_key_conflict` naming the id to use.
///
/// [resendLedger] also queues every stored ledger entry that names the
/// instrument, for the upload refusal: the server kept those entries with the
/// id it refused, so its rows could not name the card or its wallet card.
void adoptServerInstrumentId(
  Database db,
  String namespace,
  Instrument local,
  String serverId, {
  bool resendLedger = false,
}) {
  final instruments = InstrumentStore(db, namespace: namespace);
  final state = SyncStateStore(db, namespace: namespace);
  bool isDirty(String table, String column, String id) => db.select(
    'SELECT 1 FROM $table WHERE namespace=? AND $column=? AND dirty=1',
    [namespace, id],
  ).isNotEmpty;

  final wasDirty = isDirty(
    'v2_instruments',
    'instrument_id',
    local.instrumentId,
  );
  db.execute(
    'DELETE FROM v2_instruments WHERE namespace=? AND instrument_id=?',
    [namespace, local.instrumentId],
  );
  instruments.upsert(
    Instrument.fromJson({...local.toJson(), 'instrumentId': serverId}),
    dirty: wasDirty,
  );
  db.execute(
    'UPDATE v2_facts SET instrument_id=? WHERE namespace=? AND instrument_id=?',
    [serverId, namespace, local.instrumentId],
  );
  for (final child in instruments.list().where(
    (item) => item.parentInstrumentId == local.instrumentId,
  )) {
    final dirty = isDirty(
      'v2_instruments',
      'instrument_id',
      child.instrumentId,
    );
    instruments.upsert(
      child.copyWith(parentInstrumentId: serverId),
      dirty: dirty,
    );
  }
  final personal = state.get('personal:rules');
  if (personal != null) {
    final rules = jsonDecode(personal) as List;
    for (final rule in rules.whereType<Map>()) {
      if (rule['instrumentId'] == local.instrumentId) {
        rule['instrumentId'] = serverId;
      }
    }
    state.put('personal:rules', jsonEncode(rules));
  }
  void rewrite(Map<String, Object?> json) {
    for (final side in ['from', 'to']) {
      final endpoint = json[side];
      if (endpoint is Map && endpoint['instrumentId'] == local.instrumentId) {
        json[side] = <String, Object?>{'instrumentId': serverId};
      }
    }
  }

  for (final row in db.select(
    'SELECT entry_id,payload FROM v2_ledger WHERE namespace=?',
    [namespace],
  )) {
    final json = (jsonDecode(row['payload'] as String) as Map)
        .cast<String, Object?>();
    rewrite(json);
    final rewritten = jsonEncode(json);
    // Most rows do not mention the adopted instrument; leave them alone.
    if (rewritten == row['payload']) continue;
    db.execute(
      'UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?',
      [rewritten, namespace, row['entry_id']],
    );
  }
  final pending = db.select(
    'SELECT id,kind,payload FROM v2_outbox WHERE namespace=?',
    [namespace],
  );
  final queue = OutboxStore(db, namespace: namespace);
  for (final row in pending) {
    final json = (jsonDecode(row['payload'] as String) as Map)
        .cast<String, Object?>();
    if (row['id'] == 'instrument:${local.instrumentId}') {
      db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
        namespace,
        row['id'],
      ]);
      json['instrumentId'] = serverId;
      queue.enqueue('instrument', serverId, json);
    } else if (row['kind'] == 'instrument' &&
        json['parentInstrumentId'] == local.instrumentId) {
      json['parentInstrumentId'] = serverId;
      db.execute('UPDATE v2_outbox SET payload=? WHERE namespace=? AND id=?', [
        jsonEncode(json),
        namespace,
        row['id'],
      ]);
    } else if (row['kind'] == 'ledger') {
      rewrite(json);
      db.execute('UPDATE v2_outbox SET payload=? WHERE namespace=? AND id=?', [
        jsonEncode(json),
        namespace,
        row['id'],
      ]);
    }
  }
  if (resendLedger) {
    // The server holds every ledger entry with the id it refused; send the
    // ones that now name [serverId] again, so its rows and the wallet card
    // link (and with it card rewards) follow.
    for (final row in db.select(
      'SELECT entry_id,payload FROM v2_ledger WHERE namespace=?',
      [namespace],
    )) {
      final json =
          (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>()
            ..remove('_categoryDecision');
      final names = [
        'from',
        'to',
      ].any((side) => (json[side] as Map?)?['instrumentId'] == serverId);
      if (names) queue.enqueue('ledger', row['entry_id'] as String, json);
    }
  }
}
