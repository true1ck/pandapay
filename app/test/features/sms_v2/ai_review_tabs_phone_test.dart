// The three-tab Needs review model on the phone, through the real runtime with a fake server: an AI reading is
// applied, listed under AI auto-resolved, dismissed from there (the transaction leaves the totals), recovered
// (it counts again and is AI auto-resolved again), or edited (it moves to History, read-only). All data is invented.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TransactionEntry;
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/storage/dismissal_store.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/ui/auto_dismissal_actions.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay/features/sms_v2/ui/transaction_actions.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart' show LedgerReadModel;
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart';
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

  SettledLists lists({Set<String> open = const {}}) {
    final m = model();
    return settledLists(
      m.transactions,
      m.factsBySource,
      openReviewSources: open,
      confirmedEvents: {
        for (final e in m.ledger.events)
          if (e.status == EventStatus.userConfirmed) e.eventId: e.decidedAt,
      },
      dismissals: store().all(),
    );
  }

  Future<SmsTransactionActions> actions() async => SmsTransactionActions(
    controller: ReviewController(
      financial: financial,
      namespace: _namespace,
      bundle: await runtime.activeBundle(),
    ),
  );

  /// What the app does for Dismiss and Recover on a transaction (the existing "Report wrong transaction" action
  /// and its restore: transaction_action_flow.dart `ignoreEntry` / `restoreEntry`, v2 branch).
  Future<void> hide(TransactionEntry e) async {
    final sms = await actions();
    expect(sms.ownsRow(e), isTrue);
    sms.hide(e);
    financial.markInactive(_namespace, e.id, reason: 'wrong_transaction');
  }

  Future<void> restore(TransactionEntry e) async {
    final sms = await actions();
    sms.restore(e);
    financial.markActive(_namespace, e.id);
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

  setUp(() {});

  test('a confident AI transaction is AI auto-resolved, with no question', () async {
    final tx = await readByAi();
    expect(spendMinor(), 45000);
    expect(openTemplateReviews(), isEmpty);
    expect(lists().autoTransactions.single.how, 'Read by an AI rule, not yet verified');
    expect(lists().history, isEmpty);
    expect(tx.status, 'active');
    expect(tx.aiUnverified, isTrue, reason: 'the row carries the AI tag: unverified AI rule, not edited');
  });

  test('a transaction open on Needs review is not also AI auto-resolved', () async {
    final tx = await readByAi();
    expect(lists(open: {tx.sourceKey!}).auto, isEmpty);
  });

  test('Dismiss takes the transaction out of the totals into History; Recover re-applies it as AI auto-resolved',
      () async {
    final tx = await readByAi();
    await dismissTransaction(
      store: store(),
      entry: tx,
      at: clockNow,
      hide: () => hide(tx),
    );
    expect(spendMinor(), 0, reason: 'dismissed: not counted');
    var l = lists();
    expect(l.auto, isEmpty, reason: 'it left AI auto-resolved');
    expect(l.history, isEmpty, reason: 'a dismissal is not a person edit');
    final dismissed = l.dismissed.single;
    expect(dismissed.record.origin, AutoDismissal.originAutoResolved);
    expect(dismissed.record.isTransaction, isTrue);
    expect(dismissed.title, 'RAHUL KUMAR');
    expect(l.historyMessages, 1);

    final to = await recoverDismissed(
      store: store(),
      record: dismissed.record,
      aiStillReads: true,
      restore: () => restore(dismissed.entry!),
      decidedAt: () => decidedAtOf(tx.eventId!),
      sendToReview: () async => fail('should not go to Needs review'),
    );
    expect(to, RecoveredTo.autoResolved);
    expect(spendMinor(), 45000, reason: 'recovered: counted again');
    l = lists();
    expect(l.dismissed, isEmpty);
    expect(l.history, isEmpty, reason: 'the restore is not an edit by the person');
    expect(l.autoTransactions.single.entry.id, tx.id);
    expect(l.autoTransactions.single.byUser, isFalse);
  });

  test('a recovered transaction the person then edits is History, not AI auto-resolved', () async {
    final tx = await readByAi();
    await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
    final record = store().get(tx.sourceKey!)!;
    await recoverDismissed(
      store: store(),
      record: record,
      aiStillReads: true,
      restore: () => restore(lists().dismissed.single.entry!),
      decidedAt: () => decidedAtOf(tx.eventId!),
      sendToReview: () async => fail('no'),
    );
    expect(lists().autoTransactions, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final current = model().transactions.firstWhere((e) => e.id == tx.id);
    (await actions()).edit(
      current,
      amountMinor: 50000,
      merchant: current.merchantName ?? '',
      occurredAt: current.occurredAt,
      eventType: EventType.purchase,
    );
    final l = lists();
    expect(l.auto, isEmpty);
    expect(l.history.single.entry.id, tx.id);
    expect(l.history.single.byUser, isTrue);
    expect(l.history.single.how, 'The AI read this; you confirmed or fixed it');
  });

  test('the person fixing an AI reading puts it in History (the user fact is not under the message source)', () async {
    final tx = await readByAi();
    (await actions()).edit(
      tx,
      amountMinor: 52000,
      merchant: tx.merchantName ?? '',
      occurredAt: tx.occurredAt,
      eventType: EventType.purchase,
    );
    final m = model();
    expect(
      m.factsBySource[tx.sourceKey]!.any((f) => f.provenance.engine == Engine.user),
      isFalse,
      reason: 'a correction writes its fact under correction:<id>, so the event is the only place it shows',
    );
    final l = lists();
    expect(l.auto, isEmpty);
    expect(l.history.single.entry.id, tx.id);
    expect(
      model().transactions.firstWhere((e) => e.id == tx.id).aiUnverified,
      isFalse,
      reason: 'the tag ends when the person edits it',
    );
  });

  test('Recover falls back to Needs review when the AI no longer reads the message', () async {
    final tx = await readByAi();
    await dismissTransaction(store: store(), entry: tx, at: clockNow, hide: () => hide(tx));
    final sent = <String>[];
    final to = await recoverDismissed(
      store: store(),
      record: store().get(tx.sourceKey!)!,
      aiStillReads: false,
      restore: () async => fail('not restored'),
      decidedAt: () => null,
      sendToReview: () async => sent.add(tx.sourceKey!),
    );
    expect(to, RecoveredTo.needsReview);
    expect(sent, [tx.sourceKey]);
    expect(store().get(tx.sourceKey!), isNull);
  });
}
