import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_capture_worker.dart';

void main() {
  test('test SmsCaptureWorker with real file on disk', () async {
    final tempDir = Directory.systemTemp.createTempSync('sms_worker_test_');
    final dbPath = p.join(tempDir.path, 'test_pandapay.sqlite');

    try {
      // 1. Initialize DB
      final db = AppDatabase.openFile(dbPath);
      final store = FinancialStore(db);
      store.saveObservation('user:123', 'initial', {
        'id': 'initial',
        'event_type': 'test',
      });
      // Keep db open as main isolate would

      // 2. Start worker
      final worker = SmsCaptureWorker(dbPath, clientVersion: '1.0.13-dev');

      final messages = [
        QueuedSms(
          sender: 'VA-SLCBNK-S',
          body: 'Rs. 859 spent on your credit card xx9080 at slice on 22-Oct-26 (UPI Ref: 629534133759). Not you? Call 080-4832-9999 - slice',
          receivedAt: DateTime.fromMillisecondsSinceEpoch(1792651606529),
        ),
        QueuedSms(
          sender: 'VD-TNUCRD-S',
          body: 'Important update Sujay, We have credited 12 NeuCoins based on your latest NeuCard statement. Check your dashboard for referral benefits https://m.tneu.in/TNUCRD/n2kWGPp Tata Neu',
          receivedAt: DateTime.fromMillisecondsSinceEpoch(1792661167480),
        ),
        QueuedSms(
          sender: 'AD-MYTNEU-S',
          body: 'Your Goa Electricity bill of Rs. 927.00 is ready. Pay by 2026-11-09 to avoid late charges: https://m.tneu.in/MYTNEU/X0jzNhN - Tata Neu',
          receivedAt: DateTime.fromMillisecondsSinceEpoch(1792896735348),
        ),
      ];

      print('Sending capture command to worker...');
      final changed = await worker.capture('user:123', messages);
      print('Worker returned changed entities: $changed');

      worker.dispose();
      db.close();
    } catch (e, st) {
      print('Error in SmsCaptureWorker test: $e\n$st');
      rethrow;
    } finally {
      for (var attempt = 0; attempt < 20; attempt++) {
        try {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  });
}
