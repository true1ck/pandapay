import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay/features/sms_v2/ui/transaction_actions.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// "This payment was to my own account" and "this was a credit card bill" are
// one-tap choices on a transaction, so they must change the event type and
// take the money out of spending.
void main() {
  const namespace = 'user:mark-kind';
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsTransactionActions actions;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    SmsIntakeRepository(database);
    SmsV2Schema.ensure(database.db);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    actions = SmsTransactionActions(
      controller: ReviewController(financial: financial, namespace: namespace, bundle: bundle),
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  TransactionEntry current() => financial
      .entities(namespace, 'transactions')
      .map(TransactionEntry.fromJson)
      .single;

  TransactionEntry receive() {
    final message = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: bundle.rules.first.examples.first.body,
      sourceKey: 'a' * 64,
      observedAt: DateTime.utc(2026, 11, 1, 7),
    );
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [namespace, message.sourceKey, message.sender, message.body, message.observedAt.millisecondsSinceEpoch],
    );
    SmsV2Pipeline(financial: financial, namespace: namespace, bundle: bundle, appVersion: '2').process(message);
    return current();
  }

  EventType? storedType(TransactionEntry e) =>
      EventStore(database.db, namespace: namespace).get(e.eventId!)?.type;

  bool spends() => LedgerStore(database.db, namespace: namespace).list().any((e) => e.isSpend);

  test('a payment starts as a purchase that counts as spending', () {
    final entry = receive();
    expect(storedType(entry), EventType.purchase);
    expect(spends(), isTrue);
  });

  test('"transfer between my accounts" takes it out of spending', () {
    final entry = receive();
    actions.markAs(entry, EventType.ownTransfer);
    expect(storedType(current()), EventType.ownTransfer);
    expect(current().entryKind, TxnEntryKind.transfer);
    expect(spends(), isFalse);
  });

  test('"credit card bill" takes it out of spending and is labelled as a card payment', () {
    final entry = receive();
    actions.markAs(entry, EventType.cardBillPayment);
    expect(storedType(current()), EventType.cardBillPayment);
    expect(current().entryKind, TxnEntryKind.transfer);
    expect(current().merchantName, 'Credit card payment');
    expect(spends(), isFalse);
  });

  test('the stored type tells a card bill from an own transfer', () {
    final entry = receive();
    expect(actions.storedType(entry), EventType.purchase);
    actions.markAs(entry, EventType.cardBillPayment);
    expect(actions.storedType(current()), EventType.cardBillPayment);
  });

  test('an edit that leaves a card bill as a transfer keeps it a card bill', () {
    final entry = receive();
    actions.markAs(entry, EventType.cardBillPayment);
    final bill = current();
    actions.edit(
      bill,
      amountMinor: bill.amount.paise + 100,
      merchant: bill.merchantName ?? '',
      occurredAt: bill.occurredAt,
      eventType: EventType.cardBillPayment,
    );
    expect(storedType(current()), EventType.cardBillPayment);
  });
}
