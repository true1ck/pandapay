import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_backup_import_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _backupXml = '''
<smses count="2">
  <sms address="VM-HDFCBK" body="Rs.499.00 spent on HDFC Bank Card x1234 at AMAZON on 01-01-24" />
  <sms address="unknown-sender" body="This is not a bank message and will fail to parse." />
</smses>
''';

class _FakeXmlFilePickerPlatform extends FilePickerPlatform {
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
      PlatformFile(name: 'sms_backup.xml', size: _backupXml.length, bytes: Uint8List.fromList(utf8.encode(_backupXml))),
    ]);
  }
}

class _FakeUserCardsRepository extends UserCardsRepository {
  _FakeUserCardsRepository() : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  @override
  Future<SmsImportResult> logTransactionFromSms({
    required String userCardId,
    required String sender,
    required String body,
  }) async {
    if (sender == 'unknown-sender') return const SmsImportResult(parsed: false, reason: 'no_pattern_matched');
    return const SmsImportResult(parsed: true);
  }
}

class _RecordingImportRepository extends ImportRepository {
  Map<String, dynamic>? lastBatchArgs;
  _RecordingImportRepository() : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  @override
  Future<SmsImportBatch> recordSmsImportBatch({
    required int messageCount,
    required int parsedCount,
    required int failedCount,
  }) async {
    lastBatchArgs = {'messageCount': messageCount, 'parsedCount': parsedCount, 'failedCount': failedCount};
    return SmsImportBatch(
      id: 'b1',
      messageCount: messageCount,
      parsedCount: parsedCount,
      failedCount: failedCount,
      importedAt: DateTime.now(),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('pick -> real XML parse -> import -> summary reflects real parsed/failed counts', (tester) async {
    FilePickerPlatform.instance = _FakeXmlFilePickerPlatform();
    const card = UserCard(id: 'card-1', cardProductId: 'p1', cardName: 'Test Card', isDefault: true);
    final importRepo = _RecordingImportRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const [card]),
          userCardsRepositoryProvider.overrideWithValue(_FakeUserCardsRepository()),
          importRepositoryProvider.overrideWithValue(importRepo),
        ],
        child: const MaterialApp(home: SmsBackupImportScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select backup file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('sms_backup.xml selected — 2 messages found'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Card').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import messages'));
    await tester.pumpAndSettle();

    expect(find.text('Import complete'), findsOneWidget);
    expect(find.text('2 messages · 1 logged · 1 could not be parsed.'), findsOneWidget);
    expect(importRepo.lastBatchArgs, {'messageCount': 2, 'parsedCount': 1, 'failedCount': 1});
  });
}
