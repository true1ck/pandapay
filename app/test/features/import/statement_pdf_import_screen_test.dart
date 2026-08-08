import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
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
      PlatformFile(name: 'statement.pdf', size: pdfBytes.length, bytes: pdfBytes),
    ]);
  }
}

Uint8List _buildTestPdf({String? password}) {
  final document = PdfDocument();
  document.pages.add().graphics.drawString(
        '01/04/2026 TEST MERCHANT 250.00\nClosing Balance: 900.00',
        PdfStandardFont(PdfFontFamily.helvetica, 12),
      );
  if (password != null) document.security.userPassword = password;
  final bytes = Uint8List.fromList(document.saveSync());
  document.dispose();
  return bytes;
}

class _RecordingImportRepository extends ImportRepository {
  Map<String, dynamic>? lastConfirmArgs;
  _RecordingImportRepository() : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  @override
  Future<StatementImport> confirmStatementImport({
    required String userCardId,
    required DateTime statementFrom,
    required DateTime statementTo,
    Money? closingBalance,
    double? pointsPosted,
    required int txnCount,
    required int reconciledCount,
    String? issuerFormatId,
  }) async {
    lastConfirmArgs = {
      'userCardId': userCardId,
      'closingBalance': closingBalance,
      'txnCount': txnCount,
      'reconciledCount': reconciledCount,
    };
    return StatementImport.fromJson({
      'id': 'si1',
      'user_card_id': userCardId,
      'statement_from': statementFrom.toIso8601String(),
      'statement_to': statementTo.toIso8601String(),
      'txn_count': txnCount,
      'reconciled_count': reconciledCount,
      'imported_at': DateTime.now().toIso8601String(),
    });
  }
}

void main() {
  testWidgets('unencrypted PDF: pick -> parse -> preview shows real detected data -> confirm', (tester) async {
    FilePickerPlatform.instance = _FakePdfFilePickerPlatform(_buildTestPdf());
    const card = UserCard(id: 'card-1', cardProductId: 'p1', cardName: 'Test Card', isDefault: true);
    final repo = _RecordingImportRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const [card]),
          importRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: StatementPdfImportScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();

    expect(find.text('statement.pdf'), findsOneWidget);
    await tester.tap(find.text('Unlock & parse'));
    await tester.pumpAndSettle();

    expect(find.text('1 transactions found'), findsOneWidget);
    expect(find.textContaining('TEST MERCHANT'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Card').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();

    expect(find.text('Statement imported'), findsOneWidget);
    expect(repo.lastConfirmArgs!['txnCount'], 1);
    expect(repo.lastConfirmArgs!['reconciledCount'], 1);
    expect((repo.lastConfirmArgs!['closingBalance'] as Money).paise, Money.fromRupees(900).paise);
  });

  testWidgets('a wrong password shows a plain-language error, not a raw exception', (tester) async {
    FilePickerPlatform.instance = _FakePdfFilePickerPlatform(_buildTestPdf(password: 'correct'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: StatementPdfImportScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Statement password (optional)'), 'wrong-password');
    await tester.tap(find.text('Unlock & parse'));
    await tester.pumpAndSettle();

    expect(find.text("That password didn't work for this statement."), findsOneWidget);
  });
}
