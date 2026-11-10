import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/recovery_email_api.dart';
import 'package:pandapay/features/auth/recovery_email_reminder.dart';
import 'package:pandapay/features/notifications/notification_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingGate extends NotificationGate {
  _RecordingGate(Ref ref) : super(ref: ref, notifications: FlutterLocalNotificationsPlugin());
  final fired = <({String title, String body, String key, String category})>[];

  @override
  Future<bool> fire({
    required String category,
    required String title,
    required String body,
    required String dedupeKey,
    String? merchantId,
    String severity = 'info',
    String? deepLink,
    DateTime? now,
    int? notificationId,
  }) async {
    fired.add((title: title, body: body, key: dedupeKey, category: category));
    return true;
  }
}

final _probe = Provider<Ref>((ref) => ref);
final _t0 = DateTime(2026, 11, 9, 12);

({ProviderContainer container, _RecordingGate gate, Ref ref}) setup({
  bool signedIn = true,
  int statusCode = 200,
  bool hasRecovery = false,
  void Function()? onStatus,
}) {
  late _RecordingGate gate;
  final api = RecoveryEmailApi(
    authBaseUrl: 'https://auth.test',
    accessToken: 't',
    client: MockClient((_) async {
      onStatus?.call();
      return http.Response(
        '{"has_recovery_email": $hasRecovery, "recovery_email_hint": null}',
        statusCode,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  final container = ProviderContainer(
    overrides: [
      accessTokenProvider.overrideWith((ref) => signedIn ? 'token' : null),
      recoveryEmailApiProvider.overrideWithValue(signedIn ? api : null),
      notificationGateProvider.overrideWith((ref) => gate = _RecordingGate(ref)),
    ],
  );
  addTearDown(container.dispose);
  final ref = container.read(_probe);
  container.read(notificationGateProvider);
  return (container: container, gate: gate, ref: ref);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the stage is the latest of 1 hour, 1 day, 3 days and 7 days that has passed', () {
    final at = DateTime(2026, 11, 1, 9);
    expect(recoveryReminderStage(at, at.add(const Duration(minutes: 59))), 0);
    expect(recoveryReminderStage(at, at.add(const Duration(hours: 1))), 1);
    expect(recoveryReminderStage(at, at.add(const Duration(hours: 23))), 1);
    expect(recoveryReminderStage(at, at.add(const Duration(days: 1))), 2);
    expect(recoveryReminderStage(at, at.add(const Duration(days: 2, hours: 23))), 2);
    expect(recoveryReminderStage(at, at.add(const Duration(days: 3))), 3);
    expect(recoveryReminderStage(at, at.add(const Duration(days: 7))), 4);
    expect(recoveryReminderStage(at, at.add(const Duration(days: 400))), 4);
    expect(recoveryReminderStage(at, at.subtract(const Duration(hours: 5))), 0);
  });

  test('every stage has its own words and none promises more than it can do', () {
    final titles = {for (var i = 1; i <= 4; i++) recoveryReminderCopy(i).title};
    expect(titles, hasLength(4));
    for (var i = 1; i <= 4; i++) {
      expect(recoveryReminderCopy(i).body, isNotEmpty);
    }
  });

  test('a new sign-up restarts the clock; an existing account starts it when first seen', () async {
    final store = RecoveryEmailReminderStore();
    expect(await store.origin(), isNull);
    await store.ensureOrigin(_t0);
    expect((await store.origin())!.toUtc(), _t0.toUtc());
    await store.ensureOrigin(_t0.add(const Duration(days: 9)));
    expect((await store.origin())!.toUtc(), _t0.toUtc(), reason: 'the first sighting wins');
    await store.setNotifiedStage(3);
    await store.markAdded();
    await store.markSignUp(_t0.add(const Duration(days: 20)));
    expect((await store.origin())!.toUtc(), _t0.add(const Duration(days: 20)).toUtc());
    expect(await store.notifiedStage(), 0);
    expect(await store.added(), isFalse);
  });

  test('nothing happens while signed out', () async {
    final s = setup(signedIn: false);
    expect(await evaluateRecoveryReminders(s.ref, now: _t0), isFalse);
    expect(s.gate.fired, isEmpty);
  });

  test('on first sight an account is not nudged at once, only an hour later', () async {
    final s = setup();
    expect(await evaluateRecoveryReminders(s.ref, now: _t0), isFalse);
    expect(s.gate.fired, isEmpty);
    expect(await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(minutes: 30))), isFalse);
    expect(await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(hours: 1))), isTrue);
    expect(s.gate.fired.single.key, 'recovery-email-stage-1');
    expect(s.gate.fired.single.title, recoveryReminderCopy(1).title);
  });

  test('each stage fires once, a long absence fires only the latest stage', () async {
    final s = setup();
    await s.container.read(recoveryEmailReminderStoreProvider).markSignUp(_t0);
    await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(hours: 2)));
    await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(hours: 5)));
    expect(s.gate.fired.map((f) => f.key), ['recovery-email-stage-1'], reason: 'same stage never repeats');
    await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(days: 9)));
    expect(s.gate.fired.map((f) => f.key), ['recovery-email-stage-1', 'recovery-email-stage-4'],
        reason: 'stages 2 and 3 are skipped, not replayed');
    await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(days: 30)));
    expect(s.gate.fired, hasLength(2), reason: 'at most four, and the last stays the last');
  });

  test('if the account already has a recovery email nothing is shown and it stops for good', () async {
    final s = setup(hasRecovery: true);
    await s.container.read(recoveryEmailReminderStoreProvider).markSignUp(_t0);
    expect(await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(days: 2))), isFalse);
    expect(s.gate.fired, isEmpty);
    expect(await s.container.read(recoveryEmailReminderStoreProvider).added(), isTrue);
  });

  test('adding one on the phone stops the reminders without asking the server again', () async {
    var asks = 0;
    final s = setup(onStatus: () => asks++);
    final store = s.container.read(recoveryEmailReminderStoreProvider);
    await store.markSignUp(_t0);
    await store.markAdded();
    expect(await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(days: 2))), isFalse);
    expect(asks, 0);
  });

  test('an unreachable or older server never shows a reminder and does not use up the stage', () async {
    final s = setup(statusCode: 500);
    final store = s.container.read(recoveryEmailReminderStoreProvider);
    await store.markSignUp(_t0);
    expect(await evaluateRecoveryReminders(s.ref, now: _t0.add(const Duration(days: 2))), isFalse);
    expect(s.gate.fired, isEmpty);
    expect(await store.notifiedStage(), 0, reason: 'it can try again next time');
  });
}
