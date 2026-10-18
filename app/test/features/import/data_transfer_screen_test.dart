import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/features/import/data_transfer_screen.dart';

void main() {
  final imports = [
    for (var i = 0; i < 4; i++)
      StatementImport(
        id: 'batch-$i',
        userCardId: null,
        statementFrom: DateTime(2026, 10, 1 + i),
        statementTo: DateTime(2026, 10, 10 + i),
        txnCount: 20 + i,
        reconciledCount: 18 + i,
        importedAt: DateTime(2026, 10, 18, 10 + i),
      ),
  ];

  testWidgets('shows recent imports and expands the batch history', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statementImportsProvider.overrideWith((ref) async => imports),
        ],
        child: const MaterialApp(home: DataTransferScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recent imports'), findsOneWidget);
    expect(find.text('Statement import'), findsNWidgets(3));
    expect(find.text('Show all'), findsOneWidget);

    await tester.ensureVisible(find.text('Show all'));
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();

    expect(find.text('Statement import'), findsNWidgets(4));
    expect(find.text('Show less'), findsOneWidget);

    await tester.ensureVisible(find.text('Statement import').first);
    await tester.tap(find.text('Statement import').first);
    await tester.pumpAndSettle();

    expect(find.text('Rows sent for import'), findsOneWidget);
    expect(find.text('Rows reconciled'), findsOneWidget);
    expect(
      find.text('The original PDF, CSV, or screenshot stays on your device.'),
      findsOneWidget,
    );
  });

  testWidgets('shows an honest empty state before the first import', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statementImportsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: DataTransferScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recent imports'), findsOneWidget);
    expect(
      find.text(
        'Completed statement imports will appear here. Your original files are not stored.',
      ),
      findsOneWidget,
    );
  });
}
