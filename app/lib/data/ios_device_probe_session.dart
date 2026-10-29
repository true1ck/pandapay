import '../features/sms_import/ios_shortcut_sms.dart';
import 'local/app_database.dart';
import 'local/financial_store.dart';
import 'local/sms_import_store.dart';
import 'local/sms_intake_repository.dart';

class IosProbeSource {
  final String sender, body, senderEvidence;
  final DateTime date;
  final DateTime? capturedAt;
  final bool senderInferred;
  const IosProbeSource({
    required this.sender,
    required this.body,
    required this.date,
    required this.senderEvidence,
    required this.senderInferred,
    this.capturedAt,
  });
}

class IosProbeRunResults {
  int handedOff = 0, retainedAdded = 0, existing = 0, ignored = 0;
  int transactionsAdded = 0, missingDate = 0, invalid = 0, sensitive = 0;
  final sourceKeys = <String>{};
}

/// Actual shared intake, in a disposable DB. Metadata stays separate from the
/// Android contract so inferred sender and capture time never become evidence.
class IosDeviceProbeSession {
  static const namespace = 'user:isolated-ios-device-probe';
  final AppDatabase database;
  late final FinancialStore store = FinancialStore(database);
  final _seenTransportIds = <String>{};
  final _sources = <String, IosProbeSource>{};
  final _runSources = <String, Map<String, List<IosProbeSource>>>{};
  final runs = <String, IosProbeRunResults>{};
  int received = 0,
      complete = 0,
      incomplete = 0,
      missingSender = 0,
      missingDate = 0;
  int sensitive = 0, invalid = 0;

  IosDeviceProbeSession(this.database);

  void accept(List<Map<Object?, Object?>> rows) {
    final ids = {..._seenTransportIds};
    final groups = <String, List<Map<Object?, Object?>>>{};
    for (final row in rows) {
      final id = row['id'];
      if (id is String && !ids.add(id)) continue;
      (groups[row['runId'] as String? ?? 'legacy'] ??= []).add(row);
    }
    for (final group in groups.entries) {
      final batch = IosShortcutSmsBatch.fromRows(group.value);
      final result = runs.putIfAbsent(group.key, IosProbeRunResults.new);
      final before = counts.captured;
      final txBefore = transactions;
      final retainedBefore = _retainedKeys;
      final classifiedKeys = {...retainedBefore};
      SmsImportStore(store).captureBatch(namespace, batch.messages);
      final retainedAfter = _retainedKeys;
      for (var i = 0; i < batch.messages.length; i++) {
        final message = batch.messages[i];
        final row = batch.sourceRows[i];
        final key = smsSourceKey(namespace, message.sender, message.body);
        if (!retainedAfter.contains(key)) {
          result.ignored++;
          continue;
        }
        result.sourceKeys.add(key);
        if (!classifiedKeys.add(key)) result.existing++;
        final source = IosProbeSource(
          sender: message.sender,
          body: message.body,
          date: message.receivedAt,
          senderEvidence: row['senderEvidence'] as String? ?? 'text',
          senderInferred: row['senderInferred'] == true,
          capturedAt: DateTime.tryParse(row['capturedAt'] as String? ?? ''),
        );
        _sources.putIfAbsent(key, () => source);
        final sources = (_runSources.putIfAbsent(group.key, () => {})[key] ??=
            []);
        if (!sources.any((previous) => previous.date == source.date)) {
          sources.add(source);
        }
      }
      for (final row in group.value) {
        if (row['id'] case final String id) _seenTransportIds.add(id);
      }
      result.handedOff += batch.total;
      result.retainedAdded += counts.captured - before;
      result.transactionsAdded += transactions - txBefore;
      result.missingDate += batch.missingDate;
      result.invalid += batch.invalid;
      result.sensitive += batch.sensitive;
      received += batch.total;
      complete += batch.messages.length;
      incomplete += batch.incomplete;
      missingSender += batch.missingSender;
      missingDate += batch.missingDate;
      sensitive += batch.sensitive;
      invalid += batch.invalid;
    }
  }

  Set<String> get _retainedKeys => {
    for (final row in database.db.select(
      'SELECT id FROM sms_captured_messages WHERE namespace=?',
      [namespace],
    ))
      row['id'] as String,
  };

  ({int captured, int pending}) get counts =>
      SmsIntakeRepository(database).counts(namespace);
  List<Map<String, dynamic>> get observations =>
      store.entities(namespace, 'sms_observations');
  List<Map<String, dynamic>> get transactionList =>
      store.entities(namespace, 'transactions');
  int get transactions => transactionList.length;
  int get reviewCount =>
      database.db.select(
            'SELECT COUNT(*) AS n FROM local_needs_review WHERE namespace=?',
            [namespace],
          ).single['n']
          as int;

  List<IosProbeSource> get retainedInputs => [
    for (final key in _retainedKeys) ?_sources[key],
  ];

  Set<String> sourceKeysForTransaction(Map<String, dynamic> tx) => {
    if (tx['source_key'] case final String key) key,
    if (tx['observations'] case final List observations)
      for (final observation in observations)
        if (observation is Map && observation['source_key'] is String)
          observation['source_key'] as String,
  };

  List<Map<String, dynamic>> transactionsForRun(String id) {
    final keys = runs[id]?.sourceKeys ?? <String>{};
    return transactionList
        .where((tx) => sourceKeysForTransaction(tx).any(keys.contains))
        .toList();
  }

  List<IosProbeSource> retainedInputsForRun(String id) => [
    for (final sources in (_runSources[id] ?? {}).values) ...sources,
  ];

  /// Exact keys only. A repeated canonical source can have multiple receive
  /// records in one run; retain them all rather than choosing a date by guess.
  List<IosProbeSource> sourcesForTransaction(
    Map<String, dynamic> tx, {
    String? runId,
  }) => [
    for (final key in sourceKeysForTransaction(tx))
      if (runId != null) ...?_runSources[runId]?[key] else ?_sources[key],
  ];
  IosProbeSource? findSourceMessage(Map<String, dynamic> tx, {String? runId}) {
    final sources = sourcesForTransaction(tx, runId: runId);
    return sources.length == 1 ? sources.single : null;
  }

  String? findSourceBody(Map<String, dynamic> tx) =>
      findSourceMessage(tx)?.body;
  void dispose() {
    store.dispose();
    database.close();
  }
}
