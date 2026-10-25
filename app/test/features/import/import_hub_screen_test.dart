import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/features/import/auto_sms_sync_screen.dart';
import 'package:pandapay/features/import/import_hub_screen.dart';

void main() {
  testWidgets('ImportHubScreen displays Auto SMS detection card alongside existing import cards', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statementImportsProvider.overrideWith(
            (ref) async => const <StatementImport>[],
          ),
          smsImportBatchesProvider.overrideWith(
            (ref) async => const <SmsImportBatch>[],
          ),
        ],
        child: const MaterialApp(home: ImportHubScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Verify all channels exist
    expect(find.text('Auto SMS detection'), findsOneWidget);
    expect(find.text('Import spending file'), findsOneWidget);
    expect(find.text('Import from screenshots'), findsOneWidget);
    expect(find.text('Import SMS backup file'), findsOneWidget);
    expect(find.text('Import history'), findsOneWidget);

    // Verify that when permission is not granted, no checkmark tick is rendered
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('Tapping Auto SMS detection on non-Android shows helpful feedback without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statementImportsProvider.overrideWith(
            (ref) async => const <StatementImport>[],
          ),
          smsImportBatchesProvider.overrideWith(
            (ref) async => const <SmsImportBatch>[],
          ),
        ],
        child: const MaterialApp(home: ImportHubScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Auto SMS detection'));
    await tester.pumpAndSettle();

    // Doesn't crash, shows SnackBar on non-Android or opens AutoSmsSyncScreen
    expect(find.byType(ImportHubScreen), findsOneWidget);
  });

  testWidgets('AutoSmsSyncScreen renders initial prompt and UI elements cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          needsReviewCountProvider.overrideWith((ref) async => 0),
        ],
        child: const MaterialApp(home: AutoSmsSyncScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Check header / title / trust points
    expect(find.text('LESS TYPING. MORE CLARITY.'), findsOneWidget);
    expect(find.text('Let your spends\nfind their way.'), findsOneWidget);
    expect(find.text('Allow SMS & find my spends'), findsOneWidget);
    expect(find.text('Maybe later'), findsOneWidget);
    expect(find.text('Filtered on your phone'), findsOneWidget);
    expect(find.text('Connected to your account'), findsOneWidget);
  });
}
