import '../../data/portable_backup/account_recovery_operation_gate.dart';
import '../../data/local/app_database.dart';
import 'sms_listener_service.dart';

/// Actual rows checked and financial candidates captured in this pass.
/// Provider IDs can contain gaps, so they are never presented as a percentage.
class SmsInboxScanProgress {
  final int checked;
  final int matched;
  final bool complete;
  const SmsInboxScanProgress({
    this.checked = 0,
    this.matched = 0,
    this.complete = false,
  });
}

/// Result of one bounded inbox slice. [boundary] is the provider high-water
/// mark selected at the start of the catch-up run. Callers must pass it back
/// to the next slice so messages arriving during a catch-up do not move the
/// boundary or cause an unbounded scan.
class SmsInboxScanSliceResult {
  final int captured;
  final int checked;
  final int boundary;
  final int lastProviderId;
  final int pages;
  final bool hasMore;

  const SmsInboxScanSliceResult({
    required this.captured,
    required this.checked,
    required this.boundary,
    required this.lastProviderId,
    required this.pages,
    required this.hasMore,
  });

  bool get complete => !hasMore;
}

/// Device progress is independent of API availability, account tokens and
/// server row counts. A checkpoint means the page is durably captured locally.
class SmsInboxProgress {
  final AppDatabase database;
  SmsInboxProgress(this.database) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_inbox_progress (
        namespace TEXT PRIMARY KEY,
        last_provider_id INTEGER NOT NULL,
        last_scanned_at INTEGER NOT NULL DEFAULT 0,
        initial_complete INTEGER NOT NULL DEFAULT 0
      )
    ''');
    final columns = database.db.select('PRAGMA table_info(sms_inbox_progress)');
    final names = columns.map((row) => row['name'] as String).toSet();
    if (!names.contains('last_scanned_at')) {
      database.db.execute(
        'ALTER TABLE sms_inbox_progress ADD COLUMN last_scanned_at INTEGER NOT NULL DEFAULT 0',
      );
    }
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

  void rewind(String namespace, int count) {
    database.db.execute(
      '''
      UPDATE sms_inbox_progress
         SET last_provider_id = MAX(0, last_provider_id - ?)
       WHERE namespace = ?
      ''',
      [count, namespace],
    );
  }

  /// Android provider IDs are local row IDs, not durable message identity.
  /// A provider restore/rebuild can make its head lower than our checkpoint.
  /// Reset only the provider cursor; replay is safe because capture uses the
  /// sender/body source key and is idempotent across receiver clock skew.
  void resetForProviderReset(String namespace) {
    database.db.execute(
      '''
      UPDATE sms_inbox_progress
         SET last_provider_id = 0,
             last_scanned_at = 0,
             initial_complete = 0
       WHERE namespace = ?
      ''',
      [namespace],
    );
  }

  int lastScannedAt(String namespace) {
    final rows = database.db.select(
      'SELECT last_scanned_at FROM sms_inbox_progress WHERE namespace=?',
      [namespace],
    );
    return rows.isEmpty ? 0 : (rows.single['last_scanned_at'] as int? ?? 0);
  }

  void commit(String namespace, int id, {int timestamp = 0, bool complete = false}) {
    database.db.execute(
      '''
      INSERT INTO sms_inbox_progress(namespace,last_provider_id,last_scanned_at,initial_complete)
      VALUES (?,?,?,?) ON CONFLICT(namespace) DO UPDATE SET
        last_provider_id=MAX(last_provider_id,excluded.last_provider_id),
        last_scanned_at=MAX(last_scanned_at,excluded.last_scanned_at),
        initial_complete=MAX(initial_complete,excluded.initial_complete)
    ''',
      [namespace, id, timestamp, complete ? 1 : 0],
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
  final void Function(SmsInboxScanProgress)? onProgress;
  SmsInboxScanner({
    required this.progress,
    required this.head,
    required this.read,
    required this.capture,
    required this.checkAccount,
    this.onProgress,
  });

  Future<int> scan(String namespace) =>
      AccountRecoveryOperationGate.process.run(() => _scan(namespace));

  Future<int> _scan(String namespace) async {
    checkAccount();
    onProgress?.call(const SmsInboxScanProgress());
    final throughId = await head();
    checkAccount();
    var captured = 0;
    var checked = 0;
    var lastId = progress.lastId(namespace);
    if (throughId < lastId) {
      // Detect provider restoration before deciding whether a slice is due.
      // The old checkpoint belongs to a different local ID range.
      progress.resetForProviderReset(namespace);
      lastId = 0;
    }
    var hasMore = throughId > lastId;
    while (hasMore) {
      final result = await _scanSlice(
        namespace,
        throughId: throughId,
        maxPages: 2,
        maxDuration: const Duration(milliseconds: 50),
        initialChecked: checked,
        initialCaptured: captured,
        emitInitialProgress: false,
      );
      captured += result.captured;
      checked += result.checked;
      hasMore = result.hasMore;
    }
    if (throughId == progress.lastId(namespace)) {
      progress.commit(namespace, throughId, complete: true);
      onProgress?.call(
        SmsInboxScanProgress(checked: checked, matched: captured, complete: true),
      );
    }
    return captured;
  }

  /// Processes one bounded catch-up slice. The returned [boundary] must be
  /// supplied to the next call for a stable snapshot. The old [scan] method
  /// remains available for compatibility and drains these slices sequentially.
  Future<SmsInboxScanSliceResult> scanSlice(
    String namespace, {
    int? throughId,
    int maxPages = 2,
    Duration maxDuration = const Duration(milliseconds: 50),
    int initialChecked = 0,
    int initialCaptured = 0,
  }) => AccountRecoveryOperationGate.process.run(
    () => _scanSlice(
      namespace,
      throughId: throughId,
      maxPages: maxPages,
      maxDuration: maxDuration,
      initialChecked: initialChecked,
      initialCaptured: initialCaptured,
    ),
  );

  Future<SmsInboxScanSliceResult> _scanSlice(
    String namespace, {
    int? throughId,
    required int maxPages,
    required Duration maxDuration,
    int initialChecked = 0,
    int initialCaptured = 0,
    bool emitInitialProgress = true,
  }) async {
    if (maxPages <= 0) throw ArgumentError.value(maxPages, 'maxPages');
    if (maxDuration <= Duration.zero) {
      throw ArgumentError.value(maxDuration, 'maxDuration');
    }
    checkAccount();
    if (emitInitialProgress) {
      onProgress?.call(
        SmsInboxScanProgress(
          checked: initialChecked,
          matched: initialCaptured,
        ),
      );
    }
    final boundary = throughId ?? await head();
    checkAccount();
    var afterId = progress.lastId(namespace);
    if (boundary < afterId) {
      // The provider's ID range moved backwards (for example after an SMS
      // database restore). Replay from zero; capture remains idempotent.
      progress.resetForProviderReset(namespace);
      afterId = 0;
    }
    var captured = 0;
    var checked = 0;
    var pages = 0;
    final started = DateTime.now();
    while (afterId < boundary && pages < maxPages) {
      final page = await read(afterId, boundary);
      checkAccount();
      if (page.rowCount == 0) {
        // Deleted rows are gaps, not a reason to revisit older messages.
        afterId = boundary;
        break;
      }
      if (page.lastId <= afterId || page.lastId > boundary) {
        throw StateError('SMS scan did not advance');
      }
      await capture(page.messages);
      checkAccount();
      // A crash before this commit may replay this one page, idempotently.
      final maxTimestamp = page.messages.isEmpty
          ? 0
          : page.messages
              .map((m) => m.receivedAt.millisecondsSinceEpoch)
              .fold<int>(0, (max, ts) => ts > max ? ts : max);
      progress.commit(namespace, page.lastId, timestamp: maxTimestamp);
      afterId = page.lastId;
      captured += page.messages.length;
      checked += page.rowCount;
      pages++;
      onProgress?.call(
        SmsInboxScanProgress(
          checked: initialChecked + checked,
          matched: initialCaptured + captured,
        ),
      );
      if (afterId < boundary &&
          DateTime.now().difference(started) >= maxDuration) {
        break;
      }
      // Yield between micro-batches so rendering and touch events can run.
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    final hasMore = afterId < boundary;
    if (!hasMore) {
      progress.commit(namespace, boundary, complete: true);
    }
    onProgress?.call(
      SmsInboxScanProgress(
        checked: initialChecked + checked,
        matched: initialCaptured + captured,
        complete: !hasMore,
      ),
    );
    return SmsInboxScanSliceResult(
      captured: captured,
      checked: checked,
      boundary: boundary,
      lastProviderId: afterId,
      pages: pages,
      hasMore: hasMore,
    );
  }
}
