import 'package:sqlite3/sqlite3.dart';

/// Account-scoped pull cursors, verified entity clocks and sync scheduling.
class SyncStateStore {
  const SyncStateStore(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  String? get(String key) =>
      db.select('SELECT value FROM v2_sync_state WHERE namespace=? AND key=?', [
            namespace,
            key,
          ]).firstOrNull?['value']
          as String?;

  void put(String key, String value) => db.execute(
    'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) '
    'ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
    [namespace, key, value],
  );

  DateTime? clock(String kind, String id) {
    final value = get('clock:$kind:$id');
    return value == null ? null : DateTime.tryParse(value);
  }

  void recordClock(String kind, String id, DateTime at) =>
      put('clock:$kind:$id', at.toUtc().toIso8601String());
}
