import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_capture_worker.dart';

void main() {
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
    },
  );
}
