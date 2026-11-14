import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/instruments/unlinked_card_healer.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// A card movement saved with no card record stays "not matched" for good unless
// something links it. The heal links it to the one wallet card it names.
void main() {
  const namespace = 'user:heal';
  const walletCardId = '11111111-1111-4111-8111-111111111111';
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late Instrument card;

  Map<String, Object?> row() =>
      financial.entities(namespace, 'transactions').single;
  String? factLink() => database.db
      .select("SELECT instrument_id FROM v2_facts WHERE namespace=? AND fact_type='movement'", [namespace])
      .single['instrument_id'] as String?;
  UnlinkedCardHealer healer() =>
      UnlinkedCardHealer(financial, namespace: namespace);
  // The row as an unmatched card is saved: no card type, number or name.
  void makeRowUnmatched({String? last4}) {
    final r = row();
    financial.database.db.execute(
      "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
      [
        jsonEncode({
          ...r,
          'instrument': 'other',
          'user_card_id': null,
          'card_last4': last4,
          'card_name': null,
        }),
        namespace,
        r['id'],
      ],
    );
  }

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    final message = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: bundle.rules.first.examples.first.body,
      sourceKey: '1' * 64,
      observedAt: DateTime.utc(2026, 11, 1, 7),
    );
    SmsIntakeRepository(database); // creates the intake tables
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [namespace, message.sourceKey, message.sender, message.body, message.observedAt.millisecondsSinceEpoch],
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    ).process(message);
    final store = InstrumentStore(database.db, namespace: namespace);
    card = store.list().single;
    // The state the bug leaves: the fact has no card record.
    database.db.execute('UPDATE v2_facts SET instrument_id=NULL WHERE namespace=?', [namespace]);
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  test('a wallet card appears: the unlinked movement is linked and its row shows the card', () {
    InstrumentStore(database.db, namespace: namespace).upsert(
      card.copyWith(status: InstrumentStatus.confirmed, userCardId: walletCardId),
    );
    expect(factLink(), isNull);
    final linked = healer().healAll(now: DateTime.utc(2026, 11, 15));
    expect(linked, 1);
    expect(factLink(), card.instrumentId);
    expect(row()['user_card_id'], walletCardId);
    // Nothing left to do on a second run.
    expect(healer().healAll(now: DateTime.utc(2026, 11, 15)), 0);
  });

  test('a wallet card with another number is not a match', () {
    InstrumentStore(database.db, namespace: namespace).upsert(
      card.copyWith(
        status: InstrumentStatus.confirmed,
        userCardId: walletCardId,
        maskDigits: '9999',
      ),
    );
    expect(healer().healAll(now: DateTime.utc(2026, 11, 15)), 0);
    expect(factLink(), isNull);
  });

  test('without a wallet card nothing is linked', () {
    expect(healer().healAll(now: DateTime.utc(2026, 11, 15)), 0);
  });

  test('a "not matched" row shows the wallet card: type, number, name', () {
    InstrumentStore(database.db, namespace: namespace).upsert(
      card.copyWith(status: InstrumentStatus.confirmed, userCardId: walletCardId),
    );
    makeRowUnmatched();
    expect(row()['instrument'], 'other');
    expect(healer().healAll(now: DateTime.utc(2026, 11, 15)), 1);
    expect(row()['instrument'], 'credit_card');
    expect(row()['user_card_id'], walletCardId);
    expect(row()['card_last4'], card.maskDigits);
    expect(row()['card_name'], card.displayName);
  });

  test('a row that shows another card number is not moved onto this card', () {
    InstrumentStore(database.db, namespace: namespace).upsert(
      card.copyWith(status: InstrumentStatus.confirmed, userCardId: walletCardId),
    );
    makeRowUnmatched(last4: '0000');
    healer().healAll(now: DateTime.utc(2026, 11, 15));
    expect(row()['user_card_id'], isNull);
    expect(row()['card_last4'], '0000');
  });

  test('a walk one fact at a time ends, and links what fits', () {
    InstrumentStore(database.db, namespace: namespace).upsert(
      card.copyWith(status: InstrumentStatus.confirmed, userCardId: walletCardId),
    );
    var steps = 0, linked = 0;
    HealCursor? cursor;
    do {
      final r = healer().step(after: cursor, now: DateTime.utc(2026, 11, 15), limit: 1);
      linked += r.linked;
      cursor = r.next;
      expect(++steps, lessThan(50), reason: 'a walk must end');
    } while (cursor != null);
    expect(linked, 1);
    expect(factLink(), card.instrumentId);
  });
}
