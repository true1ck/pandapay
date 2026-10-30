import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/ios_sms_acquisition_receipts.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_capture_worker.dart';

void main() {
  test('disposal does not abandon an admitted native writer', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pandapay-sms-worker-dispose-',
    );
    final database = AppDatabase.openFile('${directory.path}/financial.sqlite');
    final worker = SmsCaptureWorker(database.filePath!);
    try {
      final first = QueuedSms(
        sender: 'VM-ICICIB',
        body: 'INR 10 spent on ICICI Card XX1234 at SYNTHETIC CAFE.',
        receivedAt: DateTime(2026, 10, 30),
      );
      await worker.capture('user:synthetic', [first]);
      final messages = List.generate(
        30,
        (i) => QueuedSms(
          sender: first.sender,
          body:
              'INR ${i + 11} spent on ICICI Card XX1234 at SYNTHETIC CAFE. Ref TEST-$i',
          receivedAt: first.receivedAt,
        ),
      );
      final work = worker.capture('user:synthetic', messages);
      await Future<void>.delayed(Duration.zero);
      worker.dispose();
      await work;
      final intake = SmsIntakeRepository(database);
      expect(intake.pending('user:synthetic'), hasLength(31));
      final before = intake.counts('user:synthetic');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(intake.counts('user:synthetic'), before);
    } finally {
      worker.dispose();
      database.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await directory.delete(recursive: true);
    }
  });
  test(
    'capture worker commits readable shared data and duplicates stay quiet',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pandapay-sms-worker-',
      );
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await directory.resolveSymbolicLinks();
      if (!target.startsWith('$temporaryRoot${Platform.pathSeparator}') ||
          !directory.path.contains('pandapay-sms-worker-')) {
        throw StateError('Unexpected temporary test directory');
      }
      final database = AppDatabase.openFile(
        '${directory.path}/financial.sqlite',
      );
      final store = FinancialStore(database);
      final worker = SmsCaptureWorker(database.filePath!);
      addTearDown(() async {
        worker.dispose();
        store.dispose();
        database.close();
        // Graceful worker shutdown releases its separate SQLite connection.
        for (var attempt = 0; attempt < 20; attempt++) {
          try {
            await directory.delete(recursive: true);
            return;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        await directory.delete(recursive: true);
      });
      final message = QueuedSms(
        sender: 'VM-ICICIB',
        body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
        receivedAt: DateTime(2026, 10, 18),
      );
      final changed = await worker.capture('user:a', [message]);
      expect(changed, contains('transactions'));
      final intake = SmsIntakeRepository(database);
      expect(intake.pending('user:a'), hasLength(1));
      expect(
        store
            .transactions('user:a', const TransactionQuery())!
            .rows
            .single
            .amount
            .rupees,
        250,
      );
      expect(store.transactions('user:b', const TransactionQuery()), isNull);
      expect(await worker.capture('user:a', [message]), isEmpty);
      intake.acknowledge('user:a', intake.pending('user:a').single.id);
      expect(await worker.capture('user:a', [message]), isEmpty);
      expect(intake.pending('user:a'), isEmpty);
      expect(intake.capturedBodies('user:a'), [message.body]);

      final unknown = QueuedSms(
        sender: '',
        body:
            'INR 180 spent on Card XX7788 at SYNTHETIC CAFE. Ref TEST-UNKNOWN',
        receivedAt: DateTime(2026, 10, 19),
      );
      expect(
        await worker.capture('user:a', [unknown]),
        contains('needs_review'),
      );
      expect(intake.pending('user:a'), isEmpty);
      final receipt = IosSmsAcquisitionReceipts(store).record('user:a', 'g1', [
        {
          'id': 'unknown-worker',
          'namespace': 'user:a',
          'generation': 'g1',
          'sender': '',
          'body': unknown.body,
          'receivedAt': unknown.receivedAt.toUtc().toIso8601String(),
          'dateProvenance': 'original',
        },
      ]);
      expect(receipt.single['outcome'], 'review');
      expect(
        database.db.select('SELECT * FROM local_needs_review'),
        hasLength(1),
      );
      expect(await worker.capture('user:a', [unknown]), isEmpty);
      expect(
        database.db.select('SELECT * FROM local_needs_review'),
        hasLength(1),
      );
    },
  );
}
