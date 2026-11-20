// INT-1: the phone-side fixes together (A4a withdrawal and re-read, A4b upload brand and overlay cache), through the
// real runtime with a fake server that, like the real one, refuses a layout whose hash is not sha256(brand, newline,
// body). The answers the fake sync route gives are the shapes ai_integration_pg.test.js shows the real route gives
// (ready; pending after a quarantine; rejected after a rejection, a failure or a pause). Harness as in
// ai_draft_lifecycle_phone_test.dart. Original header:
// What the phone does with an AI draft over its life, through the real runtime
// with a fake server (same harness idea as ai_scenarios_phone_test.dart):
//  - a second revision of a draft reaches messages the first revision read,
//  - a draft the server took back (quarantined, so the phone sees "pending")
//    stops counting what it read,
//  - a withdrawal leaves nothing queued for upload (source, event, ledger),
//  - a message read again by another rule leaves one reading, not two,
//  - the withdrawal pass does no whole-history work when there is nothing to do.
// Synthetic messages and ids only.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:life';
const _draft1 = '11111111-1111-4111-8111-111111111111';
const _draft2 = '22222222-2222-4222-8222-222222222222';

QueuedSms _msg(
  String shop,
  int rupees,
  int minute, {
  String sender = 'AX-HDFCBK-S',
}) => QueuedSms(
  sender: sender,
  body:
      'Sent Rs.$rupees.00 from HDFC Bank A/c XX1234 to $shop on 20-11-26. Ref 61234567890$minute.',
  receivedAt: DateTime.utc(2026, 11, 20, 7, minute),
);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late SmsV2Runtime runtime;
  late SyncStateStore state;
  var clockNow = DateTime.utc(2026, 11, 20, 12);
  // What the server answers for every layout this phone uploaded.
  var answer = <String, Object?>{'status': 'none'};
  var factsStatus = 200;
  String? servedBundle;
  final uploaded = <String>[];
  final uploadedBrands = <String>[];
  final fixture =
      (jsonDecode(
                File(
                  'test/features/sms_v2/fixtures/real_gemini_rule.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  final fullBundle =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  // A rule set that reads nothing: every message of this layout is unknown.
  final baseline = <String, Object?>{
    ...fullBundle,
    'rules': <Object?>[],
    'categoryRules': <Object?>[],
  };

  /// The draft's rule for [hash]; [purpose] is what tells revision 1 from 2.
  Map<String, Object?> ruleFor(
    String hash, {
    String purpose = 'purchase',
    List<String>? senders,
  }) {
    final rule = (jsonDecode(jsonEncode(fixture['rule'])) as Map)
        .cast<String, Object?>();
    final emit = (rule['emit'] as List).cast<Map>().single;
    return {
      ...rule,
      'id': 'AI-$hash',
      'senders': ?senders,
      'status': 'provisional',
      'match': {...(rule['match'] as Map), 'templateHash': hash},
      'emit': [
        {
          ...emit,
          'attrs': {...(emit['attrs'] as Map), 'purpose': purpose},
        },
      ],
    };
  }

  void ready(String purpose, String draftId, {List<String>? senders}) => answer = {
    'status': 'ready',
    'purpose': purpose,
    'draftId': draftId,
    'senders': ?senders,
  };
  void pending() => answer = {'status': 'pending'};
  void rejected() => answer = {'status': 'rejected'};

  http.Response server(http.Request request) {
    switch (request.url.path) {
      case '/sms/v2/rules':
        return servedBundle == null
            ? http.Response('', 304)
            : http.Response.bytes(utf8.encode(servedBundle!), 200);
      case '/sms/v2/unknown-templates':
        final items = (jsonDecode(request.body) as Map)['items'] as List;
        for (final item in items) {
          final brand = (item as Map)['senderBrand'];
          // What the server does at intake: the hash must be sha256(brand, newline, body).
          final again = sha256
              .convert(utf8.encode('$brand\n${item['redactedBody']}'))
              .toString();
          if (again != item['templateHash']) {
            return http.Response('{"error":"template_invalid"}', 400);
          }
          uploadedBrands.add(brand as String);
          uploaded.add(item['templateHash'] as String);
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
        if (factsStatus != 200) return http.Response('{}', factsStatus);
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
        final status = answer['status'] as String;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'cursor': 'one',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [
                if (status != 'none')
                  for (final hash in uploaded.toSet())
                    {
                      'templateHash': hash,
                      'status': status,
                      if (status == 'ready') ...{
                        'ruleId': 'AI-$hash',
                        'ruleVersion': 1,
                        'rule': ruleFor(
                          hash,
                          purpose: answer['purpose'] as String,
                          senders: answer['senders'] as List<String>?,
                        ),
                        'draftId': answer['draftId'],
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

  /// The purpose each stored money movement was read with.
  List<String?> purposes() => [
    for (final row in database.db.select(
      "SELECT payload FROM v2_facts WHERE namespace=? AND fact_type='movement'",
      [_namespace],
    ))
      ((jsonDecode(row['payload'] as String) as Map)['attrs'] as Map)['purpose']
          as String?,
  ];

  List<String> outboxIds() => [
    for (final row in database.db.select(
      'SELECT id FROM v2_outbox WHERE namespace=? ORDER BY id',
      [_namespace],
    ))
      row['id'] as String,
  ];

  int count(String sql) =>
      database.db.select(sql, [_namespace]).single.values.first as int;

  setUp(() {
    clockNow = DateTime.utc(2026, 11, 20, 12);
    answer = {'status': 'none'};
    factsStatus = 200;
    servedBundle = null;
    uploaded.clear();
    uploadedBrands.clear();
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    runtime = SmsV2Runtime(
      financial: financial,
      namespace: _namespace,
      client: MockClient((request) async => server(request)),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'life-device',
      appVersion: '2.0.0',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async =>
          RuleBundle.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      loadShippedBundle: () async => jsonEncode(baseline),
      accountIsCurrent: () => true,
      hasSharingConsent: () async => true,
      clock: () => clockNow,
    );
    state = SyncStateStore(database.db, namespace: _namespace);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  // A bundle brand is letters and digits only and a header the registry does not know is never read, so a punctuated
  // header (SBI-UPI) cannot reach the review queue in the runtime; the brand cleaning is covered by
  // template_upload_hardening_test and template_hash_vectors_test. Here the hash the server recomputes is the real one.
  const sbiHeader = 'AX-HDFCBK-S';
  const sbiBrand = ['HDFCBK'];

  test(
    'INT-c a layout uploaded with a hash the server accepts, read by the draft, revision 2 and a quarantine and its replacement re-read, a rejection withdraws and the overlay drops the draft',
    () async {
      final shared = RuleBundle.fromJson(baseline);
      final store = ProvisionalStore(state);
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1, sender: sbiHeader)]);
      await sync();
      expect(uploadedBrands, ['HDFCBK'], reason: 'the hash agrees with sha256(brand, newline, body), as the server checks');

      ready('purchase', _draft1, senders: sbiBrand);
      await sync();
      expect(purposes(), ['purchase'], reason: 'the draft reads the SBI-UPI message');
      expect(spendMinor(), 45000);
      final overlay1 = store.overlay(shared);
      expect(overlay1.bundle.rules.where((r) => r.id.startsWith('AI-')), isNotEmpty);

      // Revision 2: the overlay cache must not serve revision 1, and the re-read must use revision 2.
      ready('p2p', _draft2, senders: sbiBrand);
      await sync();
      final overlay2 = store.overlay(shared);
      expect(overlay2.revision, isNot(overlay1.revision), reason: 'a revised draft is a new overlay');
      expect(purposes(), ['p2p'], reason: 'revision 2 reads what revision 1 read');
      expect(spendMinor(), 45000, reason: 'counted once');

      // Quarantine: pending, the spend leaves, the message is plain Needs review again.
      pending();
      await sync();
      expect(spendMinor(), 0);
      expect(purposes(), isEmpty);
      expect(store.overlay(shared).bundle, same(shared), reason: 'no draft offered, no private rule');
      // Replacement.
      ready('p2p', _draft2, senders: sbiBrand);
      await sync();
      expect(purposes(), ['p2p']);
      expect(spendMinor(), 45000);

      // Rejection (quorum, admin pause or failure all reach the phone as "rejected"): withdrawn, cache drops it.
      rejected();
      await sync();
      expect(spendMinor(), 0, reason: 'a rejected draft stops counting');
      expect(purposes(), isEmpty);
      expect(store.overlay(shared).bundle, same(shared));
      await runtime.capture([_msg('PRIYA SHARMA', 300, 2, sender: sbiHeader)]);
      await sync();
      expect(spendMinor(), 0, reason: 'and reads nothing new');
      expect(
        count(
          "SELECT count(*) FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
        ),
        greaterThanOrEqualTo(1),
      );
    },
  );

  test(
    'INT-d a template the server retracted (admin pause, rejected) is withdrawn at once on the next sync, once, with nothing queued',
    () async {
      factsStatus = 503;
      await runtime.capture([_msg('RAHUL KUMAR', 450, 1, sender: sbiHeader)]);
      try {
        await sync();
      } catch (_) {}
      ready('purchase', _draft1, senders: sbiBrand);
      try {
        await sync();
      } catch (_) {}
      expect(spendMinor(), 45000);
      rejected();
      try {
        await sync();
      } catch (_) {}
      expect(spendMinor(), 0);
      expect(
        outboxIds().where(
          (id) => id.startsWith('ledger:') || id.startsWith('source:') || id.startsWith('event:'),
        ),
        isEmpty,
      );
      // Syncing again does no more work and changes nothing.
      try {
        await sync();
      } catch (_) {}
      expect(spendMinor(), 0);
    },
  );
}
