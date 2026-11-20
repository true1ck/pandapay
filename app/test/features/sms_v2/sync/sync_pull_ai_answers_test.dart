// The AI answers arrive in the same page as the entities (facts, events, ledger
// rows), and the page used to be saved as one unit: when anything in it could
// not be saved on this phone, the answers it carried were rolled back with it,
// and the next pull asked for the same page and failed the same way. One phone
// then never applied an AI answer while another, which had the same account
// and the same answers, did.
//
// The answers are now kept first, on their own. The rest of the page is still
// all-or-nothing, and what stopped it is recorded for the phone details.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';


void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late Map<String, Object?> body;
  late SyncStateStore state;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: 'source',
      bundle: bundle,
      appVersion: '2',
    ).process(
      SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: 'a' * 64,
        observedAt: DateTime.utc(2026, 11, 1, 7),
      ),
    );
    final rows = OutboxStore(
      database.db,
      namespace: 'source',
    ).due(DateTime.utc(2026, 12));
    List<Map<String, Object?>> kind(String kind) => [
      for (final row in rows)
        if (row.kind == kind) row.json,
    ];
    body = {
      'cursor': 'page-1',
      'facts': [for (final item in kind('source')) ...item['facts'] as List],
      'instruments': kind('instrument'),
      'events': kind('event'),
      'ledger': kind('ledger'),
      'aiResults': <Object?>[],
      'corrections': <Object?>[],
      'latestBundleVersion': 1,
      'updatedAt': {
        'events': {
          for (final event in kind('event'))
            event['eventId']: '2026-11-01T07:01:00Z',
        },
        'instruments': {
          for (final instrument in kind('instrument'))
            instrument['instrumentId']: '2026-11-01T07:01:00Z',
        },
        'ledger': {
          for (final entry in kind('ledger'))
            entry['entryId']: '2026-11-01T07:01:00Z',
        },
      },
    };
    state = SyncStateStore(database.db, namespace: 'target');
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  SyncPull puller() => SyncPull(
    financial: financial,
    namespace: 'target',
    client: MockClient(
      (_) async => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
    baseUri: Uri.parse('https://api.invalid'),
    headers: () async => {},
    bundle: bundle,
  );

  late String hash;
  Map<String, Object?> answer() {
    final rule = bundle.rules.firstWhere(
      (r) => r.status == RuleStatus.provisional,
    );
    hash = rule.match.templateHash!;
    return {
      'templateHash': hash,
      'status': 'ready',
      'ruleId': rule.id,
      'ruleVersion': rule.version,
      'rule': rule.toJson(),
    };
  }

  void refuseFacts() => database.db.execute(
    "CREATE TRIGGER refuse_facts BEFORE INSERT ON v2_facts BEGIN SELECT RAISE(ABORT, 'refused here'); END",
  );

  test('a page that cannot be saved still keeps the AI answers it carried', () async {
    body['aiResults'] = [answer()];
    refuseFacts();
    await expectLater(puller().pull(), throwsA(isA<SqliteException>()));
    expect(state.get('ai:$hash'), isNotNull, reason: 'the answer is kept');
    expect(state.get('pull:cursor'), isNull, reason: 'the entities were rolled back');
  });

  test('a page that fails the contract check still keeps the AI answers', () async {
    body['facts'] = [
      <String, Object?>{'bogus': true},
    ];
    body['aiResults'] = [answer()];
    await expectLater(puller().pull(), throwsA(isA<ContractException>()));
    expect(state.get('ai:$hash'), isNotNull);
  });

  test('only well-formed answers are kept ahead of the check', () async {
    body['facts'] = [
      <String, Object?>{'bogus': true},
    ];
    body['aiResults'] = [
      'junk',
      <String, Object?>{'status': 'ready'},
      <String, Object?>{'templateHash': 7, 'status': 'ready'},
      // A status the contract does not know (the page is refused whole for it).
      <String, Object?>{'templateHash': 'd' * 64, 'status': 'failed'},
      answer(),
    ];
    await expectLater(puller().pull(), throwsA(isA<ContractException>()));
    final kept = database.db
        .select(
          "SELECT key FROM v2_sync_state WHERE namespace='target' AND key LIKE 'ai:%'",
        )
        .map((row) => row['key'])
        .toList();
    expect(kept, ['ai:$hash']);
  });

  test('a normal page still saves the answers and the cursor together', () async {
    body['aiResults'] = [answer()];
    await puller().pull();
    expect(state.get('ai:$hash'), isNotNull);
    expect(state.get('pull:cursor'), 'page-1');
    expect(state.get('pull:error'), isNull);
  });

  test('what stopped a page is recorded, and a good pull clears it', () async {
    refuseFacts();
    await expectLater(puller().pull(), throwsA(anything));
    final problem = jsonDecode(state.get('pull:error')!) as Map;
    expect(problem['type'], 'SqliteException');
    expect(problem['message'], contains('refused here'));
    expect(DateTime.tryParse(problem['at'] as String), isNotNull);

    database.db.execute('DROP TRIGGER refuse_facts');
    await puller().pull();
    expect(state.get('pull:error'), isNull);
  });
}
