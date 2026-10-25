import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../../features/sms_import/sms_background_queue.dart';
import '../local_sms_parser.dart';
import 'app_database.dart';
import 'sms_intake_repository.dart';

/// A separate append/ack spool for SMS arriving while recovery owns the main
/// SQLite writer lock. Account labels are retained; no token or HTTP is used.
/// It is bounded and never evicts an older unsent message to make room.
class RecoveryDeferredSms {
  static const maxMessages = 200;
  static const maxTextBytes = 1024 * 1024;
  final Database _database;
  RecoveryDeferredSms._(this._database);

  factory RecoveryDeferredSms.open(String mainDatabasePath) {
    final location = path.join(
      path.dirname(mainDatabasePath),
      'pandapay-recovery-deferred-sms.sqlite',
    );
    final db = sqlite3.open(location);
    try {
      db.execute('PRAGMA busy_timeout=5000');
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('''
        CREATE TABLE IF NOT EXISTS deferred_sms(
          namespace TEXT NOT NULL,id TEXT NOT NULL,sender TEXT NOT NULL,
          body TEXT NOT NULL,received_at INTEGER NOT NULL,
          PRIMARY KEY(namespace,id)
        )
      ''');
      return RecoveryDeferredSms._(db);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  void enqueue(String namespace, QueuedSms message) {
    if (namespace.isEmpty ||
        namespace.length > 100 ||
        message.sender.length > 200 ||
        message.body.length > 16000 ||
        LocalSmsParser.sensitive(message.body)) {
      throw const FormatException('Invalid deferred SMS');
    }
    final id = smsSourceKey(namespace, message.sender, message.body);
    _database.execute('BEGIN IMMEDIATE');
    try {
      if (_database.select(
        'SELECT 1 FROM deferred_sms WHERE namespace=? AND id=?',
        [namespace, id],
      ).isNotEmpty) {
        _database.execute('COMMIT');
        return;
      }
      final usage = _database
          .select(
            'SELECT COUNT(*) AS n,COALESCE(SUM(LENGTH(CAST(sender AS BLOB))+LENGTH(CAST(body AS BLOB))),0) AS bytes FROM deferred_sms',
          )
          .single;
      if ((usage['n'] as int) >= maxMessages ||
          (usage['bytes'] as int) +
                  message.sender.length * 4 +
                  message.body.length * 4 >
              maxTextBytes) {
        throw StateError(
          'Deferred SMS storage is full; inbox reconciliation is required',
        );
      }
      _database.execute('INSERT INTO deferred_sms VALUES(?,?,?,?,?)', [
        namespace,
        id,
        message.sender,
        message.body,
        message.receivedAt.millisecondsSinceEpoch,
      ]);
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Commit to the ordinary durable intake first, then acknowledge this spool.
  /// A crash between commits replays the same source ID idempotently.
  int drainInto(AppDatabase target) {
    final intake = SmsIntakeRepository(target);
    var handled = 0;
    for (final row in _database.select(
      'SELECT * FROM deferred_sms ORDER BY received_at,id LIMIT 200',
    )) {
      intake.capture(
        row['namespace'] as String,
        QueuedSms(
          sender: row['sender'] as String,
          body: row['body'] as String,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            row['received_at'] as int,
          ),
        ),
      );
      _database.execute('DELETE FROM deferred_sms WHERE namespace=? AND id=?', [
        row['namespace'],
        row['id'],
      ]);
      handled++;
    }
    return handled;
  }

  void close() => _database.dispose();

  static int drainFor(AppDatabase database) {
    final location = database.filePath;
    if (location == null ||
        !File(
          path.join(
            path.dirname(location),
            'pandapay-recovery-deferred-sms.sqlite',
          ),
        ).existsSync()) {
      return 0;
    }
    final spool = RecoveryDeferredSms.open(location);
    try {
      return spool.drainInto(database);
    } finally {
      spool.close();
    }
  }
}
