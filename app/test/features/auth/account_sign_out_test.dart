import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';

void main() {
  AccountSignOut build(
    List<String> log, {
    bool offline = false,
    bool flushFails = false,
    String? failStep,
    SignOutReport report = const SignOutReport(
      unsynced: 2,
      phoneOnlyReceipts: 1,
      phoneOnlyReviewItems: 3,
    ),
  }) {
    Future<void> step(String name, {bool network = false}) async {
      log.add(name);
      if (network && offline) throw Exception('offline');
      if (failStep == name) throw StateError('$name failed');
    }

    return AccountSignOut(
      flushOutboxes: () async {
        log.add('flush');
        if (flushFails) throw Exception('offline');
      },
      report: () async => report,
      unregisterPush: () => step('push', network: true),
      revokeSession: () => step('revoke', network: true),
      closeDatabases: () => step('close'),
      destroyKeysAndTokens: () => step('keys'),
      deleteFiles: () => step('files'),
      clearWidgetsAndNotifications: () => step('widgets'),
      clearPreferences: () => step('prefs'),
      resetSession: () => log.add('reset'),
    );
  }

  test('prepare uploads first, then reports what would be lost', () async {
    final log = <String>[];
    final report = await build(log).prepare();
    expect(log, ['flush']);
    expect(report.unsynced, 2);
    expect(report.losesSomething, isTrue);
  });

  test('prepare still reports when the upload fails', () async {
    final log = <String>[];
    final report = await build(log, flushFails: true).prepare();
    expect(report.unsynced, 2);
  });

  test('prepare gives up on a stuck upload after the timeout', () async {
    final signOut = AccountSignOut(
      flushOutboxes: () => Completer<void>().future,
      report: () async => const SignOutReport(
        unsynced: 1,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
      ),
      unregisterPush: () async {},
      revokeSession: () async {},
      closeDatabases: () async {},
      destroyKeysAndTokens: () async {},
      deleteFiles: () async {},
      clearWidgetsAndNotifications: () async {},
      clearPreferences: () async {},
      resetSession: () {},
    );
    final report = await signOut.prepare(
      timeout: const Duration(milliseconds: 20),
    );
    expect(report.unsynced, 1);
  });

  test(
    'run revokes on the server before destroying keys, then deletes files',
    () async {
      final log = <String>[];
      final outcome = await build(log).run();
      expect(log, [
        'push',
        'revoke',
        'close',
        'keys',
        'files',
        'widgets',
        'prefs',
        'reset',
      ]);
      expect(outcome.complete, isTrue);
    },
  );

  test('an offline sign-out still wipes the phone', () async {
    final log = <String>[];
    final outcome = await build(log, offline: true).run();
    expect(log.last, 'reset');
    expect(log, containsAllInOrder(['keys', 'files']));
    expect(outcome.complete, isTrue);
  });

  test(
    'a failing wipe step does not stop the later steps or the reset',
    () async {
      final log = <String>[];
      final outcome = await build(log, failStep: 'keys').run();
      expect(log, containsAllInOrder(['files', 'widgets', 'prefs', 'reset']));
      expect(outcome.failedSteps, ['keys']);
      expect(outcome.complete, isFalse);
    },
  );

  group('warning copy', () {
    SignOutReport r(int u, int p, int v) => SignOutReport(
      unsynced: u,
      phoneOnlyReceipts: p,
      phoneOnlyReviewItems: v,
    );

    test('names every count that is not zero', () {
      expect(
        signOutWarningMessage(r(2, 1, 3)),
        "2 changes haven't reached PandaPay yet, and 1 receipt and 3 "
        'messages to review are stored only on this phone. '
        'Signing out deletes them from this phone.',
      );
    });

    test('omits a zero-count clause', () {
      expect(
        signOutWarningMessage(r(0, 4, 0)),
        '4 receipts are stored only on this phone. '
        'Signing out deletes them from this phone.',
      );
      expect(
        signOutWarningMessage(r(3, 0, 0)),
        "3 changes haven't reached PandaPay yet. "
        'Signing out deletes them from this phone.',
      );
      expect(
        signOutWarningMessage(r(0, 0, 5)),
        '5 messages to review are stored only on this phone. '
        'Signing out deletes them from this phone.',
      );
    });

    test('uses singular wording for one item', () {
      expect(
        signOutWarningMessage(r(1, 0, 0)),
        "1 change hasn't reached PandaPay yet. "
        'Signing out deletes it from this phone.',
      );
      expect(
        signOutWarningMessage(r(0, 0, 1)),
        '1 message to review is stored only on this phone. '
        'Signing out deletes it from this phone.',
      );
    });

    test('nothing to lose means no warning', () {
      expect(r(0, 0, 0).losesSomething, isFalse);
      expect(signOutWarningMessage(r(0, 0, 0)), isEmpty);
    });
  });
}
