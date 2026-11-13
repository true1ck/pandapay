import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';

/// WP-C3 / L-01: the sign-out records that the person chose it before any
/// step that drops the session token runs.
void main() {
  AccountSignOut build(List<String> log, {Object? startedThrows}) {
    Future<void> step(String name) async => log.add(name);
    return AccountSignOut(
      flushOutboxes: () async {},
      report: () async => const SignOutReport(
        unsynced: 0,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
      ),
      unregisterPush: () => step('push'),
      revokeSession: () => step('revoke'),
      closeDatabases: () => step('close'),
      destroyKeysAndTokens: () => step('keys'),
      deleteFiles: () => step('files'),
      clearWidgetsAndNotifications: () => step('widgets'),
      clearPreferences: () => step('prefs'),
      resetSession: () => log.add('reset'),
      onSignOutStarted: () {
        log.add('started');
        if (startedThrows != null) throw startedThrows;
      },
    );
  }

  test('onSignOutStarted runs before the first server or wipe step', () async {
    final log = <String>[];
    await build(log).run();
    expect(log.first, 'started');
    expect(log.indexOf('started'), lessThan(log.indexOf('push')));
    expect(log.indexOf('started'), lessThan(log.indexOf('close')));
  });

  test('a failing callback never stops the wipe', () async {
    final log = <String>[];
    final outcome = await build(log, startedThrows: StateError('x')).run();
    expect(outcome.complete, isTrue);
    expect(log, containsAll(['keys', 'files', 'reset']));
  });
}
