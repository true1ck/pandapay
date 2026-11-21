// Review fixes for the three-tab model, on the phone through the real runtime with a fake server: a message is in
// exactly one place, a recovered AI transaction is withdrawn like an untouched one when its rule is rejected, a
// double Dismiss cannot lose the saved event, a restore from Activity is still AI auto-resolved, and the AI tag
// follows the card. All data is invented.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TransactionEntry;
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart' show LedgerReadModel;
import 'package:pandapay/features/sms_v2/pipeline/trace.dart' show CorrectionKind;
import 'package:pandapay/features/sms_v2/providers/data_providers.dart' show LocalReviewItem, readDismissedReviewItems;
import 'package:pandapay/features/sms_v2/storage/dismissal_store.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/ui/auto_dismissal_actions.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay/features/sms_v2/ui/transaction_actions.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart';
import 'package:pandapay/features/sms_v2/sync/template_retry.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:ai';

QueuedSms _msg(String shop, int rupees, int minute) => QueuedSms(
  sender: 'AX-HDFCBK-S',
  body:
      'Sent Rs.$rupees.00 from HDFC Bank A/c XX1234 to $shop on 20-11-26. Ref 61234567890$minute.',
  receivedAt: DateTime.utc(2026, 11, 20, 7, minute),
);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late SmsV2Runtime runtime;
  late SyncStateStore state;
  var consent = true;
  var clockNow = DateTime.utc(2026, 11, 20, 12);
  var aiStatus = 'none'; // none | pending | ready | rejected | failed
  var brokenPage = false; // the sync page carries a row this phone cannot read
  String? servedBundle;
  final uploaded = <String>[]; // remote template hashes the phone sent
  final fixture =
      (jsonDecode(
                File(
                  'test/features/sms_v2/fixtures/real_gemini_rule.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  // A rule set that reads nothing: every message of this layout is unknown.
  final baseline = <String, Object?>{
    ...(jsonDecode(
              File(
                '../contracts/sms/v2/fixtures/valid/bundle/full.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>(),
    'rules': <Object?>[],
    'categoryRules': <Object?>[],
  };
  final signature =
      ((jsonDecode(
                    File(
                      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)['signature']
              as Map)
          .cast<String, Object?>();

  // What the draft says about itself: how sure it is, and which way it says the money went.
  double? draftConfidence;
  bool attemptMode = false; // the draft reads the message as a failed attempt: no transaction
  String? draftDirection;

  Map<String, Object?> ruleFor(String hash, {String status = 'provisional'}) {
    final rule = (jsonDecode(jsonEncode(fixture['rule'])) as Map)
        .cast<String, Object?>();
    final emit = (rule['emit'] as List).cast<Map>().single;
    return {
      ...rule,
      'id': 'AI-$hash',
      'status': status,
      'match': {...(rule['match'] as Map), 'templateHash': hash},
      if (draftConfidence != null) 'confidence': draftConfidence,
      if (attemptMode)
        'emit': [
          {
            ...emit,
            'factType': 'attempt',
            'attrs': {'status': 'failed', 'direction': 'debit', 'purpose': 'purchase'},
          },
        ],
      if (draftDirection != null)
        'emit': [
          {
            ...emit,
            'attrs': {
              ...(emit['attrs'] as Map),
              'direction': draftDirection,
              if (draftDirection == 'credit') 'purpose': 'refund',
            },
          },
        ],
    };
  }

  http.Response server(http.Request request) {
    switch (request.url.path) {
      case '/sms/v2/rules':
        return servedBundle == null
            ? http.Response('', 304)
            : http.Response.bytes(utf8.encode(servedBundle!), 200);
      case '/sms/v2/unknown-templates':
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        for (final item in items) {
          uploaded.add((item as Map)['templateHash'] as String);
        }
        return http.Response(
          jsonEncode({
            'accepted': [
              for (final item in items) (item as Map)['templateHash'],
            ],
          }),
          202,
        );
      case '/sms/v2/facts:batch':
        final body =
            jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
        return http.Response(
          jsonEncode({
            'results': [
              for (final item in body['items'])
                for (final fact in item['facts'])
                  {'kind': 'fact', 'id': fact['factId'], 'status': 'accepted'},
              for (final (key, kind, id) in [
                ('instruments', 'instrument', 'instrumentId'),
                ('events', 'event', 'eventId'),
                ('ledger', 'ledger', 'entryId'),
              ])
                for (final row in body[key])
                  {'kind': kind, 'id': row[id], 'status': 'accepted'},
            ],
          }),
          200,
        );
      case '/sms/v2/rule-stats:batch':
        return http.Response('{}', 202);
      case '/sms/v2/learning-signals':
        return http.Response('{"accepted":1}', 202);
      case '/sms/v2/sync':
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'cursor': 'one',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [
                if (brokenPage) <String, Object?>{'bogus': true},
              ],
              'aiResults': [
                if (aiStatus != 'none')
                  for (final hash in uploaded.toSet())
                    {
                      'templateHash': hash,
                      'status': aiStatus,
                      if (aiStatus == 'ready') ...{
                        'ruleId': 'AI-$hash',
                        'ruleVersion': 1,
                        'rule': ruleFor(hash),
                      },
                    },
              ],
              'corrections': [],
              'latestBundleVersion': servedBundle == null ? 1 : 2,
            }),
          ),
          200,
        );
      default:
        fail('Unexpected endpoint ${request.url.path}');
    }
  }

  Future<void> sync() => runtime.sync();

  int spendMinor() {
    var total = 0;
    for (final row in database.db.select(
      'SELECT payload FROM v2_ledger WHERE namespace=?',
      [_namespace],
    )) {
      total +=
          ((jsonDecode(row['payload'] as String) as Map)['amountMinor'] as num)
              .toInt();
    }
    return total;
  }

  List<Map<String, Object?>> openTemplateReviews() => [
    for (final row in database.db.select(
      "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status!='resolved'",
      [_namespace],
    ))
      (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
  ];

  /// The AI rule that read a message, from the traces saved when it was read. A confident AI reading no longer
  /// leaves an open review item, so the trace is the one place to ask.
  AiResolution? resolutionOfFirst({Set<String> shared = const {}}) {
    for (final row in database.db.select(
      "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%'",
      [_namespace],
    )) {
      final r = AiStatusReader(state).resolution(
        (row['key'] as String).substring('trace:'.length),
        sharedRuleIds: shared,
      );
      if (r != null) return r;
    }
    return null;
  }

  setUp(() async {
    consent = true;
    draftConfidence = null;
    attemptMode = false;
    draftDirection = null;
    clockNow = DateTime.utc(2026, 11, 20, 12);
    aiStatus = 'none';
    brokenPage = false;
    servedBundle = null;
    uploaded.clear();
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    runtime = SmsV2Runtime(
      financial: financial,
      namespace: _namespace,
      client: MockClient((request) async => server(request)),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'ai-device',
      appVersion: '2.0.0',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async =>
          RuleBundle.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      loadShippedBundle: () async => jsonEncode(baseline),
      accountIsCurrent: () => true,
      hasSharingConsent: () async => consent,
      clock: () => clockNow,
    );
    state = SyncStateStore(database.db, namespace: _namespace);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  LedgerReadModel model() => loadLedgerReadModel(
    db: database.db,
    financialStore: financial,
    namespace: _namespace,
  );

  DismissalStore store() => DismissalStore(state);

  /// What settledListsProvider computes, without Riverpod.
  SettledLists lists({Set<String> open = const {}}) {
    final m = model();
    final reviewDismissed = readDismissedReviewItems(
      db: database.db,
      intake: SmsIntakeRepository(database),
      feedback: SmsLearningFeedback(database, namespace: _namespace),
      namespace: _namespace,
    );
    final l = settledLists(
      m.transactions,
      m.factsBySource,
      openReviewSources: open,
      reviewDismissedSources: {
        for (final i in reviewDismissed)
          if (i.payload['sourceKey'] case final String s) s,
      },
      eventLegSources: {
        for (final e in m.ledger.events)
          for (final leg in e.legs)
            if (m.factsById[leg.factId]?.sourceKey case final String s) s,
      },
      confirmedEvents: {
        for (final e in m.ledger.events)
          if (e.status == EventStatus.userConfirmed) e.eventId: e.decidedAt,
      },
      dismissals: store().all(),
    );
    for (final record in l.healed) {
      store().put(record);
    }
    return l;
  }

  List<LocalReviewItem> openItems() => [
    for (final row in database.db.select(
      "SELECT review_id,kind,payload FROM v2_review_items WHERE namespace=? AND status='open'",
      [_namespace],
    ))
      LocalReviewItem(
        id: row['review_id'] as String,
        kind: row['kind'] as String,
        payload: (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
      ),
  ];

  Future<ReviewController> controller() async => ReviewController(
    financial: financial,
    namespace: _namespace,
    bundle: await runtime.activeBundle(),
  );

  Future<SmsTransactionActions> actions() async =>
      SmsTransactionActions(controller: await controller());

  Future<void> hide(TransactionEntry e) async {
    final sms = await actions();
    expect(sms.ownsRow(e), isTrue);
    sms.hide(e);
    financial.markInactive(_namespace, e.id, reason: 'wrong_transaction');
  }

  Future<bool> restore(TransactionEntry e) async {
    (await actions()).restore(e);
    financial.markActive(_namespace, e.id);
    return true;
  }

  String? decidedAtOf(String eventId) => EventStore(
    database.db,
    namespace: _namespace,
  ).get(eventId)?.decidedAt?.toUtc().toIso8601String();

  Future<TransactionEntry> readByAi() async {
    await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
    await sync();
    aiStatus = 'ready';
    await sync();
    return lists().autoTransactions.single.entry;
  }

  TransactionEntry current(TransactionEntry tx) =>
      model().transactions.firstWhere((e) => e.id == tx.id);

  Future<void> recover(TransactionEntry tx) async {
    final d = lists().dismissed.single;
    final to = await recoverDismissed(
      store: store(),
      record: d.record,
      aiStillReads: true,
      restore: () => restore(d.entry!),
      decidedAt: () => decidedAtOf(tx.eventId!),
      sendToReview: () async => fail('should not go to Needs review'),
    );
    expect(to, RecoveredTo.autoResolved);
  }

  group('1: Not financial on an AI reading with no transaction lists the message once', () {
    test('it leaves AI auto-resolved and is a History row, not both', () async {
      attemptMode = true;
      draftConfidence = .5;
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1)]);
      await sync();
      aiStatus = 'ready';
      await sync();
      expect(model().transactions, isEmpty, reason: 'a failed attempt makes no transaction');
      final items = openItems().where((i) => i.kind == 'template').toList();
      expect(items, isNotEmpty);
      final source = items.first.payload['sourceKey'] as String;
      // Still a question on Needs review: not AI auto-resolved.
      expect(lists(open: {source}).autoReads, isEmpty);

      (await controller()).apply(items: items, kind: CorrectionKind.notFinancial);
      final l = lists();
      expect(l.autoReads.map((r) => r.sourceKey), isNot(contains(source)), reason: 'not in AI auto-resolved');
      final history = readDismissedReviewItems(
        db: database.db,
        intake: SmsIntakeRepository(database),
        feedback: SmsLearningFeedback(database, namespace: _namespace),
        namespace: _namespace,
      );
      expect(history.map((i) => i.payload['sourceKey']), [source], reason: 'one History row');
    });
  });

  group('2: a recovered AI transaction is withdrawn like an untouched one when its rule is rejected', () {
    test('the spend leaves and the card goes away', () async {
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1), _msg('SHOP TWO', 300, 2)]);
      await sync();
      aiStatus = 'ready';
      await sync();
      expect(spendMinor(), 75000);
      final tx = lists().autoTransactions.firstWhere((t) => t.entry.merchantName == 'RAHUL KUMAR').entry;
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      expect(spendMinor(), 30000);
      await recover(tx);
      expect(spendMinor(), 75000, reason: 'recovered: counted again');
      expect(lists().autoTransactions, hasLength(2));

      aiStatus = 'rejected';
      await sync();
      await sync();
      expect(spendMinor(), 0, reason: 'the rejected rule took back what it read, recovered or not');
      expect(lists().auto, isEmpty, reason: 'both cards are gone');
      expect(lists().history, isEmpty);
      expect(lists().dismissed, isEmpty);
    });

    test('a transaction the person really edited is still left alone', () async {
      final tx = await readByAi();
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      await recover(tx);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final c = current(tx);
      (await actions()).edit(
        c,
        amountMinor: 50000,
        merchant: c.merchantName ?? '',
        occurredAt: c.occurredAt,
        eventType: EventType.purchase,
      );
      aiStatus = 'rejected';
      await sync();
      await sync();
      expect(spendMinor(), 50000, reason: 'the person decided it after the restore');
    });
  });

  group('3: a second Dismiss cannot lose the saved event', () {
    test('Dismiss twice, then Recover: counted again and active', () async {
      final tx = await readByAi();
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      expect(spendMinor(), 0);
      final saved = jsonDecode(state.get('hidden-event:${tx.eventId}')!) as Map;
      expect(saved['type'], isNot('unknown'), reason: 'the copy is the event as it was before the first hide');
      await recover(tx);
      expect(spendMinor(), 45000);
      expect(current(tx).status, 'active');
      expect(lists().autoTransactions.single.entry.id, tx.id);
    });

    test('hide on an already hidden transaction changes nothing', () async {
      final tx = await readByAi();
      final sms = await actions();
      sms.hide(tx);
      final first = state.get('hidden-event:${tx.eventId}');
      final decided = decidedAtOf(tx.eventId!);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      sms.hide(tx);
      expect(state.get('hidden-event:${tx.eventId}'), first);
      expect(decidedAtOf(tx.eventId!), decided, reason: 'no second correction');
    });
  });

  group('4: restored from Activity, not History', () {
    test('it is AI auto-resolved again, and the record is converted', () async {
      final tx = await readByAi();
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      await restore(lists().dismissed.single.entry!); // Activity > Deleted transactions > Restore
      final record = store().get(tx.sourceKey!)!;
      expect(record.restored, isTrue, reason: 'the restore converted the record');
      final l = lists();
      expect(l.autoTransactions.single.entry.id, tx.id);
      expect(l.history, isEmpty);
      expect(l.dismissed, isEmpty);
    });

    test('a record left unconverted (the app closed in between) heals when the list is read', () async {
      final tx = await readByAi();
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      final unconverted = store().get(tx.sourceKey!)!;
      await restore(lists().dismissed.single.entry!);
      store().put(unconverted); // as if the app was killed before the record was updated
      expect(store().get(tx.sourceKey!)!.restored, isFalse);
      final l = lists();
      expect(l.autoTransactions.single.entry.id, tx.id, reason: 'not "you edited"');
      expect(l.history, isEmpty);
      expect(store().get(tx.sourceKey!)!.restored, isTrue, reason: 'saved as put back');
    });
  });

  group('8: the AI tag follows the card', () {
    test('a recovered transaction is AI auto-resolved again and keeps its tag while the rule is unverified', () async {
      final tx = await readByAi();
      expect(tx.aiUnverified, isTrue);
      await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
      await recover(tx);
      expect(lists().autoTransactions.single.how, 'Read by an AI rule, not yet verified');
      expect(current(tx).aiUnverified, isTrue);
      // A later re-projection (any correction touching the event) agrees with the card.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final c = current(tx);
      (await actions()).edit(
        c,
        amountMinor: 50000,
        merchant: c.merchantName ?? '',
        occurredAt: c.occurredAt,
        eventType: EventType.purchase,
      );
      expect(current(tx).aiUnverified, isFalse, reason: 'edited by the person: no tag, History');
    });
  });
}
