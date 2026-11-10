import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'consent gates a redacted template and revocation prevents a queued retry',
    () async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      addTearDown(db.db.dispose);
      SmsV2Schema.ensure(db.db);
      final intake = SmsIntakeRepository(db);
      final now = DateTime.utc(2026, 11);
      const raw =
          'Rs.12345.67 debited from A/c XX6789 to RAHUL SHARMA. Ref 1234567890 https://bank.example.in';
      const sender = 'HDFCBK';
      final source = smsSourceKey('a', sender, raw);
      intake.remember(
        'a',
        QueuedSms(sender: sender, body: raw, receivedAt: now),
      );
      db.db.execute("INSERT INTO v2_review_items VALUES(?,?,?,?,?)", [
        'a',
        source,
        'template',
        jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}),
        'open',
      ]);
      var consent = false;
      var calls = 0;
      final queue = OutboxStore(db.db, namespace: 'a');
      final uploader = TemplateUpload(
        intake: intake,
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => consent,
        accountIsCurrent: () => true,
        clock: () => now,
        client: MockClient((request) async {
          calls++;
          final item = (jsonDecode(request.body) as Map)['items'].single;
          final redacted = item['redactedBody'] as String;
          expect(redacted, isNot(contains('12345.67')));
          expect(redacted, isNot(contains('6789')));
          expect(redacted.toLowerCase(), isNot(contains('rahul')));
          expect(RegExp(r'\d{6,}|https?://').hasMatch(redacted), isFalse);
          return http.Response('{}', 503);
        }),
      );
      await uploader.drain();
      expect(calls, 0);
      expect(queue.due(now), isEmpty);
      consent = true;
      await uploader.drain();
      expect(calls, 1);
      expect(db.db.select('SELECT * FROM v2_outbox'), hasLength(1));
      consent = false;
      await uploader.drain();
      expect(calls, 1);
      expect(
        db.db.select("SELECT * FROM v2_outbox WHERE kind='template'"),
        isEmpty,
      );
    },
  );

  test('a message waiting on history is never sent for AI rule drafting', () async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.db.dispose);
    SmsV2Schema.ensure(db.db);
    final intake = SmsIntakeRepository(db);
    final now = DateTime.utc(2026, 11);
    const sender = 'HDFCBK';
    const reminder =
        'Reminder: your credit card bill of Rs 23,540 is due. Pay on or before the due date.';
    const ordinary = 'Your Sample Bank account was updated with a new feature.';
    final held = smsSourceKey('a', sender, reminder);
    final normal = smsSourceKey('a', sender, ordinary);
    intake.remember('a', QueuedSms(sender: sender, body: reminder, receivedAt: now));
    intake.remember('a', QueuedSms(sender: sender, body: ordinary, receivedAt: now));
    for (final (key, payload) in [
      (held, {'sourceKey': held, 'templateHash': 'a' * 64, 'aiHold': 'history'}),
      (normal, {'sourceKey': normal, 'templateHash': 'b' * 64}),
    ]) {
      db.db.execute('INSERT INTO v2_review_items VALUES(?,?,?,?,?)', [
        'a',
        key,
        'template',
        jsonEncode(payload),
        'open',
      ]);
    }
    final sent = <String>[];
    final queue = OutboxStore(db.db, namespace: 'a');
    final uploader = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => true,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async {
        for (final item in (jsonDecode(request.body) as Map)['items'] as List) {
          sent.add((item as Map)['redactedBody'] as String);
        }
        return http.Response('{}', 503);
      }),
    );
    await uploader.drain();
    expect(sent.join(' ').toLowerCase(), contains('feature'));
    expect(sent.join(' ').toLowerCase(), isNot(contains('credit card bill')));
  });

  test(
    'consented safe hash maps authenticated private rules back to original formats',
    () async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(db);
      addTearDown(() {
        financial.dispose();
        db.db.dispose();
      });
      SmsV2Schema.ensure(db.db);
      const namespace = 'user:template';
      const sender = 'VM-HDFCCC-S (smsft_fi)';
      const original = 'Rs.125.40 paid from card XX1234 to RAHUL SHARMA.';
      const another = 'Rs.700.15 paid from card XX1234 to ALICE FERNANDES.';
      final now = DateTime.utc(2026, 11, 4);
      final full = RuleBundle.fromJson(
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>(),
      );
      final shared = RuleBundle.fromJson({
        ...full.toJson(),
        'rules': [
          for (final rule in full.rules)
            if (rule.status != RuleStatus.provisional) rule.toJson(),
        ],
      });
      final sharedJson = jsonEncode(shared.toJson());
      final intake = SmsIntakeRepository(db);
      final pipeline = SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: shared,
        appVersion: 'test',
      );
      for (final body in [original, another]) {
        intake.remember(
          namespace,
          QueuedSms(sender: sender, body: body, receivedAt: now),
        );
        pipeline.process(
          SmsMessage(
            sender: sender,
            body: body,
            observedAt: now,
            sourceKey: smsSourceKey(namespace, sender, body),
          ),
        );
      }
      final queue = OutboxStore(db.db, namespace: namespace);
      final state = SyncStateStore(db.db, namespace: namespace);
      var consent = true, current = true, offline = false;
      var submissions = 0;
      Map<String, Object?>? submitted;
      final uploader = TemplateUpload(
        intake: intake,
        queue: queue,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {'Authorization': 'Bearer account-template'},
        hasConsent: () async {
          if (offline) throw const SocketException('offline');
          return consent;
        },
        accountIsCurrent: () => current,
        clock: () => now,
        client: MockClient((request) async {
          submissions++;
          final items = (jsonDecode(request.body) as Map)['items'] as List;
          expect(items, hasLength(1));
          final item = (items.single as Map).cast<String, Object?>();
          submitted = item;
          // Same digest bytes as the server acceptance check, over the body sent.
          final acceptedHash = sha256
              .convert(
                utf8.encode('${item['senderBrand']}\n${item['redactedBody']}'),
              )
              .toString();
          expect(item['templateHash'], acceptedHash);
          expect(item['senderBrand'], smsTemplateBrand(sender));
          expect(
            item.keys,
            unorderedEquals([
              'templateHash',
              'senderBrand',
              'redactedBody',
              'observedAt',
            ]),
          );
          for (final raw in [
            '125.40',
            '700.15',
            '1234',
            'RAHUL',
            'SHARMA',
            'ALICE',
            'FERNANDES',
          ]) {
            expect(
              request.body.toUpperCase(),
              isNot(contains(raw.toUpperCase())),
            );
          }
          expect(
            item['redactedBody'],
            smsSkeleton(item['redactedBody'] as String),
          );
          return http.Response(
            jsonEncode({
              'accepted': [acceptedHash],
            }),
            202,
          );
        }),
      );
      // An older queued original hash must not be retried with a redacted body.
      queue.enqueue('template', 'b' * 64, {
        'templateHash': 'b' * 64,
        'senderBrand': 'HDFCCC',
        'redactedBody': '<AMT> paid.',
        'observedAt': now.toIso8601String(),
      });
      await uploader.drain();
      final remoteHash = submitted!['templateHash'] as String;
      final localHash = smsTemplateHash(
        smsTemplateBrand(sender),
        smsSkeleton(original),
      );
      expect(remoteHash, isNot(localHash));
      final origin = TemplateOriginStore(state).get(remoteHash)!;
      expect(origin.localHashes, hasLength(2));
      expect(origin.localHashes, contains(localHash));
      expect(
        intake
            .capturedById(namespace, smsSourceKey(namespace, sender, original))!
            .message
            .body,
        original,
      );
      final rule = {
        ...full.rules.first.toJson(),
        'id': 'AI-$remoteHash',
        'version': 1,
        'status': 'provisional',
        'createdBy': 'ai:synthetic',
        'senders': [smsTemplateBrand(sender)],
        'match': {
          'pattern':
              r'^Rs\.(?<amt>\d+(?:\.\d{1,2})?) paid from card XX(?<mask>\d{4}) to (?<merchant>[A-Z ]+)\.$',
          'flags': 'i',
          'templateHash': remoteHash,
        },
        'emit': [
          {
            'factType': 'movement',
            'attrs': {
              'direction': 'debit',
              'purpose': 'purchase',
              'rail': 'card',
            },
            'amounts': [
              {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
            ],
            'instrument': {'kind': 'credit_card', 'maskFrom': 'mask'},
            'counterparty': {'nameFrom': 'merchant', 'kind': 'merchant'},
          },
        ],
      };
      await SyncPull(
        financial: financial,
        namespace: namespace,
        bundle: shared,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {'Authorization': 'Bearer account-template'},
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'cursor': 'private-result',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [
                {
                  'templateHash': remoteHash,
                  'status': 'ready',
                  'ruleId': rule['id'],
                  'ruleVersion': 1,
                  'rule': rule,
                },
              ],
              'corrections': [],
              'latestBundleVersion': shared.bundleVersion,
            }),
            200,
          ),
        ),
      ).pull();
      final overlay = ProvisionalStore(state).overlay(shared);
      expect(overlay.bundle.rules, hasLength(shared.rules.length + 2));
      final varied = original.replaceFirst('125.40', '999.25');
      final result = RuleEngine().interpret(
        SmsMessage(
          sender: sender,
          body: varied,
          observedAt: now,
          sourceKey: 'varying',
        ),
        overlay.bundle,
        appVersion: 'test',
      );
      expect(result.outcome, InterpretOutcome.matched);
      expect(result.facts.single.amounts.single.minor, 99925);
      expect(result.facts.single.instrument!.issuerSlug, 'hdfc');
      SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: overlay.bundle,
        appVersion: 'test',
        revision: overlay.revision,
      ).process(
        SmsMessage(
          sender: sender,
          body: varied,
          observedAt: now,
          sourceKey: 'varying',
        ),
      );
      // A private AI rule reports under its layout's AI id (never its
      // per-phone local id), counted as sent to review.
      final stats = db.db.select(
        'SELECT rule_id,rule_version,hits,to_review,corrected FROM v2_rule_stats_by_account WHERE namespace=?',
        [namespace],
      );
      expect(stats, hasLength(1));
      expect(stats.single['rule_id'], matches(RegExp(r'^AI-[0-9a-f]{64}$')));
      expect(
        [stats.single['hits'], stats.single['to_review'], stats.single['corrected']],
        [1, 1, 0],
      );
      expect(
        ProvisionalStore(
          SyncStateStore(db.db, namespace: 'user:other'),
        ).overlay(shared).bundle,
        shared,
      );
      expect(jsonEncode(shared.toJson()), sharedJson);
      state.put('personal:rule:keep', 'private user choice');
      state.put('category:keep', 'category choice');
      final otherState = SyncStateStore(db.db, namespace: 'user:other');
      otherState.put('ai:keep', 'other account');
      offline = true;
      await uploader.drain();
      expect(
        ProvisionalStore(state).overlay(shared).bundle.rules,
        hasLength(shared.rules.length + 2),
      );
      offline = false;
      consent = false;
      await uploader.drain();
      expect(TemplateOriginStore(state).get(remoteHash), isNull);
      expect(state.get('ai:$remoteHash'), isNull);
      expect(state.get('template:sent:$remoteHash'), isNull);
      expect(state.get('personal:rule:keep'), 'private user choice');
      expect(state.get('category:keep'), 'category choice');
      expect(otherState.get('ai:keep'), 'other account');
      expect(ProvisionalStore(state).overlay(shared).bundle, shared);
      consent = true;
      current = false;
      await uploader.drain();
      expect(submissions, 1);
      current = true;
      await uploader.drain();
      expect(submissions, 2);
      expect(TemplateOriginStore(state).get(remoteHash), isNotNull);
      expect(ProvisionalStore(state).overlay(shared).bundle, shared);
    },
  );
}
