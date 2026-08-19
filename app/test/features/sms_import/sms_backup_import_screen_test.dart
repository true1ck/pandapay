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
import 'package:shared_preferences/shared_preferences.dart';

/// Two bank alerts on two different cards, one OTP, one message from a
/// friend, and one bank alert with no `date` attribute.
///
/// The mix is the point: a real export is overwhelmingly NOT bank alerts,
/// and smsextractionimple.md §0.1 D1 is precisely that the old importer
/// uploaded all of it. The `₹` in the second alert is also deliberate — it
/// is the character `String.fromCharCodes` used to mangle (D6).
const _backupXml = '''
<smses count="5">
  <sms address="VM-HDFCBK" date="1704067200000"
       body="Rs.499.00 spent on HDFC Bank Card x1234 at AMAZON on 01-01-24" />
  <sms address="AX-AxisBk" date="1704153600000"
       body="INR 1250.00 debited from Axis Bank Card XX5678 at SWIGGY — ₹1250 total" />
  <sms address="VM-OTPSMS" date="1704153600000"
       body="123456 is your one-time password. Do not share it with anyone." />
  <sms address="+919000000000" date="1704153600000"
       body="hey are we still on for dinner tonight" />
  <sms address="VM-ICICIB" body="Rs.75.00 spent on ICICI Card x9999 at CAFE" />
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
    final bytes = utf8.encode(_backupXml);
    return FilePickerResult([
      PlatformFile(name: 'sms_backup.xml', size: bytes.length, bytes: Uint8List.fromList(bytes)),
    ]);
  }
}

class _RecordingUserCardsRepository extends UserCardsRepository {
  _RecordingUserCardsRepository() : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  final List<List<SmsBatchMessage>> batches = [];

  @override
  Future<SmsBatchImportResult> logTransactionsFromSmsBatch({
    required List<SmsBatchMessage> messages,
    bool backfill = true,
  }) async {
    batches.add(messages);
    return SmsBatchImportResult(
      imported: messages.length,
      duplicate: 0,
      unparsed: 0,
      invalid: 0,
      errored: 0,
    );
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

const _hdfc = UserCard(id: 'card-1', cardProductId: 'p1', cardName: 'HDFC Millennia', isDefault: true);
const _axis = UserCard(id: 'card-2', cardProductId: 'p2', cardName: 'Axis Ace', isDefault: false);

/// The review view is a ListView; on a test-sized viewport the import
/// button sits below the fold, so a bare tap silently misses.
Future<void> _tapScrolled(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required List<UserCard> cards,
  required UserCardsRepository userCards,
  required ImportRepository imports,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsProvider.overrideWith((ref) async => cards),
        userCardsRepositoryProvider.overrideWithValue(userCards),
        importRepositoryProvider.overrideWithValue(imports),
      ],
      child: const MaterialApp(home: SmsBackupImportScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Select backup file'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FilePickerPlatform.instance = _FakeXmlFilePickerPlatform();
  });

  testWidgets('filters non-bank messages on-device and reports what stayed on the phone', (tester) async {
    await _pumpScreen(
      tester,
      cards: const [_hdfc, _axis],
      userCards: _RecordingUserCardsRepository(),
      imports: _RecordingImportRepository(),
    );

    // 3 of the 5 look like bank alerts; one of those three has no date and
    // is skipped, leaving 2. The OTP and the dinner message are dropped
    // locally and must be reported as such.
    expect(find.text('2 bank alerts found'), findsOneWidget);
    expect(find.textContaining('5 messages read on this device'), findsOneWidget);
    expect(find.textContaining('2 not bank alerts, kept on your phone'), findsOneWidget);
    expect(find.textContaining('1 skipped (no date in the export)'), findsOneWidget);
  });

  testWidgets('groups by the card suffix in the message rather than importing all against one card', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      cards: const [_hdfc, _axis],
      userCards: _RecordingUserCardsRepository(),
      imports: _RecordingImportRepository(),
    );

    expect(find.text('Card ending 1234'), findsOneWidget);
    expect(find.text('Card ending 5678'), findsOneWidget);
  });

  testWidgets('decodes UTF-8 so a rupee sign survives into the uploaded body', (tester) async {
    final repo = _RecordingUserCardsRepository();
    await _pumpScreen(
      tester,
      cards: const [_hdfc, _axis],
      userCards: repo,
      imports: _RecordingImportRepository(),
    );

    // Attribute the Axis group (the one carrying `₹`) and import it.
    await _tapScrolled(tester, find.byType(DropdownButtonFormField<String?>).last);
    await tester.tap(find.text('Axis Ace').last);
    await tester.pumpAndSettle();
    await _tapScrolled(tester, find.textContaining('Import 1 message'));

    final sent = repo.batches.expand((b) => b).map((m) => m.body).join();
    expect(sent, contains('₹1250'), reason: 'String.fromCharCodes would have mangled this to 3 chars');
  });

  testWidgets('sends each message with its ORIGINAL timestamp, not now()', (tester) async {
    final repo = _RecordingUserCardsRepository();
    await _pumpScreen(
      tester,
      cards: const [_hdfc, _axis],
      userCards: repo,
      imports: _RecordingImportRepository(),
    );

    await _tapScrolled(tester, find.byType(DropdownButtonFormField<String?>).first);
    await tester.tap(find.text('HDFC Millennia').last);
    await tester.pumpAndSettle();
    await _tapScrolled(tester, find.textContaining('Import 1 message'));

    final sent = repo.batches.single.single;
    expect(sent.occurredAt.toUtc(), DateTime.utc(2024, 1, 1));
    expect(sent.userCardId, 'card-1');
  });

  testWidgets('a group left on "Skip" is not uploaded at all', (tester) async {
    final repo = _RecordingUserCardsRepository();
    await _pumpScreen(
      tester,
      cards: const [_hdfc, _axis],
      userCards: repo,
      imports: _RecordingImportRepository(),
    );

    // Attribute only the first group; leave the second on Skip.
    await _tapScrolled(tester, find.byType(DropdownButtonFormField<String?>).first);
    await tester.tap(find.text('HDFC Millennia').last);
    await tester.pumpAndSettle();
    await _tapScrolled(tester, find.textContaining('Import 1 message'));

    expect(repo.batches.expand((b) => b), hasLength(1));
  });

  testWidgets('with no cards in the wallet, offers discovery instead of a dead disabled button', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      cards: const [],
      userCards: _RecordingUserCardsRepository(),
      imports: _RecordingImportRepository(),
    );

    expect(find.text('Add a card first'), findsOneWidget);
    expect(find.text('Find my cards from these messages'), findsOneWidget);
    // The old screen showed a permanently disabled "Import messages" button
    // here, which is the D4 dead end. There must be no import affordance.
    expect(find.textContaining('Import 1 message'), findsNothing);
    expect(find.text('Pick a card to continue'), findsNothing);
  });
}
