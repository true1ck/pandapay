import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../features/sms_import/sms_background_queue.dart';
import 'app_database.dart';

const smsCaptureNamespaceKey = 'pandapay_app.sms_capture_namespace_v1';

/// Matches api/src/import_source_key.js, including whitespace and sender
/// normalization. Delivery timestamps do not identify a bank transaction.
String smsSourceKey(String namespace, String sender, String body) {
  String normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final account = namespace.startsWith('user:')
      ? namespace.substring(5)
      : namespace;
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            account,
            normalize(sender).toUpperCase(),
            normalize(body),
          ]),
        ),
      )
      .toString();
}

class SmsIntakeEntry {
  final String id;
  final QueuedSms message;
  const SmsIntakeEntry(this.id, this.message);
}

/// Append/ack queue, not read/replace. An SMS arriving during an upload is
/// never overwritten by that upload's old copy of the queue. Failed items
/// remain on disk; there is no drop-oldest limit.
class SmsIntakeRepository {
  final AppDatabase database;
  SmsIntakeRepository(this.database) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_intake (
        namespace TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL,
        body TEXT NOT NULL, received_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        PRIMARY KEY(namespace, id)
      );
    ''');
  }
  String capture(String namespace, QueuedSms sms) {
    final id = smsSourceKey(namespace, sms.sender, sms.body);
    database.db.execute(
      'INSERT OR IGNORE INTO sms_intake(namespace,id,sender,body,received_at) VALUES (?,?,?,?,?)',
      [
        namespace,
        id,
        sms.sender,
        sms.body,
        sms.receivedAt.millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  List<SmsIntakeEntry> pending(String namespace, {int limit = 200}) => database
      .db
      .select(
        'SELECT * FROM sms_intake WHERE namespace=? ORDER BY received_at, id LIMIT ?',
        [namespace, limit],
      )
      .map(
        (r) => SmsIntakeEntry(
          r['id'] as String,
          QueuedSms(
            sender: r['sender'] as String,
            body: r['body'] as String,
            receivedAt: DateTime.fromMillisecondsSinceEpoch(
              r['received_at'] as int,
            ),
          ),
        ),
      )
      .toList();
  void acknowledge(String ns, String id) => database.db.execute(
    'DELETE FROM sms_intake WHERE namespace=? AND id=?',
    [ns, id],
  );
  void failed(String ns, String id) => database.db.execute(
    "UPDATE sms_intake SET attempts=attempts+1,last_error='Upload pending' WHERE namespace=? AND id=?",
    [ns, id],
  );
  void clear(String ns) =>
      database.db.execute('DELETE FROM sms_intake WHERE namespace=?', [ns]);
}
