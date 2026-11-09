import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';

/// Reminders to add a recovery email, after sign-up: 1 hour, 1 day, 3 days and 7
/// days. They stop the moment a recovery email exists.
///
/// Each stage fires one notification, the first time the app is opened or comes
/// back to the front after that time has passed. They are not scheduled in the
/// background: the phone's alarm system is not used, so a stage reached while the
/// app is closed shows when the app is next opened. (The server also sends one
/// email at 7 days.)
const recoveryReminderOffsets = <Duration>[
  Duration(hours: 1),
  Duration(days: 1),
  Duration(days: 3),
  Duration(days: 7),
];

/// The latest stage (0 = none yet, up to 4) whose time has passed.
int recoveryReminderStage(DateTime signedUpAt, DateTime now) {
  final elapsed = now.difference(signedUpAt);
  var stage = 0;
  for (var i = 0; i < recoveryReminderOffsets.length; i++) {
    if (elapsed >= recoveryReminderOffsets[i]) stage = i + 1;
  }
  return stage;
}

/// The words for a stage (1 to 4).
({String title, String body}) recoveryReminderCopy(int stage) {
  switch (stage) {
    case 1:
      return (
        title: 'Add a recovery email',
        body: 'It takes a minute and gets you back in if you ever lose your sign-in email.',
      );
    case 2:
      return (
        title: 'Still no recovery email',
        body: 'PandaPay has no password. A recovery email is how you get back in if your sign-in email is lost.',
      );
    case 3:
      return (
        title: 'Protect your account',
        body: 'Add a recovery email so a lost sign-in email doesn’t cost you your cards and history.',
      );
    default:
      return (
        title: 'Last reminder: add a recovery email',
        body: 'Settings, then Email & phone. One minute now can save you a lot of trouble later.',
      );
  }
}

class RecoveryEmailReminderStore {
  static const _originKey = 'recovery_email_signup_at_v1';
  static const _stageKey = 'recovery_email_notified_stage_v1';
  static const _addedKey = 'recovery_email_added_v1';

  /// A new sign-up starts the clock over.
  Future<void> markSignUp(DateTime at) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_originKey, at.toUtc().toIso8601String());
    await prefs.setInt(_stageKey, 0);
    await prefs.setBool(_addedKey, false);
  }

  /// An account that was signed in before this feature existed starts its clock
  /// the first time it is seen, so it is nudged an hour later and not at once.
  Future<void> ensureOrigin(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_originKey) == null) {
      await prefs.setString(_originKey, now.toUtc().toIso8601String());
    }
  }

  Future<DateTime?> origin() async {
    final prefs = await SharedPreferences.getInstance();
    return DateTime.tryParse(prefs.getString(_originKey) ?? '')?.toLocal();
  }

  Future<int> notifiedStage() async =>
      (await SharedPreferences.getInstance()).getInt(_stageKey) ?? 0;

  Future<void> setNotifiedStage(int stage) async =>
      (await SharedPreferences.getInstance()).setInt(_stageKey, stage);

  Future<bool> added() async =>
      (await SharedPreferences.getInstance()).getBool(_addedKey) ?? false;

  Future<void> markAdded() async =>
      (await SharedPreferences.getInstance()).setBool(_addedKey, true);
}

final recoveryEmailReminderStoreProvider = Provider<RecoveryEmailReminderStore>(
  (ref) => RecoveryEmailReminderStore(),
);

/// Checks, once, whether a reminder stage is due and fires its notification. At
/// most four notifications are ever shown, and a stage is recorded before it is
/// shown so a failure never repeats it.
Future<bool> evaluateRecoveryReminders(Ref ref, {DateTime? now}) async {
  if (ref.read(accessTokenProvider) == null) return false;
  final store = ref.read(recoveryEmailReminderStoreProvider);
  if (await store.added()) return false;
  final moment = now ?? DateTime.now();
  await store.ensureOrigin(moment);
  final origin = await store.origin();
  if (origin == null) return false;
  final due = recoveryReminderStage(origin, moment);
  if (due <= await store.notifiedStage()) return false;

  // The person may have added one on another device. Ask before nagging.
  try {
    final status = await ref.read(recoveryEmailApiProvider)?.status();
    if (status == null) return false;
    if (status.hasRecoveryEmail) {
      await store.markAdded();
      return false;
    }
  } catch (_) {
    return false; // Offline or an older server: try again next time.
  }
  await store.setNotifiedStage(due);
  final copy = recoveryReminderCopy(due);
  return ref
      .read(notificationGateProvider)
      .fire(
        category: 'account_security',
        title: copy.title,
        body: copy.body,
        dedupeKey: 'recovery-email-stage-$due',
        now: moment,
      );
}

/// Watched from the signed-in shell, so it runs when the app opens and each time
/// it comes back to the front, and never in screens that mount on their own.
final recoveryEmailReminderLifecycleProvider = Provider<void>((ref) {
  Future<void> run() async {
    try {
      await evaluateRecoveryReminders(ref);
    } catch (_) {
      // A reminder is a nicety; it must never surface an error.
    }
  }

  Future.microtask(run);
  final lifecycle = AppLifecycleListener(onResume: () => Future.microtask(run));
  ref.onDispose(lifecycle.dispose);
});

/// Whether to show the reminder card in Settings: no recovery email, and at least
/// the first reminder time has passed.
final recoveryEmailNudgeProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (ref.watch(accessTokenProvider) == null) return false;
  final status = await ref.watch(recoveryEmailStatusProvider.future);
  if (status == null || status.hasRecoveryEmail) return false;
  final store = ref.read(recoveryEmailReminderStoreProvider);
  await store.ensureOrigin(DateTime.now());
  final origin = await store.origin();
  return origin != null && recoveryReminderStage(origin, DateTime.now()) >= 1;
});
