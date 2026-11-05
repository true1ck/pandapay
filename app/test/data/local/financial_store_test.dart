import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

TransactionEntry row(String id, {int day = 15, String? key, String? note}) =>
    TransactionEntry(
      id: id,
      amount: Money.fromPaise(12345),
      occurredAt: DateTime(2026, 10, day),
      sourceKey: key,
      merchantName: 'Shop',
      source: 'sms',
      status: 'active',
      note: note,
    );

const _merchantRepairSender = 'AX-SBIUPI-S';
const _merchantRepairBody =
    'Rs 700.0 debited from A/c XX5121 to Balaji Sports on 17Oct26. '
    'Your payment of Rs. 700.0 to Balaji Sports has been recorded. '
    'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r '
    '- myBillBook';
TransactionEntry provisionalSms(
  String key, {
  String? merchant = 'Unknown',
  int amountPaise = 70000,
  TxnInstrument instrument = TxnInstrument.upiBank,
  TxnEntryKind entryKind = TxnEntryKind.spend,
}) => TransactionEntry(
  id: 'local-sms:$key',
  sourceKey: key,
  amount: Money.fromPaise(amountPaise),
  occurredAt: DateTime(2026, 10, 17),
  merchantName: merchant,
  instrument: instrument,
  instrumentKnown: true,
  entryKind: entryKind,
  source: 'sms',
  status: 'active',
  rewardState: 'estimated',
);

void captureMerchantRepairSms(AppDatabase db, String namespace) {
  SmsIntakeRepository(db).remember(
    namespace,
    QueuedSms(
      sender: _merchantRepairSender,
      body: _merchantRepairBody,
      receivedAt: DateTime(2026, 10, 17),
    ),
  );
}

Map<String, Object?> rawTransaction(AppDatabase db, String namespace, String id) {
  final row = db.db
      .select(
        'SELECT payload, observed_at, pending, source_key '
        "FROM financial_entities WHERE namespace=? AND entity='transactions' "
        'AND id=?',
        [namespace, id],
      )
      .single;
  return {
    'payload': jsonDecode(row['payload'] as String),
    'observed_at': row['observed_at'],
    'pending': row['pending'],
    'source_key': row['source_key'],
  };
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
  const all = TransactionQuery();
  test('bill card choice survives re-import of its source SMS', () {
    const observation = {
      'id': 'bill-sms-1',
      'event_type': 'bill',
      'amount_due_paise': 833100,
      'due_date': '2026-11-08',
    };
    store.saveObservation('a', 'bill-sms-1', observation);
    store.saveCardBillAssignment(
      'a',
      'bill-sms-1',
      userCardId: 'moneyback',
      amountDuePaise: 833100,
      dueDate: DateTime(2026, 11, 8),
      statementDate: DateTime(2026, 10, 20),
    );
    store.saveObservation('a', 'bill-sms-1', {...observation, 'confidence': 0.95});

    final choice = store.cardBillAssignments('a')['bill-sms-1']!;
    expect(choice['user_card_id'], 'moneyback');
    expect(choice['amount_due_paise'], 833100);
    expect(choice['statement_date'], startsWith('2026-10-20'));
    expect(store.cardBillAssignments('b'), isEmpty);
  });
  test(
    'targeted detail reads retain queued corrections and account isolation',
    () {
      store.saveTransactions('a', [row('one'), row('two')]);
      SyncQueue(db, namespace: 'a').enqueueUpdate(
        entity: 'transactions',
        entityId: 'one',
        fields: {'note': 'offline edit'},
      );
      final detail = store.entities('a', 'transactions', id: 'one');
      expect(detail, hasLength(1));
      expect(detail.single['note'], 'offline edit');
      expect(store.entities('b', 'transactions', id: 'one'), isEmpty);
    },
  );

  test('card archive patches the cache-first wallet snapshot', () {
    const card = UserCard(
      id: 'card-1',
      cardProductId: 'product-1',
      cardName: 'Test Card',
      isDefault: false,
    );
    store.replaceCards('a', [card]);

    store.patchCard('a', card.id, {'is_archived': true});

    expect(store.entities('a', 'cards').single['is_archived'], isTrue);
  });

  test('large-history duplicate replay stays quiet', () async {
    final history = [for (var i = 0; i < 3000; i++) row('transaction-$i')];
    store.saveTransactions('a', history, completeQuery: all);
    await Future<void>.delayed(Duration.zero);
    final events = <FinancialChange>[];
    final subscription = store.changes.listen(events.add);
    final watch = Stopwatch()..start();
    store.saveTransactions('a', history.take(200).toList());
    for (var i = 0; i < 200; i++) {
      store.discardProvisional('a', 'already-confirmed-$i');
    }
    watch.stop();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(store.transactions('a', all)!.rows, hasLength(3000));
    // Diagnostic only: device frame timings are validated separately.
    print(
      '3000-row history / 200-row replay and acknowledgements: ${watch.elapsedMilliseconds} ms (host)',
    );
    await subscription.cancel();
  });
  test(
    'duplicate acknowledgements do not invalidate transaction readers',
    () async {
      store.saveTransactions('a', [row('server', key: 'known')]);
      await Future<void>.delayed(Duration.zero);
      final events = <FinancialChange>[];
      final subscription = store.changes.listen(events.add);
      store.discardProvisional('a', 'known', confirmedId: 'server');
      store.discardProvisional('a', 'unknown');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(store.hasReceipt('a', 'known'), isTrue);
      expect(store.transactions('a', all)!.rows.single.id, 'server');
      await subscription.cancel();
    },
  );

  test(
    'bulk provisional acknowledgements publish one committed change',
    () async {
      store.saveProvisional('a', row('local-1', key: 'one'));
      store.saveProvisional('a', row('local-2', key: 'two'));
      await Future<void>.delayed(Duration.zero);
      final events = <FinancialChange>[];
      final subscription = store.changes.listen(events.add);
      store.batch(() {
        store.discardProvisional('a', 'one');
        store.discardProvisional('a', 'two');
        store.discardProvisional('a', 'missing');
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(store.transactions('a', all), isNull);
      await subscription.cancel();
    },
  );

  test('older unchanged responses do not notify but newer edits do', () async {
    final now = DateTime(2026, 10, 18);
    store.saveTransactions('a', [row('one', note: 'current')], at: now);
    await Future<void>.delayed(Duration.zero);
    final events = <FinancialChange>[];
    final subscription = store.changes.listen(events.add);
    store.saveTransactions('a', [
      row('one', note: 'old'),
    ], at: now.subtract(const Duration(days: 1)));
    store.saveTransactions('a', [row('one', note: 'current')], at: now);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    store.saveTransactions('a', [
      row('one', note: 'updated'),
    ], at: now.add(const Duration(seconds: 1)));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(store.transactions('a', all)!.rows.single.note, 'updated');
    await subscription.cancel();
  });
  test('screens query one record and account boundaries are enforced', () {
    store.saveTransactions('user:a', [row('one')], completeQuery: all);
    expect(
      store
          .transactions(
            'user:a',
            TransactionQuery(from: DateTime(2026, 10, 1)),
          )!
          .rows
          .single
          .id,
      'one',
    );
    expect(store.transactions('user:b', all), isNull);
  });
  test(
    'successful empty response removes stale rows and remains known empty',
    () {
      store.saveTransactions('a', [row('old')], completeQuery: all);
      store.saveTransactions('a', [], completeQuery: all);
      final result = store.transactions('a', all)!;
      expect(result.rows, isEmpty);
      expect(result.complete, isTrue);
    },
  );
  test('range replacement cannot remove rows outside its scope', () {
    store.saveTransactions('a', [
      row('early', day: 1),
      row('late', day: 25),
    ], completeQuery: all);
    store.saveTransactions(
      'a',
      [],
      completeQuery: TransactionQuery(from: DateTime(2026, 10, 20)),
    );
    expect(store.transactions('a', all)!.rows.map((r) => r.id), ['early']);
  });
  test('partial observations retain their real age', () {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    store.saveTransactions('a', [row('one')], at: yesterday);
    final result = store.transactions('a', all)!;
    expect(result.complete, isFalse);
    expect(
      result.fetchedAt.millisecondsSinceEpoch,
      yesterday.millisecondsSinceEpoch,
    );
  });
  test(
    'same SMS identity is replaced by the confirmed server row exactly once',
    () {
      store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
      store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
      store.saveTransactions('a', [row('server-id', key: 'abc')]);
      store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
      expect(store.transactions('a', all)!.rows.map((r) => r.id), [
        'server-id',
      ]);
    },
  );
  test('server refresh preserves pending device transactions', () {
    store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
    store.saveTransactions('a', [], completeQuery: all);
    expect(store.transactions('a', all)!.rows.single.id, 'local-sms:abc');
  });

  test('removed server rows cannot be resurrected by an old SMS replay', () {
    store.saveTransactions('a', [
      row('server', key: 'message'),
    ], completeQuery: all);
    store.saveTransactions('a', [], completeQuery: all);
    store.saveProvisional('a', row('local-sms:message', key: 'message'));
    expect(store.transactions('a', all)!.rows, isEmpty);
  });

  test(
    'a late older response cannot overwrite a newer record or sync time',
    () {
      final newer = DateTime(2026, 10, 18);
      store.saveTransactions(
        'a',
        [row('id', note: 'new')],
        completeQuery: all,
        at: newer,
      );
      store.saveTransactions(
        'a',
        [row('id', note: 'old')],
        completeQuery: all,
        at: DateTime(2026, 10, 17),
      );
      final result = store.transactions('a', all)!;
      expect(result.rows.single.note, 'new');
      expect(result.fetchedAt, newer);
    },
  );
  test('queued correction overlays server state until acknowledged', () {
    store.saveTransactions('a', [row('id', note: 'old')], completeQuery: all);
    final queue = SyncQueue(db, namespace: 'a');
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'id',
      fields: {'note': 'edited offline'},
    );
    store.saveTransactions('a', [row('id', note: 'remote')]);
    expect(store.transactions('a', all)!.rows.single.note, 'edited offline');
    queue.remove(queue.pending().single.clientSeq);
    expect(store.transactions('a', all)!.rows.single.note, 'remote');
  });
  test('local search matches notes as well as merchants', () {
    store.saveTransactions('a', [row('id', note: 'Insurance renewal')]);
    expect(
      store
          .transactions('a', const TransactionQuery(query: 'insurance'))!
          .rows
          .single
          .id,
      'id',
    );
  });
  test(
    'legacy snapshots migrate once without resurrecting removed records',
    () {
      db.db.execute('INSERT INTO cached_responses VALUES (?,?,?)', [
        'a:transactions:all',
        jsonEncode({
          'transactions': [row('old').toJson()],
        }),
        1,
      ]);
      store.migrateLegacy('a');
      expect(store.transactions('a', all)!.rows.single.id, 'old');
      store.saveTransactions('a', [], completeQuery: all);
      store.migrateLegacy('a');
      expect(store.transactions('a', all)!.rows, isEmpty);
    },
  );
  test('clear removes one account without affecting another', () {
    store.saveTransactions('a', [row('a')], completeQuery: all);
    store.saveTransactions('b', [row('b')], completeQuery: all);
    store.clear('a');
    expect(store.transactions('a', all), isNull);
    expect(store.transactions('b', all)!.rows.single.id, 'b');
  });
  test(
    'commits notify consumers but identical server rows do not loop',
    () async {
      final events = <String>[];
      final subscription = store.changes.listen(
        (change) => events.add(change.namespace),
      );
      store.saveTransactions('a', [row('one')], completeQuery: all);
      store.saveTransactions('a', [row('one')], completeQuery: all);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['a']);
      await subscription.cancel();
    },
  );
  test(
    'syncCardDatesFromObservations heals statement day and due day from verified bill',
    () {
      final card = UserCard(
        id: 'c1',
        cardProductId: 'axis_fk',
        cardName: 'Flipkart Axis Bank Credit Card',
        isDefault: false,
        last4: '7105',
        statementDay: 26,
        statementDaySource: 'sms',
        dueDay: 2,
        dueDaySource: 'sms',
      );
      store.replaceCards('a', [card]);
      store.saveObservation('a', 'obs1', {
        'event_type': 'bill',
        'card_last4': '7105',
        'statement_date': '2026-10-14T00:00:00.000',
        // Only a statement date the issuer printed heals the card's cycle
        // days; a receive-date anchor never does.
        'statement_date_explicit': true,
        'due_date': '2026-11-02T00:00:00.000',
        'received_at': '2026-10-14T10:00:00.000',
      });
      store.syncCardDatesFromObservations('a');
      final updated = store.entities('a', 'cards').single;
      expect(updated['statement_day'], 14);
      expect(updated['due_day'], 2);
    },
  );

  test('legacy repair checks again when a newer local observation is stored', () {
    final card = UserCard(
      id: 'c-refresh',
      cardProductId: 'axis_fk',
      cardName: 'Flipkart Axis Bank Credit Card',
      isDefault: false,
      last4: '7105',
      statementDay: 26,
      statementDaySource: 'sms',
      dueDay: 2,
      dueDaySource: 'sms',
    );
    store.replaceCards('a', [card]);
    store.migrateLegacy('a');
    store.saveObservation('a', 'obs-refresh', {
      'event_type': 'bill',
      'card_last4': '7105',
      'statement_date': '2026-10-14T00:00:00.000',
      'statement_date_explicit': true,
      'due_date': '2026-11-02T00:00:00.000',
      'received_at': '2026-10-14T10:00:00.000',
    });
    store.migrateLegacy('a');
    final updated = store.entities('a', 'cards').single;
    expect(updated['statement_day'], 14);
    expect(updated['due_day'], 2);
  });

  test(
    'syncCardDatesFromObservations heals due day from verified AutoPay alert',
    () {
      final card = UserCard(
        id: 'c2',
        cardProductId: 'hdfc_mb',
        cardName: 'MoneyBack+ Credit Card',
        isDefault: false,
        last4: '8708',
        statementDay: 20,
        dueDay: null,
      );
      store.replaceCards('a', [card]);
      store.saveObservation('a', 'obs-autopay', {
        'event_type': 'bill',
        'card_last4': '8708',
        'due_date': '2026-10-09T00:00:00.000',
        'received_at': '2026-10-05T10:00:00.000',
        'is_autopay': true,
        'reason_codes': ['autopay_notice'],
      });
      store.syncCardDatesFromObservations('a');
      final updated = store.entities('a', 'cards').single;
      expect(updated['statement_day'], 20);
      expect(updated['due_day'], 9);
    },
  );

  test(
    'syncCardDatesFromObservations heals statement day from statement generated alert without explicit token',
    () {
      final card = UserCard(
        id: 'c-axis',
        cardProductId: 'axis_fk',
        cardName: 'Flipkart Axis Bank Credit Card',
        isDefault: false,
        last4: '7105',
        statementDay: 26,
        statementDaySource: 'sms',
        dueDay: 2,
        dueDaySource: 'sms',
      );
      store.replaceCards('a', [card]);
      store.saveObservation('a', 'obs-axis', {
        'event_type': 'bill',
        'card_last4': '7105',
        'statement_date': '2026-10-14T10:00:00.000',
        'statement_date_explicit': false,
        'due_date': '2026-11-02T00:00:00.000',
        'received_at': '2026-10-14T10:00:00.000',
      });
      store.syncCardDatesFromObservations('a');
      final updated = store.entities('a', 'cards').single;
      expect(updated['statement_day'], 14);
      expect(updated['due_day'], 2);
    },
  );

  test('SMS observations never overwrite user-entered card days', () {
    final card = UserCard(
      id: 'c-user',
      cardProductId: 'axis_fk',
      cardName: 'Flipkart Axis Bank Credit Card',
      isDefault: false,
      last4: '7105',
      statementDay: 26,
      statementDaySource: 'user',
      dueDay: 2,
      dueDaySource: 'user',
    );
    store.replaceCards('a', [card]);
    store.saveObservation('a', 'obs-user-days', {
      'event_type': 'bill',
      'card_last4': '7105',
      'statement_date': '2026-10-14T10:00:00.000',
      'statement_date_explicit': true,
      'due_date': '2026-11-03T00:00:00.000',
      'received_at': '2026-10-14T10:00:00.000',
    });

    store.syncCardDatesFromObservations('a');

    final updated = store.entities('a', 'cards').single;
    expect(updated['statement_day'], 26);
    expect(updated['due_day'], 2);
    expect(updated['statement_day_source'], 'user');
    expect(updated['due_day_source'], 'user');
  });

  test('newer AutoPay uses an older verified statement day, not arrival day', () {
    store.replaceCards('a', [const UserCard(
      id: 'card', cardProductId: 'credit', cardName: 'Credit Card',
      isDefault: false, last4: '7105',
    )]);
    store.saveObservation('a', 'statement', {
      'event_type': 'bill', 'card_last4': '7105',
      'statement_date': '2026-10-14', 'statement_date_explicit': true,
      'due_date': '2026-11-02', 'received_at': '2026-10-15',
    });
    store.saveObservation('a', 'autopay', {
      'event_type': 'bill', 'card_last4': '7105',
      'statement_date': '2026-10-20', 'statement_date_explicit': false,
      'due_date': '2026-11-03', 'received_at': '2026-10-20',
      'reason_codes': ['mandate_notice'],
    });
    store.syncCardDatesFromObservations('a');
    final updated = store.entities('a', 'cards').single;
    expect(updated['due_day'], 3);
    expect(updated['statement_day'], 14);
    expect(updated['due_day_source'], 'sms');
    expect(updated['statement_day_source'], 'sms');
    store.saveObservation('a', 'printed-autopay-statement', {
      'event_type': 'bill', 'card_last4': '7105',
      'statement_date': '2026-10-16', 'statement_date_explicit': true,
      'received_at': '2026-10-21', 'is_autopay': true,
    });
    store.syncCardDatesFromObservations('a');
    expect(store.entities('a', 'cards').single['statement_day'], 16);
  });

}
