import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/sync/template_resend.dart';
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
    expect(state.get('ai:resend:at'), isNull);
  });
}
