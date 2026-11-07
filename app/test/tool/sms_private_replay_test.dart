// Full-pipeline replay of a PRIVATE message corpus through the real phone
// runtime: interpret, instruments, linker and ledger, in an in-memory
// database. It skips unless SMS_PRIVATE_DIR is set, so it is inert in CI.
//
// Reads (inside SMS_PRIVATE_DIR):
//   $SMS_BUNDLE (default bundle.json)   a built rule bundle
//   $SMS_SAMPLE (default label-sample.drafted.jsonl)  labeled sample rows
//   $SMS_CORPUS (default sms.jsonl)     the full corpus, one message per line
// Optional: $SMS_OWNER_NAMES, comma-separated names of the account owner, as
// the profile would hold them (transfers under these names are the owner's own).
// Writes only inside SMS_PRIVATE_DIR, owner-readable only:
//   $SMS_REPLAY_PREFIX-sample-phone.json and $SMS_REPLAY_PREFIX-corpus-phone.json
//   (prefix default `replay`). The sample file is the optional fourth argument
//   of tools/sms_rules_cli/tool/score_private.dart.
// Nothing is printed except counts. See tools/sms_rules_cli/README.md.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

const _contributing = {'debit_leg', 'credit_leg', 'reversal', 'charge'};

String _sender(Map row) => row['iosFilter'] == null
    ? row['sender'] as String
    : "${row['sender']}(${row['iosFilter']})";

/// Replays [rows] and returns the report the scorer reads.
Future<Map<String, Object?>> replay(
  List<Map> rows,
  String encoded,
  RuleBundle bundle, {
  List<String> ownerNames = const [],
}) async {
  final ordered = [...rows]
    ..sort(
      (a, b) =>
          (a['observedAt'] as String).compareTo(b['observedAt'] as String),
    );
  final database = AppDatabase.forTesting(sqlite3.openInMemory());
  final financial = FinancialStore(database);
  const ns = 'user:private-replay';
  try {
    final runtime = SmsV2Runtime(
      financial: financial,
      namespace: ns,
      client: MockClient((_) async => throw StateError('offline')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'private-replay',
      appVersion: '2.0.0',
      headers: () async => {},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      ownerNames: () => ownerNames,
    );
    await runtime.capture([
      for (final raw in ordered)
        QueuedSms(
          sender: _sender(raw),
          body: raw['body'] as String,
          receivedAt: DateTime.parse(raw['observedAt'] as String),
        ),
    ], backfill: true);
    final ledgerStore = LedgerStore(database.db, namespace: ns);
    final snapshot = LedgerSnapshot(
      events: EventStore(
        database.db,
        namespace: ns,
      ).listSince(DateTime.utc(1900)),
      entries: ledgerStore.list(),
      categoryByEvent: ledgerStore.categoryDecisions(),
    );
    final totals = snapshot.totals(DateTime.utc(1900), DateTime.utc(2100));
    final review = database.db.select(
      "SELECT kind,count(*) AS n FROM v2_review_items WHERE namespace=? AND status='open' GROUP BY kind",
      [ns],
    );
    final sources = {
      for (final row in database.db.select(
        'SELECT fact_id,source_key FROM v2_facts WHERE namespace=?',
        [ns],
      ))
        row['fact_id']: row['source_key'],
    };
    final entries = <String, List<Map<String, Object?>>>{};
    for (final entry in snapshot.entries) {
      entries.putIfAbsent(entry.eventId, () => []).add(entry.toJson());
    }
    final bySource = <Object?, List<Map<String, Object?>>>{};
    final countedFactEvents = <String, Set<String>>{};
    final eventTypes = <String, int>{};
    var billsAsSpend = 0;
    var ipoAsSpend = 0;
    for (final event in snapshot.events) {
      final ledger = entries[event.eventId] ?? [];
      eventTypes.update(event.type.wire, (n) => n + 1, ifAbsent: () => 1);
      if (event.type == EventType.cardBillPayment &&
          ledger.any((e) => e['isSpend'] == true)) {
        billsAsSpend++;
      }
      if (event.type == EventType.ipoApplication &&
          ledger.any((e) => e['isSpend'] == true)) {
        ipoAsSpend++;
      }
      for (final leg in event.legs) {
        final source = sources[leg.factId];
        if (source == null) continue;
        bySource.putIfAbsent(source, () => []).add({
          'eventId': event.eventId,
          'type': event.type.wire,
          'role': leg.role.wire,
          'ledger': ledger,
        });
        if (ledger.any((e) => e['countsAsTransaction'] == true) &&
            _contributing.contains(leg.role.wire)) {
          countedFactEvents
              .putIfAbsent(leg.factId, () => {})
              .add(event.eventId);
        }
      }
    }
    final intake = SmsIntakeRepository(database);
    final decisions = <String, int>{};
    final outcomes = [
      for (final (i, raw) in rows.indexed)
        (() {
          final key = smsSourceKey(ns, _sender(raw), raw['body'] as String);
          final decision = intake.decision(ns, key)?.decision;
          decisions.update('$decision', (n) => n + 1, ifAbsent: () => 1);
          return {
            'index': i,
            'decision': decision,
            'events': bySource[key] ?? [],
          };
        })(),
    ];
    return {
      'rows': rows.length,
      'reviewItems': [for (final r in review) Map.of(r)],
      'transactionCount': totals.transactionCount,
      'reusedMoneyFacts': countedFactEvents.values
          .where((ids) => ids.length > 1)
          .length,
      'cardBillsCountedAsSpend': billsAsSpend,
      'ipoEventsCountedAsSpend': ipoAsSpend,
      'totals': {
        'spendMinor': totals.spendMinor,
        'incomeMinor': totals.incomeMinor,
        'investmentMinor': totals.investmentMinor,
      },
      'eventTypes': eventTypes,
      'decisions': decisions,
      'outcomes': outcomes,
    };
  } finally {
    financial.dispose();
    database.db.dispose();
  }
}

void writePrivate(String path, Object json) {
  final file = File(path);
  if (!file.existsSync()) file.createSync(exclusive: true);
  Process.runSync('chmod', ['600', path]);
  file.writeAsStringSync(jsonEncode(json));
}

void main() {
  final dir = Platform.environment['SMS_PRIVATE_DIR'];
  final skip = dir == null || dir.isEmpty
      ? 'Set SMS_PRIVATE_DIR to a private folder to replay a private corpus.'
      : false;

  test(
    'private corpus replay through the real phone pipeline',
    () async {
      final env = Platform.environment;
      final base = Directory(dir!).resolveSymbolicLinksSync();
      final prefix = env['SMS_REPLAY_PREFIX'] ?? 'replay';
      final ownerNames = [
        for (final name in (env['SMS_OWNER_NAMES'] ?? '').split(','))
          if (name.trim().isNotEmpty) name.trim(),
      ];
      final encoded = File(
        '$base/${env['SMS_BUNDLE'] ?? 'bundle.json'}',
      ).readAsStringSync();
      final bundle = RuleBundle.fromJson(
        (jsonDecode(encoded) as Map).cast<String, Object?>(),
      );
      final samplePath =
          '$base/${env['SMS_SAMPLE'] ?? 'label-sample.drafted.jsonl'}';
      final corpusPath = '$base/${env['SMS_CORPUS'] ?? 'sms.jsonl'}';
      var ran = 0;
      if (File(samplePath).existsSync()) {
        final rows = [
          for (final line in File(samplePath).readAsLinesSync())
            ((jsonDecode(line) as Map)['message'] as Map),
        ];
        final report = await replay(
          rows,
          encoded,
          bundle,
          ownerNames: ownerNames,
        );
        writePrivate('$base/$prefix-sample-phone.json', report);
        printOnSuccess(
          'sample rows=${rows.length} transactions=${report['transactionCount']}',
        );
        ran++;
      }
      if (env['SMS_REPLAY_CORPUS'] != '0' && File(corpusPath).existsSync()) {
        final rows = [
          for (final line in File(corpusPath).readAsLinesSync())
            jsonDecode(line) as Map,
        ];
        final report = await replay(
          rows,
          encoded,
          bundle,
          ownerNames: ownerNames,
        );
        writePrivate('$base/$prefix-corpus-phone.json', report);
        printOnSuccess(
          'corpus rows=${rows.length} transactions=${report['transactionCount']}',
        );
        ran++;
      }
      expect(
        ran,
        greaterThan(0),
        reason: 'no sample or corpus found in the private folder',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

void printOnSuccess(String line) => stdout.writeln('[replay] $line');
