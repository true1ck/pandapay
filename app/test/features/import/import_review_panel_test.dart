import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/transaction_import_pipeline.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TxnInstrument;
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
          categoriesProvider.overrideWith((ref) async => const []),
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
    'import preview exposes and saves editable category and metadata',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const dining = SpendCategory(
        id: 'dining-id',
        slug: 'dining',
        name: 'Dining',
      );
      const groceries = SpendCategory(
        id: 'grocery-id',
        slug: 'groceries',
        name: 'Groceries',
      );
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'json',
        statement: ParsedStatement(
          transactions: [
            ParsedStatementLine(
              date: DateTime(2026, 10, 2),
              description: 'Unknown merchant',
              amount: Money.fromRupees(250),
              sourceAccount: 'HDFC Credit Card',
              bankReference: 'ABC123456',
              categoryHint: 'Dining',
              note: 'Team lunch',
              instrument: TxnInstrument.creditCard,
              rail: 'online',
              status: 'ignored',
              merchantNameMissing: true,
            ),
          ],
        ),
      )..destinations['HDFC Credit Card'] = 'instrument:credit_card';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            userCardsRepositoryProvider.overrideWithValue(null),
            importRepositoryProvider.overrideWithValue(null),
            categoriesProvider.overrideWith(
              (ref) async => const [dining, groceries],
            ),
          ],
          child: MaterialApp(
            home: Scaffold(body: ImportReviewPanel(session: session)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Category from source: Dining'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Category from source: Dining'), findsOneWidget);
      expect(session.reviewLocked, isFalse);
      final editButton = find.byKey(const ValueKey('import-edit-transaction'));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      final editDialog = find.byKey(const ValueKey('import-edit-dialog'));
      expect(editDialog, findsOneWidget);
      final dialogPanel = find.byKey(
        const ValueKey('import-edit-dialog-panel'),
      );
      expect(tester.getSize(dialogPanel).height, lessThanOrEqualTo(760));
      expect(tester.takeException(), isNull);
      final editFields = find.descendant(
        of: editDialog,
        matching: find.byType(TextField),
      );
      final fieldRects = [
        for (var i = 0; i < editFields.evaluate().length; i++)
          tester.getRect(editFields.at(i)),
      ];
      for (var i = 1; i < fieldRects.length; i++) {
        expect(
          fieldRects[i].top,
          greaterThanOrEqualTo(fieldRects[i - 1].bottom),
          reason: 'Edit fields should have clear vertical separation.',
        );
      }

      // The review card remains behind the edit dialog; the modal exposes the
      // matching, editable PandaPay category as well.
      expect(find.text('Category from source: Dining'), findsOneWidget);
      expect(find.text('Team lunch'), findsOneWidget);
      final categoryDropdown = find.byKey(
        const ValueKey('import-edit-category'),
      );
      await tester.ensureVisible(categoryDropdown);
      await tester.tap(categoryDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groceries').last);
      await tester.pumpAndSettle();
      final noteField = find.widgetWithText(
        TextField,
        'Note / remarks (optional)',
      );
      await tester.ensureVisible(noteField);
      await tester.enterText(noteField, 'Weekly shop');
      final referenceField = find.widgetWithText(
        TextField,
        'Bank reference (optional)',
      );
      await tester.ensureVisible(referenceField);
      await tester.enterText(referenceField, 'XYZ987654');
      await tester.tap(find.text('Save reviewed row'));
      await tester.pumpAndSettle();

      expect(session.rows.single.categoryId, 'grocery-id');
      expect(session.rows.single.categoryHint, 'Groceries');
      expect(session.rows.single.note, 'Weekly shop');
      expect(session.rows.single.bankReference, 'XYZ987654');
      expect(session.rows.single.status, 'ignored');
      expect(session.rows.single.merchantNameMissing, isTrue);
      expect(session.inputFor(0).merchantName, isNull);
      expect(session.inputFor(0).categoryId, 'grocery-id');
      expect(session.inputFor(0).instrument, TxnInstrument.creditCard);
      expect(session.inputFor(0).rail, 'online');
    },
  );

  testWidgets(
    'a rejected first batch unlocks discrepancy rows for manual correction',
    (tester) async {
      final repository = ImportRepository(
        apiBaseUrl: 'https://example.test',
        accessToken: 'token',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': 'internal_error',
              'requestId': 'import-test-123',
            }),
            500,
          ),
        ),
      );
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'json',
        statement: ParsedStatement(
          transactions: [
            ParsedStatementLine(
              date: DateTime(2026, 6, 10),
              description: 'Valid row',
              amount: Money.fromRupees(25),
            ),
            ParsedStatementLine(
              date: DateTime(2026, 6, 11),
              description: 'Devaraj Enterprises',
              amount: Money.fromRupees(11.06),
              sourceRowId: 'json:row:72',
              reviewReasons: const [
                'This date has no year. Choose the export year in Formats, or edit the date.',
              ],
            ),
          ],
        ),
      )..destinations[TransactionImportSession.unknownAccount] = 'instrument:other';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            userCardsRepositoryProvider.overrideWithValue(null),
            importRepositoryProvider.overrideWithValue(repository),
            categoriesProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            home: Scaffold(body: ImportReviewPanel(session: session)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import 1 transactions · skip 1'));
      await tester.pumpAndSettle();

      expect(find.textContaining('internal_error'), findsNothing);
      expect(find.textContaining('import-test-123'), findsOneWidget);
      expect(session.progress.completedBatches, 0);
      expect(session.reviewLocked, isFalse);
      final edit = find.descendant(
        of: find.byKey(const ValueKey('import-row-1')),
        matching: find.byTooltip('Edit transaction'),
      );
      await tester.scrollUntilVisible(
        edit,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final dateField = find.widgetWithText(
        TextField,
        'Date (YYYY-MM-DD, optional time)',
      );
      await tester.ensureVisible(dateField);
      await tester.enterText(dateField, '2026-06-11');
      await tester.tap(find.text('Save reviewed row'));
      await tester.pumpAndSettle();

      expect(session.rows[1].reviewReasons, isEmpty);
      expect(session.selected, [0, 1]);
      expect(find.text('Import 2 transactions'), findsOneWidget);
    },
  );

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
            categoriesProvider.overrideWith((ref) async => const []),
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
      expect(
        find.textContaining('Enter a real date between 1900 and 2100'),
        findsNWidgets(2),
      );
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
