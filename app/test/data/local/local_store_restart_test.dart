import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  test(
    'separate connections preserve captures across acknowledgment and restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pandapay-local-store-test-',
      );
      final file = '${directory.path}${Platform.pathSeparator}local.sqlite';
      addTearDown(() async {
        for (final suffix in ['', '-wal', '-shm']) {
          final candidate = File('$file$suffix');
          if (await candidate.exists()) await candidate.delete();
        }
        await directory.delete();
      });
      QueuedSms message(int amount) => QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'INR $amount spent on credit card XX1234 at SHOP on 16-Oct-26.',
        receivedAt: DateTime(2026, 10, 16),
      );
      final foreground = AppDatabase.forTesting(sqlite3.open(file));
      final background = AppDatabase.forTesting(sqlite3.open(file));
      final first = FinancialStore(foreground);
      final second = FinancialStore(background);
      SmsImportStore(first).capture('user:a', message(100));
      final old = SmsIntakeRepository(foreground).pending('user:a').single;
      SmsImportStore(second).capture('user:a', message(200));
      SmsIntakeRepository(foreground).acknowledge('user:a', old.id);
      first.dispose();
      second.dispose();
      foreground.close();
      background.close();
      final reopened = AppDatabase.forTesting(sqlite3.open(file));
      final store = FinancialStore(reopened);
      try {
        expect(
          store.transactions('user:a', const TransactionQuery())!.rows,
          hasLength(2),
        );
        expect(SmsIntakeRepository(reopened).pending('user:a'), hasLength(1));
        expect(SmsIntakeRepository(reopened).pending('user:b'), isEmpty);
      } finally {
        store.dispose();
        reopened.close();
      }
    },
  );
}
