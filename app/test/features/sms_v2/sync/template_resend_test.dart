import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/sync/template_resend.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart' show aiUnreadCountIn;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SyncStateStore state;
  final t0 = DateTime.utc(2026, 11, 10, 12);

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    state = SyncStateStore(db, namespace: 'user:a');
    state.put('template:sent:aaa', '2026-11-10T08:00:00Z');
    state.put('template:sent:bbb', '2026-11-10T08:00:00Z');
    state.put('ai:aaa', '{"status":"pending"}');
    SyncStateStore(db, namespace: 'user:b').put('template:sent:zzz', 'x');
  });
  tearDown(() => db.dispose());

  const counted = AiServerStatus(
    countedNow: true,
    eligible: false,
    total: 2,
    held: 2,
  );

  test('counted now with held layouts: sent marks are forgotten, once', () {
    expect(
      resendHeldTemplates(db, namespace: 'user:a', status: counted, now: t0),
      isTrue,
    );
    expect(state.get('template:sent:aaa'), isNull);
    expect(state.get('template:sent:bbb'), isNull);
    // Results and other people's state are left alone.
    expect(state.get('ai:aaa'), isNotNull);
    expect(
      SyncStateStore(db, namespace: 'user:b').get('template:sent:zzz'),
      'x',
    );
    // Sent again and still held: no loop within six hours.
    state.put('template:sent:aaa', 'again');
    expect(
      resendHeldTemplates(
        db,
        namespace: 'user:a',
        status: counted,
        now: t0.add(const Duration(hours: 5)),
      ),
      isFalse,
    );
    expect(state.get('template:sent:aaa'), 'again');
    expect(
      resendHeldTemplates(
        db,
        namespace: 'user:a',
        status: counted,
        now: t0.add(const Duration(hours: 7)),
      ),
      isTrue,
    );
  });

  test('F-11: the resend mark is not an AI answer: the unread-AI count still works once it exists', () {
    state.put('ai:bbb', '{"status":"rejected"}');
    state.put('ai:ccc', '{"status":"failed"}');
    state.put('ai:ddd', '{"status":"ready"}');
    expect(aiUnreadCountIn(db, 'user:a'), 2);
    expect(resendHeldTemplates(db, namespace: 'user:a', status: counted, now: t0), isTrue);
    // json_extract over a bare date raised "malformed JSON" here, and the badge and the status bar lost the count.
    expect(aiUnreadCountIn(db, 'user:a'), 2);
    expect(
      db.select("SELECT key FROM v2_sync_state WHERE namespace='user:a' AND key LIKE 'ai:%' AND json_valid(value)=0"),
      isEmpty,
      reason: 'nothing under ai: is anything but an answer',
    );
  });

  test('F-11: a phone that already holds the old mark keeps honouring it, and moves it', () {
    state.put('ai:resend:at', t0.toIso8601String());
    // The count works even before the mark has been moved (a phone just updated).
    expect(aiUnreadCountIn(db, 'user:a'), 0);
    expect(
      resendHeldTemplates(db, namespace: 'user:a', status: counted, now: t0.add(const Duration(hours: 1))),
      isFalse,
      reason: 'sent an hour ago under the old key: still inside the six hours',
    );
    expect(state.get('ai:resend:at'), isNull, reason: 'the old key is gone');
    expect(state.get('template:resend:at'), t0.toIso8601String());
    expect(resendHeldTemplates(db, namespace: 'user:a', status: counted, now: t0.add(const Duration(hours: 7))), isTrue);
    expect(state.get('template:resend:at'), t0.add(const Duration(hours: 7)).toIso8601String());
  });

  test('not counted, or nothing held: nothing is touched', () {
    expect(
      resendHeldTemplates(
        db,
        namespace: 'user:a',
        status: const AiServerStatus(
          countedNow: false,
          eligible: false,
          held: 3,
        ),
        now: t0,
      ),
      isFalse,
    );
    expect(
      resendHeldTemplates(
        db,
        namespace: 'user:a',
        status: const AiServerStatus(
          countedNow: true,
          eligible: true,
          queued: 2,
        ),
        now: t0,
      ),
      isFalse,
    );
    expect(state.get('template:sent:aaa'), isNotNull);
    expect(state.get('template:resend:at'), isNull);
  });

  test('the background release asks the server at most every half hour and releases held layouts', () async {
    var asked = 0;
    Future<AiServerStatus?> fetch() async {
      asked++;
      return counted;
    }

    expect(
      await releaseHeldTemplatesInBackground(db, namespace: 'user:a', now: t0, fetchStatus: fetch),
      isTrue,
    );
    expect(asked, 1);
    expect(state.get('template:sent:aaa'), isNull, reason: 'held layouts will be sent again');
    // Ten minutes later: not asked again.
    expect(
      await releaseHeldTemplatesInBackground(db, namespace: 'user:a', now: t0.add(const Duration(minutes: 10)), fetchStatus: fetch),
      isFalse,
    );
    expect(asked, 1);
    // Half an hour later it asks again; the six-hour rule in the release itself still holds.
    state.put('template:sent:aaa', 'again');
    expect(
      await releaseHeldTemplatesInBackground(db, namespace: 'user:a', now: t0.add(const Duration(minutes: 31)), fetchStatus: fetch),
      isFalse,
    );
    expect(asked, 2);
    expect(state.get('template:sent:aaa'), 'again');
  });

  test('a failed ask is tried again in about five minutes; a phone that is not counted releases nothing', () async {
    var asked = 0;
    AiServerStatus? answer;
    Future<AiServerStatus?> fetch() async {
      asked++;
      return answer;
    }

    expect(await releaseHeldTemplatesInBackground(db, namespace: 'user:a', now: t0, fetchStatus: fetch), isFalse);
    expect(asked, 1);
    await releaseHeldTemplatesInBackground(db, namespace: 'user:a', now: t0.add(const Duration(minutes: 2)), fetchStatus: fetch);
    expect(asked, 1, reason: 'too soon after a failure');
    answer = const AiServerStatus(countedNow: false, eligible: false, total: 2, held: 2);
    await releaseHeldTemplatesInBackground(db, namespace: 'user:a', now: t0.add(const Duration(minutes: 6)), fetchStatus: fetch);
    expect(asked, 2);
    expect(state.get('template:sent:aaa'), isNotNull, reason: 'not counted: nothing is released');
  });
}
