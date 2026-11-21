import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay/features/sms_v2/sync/draft_check.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:sqlite3/sqlite3.dart';

// Every message, name and number is invented.
void main() {
  late AppDatabase db;
  late SmsIntakeRepository intake;
  late OutboxStore queue;
  late SyncStateStore state;
  var now = DateTime.utc(2026, 11);

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    SmsV2Schema.ensure(db.db);
    intake = SmsIntakeRepository(db);
    queue = OutboxStore(db.db, namespace: 'a');
    state = SyncStateStore(db.db, namespace: 'a');
    now = DateTime.utc(2026, 11);
  });
  tearDown(() => db.db.dispose());

  /// A message waiting in Needs review as an unknown layout.
  String open(String body, {String sender = 'HDFCBK'}) {
    final source = smsSourceKey('a', sender, body);
    intake.remember('a', QueuedSms(sender: sender, body: body, receivedAt: now));
    db.db.execute('INSERT OR IGNORE INTO v2_review_items VALUES(?,?,?,?,?)', [
      'a', source, 'template', jsonEncode({'sourceKey': source, 'templateHash': 'a' * 64}), 'open',
    ]);
    return source;
  }

  /// Layout number [i] differs from every other in how many plain words it has.
  String plain(int i) => 'Alert ${List.filled(i, 'info').join(' ')} Rs.500.00 debited from A/c XX6789';

  TemplateUpload uploader(
    Future<http.Response> Function(List<Map> items) answer, {
    bool Function()? current,
    DateTime Function()? clock,
  }) => TemplateUpload(
    intake: intake,
    queue: queue,
    baseUri: Uri.parse('https://api.invalid'),
    headers: () async => {},
    hasConsent: () async => true,
    accountIsCurrent: current ?? () => true,
    clock: clock ?? () => now,
    client: MockClient((request) async => answer(((jsonDecode(request.body) as Map)['items'] as List).cast<Map>())),
  );

  Future<http.Response> acceptAll(List<Map> items) async =>
      http.Response(jsonEncode({'accepted': [for (final item in items) item['templateHash']]}), 202);

  int outboxCount() => db.db.select("SELECT count(*) n FROM v2_outbox WHERE kind='template'").first['n'] as int;

  group('S1-5: a layout the server keeps refusing', () {
    test('it is sent alone and backed off for longer each time; the others are never carried into its failed request', () async {
      final poison = plain(3);
      open(poison);
      var requestsWithPoison = 0, carriedInnocents = 0, innocentsAccepted = 0;
      bool isPoison(Map item) => 'info'.allMatches(item['redactedBody'] as String).length == 3;
      final up = uploader((items) async {
        if (items.any(isPoison)) {
          requestsWithPoison++;
          carriedInnocents += items.where((i) => !isPoison(i)).length;
          return http.Response('{"error":"template_invalid"}', 400);
        }
        innocentsAccepted += items.length;
        return acceptAll(items);
      });
      var next = 10;
      // Twelve passes, seven hours apart (three and a half days): each brings nine new layouts.
      for (var pass = 0; pass < 12; pass++) {
        for (var k = 0; k < 9; k++) {
          open(plain(next++));
        }
        await up.drain();
        now = now.add(const Duration(hours: 7));
      }
      expect(innocentsAccepted, 12 * 9, reason: 'every innocent layout went up, in the pass it arrived');
      expect(carriedInnocents, lessThanOrEqualTo(9), reason: 'only the one batch that first found it (it was 108, one batch in every pass): a layout already refused is never put in a batch with others');
      expect(requestsWithPoison, lessThanOrEqualTo(4), reason: 'it was 12: one every six hours, for ever');
      expect(outboxCount(), 1, reason: 'the refused layout is kept, not lost');
      // However long it has been refused, it comes back at least weekly: a refusal that was the server's fault ends.
      now = now.add(const Duration(days: 8));
      expect(queue.due(now).where((r) => r.kind == 'template'), hasLength(1));
    });

    test('a layout that is accepted after refusals is sent normally again, and forgets its refusals', () async {
      open(plain(3));
      var refuse = true;
      final up = uploader((items) async => refuse ? http.Response('{}', 400) : acceptAll(items));
      await up.drain();
      expect(db.db.select("SELECT key FROM v2_sync_state WHERE key LIKE 'template:refused:%'"), hasLength(1));
      refuse = false;
      now = now.add(const Duration(hours: 7));
      await up.drain();
      expect(outboxCount(), 0);
      expect(db.db.select("SELECT key FROM v2_sync_state WHERE key LIKE 'template:refused:%'"), isEmpty);
    });
  });

  group('S1-6: work per sync pass', () {
    test('layouts waiting behind thousands of other outbox rows still go up (the kind is chosen in SQL, not after a limit)', () async {
      for (var i = 0; i < 2600; i++) {
        queue.enqueue('source', 'row$i', {'n': i});
      }
      open(plain(1));
      final sent = <String>[];
      await uploader((items) async {
        sent.addAll(items.map((i) => i['templateHash'] as String));
        return acceptAll(items);
      }).drain();
      expect(sent, hasLength(1), reason: 'the layout was behind 2,600 rows of another kind and never got a look in');
    });

    test('a pass reads at most a bounded number of new messages; the rest wait for the next pass, and nothing is read twice', () async {
      const total = 700;
      for (var i = 1; i <= total; i++) {
        open(plain(i));
      }
      final up = uploader(acceptAll);
      var passes = 0;
      final reads = <int>[];
      while (outboxCount() + (db.db.select("SELECT count(*) n FROM v2_sync_state WHERE key LIKE 'template:sent:%'").first['n'] as int) < total &&
          passes < 20) {
        final before = TemplateUpload.messagesRedacted;
        await up.drain();
        reads.add(TemplateUpload.messagesRedacted - before);
        passes++;
      }
      expect(reads.every((n) => n <= TemplateUpload.maxScannedPerPass), isTrue, reason: '$reads');
      expect(reads.fold<int>(0, (a, b) => a + b), total, reason: 'every message is read exactly once: $reads');
      expect(passes, greaterThan(1));
      final before = TemplateUpload.messagesRedacted;
      await up.drain();
      expect(TemplateUpload.messagesRedacted, before, reason: 'a settled backlog costs no redaction at all');
    });

    test('messages that can never be uploaded are not read again at every pass', () async {
      // 600 wordings of one layout past the room an origin has, and messages whose layout has too many name slots.
      final over = TemplateOriginStore.maxOrigins + 600;
      for (var i = 0; i < over; i++) {
        open('Rs.450.00 paid to ${_name(i)} on 20-11-26. Ref 123456789012', sender: 'ALPHAB');
      }
      final tooMany = List.generate(10, (i) => 'Paid Rs.${100 + i}.00 to ${[for (var k = 0; k < 10; k++) _name(1000 * (i + 1) + k)].join(', ')} and ${_name(77 + i)}');
      for (final body in tooMany) {
        open(body, sender: 'ALPHAB');
      }
      final up = uploader(acceptAll);
      // Drain until everything has been looked at once.
      for (var i = 0; i < 12; i++) {
        await up.drain();
      }
      final before = TemplateUpload.messagesRedacted;
      final sw = Stopwatch()..start();
      await up.drain();
      await up.drain();
      expect(TemplateUpload.messagesRedacted - before, 0, reason: 'settled: no message is read again');
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('F-1: wordings of one layout', () {
    test('a layout read at more wordings than the old bound of 32 keeps every wording up to the new bound', () async {
      const variants = 150;
      for (var i = 0; i < variants; i++) {
        open('Rs.450.00 paid to ${_name(i)} on 20-11-26. Ref 123456789012', sender: 'ALPHAB');
      }
      final hashes = <String>{};
      final up = uploader((items) async {
        hashes.addAll(items.map((i) => i['templateHash'] as String));
        return acceptAll(items);
      });
      for (var i = 0; i < 6; i++) {
        await up.drain();
      }
      expect(hashes, hasLength(1), reason: '150 names, one layout');
      final origin = TemplateOriginStore(state).get(hashes.single)!;
      expect(origin.localHashes.length, greaterThan(32), reason: 'it was capped at 32');
      expect(origin.localHashes.length, TemplateOriginStore.maxOrigins);
      expect(TemplateOriginStore.maxOrigins, lessThan(variants), reason: 'the bound is a bound');
    });
  });

  group('S1-8: a layout the server would refuse for its name slots', () {
    test('is not uploaded, costs no upload slot, and is not read again; its neighbours go up', () async {
      final tooMany =
          'Paid Rs.450.00 to ${List.generate(13, (i) => _name(i + 1)).join(', ')} on 20-11-26';
      open(tooMany, sender: 'ALPHAB');
      open(plain(2), sender: 'ALPHAB');
      final sent = <Map>[];
      final up = uploader((items) async {
        sent.addAll(items);
        return acceptAll(items);
      });
      await up.drain();
      expect(sent, hasLength(1), reason: 'only the ordinary layout is sent');
      for (final item in sent) {
        expect(smsLayoutWildcards(item['redactedBody'] as String), lessThanOrEqualTo(smsMaxAnchoredLayoutWildcards));
      }
      final before = TemplateUpload.messagesRedacted;
      await up.drain();
      expect(TemplateUpload.messagesRedacted, before);
    });
  });

  group('S1-9: a sender header with punctuation', () {
    const body = 'Dear Customer, Rs.500.00 sent to Joes Bakery on 20-11-26. Ref 111122223333';

    test('is filed under the brand the server derives, and the hash is of that brand and the body', () async {
      open(body, sender: 'AD-SBI-UPI');
      final sent = <Map>[];
      await uploader((items) async {
        sent.addAll(items);
        return acceptAll(items);
      }).drain();
      expect(sent, hasLength(1), reason: 'SBI-UPI was skipped for ever');
      final item = sent.single;
      // What api/src/sms_v2/upload_hygiene.js cleanSenderBrand makes of the header, and the digest the server checks.
      expect(item['senderBrand'], 'SBIUPI');
      expect(item['templateHash'], sha256.convert(utf8.encode('SBIUPI\n${item['redactedBody']}')).toString());
      expect(item['senderBrand'], matches(RegExp(r'^[A-Z0-9]+$')), reason: 'the contract pattern of unknown_templates');
    });

    test('and its draft reads the messages under the header the phone knows them by', () async {
      open(body, sender: 'AD-SBI-UPI');
      final sent = <Map>[];
      await uploader((items) async {
        sent.addAll(items);
        return acceptAll(items);
      }).drain();
      final remoteHash = sent.single['templateHash'] as String;
      final json = (jsonDecode(File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync()) as Map).cast<String, Object?>();
      final all = RuleBundle.fromJson(json);
      final base = all.rules.firstWhere((r) => r.status == RuleStatus.provisional);
      final shared = RuleBundle.fromJson({
        ...json,
        'rules': [
          for (final r in all.rules)
            if (r.status != RuleStatus.provisional) r.toJson(),
        ],
      });
      final rule = {
        ...base.toJson(),
        'id': 'AI-$remoteHash',
        'version': 1,
        'status': 'provisional',
        'createdBy': 'ai:synthetic',
        'senders': ['SBIUPI'],
        'match': {
          'pattern': r'^Dear Customer, Rs\.(?<amt>\d+(?:\.\d{1,2})?) sent to (?<merchant>[A-Za-z ]+) on [\d-]+\. Ref \d+$',
          'flags': 'i',
          'templateHash': remoteHash,
        },
        'emit': [
          {
            'factType': 'movement',
            'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'upi'},
            'amounts': [
              {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
            ],
            'counterparty': {'nameFrom': 'merchant', 'kind': 'merchant'},
          },
        ],
      };
      state.put('ai:$remoteHash', jsonEncode({'templateHash': remoteHash, 'status': 'ready', 'rule': rule}));
      final overlay = ProvisionalStore(state).overlay(shared);
      expect(overlay.bundle.rules, hasLength(shared.rules.length + 1));
      final result = RuleEngine().interpret(
        SmsMessage(sender: 'AD-SBI-UPI', body: body, observedAt: now, sourceKey: 's'),
        overlay.bundle,
        appVersion: 'test',
      );
      expect(result.outcome, InterpretOutcome.matched, reason: 'the private copy carries the header the engine matches on');
      // The phone's own check of the draft (draft_check.dart) must not refuse it for the same reason.
      final check = checkDraft(
        sharedJson: shared.toJson(),
        result: {'templateHash': remoteHash, 'status': 'ready', 'rule': rule},
        senderBrand: 'SBIUPI',
        messages: [(sender: 'AD-SBI-UPI', body: body, receivedAt: now)],
      );
      expect(check, DraftCheck.pass);
    });

    test('a brand without punctuation sends exactly what it sent before (hashes of uploaded layouts do not move)', () async {
      open('Rs.450.00 paid to Joes Bakery on 20-11-26. Ref 123456789012', sender: 'VM-HDFCBK-S');
      final sent = <Map>[];
      await uploader((items) async {
        sent.addAll(items);
        return acceptAll(items);
      }).drain();
      final item = sent.single;
      expect(item['senderBrand'], 'HDFCBK');
      expect(item['templateHash'], smsTemplateHash('HDFCBK', item['redactedBody'] as String));
    });
  });

  test('consent withdrawn forgets the refusal counts and the scan marks too', () async {
    open(plain(3));
    open(plain(4));
    var consent = true;
    final up = TemplateUpload(
      intake: intake,
      queue: queue,
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      hasConsent: () async => consent,
      accountIsCurrent: () => true,
      clock: () => now,
      client: MockClient((request) async => http.Response('{}', 400)),
    );
    await up.drain();
    state.put('template:resend:at', now.toIso8601String());
    expect(db.db.select("SELECT key FROM v2_sync_state WHERE key LIKE 'template:%'"), isNotEmpty);
    consent = false;
    await up.drain();
    expect(
      db.db.select("SELECT key FROM v2_sync_state WHERE namespace='a' AND (key LIKE 'template:scanned:%' OR key LIKE 'template:refused:%' OR key LIKE 'template:origins:%' OR key='template:resend:at')"),
      isEmpty,
    );
  });
}

/// A name that is a different word for every [i], and that redaction hides.
String _name(int i) {
  var n = i, s = '';
  do {
    s = String.fromCharCode(97 + n % 26) + s;
    n ~/= 26;
  } while (n > 0);
  return 'Zq${s[0].toUpperCase()}${s.substring(1)}x';
}
