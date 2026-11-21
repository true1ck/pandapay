import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_answer_restore.dart';
import 'package:sqlite3/sqlite3.dart';

// A phone that lost its saved AI answers (or never had them) while the server
// has already answered must be able to get them back: the server only sends an
// answer once per position of the sync cursor, so the position has to be
// wound back, and the formats have to be looked at again so each answer can be
// linked to this phone's own messages.
void main() {
  const ns = 'user:1';
  final now = DateTime.utc(2026, 11, 20, 12);
  late Database db;
  late SyncStateStore state;

  String cursor(Map<String, Object?> parts) =>
      base64Url.encode(utf8.encode(jsonEncode(parts))).replaceAll('=', '');
  Map<String, Object?> parts() {
    final raw = state.get('pull:cursor')!;
    return (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw)))) as Map).cast();
  }

  void openTemplateItem() => db.execute(
    'INSERT INTO v2_review_items VALUES(?,?,?,?,?)',
    [ns, 's1', 'template', jsonEncode({'sourceKey': 's1'}), 'open'],
  );

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    state = SyncStateStore(db, namespace: ns);
    state.put(
      'pull:cursor',
      cursor({'i': ['2026-11-01T00:00:00.000000Z', 'x'], 'a': '812', 'c': '9'}),
    );
    state.put('template:scanned:s1', 'h');
    state.put('template:sent:h', now.toIso8601String());
  });
  tearDown(() => db.dispose());

  test('no saved answers and an open format: the answer position and the '
      'format marks are wound back, once', () {
    openTemplateItem();
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
    final p = parts();
    expect(p.containsKey('a'), isFalse, reason: 'the server answers from the start again');
    expect(p['c'], '9', reason: 'nothing else about the position changes');
    expect(p['i'], isNotNull);
    expect(state.get('template:scanned:s1'), isNull);
    expect(state.get('template:sent:h'), isNull);
    expect(state.get('restore:ai:at'), isNotNull);
  });

  test('a question about a message an AI rule already read waits for no answer: nothing is wound back', () {
    openTemplateItem();
    db.execute(
      'INSERT INTO v2_facts(namespace,fact_id,source_key,fact_type,observed_at,payload) VALUES(?,?,?,?,?,?)',
      [ns, 'f1', 's1', 'movement', '2026-11-01T00:00:00Z', '{}'],
    );
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isFalse);
    expect(parts().containsKey('a'), isTrue, reason: 'the cursor was not touched');
    // A second, unread format is what makes it act.
    db.execute(
      'INSERT INTO v2_review_items VALUES(?,?,?,?,?)',
      [ns, 's2', 'template', jsonEncode({'sourceKey': 's2'}), 'open'],
    );
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
  });

  test('it does not repeat within six hours, then may try again', () {
    openTemplateItem();
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
    state.put('pull:cursor', cursor({'a': '5'}));
    expect(restoreLostAiAnswers(db, namespace: ns, now: now.add(const Duration(hours: 5))), isFalse);
    expect(parts()['a'], '5');
    expect(restoreLostAiAnswers(db, namespace: ns, now: now.add(const Duration(hours: 7))), isTrue);
    expect(parts().containsKey('a'), isFalse);
  });

  test('a phone that holds answers is left alone', () {
    openTemplateItem();
    state.put('ai:${'a' * 64}', jsonEncode({'templateHash': 'a' * 64, 'status': 'ready', 'rule': {'id': 'AI-x'}}));
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isFalse);
    expect(parts()['a'], '812');
    expect(state.get('template:scanned:s1'), 'h');
  });

  test('a phone with no open unreadable format has nothing to restore', () {
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isFalse);
    expect(parts()['a'], '812');
  });

  test('a timestamp stored under an ai: key is not an answer', () {
    openTemplateItem();
    state.put('ai:resend:at', now.toIso8601String());
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
  });

  test('a cursor that cannot be read is left as it is, and the marks are still reset', () {
    openTemplateItem();
    state.put('pull:cursor', 'not-a-cursor');
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
    expect(state.get('pull:cursor'), 'not-a-cursor');
    expect(state.get('template:scanned:s1'), isNull);
  });

  test('no cursor yet (a first sync) still resets the marks', () {
    openTemplateItem();
    db.execute("DELETE FROM v2_sync_state WHERE key='pull:cursor'");
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
    expect(state.get('pull:cursor'), isNull);
  });

  test("another account's state is not touched", () {
    openTemplateItem();
    SyncStateStore(db, namespace: 'user:2').put('template:sent:z', 'x');
    restoreLostAiAnswers(db, namespace: ns, now: now);
    expect(SyncStateStore(db, namespace: 'user:2').get('template:sent:z'), 'x');
  });

  test('its own bookkeeping never breaks the queries that read every ai: row', () {
    openTemplateItem();
    expect(restoreLostAiAnswers(db, namespace: ns, now: now), isTrue);
    // DraftVerifier and others run json_extract over every key starting "ai:":
    // a non-JSON value under such a key throws "malformed JSON".
    expect(
      () => db.select(
        "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' AND json_extract(value,'\$.status')='ready'",
        [ns],
      ),
      returnsNormally,
    );
  });
}
