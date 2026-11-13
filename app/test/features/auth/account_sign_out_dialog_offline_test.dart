import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';
import 'package:pandapay/features/auth/account_sign_out_dialog.dart';

/// WP-C3 / L-02: offline with changes waiting, the dialog says plainly that
/// the changes will be lost and needs a button that names the loss.
AccountSignOut _signOut(SignOutReport report, List<String> log) =>
    AccountSignOut(
      flushOutboxes: () async => log.add('flush'),
      report: () async => report,
      unregisterPush: () async => log.add('push'),
      revokeSession: () async => log.add('revoke'),
      closeDatabases: () async => log.add('close'),
      destroyKeysAndTokens: () async => log.add('keys'),
      deleteFiles: () async => log.add('files'),
      clearWidgetsAndNotifications: () async => log.add('widgets'),
      clearPreferences: () async => log.add('prefs'),
      resetSession: () => log.add('reset'),
    );

Future<List<bool?>> _open(WidgetTester tester, AccountSignOut signOut) async {
  final results = <bool?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  results.add(await confirmAndSignOut(context, signOut)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

const _offline = SignOutReport(
  unsynced: 5,
  phoneOnlyReceipts: 0,
  phoneOnlyReviewItems: 0,
  pendingKinds: [
    PendingKind(singular: 'new expense', plural: 'new expenses', count: 3),
    PendingKind(singular: 'queued change', plural: 'queued changes', count: 2),
  ],
  connection: SignOutConnection.offline,
);

void main() {
  testWidgets('offline: names the loss, nothing is wiped until confirmed', (
    tester,
  ) async {
    final log = <String>[];
    final results = await _open(tester, _signOut(_offline, log));

    expect(find.text("You're offline"), findsOneWidget);
    expect(find.textContaining('Your phone is offline'), findsOneWidget);
    expect(
      find.textContaining('5 changes (3 new expenses, 2 queued changes)'),
      findsOneWidget,
    );
    expect(find.text('Sign out and lose 5 changes'), findsOneWidget);
    expect(find.text('Stay signed in'), findsOneWidget);
    // The generic one-tap wording is not offered here.
    expect(find.text('Sign out anyway'), findsNothing);
    expect(log, ['flush'], reason: 'no wipe step ran yet');

    await tester.tap(find.text('Stay signed in'));
    await tester.pumpAndSettle();

    expect(results, [false]);
    expect(log, ['flush']);
  });

  testWidgets('offline: the explicit button signs out', (tester) async {
    final log = <String>[];
    final results = await _open(tester, _signOut(_offline, log));

    await tester.tap(find.text('Sign out and lose 5 changes'));
    await tester.pumpAndSettle();

    expect(results, [true]);
    expect(log, containsAll(['keys', 'files', 'reset']));
  });

  testWidgets('PandaPay unreachable gets its own title', (tester) async {
    final log = <String>[];
    await _open(
      tester,
      _signOut(
        const SignOutReport(
          unsynced: 1,
          phoneOnlyReceipts: 0,
          phoneOnlyReviewItems: 0,
          connection: SignOutConnection.unreachable,
        ),
        log,
      ),
    );

    expect(find.text("Can't reach PandaPay"), findsOneWidget);
    expect(find.text('Sign out and lose this change'), findsOneWidget);
  });

  testWidgets('online with leftovers keeps the usual dialog', (tester) async {
    final log = <String>[];
    await _open(
      tester,
      _signOut(
        const SignOutReport(
          unsynced: 1,
          phoneOnlyReceipts: 0,
          phoneOnlyReviewItems: 0,
        ),
        log,
      ),
    );
    expect(find.text('Sign out of PandaPay?'), findsOneWidget);
    expect(find.text('Sign out anyway'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });
}
