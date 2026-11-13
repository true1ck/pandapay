import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/personal/owner_identity_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../../support/owner_vocabulary_support.dart';

const _ns = 'user:learn';

void main() {
  setUpAll(installRepoOwnerVocabulary);

  late AppDatabase db;
  late FinancialStore financial;
  late SmsImportStore importer;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    SmsV2Schema.ensure(db.db);
    importer = SmsImportStore(financial);
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  QueuedSms sms(String sender, String body, int minute) => QueuedSms(
    sender: sender,
    body: body,
    receivedAt: DateTime.utc(2026, 11, 9, 6, minute),
  );

  List<String> learned() => OwnerIdentityStore(db.db, namespace: _ns).entries();

  test('greetings in messages the gate drops still teach the owner\'s name', () {
    importer.captureBatch(_ns, [
      sms('VM-SHOPAA-S', 'Dear Asha Rao, your order #1 has shipped', 1),
      sms('VM-BROKRB-S', 'Dear Asha Rao, your weekly report is ready', 2),
      sms('JD-TRAVLC-S', 'Hi Asha Rao! Your booking is confirmed', 3),
    ]);
    expect(learned(), ['ASHA RAO']);
    expect(SyncStateStore(db.db, namespace: _ns).get('owner:recheck'), '1');
  });

  test('a message captured again is not counted again', () {
    final batch = [
      sms('VM-SHOPAA-S', 'Dear Asha Rao, your order #1 has shipped', 1),
      sms('VM-BROKRB-S', 'Dear Asha Rao, your weekly report is ready', 2),
      sms('JD-TRAVLC-S', 'Hi Asha Rao! Your booking is confirmed', 3),
    ];
    importer.captureBatch(_ns, batch);
    importer.captureBatch(_ns, batch);
    final payload = db.db
        .select('SELECT payload FROM v2_owner_signals WHERE namespace=?', [_ns])
        .single['payload'] as String;
    final seen = (jsonDecode(payload) as Map)['ASHA RAO'] as Map;
    expect(seen['count'], 3);
  });

  test('a stock greeting or one sender alone teaches nothing', () {
    importer.captureBatch(_ns, [
      sms('VM-SHOPAA-S', 'Dear Customer, your order #1 has shipped', 1),
      sms('VM-SHOPAA-S', 'Dear Sunita Patel, your quote is ready', 2),
      sms('VM-SHOPAA-S', 'Dear Sunita Patel, your quote changed', 3),
      sms('VM-SHOPAA-S', 'Dear Sunita Patel, your quote expires', 4),
    ]);
    expect(learned(), isEmpty);
    expect(SyncStateStore(db.db, namespace: _ns).get('owner:recheck'), isNot('1'));
  });

  test('a learned name the owner removed does not come back', () {
    importer.captureBatch(_ns, [
      sms('VM-SHOPAA-S', 'Dear Asha Rao, your order #1 has shipped', 1),
      sms('VM-BROKRB-S', 'Dear Asha Rao, your weekly report is ready', 2),
      sms('JD-TRAVLC-S', 'Hi Asha Rao! Your booking is confirmed', 3),
    ]);
    OwnerIdentityStore(db.db, namespace: _ns).remove('ASHA RAO');
    importer.captureBatch(_ns, [
      sms('VM-SHOPAA-S', 'Dear Asha Rao, your order #2 has shipped', 11),
      sms('VM-BROKRB-S', 'Dear Asha Rao, your weekly report 2', 12),
      sms('JD-TRAVLC-S', 'Hi Asha Rao! Your booking 2 is confirmed', 13),
    ]);
    expect(learned(), isEmpty);
  });
}
