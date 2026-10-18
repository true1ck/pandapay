import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/transaction_import_pipeline.dart';
import 'package:pandapay/features/import/import_mapping_dialog.dart';
import 'package:pandapay/features/import/import_review_panel.dart';

void main() {
  testWidgets('income appears in the preview and can be corrected', (
    tester,
  ) async {
    final session = TransactionImportSession(
      fileDigest: 'file',
      importSource: 'csv',
      statement: ParsedStatement(
        transactions: [
          ParsedStatementLine(
            date: DateTime(2026, 10, 2),
            description: 'Coffee purchase',
            amount: Money.fromRupees(100),
          ),
          ParsedStatementLine(
            date: DateTime(2026, 10, 3),
            description: 'Refund received',
            amount: Money.fromRupees(50),
            isCredit: true,
          ),
        ],
      ),
    );
    session.destinations[TransactionImportSession.unknownAccount] = '';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          userCardsRepositoryProvider.overrideWithValue(null),
          importRepositoryProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          home: Scaffold(body: ImportReviewPanel(session: session)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Money in'));
    await tester.pumpAndSettle();
    final refund = find.text('Refund received');
    await tester.scrollUntilVisible(
      refund,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Coffee purchase'), findsNothing);
    expect(find.text('Refund received'), findsOneWidget);
    expect(find.text('Import 2 transactions'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit transaction'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the original statement'), findsNothing);
  });

  testWidgets(
    'unrecognized row can be corrected, validated and imported without a card',
    (tester) async {
      Map<String, dynamic>? payload;
      final repository = ImportRepository(
        apiBaseUrl: 'https://example.test',
        accessToken: 'token',
        client: MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'statementImport': {
                'id': 'batch',
                'user_card_id': null,
                'statement_from': '2026-10-02',
                'statement_to': '2026-10-02',
                'imported_at': '2026-10-18T00:00:00Z',
                'txn_count': 1,
                'reconciled_count': 1,
              },
              'summary': {
                'imported': 1,
                'pendingDuplicates': 0,
                'exactRetries': 0,
              },
            }),
            201,
          );
        }),
      );
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'csv',
        statement: const ParsedStatement(
          transactions: [],
          rejectedRows: [
            ImportRejectedRow('table:row:2', [
              '2026-10-02',
              'Coffee',
              'unreadable',
            ], 'Amount is unreadable.'),
          ],
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            importRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Scaffold(body: ImportReviewPanel(session: session)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Correct').hitTestable(),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Date (YYYY-MM-DD, optional time)'),
        '2026-02-30',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        'Coffee',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Amount (INR)'),
        '100.25',
      );
      await tester.tap(find.text('Save reviewed row'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use a real YYYY-MM-DD'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Date (YYYY-MM-DD, optional time)'),
        '2026-10-02',
      );
      await tester.tap(find.text('Save reviewed row'));
      await tester.pumpAndSettle();
      final destination = find.byKey(
        const ValueKey('destination:Unspecified account'),
      );
      await tester.ensureVisible(destination);
      await tester.pumpAndSettle();
      await tester.tap(destination);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other account (no linked card)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import 1 transactions'));
      await tester.pumpAndSettle();
      expect(payload!['userCardId'], isNull);
      expect((payload!['transactions'] as List).single['amountInr'], 100.25);
      expect((payload!['transactions'] as List).single['entryKind'], 'spend');
      expect(find.text('Import complete'), findsOneWidget);
      expect(find.textContaining('1 added'), findsOneWidget);
      expect(
        find.textContaining('0 unrecognized rows were not imported'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'formats dialog handles metadata before a header beyond the old 20-row limit',
    (tester) async {
      Map<String, StatementTableOptions>? result;
      final rows = [
        for (var i = 0; i < 40; i++) ['Metadata $i'],
        ['Date', 'Merchant', 'Amount'],
        ['03/04/2026', 'Coffee', '100'],
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<Map<String, StatementTableOptions>>(
                    context: context,
                    builder: (_) => ImportMappingDialog(
                      tables: {'table': rows},
                      options: const {},
                    ),
                  );
                },
                child: const Text('Map export'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Map export'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(
                TextField,
                'Header row number (0 = no header)',
              ),
            )
            .controller!
            .text,
        '41',
      );
      await tester.tap(find.byType(DropdownButtonFormField<ImportDateOrder>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Month / Day / Year').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply formats'));
      await tester.pumpAndSettle();
      expect(result!['table']!.headerRow, 40);
      expect(result!['table']!.dateOrder, ImportDateOrder.monthFirst);
      expect(result!['table']!.dateOrderConfirmed, isTrue);
    },
  );
}
