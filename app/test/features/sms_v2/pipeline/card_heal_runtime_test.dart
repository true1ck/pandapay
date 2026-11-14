import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardNetwork, CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// The heal links unlinked card rows when the wallet card set changes, and only
// then: a sync with the same cards does no work.
void main() {
  const ns = 'user:heal-runtime';
  const cardId = '11111111-1111-4111-8111-111111111111';
  const otherCardId = '22222222-2222-4222-8222-222222222222';

  test('runs once per wallet card set, never on every sync', () async {
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
      clock: () => now,
    );

    String? link() => db.db
        .select("SELECT instrument_id FROM v2_facts WHERE namespace=? AND fact_type='movement'", [ns])
        .single['instrument_id'] as String?;
    void unlink() => db.db.execute(
      "UPDATE v2_facts SET instrument_id=NULL WHERE namespace=? AND fact_type='movement'",
      [ns],
    );
    UserCard wallet(String id, String last4) => UserCard(
      id: id,
      cardProductId: 'hdfc_millennia',
      cardName: 'HDFC Millennia',
      cardType: 'credit',
      isDefault: false,
      last4: last4,
    );
    String? marker() => db.db
        .select("SELECT value FROM v2_sync_state WHERE namespace=? AND key='card:heal'", [ns])
        .map((r) => r['value'] as String?)
        .firstOrNull;

    await runtime.sync(); // reads the SMS; no wallet card yet
    final detected = InstrumentStore(db.db, namespace: ns).list().single;
    expect(marker(), isNull, reason: 'no cards: nothing to do, nothing recorded');

    unlink();
    financial.replaceCards(ns, [wallet(cardId, detected.maskDigits!)]);
    await runtime.sync(); // the card set changed: heal runs
    expect(link(), isNotNull);
    expect(marker(), isNotNull);
    final first = marker();

    unlink();
    await runtime.sync(); // same cards: must not run again
    expect(link(), isNull);
    expect(marker(), first);

    financial.replaceCards(ns, [
      wallet(cardId, detected.maskDigits!),
      wallet(otherCardId, '0000'),
    ]);
    await runtime.sync(); // the set changed again: runs again, once
    expect(link(), isNotNull);
    expect(marker(), isNot(first));
  });
}
