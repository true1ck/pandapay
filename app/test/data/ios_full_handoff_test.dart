import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/ios_sms_acquisition_receipts.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';

const ns = 'user:full-handoff';
const generation = 'gen-1';
const spent =
    'Rs.42.50 spent on your SBI Credit Card ending with 4242 at '
    'TESTTECHNOLOGIES on 01-11-26 via UPI (Ref No. SYNTHETIC).';

/// The exact shape native `pending` returns.
Map<Object?, Object?> nativeRow(String id, String sender, String body, String at) => {
  'id': id, 'namespace': ns, 'generation': generation, 'body': body,
  'sender': sender, 'receivedAt': at, 'capturedAt': at,
  'dateProvenance': 'original', 'bodyCharacters': body.length,
  'senderEvidence': sender.isEmpty ? 'missing' : 'text',
};

/// Same steps as the iOS controller: capture, then record one outcome per row.
List<Map<String, Object?>> drain(FinancialStore store, List<Map<Object?, Object?>> rows) {
  final batch = IosShortcutSmsBatch.fromRows(rows, allowSenderInference: false);
  expect(batch.messages.length, rows.length, reason: 'controller rejects dropped rows');
  SmsImportStore(store).captureBatch(ns, batch.messages);
  final outcomes = IosSmsAcquisitionReceipts(store).record(ns, generation, rows);
  expect(outcomes.length, rows.length, reason: 'native needs one outcome per row');
  return outcomes;
}

void main() {
  late AppDatabase db;
  late FinancialStore store;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  final export = Platform.environment['PENDING'];
  test('replay pending rows from the phone', () {
    final rows = [
      for (final r in jsonDecode(File(export!).readAsStringSync()) as List)
        nativeRow(r['id'], r['sender'] ?? '', r['body'], r['receivedAt']),
    ];
    final counts = <String, int>{};
    for (var i = 0; i < rows.length; i += 50) {
      for (final o in drain(store, rows.sublist(i, (i + 50).clamp(0, rows.length)))) {
        counts['${o['outcome']}'] = (counts['${o['outcome']}'] ?? 0) + 1;
      }
    }
    // ignore: avoid_print
    print('rows ${rows.length} outcomes $counts transactions ${store.entities(ns, 'transactions').length}');
  }, skip: export == null ? 'needs PENDING export' : false);
}
