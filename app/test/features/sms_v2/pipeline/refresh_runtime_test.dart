import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_refresh.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardNetwork, CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// An ordinary sync keeps saved rows current: rows an older build saved are
// rebuilt after an app update, and a finished pass costs nothing afterwards.
void main() {
  const ns = 'user:refresh-runtime';

  test('a sync after an app update rebuilds rows an older build saved', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    final financial = FinancialStore(db);
    addTearDown(() {
      financial.dispose();
      db.db.dispose();
    });
    final encoded = File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync();
    final bundle = RuleBundle.fromJson((jsonDecode(encoded) as Map).cast<String, Object?>());
    final now = DateTime.utc(2026, 11, 1, 7);
    SmsImportStore(financial).capture(
      ns,
      QueuedSms(sender: 'VM-HDFCBK-S', body: bundle.rules.first.examples.first.body, receivedAt: now),
    );
    final runtime = SmsV2Runtime(
      financial: financial,
      namespace: ns,
      catalogue: [
        CardProduct(
          id: 'hdfc_millennia',
          name: 'HDFC Millennia',
          issuerName: 'HDFC Bank',
          cardType: 'credit',
          network: CardNetwork.visa,
          isUpiLinkable: false,
          pointValueInr: 1.0,
          rewardRules: const [],
          capRules: const [],
          milestoneRules: const [],
          feeWaiverRules: const [],
          benefits: const [],
        ),
      ],
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/sms/v2/rules':
            return http.Response('', 304);
          case '/sms/v2/facts:batch':
            final body = jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
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
                    for (final row in body[key]) {'kind': kind, 'id': row[id], 'status': 'accepted'},
                ],
              }),
              200,
            );
          case '/sms/v2/rule-stats:batch':
            return http.Response('{}', 202);
          case '/sms/v2/sync':
            return http.Response(
              jsonEncode({
                'cursor': 'one',
                'instruments': [],
                'events': [],
                'ledger': [],
                'facts': [],
                'aiResults': [],
                'corrections': [],
                'latestBundleVersion': 1,
              }),
              200,
            );
          default:
            fail('unexpected call ${request.url.path}');
        }
      }),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'test-device',
      appVersion: '2',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      categoryIdBySlug: const {'other': 'cat-other', 'dining': 'cat-dining', 'online': 'cat-online'},
      clock: () => now,
    );


    Map<String, Object?> row() => financial.entities(ns, 'transactions').single;
    final state = SyncStateStore(db.db, namespace: ns);

    await runtime.sync();
    expect(row()['instrument'], 'credit_card');
    final done = state.get(ProjectionRefresh.doneKey);
    expect(done, isNotNull);

    // What an older build left: the card spend saved as "not matched", and a
    // newer projection version installed.
    final r = row();
    db.db.execute(
      "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
      [
        jsonEncode({...r, 'instrument': 'other', 'card_last4': null, 'card_name': null}),
        ns,
        r['id'],
      ],
    );
    state.put(ProjectionRefresh.doneKey, 'older-build');

    await runtime.sync();
    expect(row()['instrument'], 'credit_card');
    expect(row()['card_last4'], isNotNull);
    expect(state.get(ProjectionRefresh.doneKey), done);

    // Nothing due: the next sync leaves everything alone.
    final before = jsonEncode(row());
    await runtime.sync();
    expect(jsonEncode(row()), before);
  });
}
