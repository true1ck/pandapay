// "Try again" for a message format the AI could not read: the phone's own marks, the server call and its limits.
// Invented data only.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/template_retry.dart';
import 'package:pandapay/features/sms_v2/sync/template_upload.dart';
import 'package:sqlite3/sqlite3.dart';

String _h(String c) => c * 64;

void main() {
  const ns = 'user:one';
  final local = _h('a'); // the phone's own hash of the message format
  final remote = _h('b'); // the hash it was sent as
  final otherLocal = _h('c');
  final otherRemote = _h('d');
  late Database db;
  late SyncStateStore state;
  var now = DateTime.utc(2026, 11, 21, 10);

  setUp(() {
    now = DateTime.utc(2026, 11, 21, 10);
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    state = SyncStateStore(db, namespace: ns);
    for (final (loc, rem) in [(local, remote), (otherLocal, otherRemote)]) {
      state.put(
        'template:origins:$rem',
        jsonEncode({'senderBrand': 'SYNTHBK', 'localHashes': [loc]}),
      );
      state.put('template:sent:$rem', '2026-11-20T09:00:00Z');
      state.put('template:refused:$rem', '2');
      state.put('draft:verdict:$rem', jsonEncode({'draftId': 'x', 'verdict': 'rejected'}));
    }
    state.put('ai:$remote', jsonEncode({'status': 'failed', 'templateHash': remote}));
    state.put('ai:$otherRemote', jsonEncode({'status': 'failed', 'templateHash': otherRemote}));
    state.put('template:scanned:msg-1', remote);
    state.put('template:scanned:msg-2', 'skip:v2:1.1.1');
    state.put('template:wait', '2026-11-21T11:00:00Z');
  });
  tearDown(() => db.dispose());

  TemplateRetry retry() => TemplateRetry(db, namespace: ns, clock: () => now);

  test('the shared layouts of a message format come from the saved origins, one pass', () {
    expect(retry().remoteHashesOf(local), [remote]);
    expect(retry().remoteHashesOf(_h('9')), isEmpty);
    expect(retry().index(), {local: [remote], otherLocal: [otherRemote]});
  });

  test('reset clears this phone\'s marks for that layout only, and makes the queued upload due now', () {
    final queue = OutboxStore(db, namespace: ns);
    queue.enqueue('template', remote, {'templateHash': remote});
    queue.enqueue('template', otherRemote, {'templateHash': otherRemote});
    db.execute("UPDATE v2_outbox SET next_attempt_at=? WHERE kind='template'", [9999999999999]);

    final reset = retry().reset(local, sourceKeys: ['msg-1', 'msg-2']);
    expect(reset, [remote]);
    for (final key in ['template:sent:$remote', 'template:refused:$remote', 'ai:$remote', 'draft:verdict:$remote']) {
      expect(state.get(key), isNull, reason: key);
    }
    expect(state.get('template:scanned:msg-1'), isNull, reason: 'read again at the next pass');
    expect(state.get('template:scanned:msg-2'), 'skip:v2:1.1.1', reason: 'never uploadable: left as it is');
    // The other layout is untouched.
    expect(state.get('template:sent:$otherRemote'), isNotNull);
    expect(state.get('ai:$otherRemote'), isNotNull);
    // The server's own 429 wait on the whole queue is not ours to clear.
    expect(state.get('template:wait'), isNotNull);
    final due = {
      for (final row in db.select("SELECT id,next_attempt_at FROM v2_outbox WHERE kind='template'"))
        row['id'] as String: row['next_attempt_at'] as int,
    };
    expect(due['template:$remote'], 0);
    expect(due['template:$otherRemote'], 9999999999999);
  });

  test('a layout that was never sent has nothing to retry', () {
    expect(retry().reset(_h('9')), isEmpty);
  });

  test('once per five minutes per layout, then again', () {
    expect(retry().canTry(local), isTrue);
    expect(retry().reset(local), [remote]);
    expect(retry().canTry(local), isFalse);
    expect(retry().reset(local), isEmpty, reason: 'pressed again at once: nothing happens');
    expect(retry().canTry(otherLocal), isTrue, reason: 'another layout has its own clock');
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(retry().canTry(local), isFalse);
    now = now.add(const Duration(seconds: 2));
    expect(retry().canTry(local), isTrue);
  });

  test('"Trying again" shows from the press until a new answer arrives, for at most a day', () {
    expect(retry().isRetrying(local), isFalse);
    retry().reset(local);
    expect(retry().isRetrying(local), isTrue);
    expect(retry().isRetrying(otherLocal), isFalse);
    // The server answers: the answer row is back.
    state.put('ai:$remote', jsonEncode({'status': 'failed', 'templateHash': remote}));
    expect(retry().isRetrying(local), isFalse);
    // An answer that never comes does not keep the card on "Trying again" for ever.
    db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [ns, 'ai:$remote']);
    expect(retry().isRetrying(local), isTrue);
    now = now.add(TemplateRetry.showFor);
    expect(retry().isRetrying(local), isFalse);
  });

  test('withdrawing sharing forgets the retry marks with everything else it shared', () {
    retry().reset(local);
    expect(state.get('template:retry:$remote'), isNotNull);
    TemplateUpload.forgetSharedState(OutboxStore(db, namespace: ns));
    expect(state.get('template:retry:$remote'), isNull);
  });

  group('the server call', () {
    Uri base = Uri.parse('https://api.invalid');
    Future<Map<String, String>> headers() async => {'Authorization': 'Bearer fixture'};

    test('POST /sms/v2/ai-status/retry with the hashes, at most 20; 202 says how many were requeued', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return http.Response(jsonEncode({'requeued': 3}), 202);
      });
      final n = await requestServerRetry(
        client: client,
        baseUri: base,
        headers: headers,
        templateHashes: [for (var i = 0; i < 25; i++) _h('${i % 10}')],
      );
      expect(n, 3);
      expect(seen, hasLength(1), reason: 'one press, one request');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/sms/v2/ai-status/retry');
      expect(seen.single.headers['Authorization'], 'Bearer fixture');
      expect(((jsonDecode(seen.single.body) as Map)['templateHashes'] as List).length, 20);
    });

    test('a 404 (the endpoint is not there yet), any error, a timeout or no connection: null, no throw', () async {
      for (final response in [404, 400, 429, 500, 503]) {
        expect(
          await requestServerRetry(
            client: MockClient((_) async => http.Response('', response)),
            baseUri: base,
            headers: headers,
            templateHashes: [remote],
          ),
          isNull,
          reason: '$response',
        );
      }
      expect(
        await requestServerRetry(
          client: MockClient((_) async => throw http.ClientException('offline')),
          baseUri: base,
          headers: headers,
          templateHashes: [remote],
        ),
        isNull,
      );
      expect(
        await requestServerRetry(
          client: MockClient((_) async => throw StateError('headers failed')),
          baseUri: base,
          headers: () async => throw StateError('no token'),
          templateHashes: [remote],
        ),
        isNull,
      );
    });

    test('a 2xx with an unreadable body still counts as taken; no hashes sends nothing', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('ok', 200);
      });
      expect(
        await requestServerRetry(client: client, baseUri: base, headers: headers, templateHashes: [remote]),
        0,
      );
      expect(
        await requestServerRetry(client: client, baseUri: base, headers: headers, templateHashes: const []),
        isNull,
      );
      expect(calls, 1);
    });
  });
}
