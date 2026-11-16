import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:sqlite3/sqlite3.dart';

// The phone reads its own SMS; the server builds its copy from what was
// uploaded and can know less. A server copy saved over an SMS row must never
// take away what the phone read about how the payment was made.
void main() {
  const ns = 'user:phone-reading';
  const eventId = 'e1';
  late AppDatabase database;
  late FinancialStore store;

  TransactionEntry phoneRow({String id = 'v2:$eventId'}) => TransactionEntry(
    id: id,
    eventId: eventId,
    pipelineVersion: 2,
    source: 'sms',
    amount: Money.fromPaise(119000),
    occurredAt: DateTime.utc(2026, 11, 3),
    merchantName: 'MANGALORESEAPARK',
    instrument: TxnInstrument.creditCard,
    userCardId: 'wallet-sbi',
    cardLast4: '2837',
    cardDisplayName: 'PhonePe SBI Select Black',
    smsReceivedAt: DateTime.utc(2026, 11, 3, 10),
    status: 'active',
  );

  TransactionEntry serverRow({
    String id = '882172c5-1474-4753-8719-9a0c78cb8a21',
    TxnInstrument instrument = TxnInstrument.other,
  }) => TransactionEntry(
    id: id,
    eventId: eventId,
    pipelineVersion: 2,
    source: 'sms',
    amount: Money.fromPaise(119000),
    occurredAt: DateTime.utc(2026, 11, 3),
    merchantName: 'MANGALORESEAPARK',
    instrument: instrument,
    status: 'active',
    note: 'set on another phone',
  );

  Map<String, Object?> only() => store.entities(ns, 'transactions').single;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    store = FinancialStore(database);
  });
  tearDown(() {
    store.dispose();
    database.db.dispose();
  });

  test('a server copy that says "other" keeps the card the phone read', () {
    store.saveTransactions(ns, [phoneRow()], fromPhoneProjection: true);
    store.saveTransactions(ns, [serverRow()]);
    final row = only();
    expect(row['instrument'], 'credit_card');
    expect(row['card_last4'], '2837');
    expect(row['user_card_id'], 'wallet-sbi');
    expect(row['card_name'], 'PhonePe SBI Select Black');
    expect(row['sms_received_at'], isNotNull);
    // What only the server has still arrives.
    expect(row['note'], 'set on another phone');
  });

  test('the same holds when the phone row already carries the server id', () {
    const id = '882172c5-1474-4753-8719-9a0c78cb8a21';
    store.saveTransactions(ns, [phoneRow(id: id)], fromPhoneProjection: true);
    store.saveTransactions(ns, [serverRow(id: id)]);
    expect(only()['instrument'], 'credit_card');
    expect(only()['card_last4'], '2837');
  });

  test('a server copy that names a payment method itself is taken', () {
    store.saveTransactions(ns, [phoneRow()], fromPhoneProjection: true);
    store.saveTransactions(ns, [serverRow(instrument: TxnInstrument.upiBank)]);
    expect(only()['instrument'], 'upi_bank');
  });

  test('the phone\'s own projection may still change it, also to "other"', () {
    store.saveTransactions(ns, [phoneRow()], fromPhoneProjection: true);
    store.saveTransactions(ns, [
      TransactionEntry.fromJson({
        ...phoneRow().toJson(),
        'instrument': 'other',
        'card_last4': null,
        'user_card_id': null,
        'card_name': null,
      }),
    ], fromPhoneProjection: true);
    expect(only()['instrument'], 'other');
  });

  test('a row that is not an SMS row is saved as the server sends it', () {
    store.saveTransactions(ns, [
      TransactionEntry.fromJson({
        ...phoneRow().toJson(),
        'source': 'manual',
        'pipeline_version': 1,
      }),
    ], fromPhoneProjection: true);
    store.saveTransactions(ns, [
      TransactionEntry.fromJson({...serverRow().toJson(), 'source': 'manual'}),
    ]);
    expect(only()['instrument'], 'other');
  });

  test('a server copy shown on a screen keeps the phone\'s reading too', () {
    final shown = FinancialStore.keepPhoneReading(serverRow(), phoneRow());
    expect(shown.instrument, TxnInstrument.creditCard);
    expect(shown.cardLast4, '2837');
    expect(shown.userCardId, 'wallet-sbi');
    expect(shown.smsReceivedAt, isNotNull);
    expect(shown.note, 'set on another phone');
    // Another transaction's row is never mixed in.
    final other = TransactionEntry.fromJson({...phoneRow().toJson(), 'event_id': 'e2'});
    expect(FinancialStore.keepPhoneReading(serverRow(), other).instrument, TxnInstrument.other);
    expect(FinancialStore.keepPhoneReading(serverRow(), null).instrument, TxnInstrument.other);
  });
}
