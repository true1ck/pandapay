import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/features/import/sync_backup_screen.dart';
import 'package:pandapay/features/settings/feedback_support_screen.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupStatusProvider.overrideWith((ref) async => const BackupStatus()),
        accessTokenProvider.overrideWith((ref) => 'token'),
      ],
      child: const MaterialApp(home: SyncBackupScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('confirming Restore routes to Feedback & Support instead of a dead-end snackbar', (
    tester,
  ) async {
    await _pump(tester);

    await tester.scrollUntilVisible(
      find.text('Restore from backup'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Restore from backup'));
    await tester.pumpAndSettle();
    expect(find.text('Restore from backup?'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Type RESTORE to confirm'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'RESTORE');
    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(find.byType(FeedbackSupportScreen), findsOneWidget);
    expect(
      find.textContaining('I need help restoring my data from a backup.'),
      findsOneWidget,
    );
    // The old dead end must be gone.
    expect(find.textContaining('No restore engine is wired up'), findsNothing);
  });

  testWidgets('typing the wrong confirmation word cancels without navigating anywhere', (tester) async {
    await _pump(tester);

    await tester.scrollUntilVisible(
      find.text('Restore from backup'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Restore from backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not it');
    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(find.byType(FeedbackSupportScreen), findsNothing);
    expect(find.byType(SyncBackupScreen), findsOneWidget);
  });
}
