import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/portable_backup/account_recovery_operation_gate.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/capture_executor.dart';
import 'package:pandapay/features/sms_v2/pipeline/capture_worker.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/personal/personal_rule_engine.dart';
import 'package:pandapay/features/sms_v2/personal/personal_rule_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:capture';
final _uuid = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
);
final _now = DateTime.utc(2026, 11, 30, 12);

/// Wraps an executor to inject a worker fault into every request.
class _Faulty implements CaptureExecutor {
  _Faulty(this.inner, this.fault);
  final CaptureExecutor inner;
  final String fault;
  @override
  Future<void> run(CaptureChunkRequest r) => inner.run(
    CaptureChunkRequest(
      namespace: r.namespace,
      appVersion: r.appVersion,
      categoryIdBySlug: r.categoryIdBySlug,
      session: r.session,
      shared: r.shared,
      groups: r.groups,
      onCommitted: r.onCommitted,
      debugFault: fault,
    ),
  );
  @override
  Future<void> close() => inner.close();
}

/// Runs [then] after each successful chunk (e.g. to switch the account).
class _AfterChunk implements CaptureExecutor {
  _AfterChunk(this.inner, this.then);
  final CaptureExecutor inner;
  final void Function() then;
  @override
  Future<void> run(CaptureChunkRequest r) async {
    await inner.run(r);
    then();
  }

  @override
  Future<void> close() => inner.close();
}

class _Env {
  _Env(this.directory, this.name, this.bundle, {this.current = _always});
  final Directory directory;
  final String name;
  final RuleBundle bundle;
  final bool Function() current;
  static bool _always() => true;
  late final AppDatabase database = AppDatabase.openUnencryptedFileForTesting(
    '${directory.path}/$name.sqlite',
  );
  late final FinancialStore financial = FinancialStore(database);

  SmsV2Runtime runtime({CaptureExecutor? executor}) {
    final encoded = jsonEncode(bundle.toJson());
    return SmsV2Runtime(
      financial: financial,
      namespace: _ns,
      client: MockClient((_) async => throw StateError('offline')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'device',
      appVersion: '2',
      headers: () async => {},
      verify: (value) async => value == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: current,
      clock: () => _now,
      captureExecutor: executor,
    );
  }

  InProcessCaptureExecutor inProcess() {
    final personal = PersonalRuleStore(
      SyncStateStore(database.db, namespace: _ns),
    );
    return InProcessCaptureExecutor(
      financial: financial,
      namespace: _ns,
      engine: PersonalRuleEngine(
        store: personal,
        instruments: InstrumentStore(database.db, namespace: _ns),
      ),
      personalRules: personal,
    );
  }

  /// Puts the messages in `sms_intake` like a live receiver does (no pipeline).
  void deliver(List<QueuedSms> messages) =>
      SmsImportStore(financial).captureBatch(_ns, messages);

  int pending() =>
      SmsIntakeRepository(database).pending(_ns, limit: 100000).length;

  void dispose() {
    financial.dispose();
    database.close();
  }
}

/// A realistic mixed batch: card spends (history and live), repeats, an OTP,
/// a promotion, an unknown sender and an unparseable bank-looking text.
List<QueuedSms> _messages(int count) => [
  for (var i = 0; i < count; i++)
    switch (i % 10) {
      3 => QueuedSms(
        sender: 'VM-HDFCBK-S',
        body: 'OTP is ${100000 + i} for txn of Rs.${i + 1}.00. Do not share.',
        receivedAt: DateTime.utc(2026, 11, 1, 7).add(Duration(minutes: i)),
      ),
      5 => QueuedSms(
        sender: 'AX-OFFERS',
        body: 'Get 50% off on shopping this weekend! Use code SAVE$i',
        receivedAt: DateTime.utc(2026, 11, 1, 7).add(Duration(minutes: i)),
      ),
      7 => QueuedSms(
        sender: 'VM-HDFCBK-S',
        body:
            'Rs.${i + 1}.00 spent on HDFC Bank Card x5678 at ZOMATO on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00',
        receivedAt: DateTime.utc(2026, 11, 29, 9).add(Duration(minutes: i)),
      ),
      9 => QueuedSms(
        sender: 'VM-HDFCBK-S',
        body: 'Your a/c XX1234 has an update number $i. Call us for details.',
        receivedAt: DateTime.utc(2026, 11, 1, 7).add(Duration(minutes: i)),
      ),
      _ => QueuedSms(
        sender: 'VM-HDFCBK-S',
        body:
            'Rs.${i + 1}.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00',
        receivedAt: DateTime.utc(2026, 11, 1, 7).add(Duration(minutes: i)),
      ),
    },
];

/// Every table, every column, in a stable order, minus wall-clock columns.
Map<String, List<String>> _dump(Database db) {
  const volatile = {'decided_at', 'fetched_at', 'created_at', 'updated_at'};
  final tables = [
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ))
      row['name'] as String,
  ];
  return {
    for (final table in tables)
      table: () {
        final rows = [
          for (final row in db.select('SELECT * FROM "$table"'))
            // Instrument ids are random v4 UUIDs; everything else is deterministic.
            jsonEncode({
              for (final entry in row.entries)
                if (!volatile.contains(entry.key) &&
                    // wall-clock write time of a display row (DateTime.now)
                    !(table == 'financial_entities' &&
                        entry.key == 'observed_at'))
                  entry.key: entry.value,
            }).replaceAll(_uuid, '<uuid>'),
        ]..sort();
        return rows;
      }(),
  };
}

void main() {
  void t(String name, Future<void> Function() body) =>
      test(name, body, timeout: const Timeout(Duration(minutes: 5)));

  late Directory directory;
  late RuleBundle bundle;
  final envs = <_Env>[];
  final workers = <SmsCaptureWorker>[];

  SmsCaptureWorker spawn(
    _Env e, {
    Duration? jobTimeout,
    AccountRecoveryOperationGate? gate,
    String? path,
  }) {
    final value = SmsCaptureWorker(
      path ?? e.database.filePath!,
      recoveryGate: gate,
      jobTimeout: jobTimeout ?? const Duration(seconds: 90),
    );
    workers.add(value);
    return value;
  }

  _Env env(String name, {bool Function()? current}) {
    final value = _Env(
      directory,
      name,
      bundle,
      current: current ?? _Env._always,
    );
    envs.add(value);
    return value;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pandapay-capture-');
    bundle = testRuleBundle();
  });

  tearDown(() async {
    for (final w in workers) {
      await w.close();
    }
    workers.clear();
    await SmsCaptureWorker.closeAllShared();
    for (final e in envs) {
      e.dispose();
    }
    envs.clear();
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A worker that died on purpose never closed its handle (Windows only).
    }
  });

  t('worker path stores exactly what the in-process path stores', () async {
    final messages = _messages(410); // three chunks, history and live mixed
    final reference = env('reference');
    reference.deliver(messages);
    await reference.runtime(executor: reference.inProcess()).capture(messages);

    final worker = env('worker');
    final changes = <String>{};
    final sub = worker.financial.changes.listen((c) => changes.add(c.entity));
    final executor = spawn(worker);
    worker.deliver(messages);
    await worker.runtime(executor: executor).capture(messages);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    final expected = _dump(reference.database.db);
    final actual = _dump(worker.database.db);
    expect(actual.keys, expected.keys);
    for (final table in expected.keys) {
      expect(actual[table], expected[table], reason: 'table $table differs');
    }
    // Sanity: the batch really produced ledger rows, decisions and acks.
    expect(expected['v2_facts'], isNotEmpty);
    expect(expected['v2_events'], isNotEmpty);
    expect(expected['v2_ledger'], isNotEmpty);
    expect(expected['sms_source_decisions'], isNotEmpty);
    expect(worker.pending(), 0);
    expect(reference.pending(), 0);

    // The UI connection reads the worker's committed rows ...
    final rows = worker.financial.entities(_ns, 'transactions');
    expect(rows, isNotEmpty);
    expect(
      rows.length,
      reference.financial.entities(_ns, 'transactions').length,
    );
    // ... and was told about every changed entity after the commit.
    expect(
      changes,
      containsAll(['observations', 'needs_review', 'transactions']),
    );
  });

  t(
    'a worker error rolls the chunk back and leaves messages pending',
    () async {
      final e = env('throw');
      final runtime = e.runtime(executor: _Faulty(spawn(e), 'throw'));
      final messages = _messages(60);
      e.deliver(messages);
      final before = e.pending();
      final decisions = e.database.db
          .select('SELECT COUNT(*) AS n FROM sms_source_decisions')
          .single['n'];
      expect(before, greaterThan(0));
      await expectLater(runtime.capture(messages), throwsStateError);
      expect(e.pending(), before);
      expect(e.database.db.select('SELECT 1 FROM v2_facts'), isEmpty);
      expect(
        e.database.db
            .select('SELECT COUNT(*) AS n FROM sms_source_decisions')
            .single['n'],
        decisions,
      );
      expect(e.financial.entities(_ns, 'transactions'), isEmpty);
      // The same worker is still healthy and a retry completes the work.
      final retry = e.runtime(executor: spawn(e));
      await retry.capture(messages);
      expect(e.pending(), 0);
      expect(e.financial.entities(_ns, 'transactions'), isNotEmpty);
    },
  );

  t('a dead worker leaves messages pending and the next run respawns', () async {
    final e = env('exit');
    final messages = _messages(40);
    e.deliver(messages);
    final before = e.pending();
    final dying = e.runtime(
      executor: _Faulty(PooledCaptureExecutor(e.database), 'exit'),
    );
    await expectLater(dying.capture(messages), throwsStateError);
    expect(e.pending(), before);
    expect(e.database.db.select('SELECT 1 FROM v2_facts'), isEmpty);
    // The default wiring (pooled shared worker) replaces the dead one.
    final healthy = e.runtime(executor: PooledCaptureExecutor(e.database));
    await healthy.capture(messages);
    expect(e.pending(), 0);
    expect(e.database.db.select('SELECT 1 FROM v2_facts'), isNotEmpty);
    // The UI connection can still write: no lock was left behind.
    e.database.db.execute(
      "INSERT OR REPLACE INTO profile_name_cache(namespace, display_name) VALUES('x','y')",
    );
  });

  t('a stalled worker times out and nothing is acknowledged', () async {
    final e = env('stall');
    final stalled = spawn(e, jobTimeout: const Duration(milliseconds: 300));
    final runtime = e.runtime(executor: _Faulty(stalled, 'stall'));
    final messages = _messages(30);
    e.deliver(messages);
    final before = e.pending();
    await expectLater(
      runtime.capture(messages),
      throwsA(isA<TimeoutException>()),
    );
    expect(e.pending(), before);
    expect(e.database.db.select('SELECT 1 FROM v2_facts'), isEmpty);
    await stalled.close(); // waits for the stalled job to finish and answer
  });

  t('an account change after a chunk stops later chunks', () async {
    var accountOk = true;
    final e = env('account', current: () => accountOk);
    final messages = _messages(410);
    e.deliver(messages);
    final runtime = e.runtime(
      executor: _AfterChunk(spawn(e), () => accountOk = false),
    );
    final before = e.pending();
    final decisionsBefore =
        e.database.db
                .select('SELECT COUNT(*) AS n FROM sms_source_decisions')
                .single['n']
            as int;
    await expectLater(runtime.capture(messages), throwsStateError);
    // The first 200 messages were captured and acknowledged atomically under
    // their own namespace; the remaining chunks were never sent.
    final after = e.pending();
    expect(after, lessThan(before));
    expect(after, greaterThan(0));
    final processed =
        e.database.db
                .select('SELECT COUNT(*) AS n FROM sms_source_decisions')
                .single['n']
            as int;
    expect(processed - decisionsBefore, inInclusiveRange(1, 200));
  });

  t('a dead account is refused before a chunk is dispatched', () async {
    final e = env('refused', current: () => false);
    final messages = _messages(20);
    e.deliver(messages);
    final runtime = e.runtime(executor: spawn(e));
    await expectLater(runtime.capture(messages), throwsStateError);
    expect(e.pending(), greaterThan(0));
    expect(e.database.db.select('SELECT 1 FROM v2_facts'), isEmpty);
  });

  t('a worker that cannot start falls back to the in-process path', () async {
    final e = env('fallback');
    final broken = spawn(e, path: '${directory.path}/missing/dir/x.sqlite');
    final fallback = FallbackCaptureExecutor(
      primary: broken,
      fallback: e.inProcess(),
    );
    final messages = _messages(30);
    e.deliver(messages);
    await e.runtime(executor: fallback).capture(messages);
    expect(e.pending(), 0);
    expect(e.financial.entities(_ns, 'transactions'), isNotEmpty);
  });

  t('default wiring: a file database uses the shared worker', () async {
    final messages = _messages(120);
    final reference = env('default-reference');
    reference.deliver(messages);
    await reference.runtime(executor: reference.inProcess()).capture(messages);
    final e = env('default');
    e.deliver(messages);
    await e.runtime().capture(
      messages,
    ); // no executor: file db => pooled worker
    expect(e.pending(), 0);
    expect(
      _dump(e.database.db)['v2_ledger'],
      _dump(reference.database.db)['v2_ledger'],
    );
    expect(
      _dump(e.database.db)['financial_entities'],
      _dump(reference.database.db)['financial_entities'],
    );
  });

  t('recovery admission is held while a job is in flight', () async {
    final e = env('gate');
    final gate = AccountRecoveryOperationGate();
    final runtime = e.runtime(executor: _Faulty(spawn(e, gate: gate), 'stall'));
    final messages = _messages(30);
    e.deliver(messages);
    final done = runtime.capture(messages);
    final failed = expectLater(done, throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(gate.activeOperations, 1);
    await failed;
    expect(gate.activeOperations, 0);
  });
}
