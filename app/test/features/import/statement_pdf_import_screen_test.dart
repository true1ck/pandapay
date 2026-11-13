import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/memory_import_continuation.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay/data/user_cards_repository.dart' show UserCard;
import 'package:pandapay/features/import/statement_pdf_import_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Fakes the platform channel file_picker would otherwise use, returning a
/// real (generated in-memory, not a fixture file) unencrypted PDF whose
/// text is a genuine statement-shaped line — so this test exercises the
/// real syncfusion extraction + regex parse, not just UI plumbing.
class _FakePdfFilePickerPlatform extends FilePickerPlatform {
  final Uint8List pdfBytes;
  _FakePdfFilePickerPlatform(this.pdfBytes);

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    dynamic androidSafOptions,
  }) async {
    return FilePickerResult([
      PlatformFile(
        name: 'statement.pdf',
        size: pdfBytes.length,
        bytes: pdfBytes,
      ),
    ]);
  }
}

Uint8List _buildTestPdf({String? password, String? text}) {
  final document = PdfDocument();
  document.pages.add().graphics.drawString(
    text ?? '01/04/2026 TEST MERCHANT 250.00\nClosing Balance: 900.00',
    PdfStandardFont(PdfFontFamily.helvetica, 12),
  );
  if (password != null) document.security.userPassword = password;
  final bytes = Uint8List.fromList(document.saveSync());
  document.dispose();
  return bytes;
}

class _RecordingImportRepository extends ImportRepository {
  Map<String, dynamic>? lastConfirmArgs;
  final calls = <Map<String, dynamic>>[];
  _RecordingImportRepository()
    : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  @override
  Future<StatementImport> confirmPreparedStatementImport(
    Map<String, dynamic> payload,
  ) async {
    final closing = payload['closingBalanceInr'];
    lastConfirmArgs = {
      'userCardId': payload['userCardId'],
      'closingBalance': closing == null
          ? null
          : Money.fromRupees((closing as num).toDouble()),
      'txnCount': payload['txnCount'],
      'reconciledCount': payload['reconciledCount'],
      'importKey': payload['importKey'],
      'transactions': payload['transactions'],
    };
    calls.add(lastConfirmArgs!);
    final count = payload['txnCount'] as int;
    return StatementImport.fromJson({
      'id': 'si1',
      'user_card_id': payload['userCardId'],
      'statement_from': payload['statementFrom'],
      'statement_to': payload['statementTo'],
      'txn_count': count,
      'reconciled_count': payload['reconciledCount'],
      'imported_at': DateTime.now().toIso8601String(),
      'summary': {'imported': count, 'pendingDuplicates': 0, 'exactRetries': 0},
    });
  }
}

Future<void> waitForParsing(
  WidgetTester tester, {
  required Finder completedState,
}) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (completedState.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Import did not reach the expected completed state: $completedState');
}

void main() {
  setUpAll(() => BambooFonts.useSystemFontsForTests = true);
  tearDownAll(() => BambooFonts.useSystemFontsForTests = false);
  late FilePickerPlatform originalFilePickerPlatform;
  setUp(() => originalFilePickerPlatform = FilePickerPlatform.instance);
  tearDown(() => FilePickerPlatform.instance = originalFilePickerPlatform);

  testWidgets(
    'mixed-account PDF auto-suggests sources and supports non-card spending',
    (tester) async {
      FilePickerPlatform.instance = _FakePdfFilePickerPlatform(
        _buildTestPdf(
          text:
              '2026-10-02 08:32 PM COFFEE 100 DR Example bank 1234 Yes - FOOD\n'
              '2026-10-03 09:00 AM FUEL 500 DR Other credit 5678 Yes - FUEL',
        ),
      );
      final repo = _RecordingImportRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const []),
            importRepositoryProvider.overrideWithValue(repo),
            memoryContinuationOverride(repo),
          ],
          child: const MaterialApp(home: StatementPdfImportScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose file'));
      await waitForParsing(
        tester,
        completedState: find.byType(DropdownButtonFormField<String>),
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
        isNotNull,
      );
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<String>).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other account (no linked card)').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<String>).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other account (no linked card)').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(FilledButton).last);
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(repo.lastConfirmArgs!['userCardId'], isNull);
      expect(repo.calls, hasLength(2));
      final rows =
          (repo.calls.first["transactions"] as List).cast<Map<String, dynamic>>();
      expect(rows, hasLength(1));
      expect(rows.single["merchantName"], 'COFFEE');
      expect(rows.single["importRowKey"], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(DateTime.parse(rows.single["occurredAt"] as String).toLocal(), DateTime(2026, 10, 2, 20, 32));
    },
  );
  testWidgets(
    'unencrypted PDF: pick -> parse -> preview shows real detected data -> confirm',
    (tester) async {
      FilePickerPlatform.instance = _FakePdfFilePickerPlatform(_buildTestPdf());
      const card = UserCard(
        id: 'card-1',
        cardProductId: 'p1',
        cardName: 'Test Card',
        isDefault: true,
      );
      final repo = _RecordingImportRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userCardsProvider.overrideWith((ref) async => const [card]),
            importRepositoryProvider.overrideWithValue(repo),
            memoryContinuationOverride(repo),
          ],
          child: const MaterialApp(home: StatementPdfImportScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose file'));
      await waitForParsing(
        tester,
        completedState: find.text('Columns and formats'),
      );

      await tester.ensureVisible(find.text('Columns and formats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Columns and formats'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<ImportDateOrder>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Day / Month / Year').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply formats'));
      await waitForParsing(
        tester,
        completedState: find.text('1 transactions found'),
      );

      expect(find.text('1 transactions found'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('TEST MERCHANT'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('TEST MERCHANT'), findsOneWidget);

      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Card').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();

      expect(find.text('Statement imported'), findsOneWidget);
      expect(repo.lastConfirmArgs!['txnCount'], 1);
      expect(repo.lastConfirmArgs!['reconciledCount'], 0);
      expect(
        (repo.lastConfirmArgs!['closingBalance'] as Money).paise,
        Money.fromRupees(900).paise,
      );
    },
  );

  testWidgets(
    'a wrong password shows a plain-language error, not a raw exception',
    (tester) async {
      FilePickerPlatform.instance = _FakePdfFilePickerPlatform(
        _buildTestPdf(password: 'correct'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [userCardsProvider.overrideWith((ref) async => const [])],
          child: const MaterialApp(home: StatementPdfImportScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose file'));
      await waitForParsing(
        tester,
        completedState: find.text('Statement password (optional)'),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Statement password (optional)'),
        'wrong-password',
      );
      await tester.tap(find.text('Unlock & parse'));
      await waitForParsing(
        tester,
        completedState: find.text("That password didn't work for this statement."),
      );

      expect(
        find.text("That password didn't work for this statement."),
        findsOneWidget,
      );
    },
  );
}
