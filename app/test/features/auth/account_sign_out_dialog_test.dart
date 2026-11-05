import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';
import 'package:pandapay/features/auth/account_sign_out_dialog.dart';

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

void main() {
  const loses = SignOutReport(
    unsynced: 2,
    phoneOnlyReceipts: 1,
    phoneOnlyReviewItems: 3,
  );
  const clean = SignOutReport(
    unsynced: 0,
    phoneOnlyReceipts: 0,
    phoneOnlyReviewItems: 0,
  );

  testWidgets('warns with counts and wipes only after Sign out anyway', (
    tester,
  ) async {
    final log = <String>[];
    final results = await _open(tester, _signOut(loses, log));

    expect(find.text('Sign out of PandaPay?'), findsOneWidget);
    expect(
      find.text(
        "2 changes haven't reached PandaPay yet, and 1 receipt and 3 "
        'messages to review are stored only on this phone. '
        'Signing out deletes them from this phone.',
      ),
      findsOneWidget,
    );
    expect(log, ['flush']);

    await tester.tap(find.text('Sign out anyway'));
    await tester.pumpAndSettle();

    expect(log.last, 'reset');
    expect(log, contains('keys'));
    expect(results, [true]);
  });

  testWidgets('Cancel keeps the account and the data', (tester) async {
    final log = <String>[];
    final results = await _open(tester, _signOut(loses, log));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(log, ['flush']);
    expect(results, [false]);
  });

  testWidgets('nothing to lose signs out without a warning', (tester) async {
    final log = <String>[];
    final results = await _open(tester, _signOut(clean, log));

    expect(find.text('Sign out of PandaPay?'), findsNothing);
    expect(log.last, 'reset');
    expect(results, [true]);
  });
}
