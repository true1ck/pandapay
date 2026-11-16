import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/personal/personal_rule_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/capture_executor.dart';
import 'package:pandapay/features/sms_v2/pipeline/reading_refresh.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// Messages read under older rules are read again when the rules in force read
// them differently, and only then: unchanged readings, banks whose rules did
// not change, and messages the person acted on are left exactly as they are.
void main() {
  const namespace = 'user:reread';
  const overlay = 'overlay-1';
  const categories = {'other': 'cat-other', 'dining': 'cat-dining'};
  late AppDatabase database;
  late Database db;
  late FinancialStore financial;
  late RuleBundle bundle;
  late QueuedSms message;
  late Directory dir;
  late SyncStateStore state;
  late PersonalRuleStore personal;
  final engine = RuleEngine();

  void open() {
    database = AppDatabase.forTesting(sqlite3.open('${dir.path}/app.db'));
    db = database.db;
    financial = FinancialStore(database);
    SmsV2Schema.ensure(db);
    SmsIntakeRepository(database);
    state = SyncStateStore(db, namespace: namespace);
    personal = PersonalRuleStore(state);
  }

  /// The app closed and opened again: nothing decoded earlier is kept.
  void reopen() {
    financial.dispose();
    db.dispose();
    open();
  }

  void run({
    List<QueuedSms> messages = const [],
    bool refreshReadings = false,
    String overlayRevision = overlay,
  }) => runCaptureChunk(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
    overlayRevision: overlayRevision,
    engine: engine,
    personalRules: personal,
    appVersion: '2',
    categoryIdBySlug: categories,
    groups: [
      if (messages.isNotEmpty) CaptureGroup(backfill: true, messages: messages),
    ],
    ownerNames: const [],
    refreshReadings: refreshReadings,
  );

  String pass([String overlayRevision = overlay]) =>
      ReadingRefresh.passRevisionFor(
        '$overlayRevision:personal:${personal.revision}',
      );

  /// Runs slices until the pass for [overlayRevision] is done.
  int refreshAll([String overlayRevision = overlay]) {
    var slices = 0;
    while (ReadingRefresh.isPending(state, pass(overlayRevision))) {
      run(refreshReadings: true, overlayRevision: overlayRevision);
      if (++slices > 50) fail('the pass did not end');
    }
    return slices;
  }

  List<Map<String, Object?>> movementFacts() => [
    for (final row in db.select(
      "SELECT fact_id, payload FROM v2_facts WHERE namespace=? AND fact_type='movement'",
      [namespace],
    ))
      (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
  ];

  /// What a reading by an older rule version left behind: the same message,
  /// stored with a different shape (here, another payee).
  void storeOlderReading() {
    for (final row in db.select(
      "SELECT fact_id, payload FROM v2_facts WHERE namespace=? AND fact_type='movement'",
      [namespace],
    )) {
      final j = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>();
      final counterparty = (j['counterparty'] as Map?)?.cast<String, Object?>();
      j['counterparty'] = {...?counterparty, 'name': 'OLD READING'};
      db.execute(
        'UPDATE v2_facts SET payload=? WHERE namespace=? AND fact_id=?',
        [jsonEncode(j), namespace, row['fact_id']],
      );
    }
    reopen();
  }

  String? payee() =>
      ((movementFacts().single['counterparty'] as Map?)?['name']) as String?;

  Map<String, Object?> row() =>
      financial.entities(namespace, 'transactions').single;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reading_refresh');
    open();
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    message = QueuedSms(
      sender: 'VM-HDFCBK-S',
      body: bundle.rules.first.examples.first.body,
      receivedAt: DateTime.utc(2026, 11, 1, 7),
    );
    run(messages: [message]);
    expect(movementFacts(), hasLength(1));
  });
  tearDown(() {
    financial.dispose();
    db.dispose();
    dir.deleteSync(recursive: true);
  });

  test('a reading the rules in force no longer give is read again', () {
    final current = payee();
    storeOlderReading();
    expect(payee(), 'OLD READING');
    refreshAll();
    expect(payee(), current);
    expect(row()['status'], 'active');
    expect(row()['merchant_name'], isNot('OLD READING'));
  });

  test('a reading that is still right is not touched', () {
    final before = db
        .select('SELECT fact_id FROM v2_facts WHERE namespace=?', [namespace])
        .map((r) => r['fact_id'])
        .toList();
    final rowBefore = jsonEncode(row());
    refreshAll();
    final after = db
        .select('SELECT fact_id FROM v2_facts WHERE namespace=?', [namespace])
        .map((r) => r['fact_id'])
        .toList();
    expect(after, before);
    expect(jsonEncode(row()), rowBefore);
  });

  test('a finished pass is not repeated for the same rules', () {
    refreshAll();
    storeOlderReading();
    // Same rules in force: the bank's fingerprint is recorded, nothing to do.
    expect(ReadingRefresh.isPending(state, pass()), isFalse);
    expect(refreshAll(), 0);
    expect(payee(), 'OLD READING');
  });

  test('new rules for another bank leave this bank alone', () {
    refreshAll();
    storeOlderReading();
    // A new rule set whose only change is a rule for another sender.
    final changed = RuleBundle.fromJson({
      ...bundle.toJson(),
      'rules': [
        ...bundle.rules.map((r) => r.toJson()),
        {
          ...bundle.rules.first.toJson(),
          'id': 'OTHER-BANK-NEW-1',
          'senders': ['SOMEOTHERBANK'],
        },
      ],
    });
    bundle = changed;
    refreshAll('overlay-2');
    expect(payee(), 'OLD READING');
  });

  test('a change to this bank\'s rules makes its messages be checked again', () {
    refreshAll();
    storeOlderReading();
    final first = bundle.rules.first.toJson();
    bundle = RuleBundle.fromJson({
      ...bundle.toJson(),
      'rules': [
        {...first, 'version': (first['version'] as int) + 1},
        ...bundle.rules.skip(1).map((r) => r.toJson()),
      ],
    });
    refreshAll('overlay-2');
    expect(payee(), isNot('OLD READING'));
  });

  test('a message the person acted on keeps their version', () {
    storeOlderReading();
    final r = row();
    db.execute(
      "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
      [
        jsonEncode({...r, 'note': 'mine'}),
        namespace,
        r['id'],
      ],
    );
    refreshAll();
    expect(payee(), 'OLD READING');
    expect(row()['note'], 'mine');
  });

  test('a pass over many messages runs in slices and finishes', () {
    final more = [
      for (var i = 0; i < 5; i++)
        QueuedSms(
          sender: 'VM-HDFCBK-S',
          body: bundle.rules.first.examples.first.body.replaceFirst(
            RegExp(r'\d+(\.\d+)?'),
            '${200 + i}',
          ),
          receivedAt: DateTime.utc(2026, 11, 2 + i, 7),
        ),
    ];
    run(messages: more);
    storeOlderReading();
    var slices = 0;
    while (ReadingRefresh.isPending(state, pass())) {
      runCaptureChunk(
        financial: financial,
        namespace: namespace,
        bundle: bundle,
        overlayRevision: overlay,
        engine: engine,
        personalRules: personal,
        appVersion: '2',
        categoryIdBySlug: categories,
        groups: const [],
        ownerNames: const [],
        refreshReadings: true,
      );
      slices++;
      if (slices > 50) fail('the pass did not end');
    }
    expect(
      movementFacts().where(
        (f) => (f['counterparty'] as Map?)?['name'] == 'OLD READING',
      ),
      isEmpty,
    );
  });

}
