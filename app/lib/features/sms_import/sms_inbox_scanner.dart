import '../../data/local/app_database.dart';
import 'sms_listener_service.dart';

/// Device progress is independent of API availability, account tokens and
/// server row counts. A checkpoint means the page is durably captured locally.
class SmsInboxProgress {
  final AppDatabase database;
  SmsInboxProgress(this.database) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_inbox_progress (
        namespace TEXT PRIMARY KEY,
        last_provider_id INTEGER NOT NULL,
        initial_complete INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  int lastId(String namespace) {
    final rows = database.db.select(
      'SELECT last_provider_id FROM sms_inbox_progress WHERE namespace=?',
      [namespace],
    );
    return rows.isEmpty ? 0 : rows.single['last_provider_id'] as int;
  }

  bool initialComplete(String namespace) {
    final rows = database.db.select(
      'SELECT initial_complete FROM sms_inbox_progress WHERE namespace=?',
      [namespace],
    );
    return rows.isNotEmpty && rows.single['initial_complete'] == 1;
  }

  void commit(String namespace, int id, {bool complete = false}) {
    database.db.execute(
      '''
      INSERT INTO sms_inbox_progress(namespace,last_provider_id,initial_complete)
      VALUES (?,?,?) ON CONFLICT(namespace) DO UPDATE SET
        last_provider_id=MAX(last_provider_id,excluded.last_provider_id),
        initial_complete=MAX(initial_complete,excluded.initial_complete)
    ''',
      [namespace, id, complete ? 1 : 0],
    );
  }
}

/// One initial paged scan, then only IDs newer than the saved boundary. The
/// scanner has no HTTP dependency: an offline initial scan can still finish.
class SmsInboxScanner {
  final SmsInboxProgress progress;
  final Future<int> Function() head;
  final Future<SmsInboxPage> Function(int afterId, int throughId) read;
  final Future<void> Function(List<InboxSms>) capture;
  final void Function() checkAccount;
  SmsInboxScanner({
    required this.progress,
    required this.head,
    required this.read,
    required this.capture,
    required this.checkAccount,
  });

  Future<int> scan(String namespace) async {
    checkAccount();
    final throughId = await head();
    checkAccount();
    var afterId = progress.lastId(namespace);
    var captured = 0;
    while (afterId < throughId) {
      final page = await read(afterId, throughId);
      checkAccount();
      if (page.rowCount == 0) {
        // Deleted rows are gaps, not a reason to revisit older messages.
        afterId = throughId;
        break;
      }
      if (page.lastId <= afterId || page.lastId > throughId) {
        throw StateError('SMS scan did not advance');
      }
      await capture(page.messages);
      checkAccount();
      // A crash before this commit may replay this one page, idempotently.
      // A network failure can never move this checkpoint backwards.
      progress.commit(namespace, page.lastId);
      afterId = page.lastId;
      captured += page.messages.length;
      await Future<void>.delayed(Duration.zero);
    }
    // Never rewind automatically if the provider was reset/restored.
    progress.commit(namespace, afterId, complete: true);
    return captured;
  }
}
