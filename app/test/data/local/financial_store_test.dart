import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local_sms_parser.dart';
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
const _googlePlaySender = 'AD-AXISBK-S';
const _googlePlayBody =
    'Your A/c has been debited towards Google Play for INR 4999.00 '
    'on 10-10-26. '
    '9901e1edad8e46cd937da209ef0baf55@axl - Axis Bank';

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

  for (final historical in [false, true]) {
    test('${historical ? 'historical repair' : 'date sync'} only learns unique active card dates', () {
      UserCard card(String id, String suffix, {
        String? type, bool archived = false, String? source, int? day,
      }) => UserCard(
        id: id, cardProductId: id, cardName: 'Card $id', isDefault: false,
        last4: suffix, cardType: type, isArchived: archived,
        dueDay: day, dueDaySource: source,
        statementDay: day, statementDaySource: source,
      );
      store.replaceCards('a', [
        card('active', '1001'),
        card('debit', '1001', type: 'debit'),
        card('archived', '1001', archived: true),
        card('collision-one', '1002'), card('collision-two', '1002'),
        card('only-debit', '1003', type: 'debit'),
        card('only-archived', '1003', archived: true),
        card('user', '1004', source: 'user', day: 7),
        card('user-cleared', '1005', source: 'user'),
        card('legacy', '1006', day: 8),
      ]);
      store.replaceCards('b', [card('active', '1001')]);
      for (final suffix in ['1001', '1002', '1003', '1004', '1005', '1006']) {
        if (historical) {
          SmsIntakeRepository(db).capture('a', QueuedSms(
            sender: 'HDFCBK',
            body: 'AutoPay scheduled for your credit card ending in $suffix on 25-Oct-2026 for Rs 4500. Maintain sufficient balance in your account.',
            receivedAt: DateTime(2026, 10, 20),
          ));
        } else {
          store.saveObservation('a', suffix, {
            'event_type': 'bill', 'card_last4': suffix,
            'due_date': '2026-10-25', 'statement_date': '2026-10-20',
            'received_at': '2026-10-20', 'is_autopay': true,
          });
        }
      }
      if (historical) {
        store.repairAutoPayArtifacts('a');
      } else {
        store.syncCardDatesFromObservations('a');
      }
      final cards = store.entities('a', 'cards');
      final active = cards.singleWhere((card) => card['id'] == 'active');
      expect(active['due_day'], 25);
      expect(active['due_day_source'], 'sms');
      expect(active['statement_day'], isNull);
      for (final card in cards.where((card) => card['id'] != 'active')) {
        final id = card['id'];
        final day = id == 'user' ? 7 : id == 'legacy' ? 8 : null;
        expect(card['due_day'], day, reason: '$id due day');
        expect(card['statement_day'], day, reason: '$id statement day');
        final source = id == 'user' || id == 'user-cleared' ? 'user' : null;
        expect(card['due_day_source'], source, reason: '$id due source');
        expect(card['statement_day_source'], source, reason: '$id statement source');
      }
      expect(store.entities('b', 'cards').single['due_day'], isNull);
    });
  }

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

  test('historical insurance repair keeps explicit cadence or one-time renewal', () {
    for (final (evidence, cadence) in [('', 'oneTime'), ('Half-yearly premium.', 'halfYearly')]) {
      final namespace = 'insurance-$cadence';
      SmsIntakeRepository(db).capture(namespace, QueuedSms(
        sender: 'HDFCER',
        body: 'Your insurance expires on 25-Oct-2026. Premium of Rs 2000. AutoPay will be debited on 25-Oct-2026. $evidence',
        receivedAt: DateTime(2026, 10, 20),
      ));
      store.repairAutoPayArtifacts(namespace);
      final commitments = db.db.select(
        'SELECT payload FROM local_commitments WHERE namespace=?', [namespace],
      );
      expect(jsonDecode(commitments.single['payload'] as String)['cadence'], cadence);
    }
  });

  test(
    'historical balance-bearing bank SMS resurfaces through the repair pass',
    () {
      db.db.execute(
        '''
        CREATE TABLE IF NOT EXISTS sms_captured_messages (
          namespace TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL,
          body TEXT NOT NULL, received_at INTEGER NOT NULL,
          processed INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(namespace, id)
        );
        ''',
      );
      const sliceBody =
          'Rs. 1 received in A/c xx5799 on 30-Jul-26 from API Banking EB via '
          'IMPS (Ref ID: 621107441979). Avl. Bal. Rs. 5,431.54 - slice';
      const kotakBody =
          'Rs. 1000.00 debited from A/c xx2626 on 30-Jul-26 towards UPI '
          'ref 621107441980 blocked. - Kotak Bank';
      final receivedAt =
          DateTime.utc(2026, 7, 30, 15, 3, 43).millisecondsSinceEpoch;
      for (final (id, sender, body) in [
        ('slice-balance', 'VM-SLCBNK-T', sliceBody),
        ('kotak-no-balance', 'VM-KOTAKB-T', kotakBody),
        ('slice-current', 'VM-SLCBNK-T', sliceBody),
      ]) {
        db.db.execute(
          'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at)'
          ' VALUES (?,?,?,?,?)',
          ['ns1', id, sender, body, receivedAt],
        );
      }
      // A capture whose observation is already at the current parser version
      // must be left untouched by the repair.
      store.saveObservation('ns1', 'slice-current', {
        'id': 'slice-current',
        'sender_bank': 'SLCBNK',
        'parser_version': LocalSmsParser.version,
        'received_at': '2026-07-30T15:03:43.000Z',
        'account_last4': '5799',
        'is_bank_account': true,
        'card_last4': null,
        'biller_name': null,
        'cadence_hint': null,
        'balance_paise': null,
        'amount_due_paise': null,
        'minimum_due_paise': null,
        'autopay_limit_paise': null,
        'due_date': null,
        'statement_date': null,
        'statement_date_explicit': false,
        'event_type': 'transaction',
        'disposition': 'sync',
        'reason_codes': <String>[],
        'confidence': 0.9,
      });
      // Simulate a stale pre-fix observation already persisted as a bank
      // account. Projection-level filtering must remove it without requiring
      // destructive local data deletion.
      store.saveObservation('ns1', 'axio-pay-later', {
        'id': 'axio-pay-later',
        'sender_bank': 'VM-axioFN',
        'parser_version': LocalSmsParser.version,
        'received_at': '2024-11-30T04:26:03.644Z',
        'account_last4': '6016',
        'is_bank_account': true,
        'card_last4': null,
        'balance_paise': null,
        'event_type': 'promotion',
        'disposition': 'local_ignore',
      });

      store.repairAutoPayArtifacts('ns1');

      // Both SLCBNK rows group into one account; the Kotak debit SMS
      // carries no balance, so it must never mint an observation.
      final accounts = store.bankAccounts('ns1');
      expect(accounts, hasLength(1));
      expect(accounts.single.accountLast4, '5799');
      expect(accounts.single.availableBalance?.paise, 543154);
      expect(
        accounts.single.latestBalanceSmsAt,
        DateTime.parse('2026-07-30T15:03:43.000Z'),
      );
      expect(accounts.single.smsCount, 2);

      final repaired =
          store.entities('ns1', 'sms_observations', id: 'slice-balance');
      expect(repaired, hasLength(1));
      expect(repaired.single['is_bank_account'], isTrue);
      expect(repaired.single['balance_paise'], 543154);

      final untouched =
          store.entities('ns1', 'sms_observations', id: 'slice-current');
      expect(untouched, hasLength(1));
      expect(untouched.single['balance_paise'], isNull);
      expect(untouched.single['parser_version'], LocalSmsParser.version);

      // Idempotent: a second pass neither duplicates observations nor
      // overwrites the already-current one, and the accountless Kotak
      // capture still produced nothing.
      final idsBefore = store
          .entities('ns1', 'sms_observations')
          .map((o) => o['id'])
          .toSet();
      // The stale Axio observation is intentionally retained as audit data;
      // bankAccounts() filters it at the projection boundary.
      expect(idsBefore, hasLength(3));
      store.repairAutoPayArtifacts('ns1');
      expect(
        store.entities('ns1', 'sms_observations').map((o) => o['id']).toSet(),
        idsBefore,
      );
    },
  );

  group('provisional SMS merchant repair', () {
    test('weak provisional merchant is repaired without changing money', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      final original = provisionalSms(key);
      store.saveProvisional(ns, original);
      final before = rawTransaction(db, ns, original.id);

      final rows = store.entities(ns, 'transactions');

      expect(rows, hasLength(1));
      expect(rows.single['merchant_name'], 'Balaji Sports');
      final after = rawTransaction(db, ns, original.id);
      expect(after['pending'], 1);
      expect(after['observed_at'], before['observed_at']);
      expect(after['source_key'], key);
      final beforePayload = before['payload'] as Map<String, dynamic>;
      final afterPayload = after['payload'] as Map<String, dynamic>;
      expect(afterPayload['merchant_name'], 'Balaji Sports');
      expect(
        {...afterPayload, 'merchant_name': beforePayload['merchant_name']},
        equals(beforePayload),
      );
      expect(
        db.db.select('SELECT 1 FROM sync_pending_changes'),
        isEmpty,
      );
    });

    test('confirmed SMS row is never rewritten or duplicated', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      final confirmed = provisionalSms(key);
      store.saveTransactions(ns, [confirmed]);
      final before = rawTransaction(db, ns, confirmed.id);

      final rows = store.entities(ns, 'transactions');

      expect(rows, hasLength(1));
      expect(rows.single['merchant_name'], 'Balaji Sports');
      expect(rawTransaction(db, ns, confirmed.id), before);
    });

    test('legacy generic name on a named-payee debit is repaired', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _googlePlaySender, _googlePlayBody);
      SmsIntakeRepository(db).remember(
        ns,
        QueuedSms(
          sender: _googlePlaySender,
          body: _googlePlayBody,
          receivedAt: DateTime(2026, 10, 10, 5, 30),
        ),
      );
      store.saveProvisional(
        ns,
        provisionalSms(
          key,
          merchant: 'Bank transfer',
          amountPaise: 499900,
        ),
      );

      final rows = store.entities(ns, 'transactions');

      expect(rows, hasLength(1));
      expect(rows.single['merchant_name'], 'Google Play');
      final after = rawTransaction(db, ns, 'local-sms:$key');
      expect(after['pending'], 1);
      expect((after['payload'] as Map<String, dynamic>)['amount_inr'], 4999);
    });

    test('a first capture of a named-payee debit stores the merchant', () {
      const ns = 'a';
      SmsImportStore(store).capture(
        ns,
        QueuedSms(
          sender: _googlePlaySender,
          body: _googlePlayBody,
          receivedAt: DateTime(2026, 10, 10, 5, 30),
        ),
      );

      final rows = store.entities(ns, 'transactions');

      expect(rows, hasLength(1));
      expect(rows.single['merchant_name'], 'Google Play');
      expect(rows.single['amount_inr'], 4999);
      expect(rows.single['entry_kind'], 'spend');
    });

    test('repair is scoped to the captured namespace', () {
      const ns = 'a';
      final keyA = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      final keyB = smsSourceKey('b', _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      store.saveProvisional(ns, provisionalSms(keyA));
      store.saveProvisional('b', provisionalSms(keyB));
      final beforeB = rawTransaction(db, 'b', 'local-sms:$keyB');

      store.entities(ns, 'transactions');

      expect(store.entities(ns, 'transactions').single['merchant_name'],
          'Balaji Sports');
      expect(store.entities('b', 'transactions').single['merchant_name'],
          'Unknown');
      expect(rawTransaction(db, 'b', 'local-sms:$keyB'), beforeB);
    });

    test('pending manual correction is never replaced', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      final original = provisionalSms(key);
      store.saveProvisional(ns, original);
      SyncQueue(db, namespace: ns).enqueueUpdate(
        entity: 'transactions',
        entityId: original.id,
        fields: {'merchant_name': 'Corner Shop'},
      );

      final visible = store.entities(ns, 'transactions').single;

      expect(visible['merchant_name'], 'Corner Shop');
      final raw = rawTransaction(db, ns, original.id);
      expect(
        (raw['payload'] as Map<String, dynamic>)['merchant_name'],
        'Unknown',
      );
    });

    test('a real provisional merchant is preserved', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      store.saveProvisional(ns, provisionalSms(key, merchant: 'Corner Shop'));

      expect(store.entities(ns, 'transactions').single['merchant_name'],
          'Corner Shop');
    });

    test('a mismatched amount keeps the provisional merchant', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      final original = provisionalSms(key, amountPaise: 12345);
      store.saveProvisional(ns, original);
      final before = rawTransaction(db, ns, original.id);

      expect(store.entities(ns, 'transactions').single['merchant_name'],
          'Unknown');
      expect(rawTransaction(db, ns, original.id), before);
    });

    test('mismatched instrument or entry kind keeps the provisional merchant',
        () {
      for (final (suffix, rowFor) in [
        ('instrument', (String key) =>
            provisionalSms(key, instrument: TxnInstrument.wallet)),
        ('kind', (String key) =>
            provisionalSms(key, entryKind: TxnEntryKind.transfer)),
      ]) {
        final ns = 'a-$suffix';
        final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
        captureMerchantRepairSms(db, ns);
        store.saveProvisional(ns, rowFor(key));

        expect(store.entities(ns, 'transactions').single['merchant_name'],
            'Unknown');
      }
    });

    test('a source receipt blocks provisional merchant repair', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      final original = provisionalSms(key);
      store.saveProvisional(ns, original);
      db.db.execute(
        'INSERT OR REPLACE INTO financial_source_receipts VALUES (?,?,?)',
        [ns, key, 'server-id'],
      );

      expect(store.entities(ns, 'transactions').single['merchant_name'],
          'Unknown');
    });

    test('user-modified auto-resolution history blocks repair', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      final original = provisionalSms(key);
      store.saveProvisional(ns, original);
      db.db.execute(
        'INSERT INTO local_auto_resolved_history (id, namespace, source_key, '
        'sender, resolved_kind, title, amount_paise, occurred_at, confidence, '
        'auto_resolved_at, is_user_modified) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,1)',
        [
          'ai:$key',
          ns,
          key,
          _merchantRepairSender,
          'transaction',
          'Manual Shop',
          70000,
          '2026-10-17T00:00:00.000',
          1.0,
          DateTime(2026, 10, 17).millisecondsSinceEpoch,
        ],
      );

      expect(store.entities(ns, 'transactions').single['merchant_name'],
          'Unknown');
    });

    test('receipt enrichment edits only a weak provisional merchant', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      final original = provisionalSms(key);
      store.saveProvisional(ns, original);
      final before = rawTransaction(db, ns, original.id);

      expect(
        FinancialStore.enrichProvisionalReceiptMerchant(
          db,
          ns,
          original.id,
          'Balaji Sports',
        ),
        isTrue,
      );

      final after = rawTransaction(db, ns, original.id);
      expect(after['pending'], 1);
      expect(after['observed_at'], before['observed_at']);
      final beforePayload = before['payload'] as Map<String, dynamic>;
      final afterPayload = after['payload'] as Map<String, dynamic>;
      expect(afterPayload['merchant_name'], 'Balaji Sports');
      expect(
        {...afterPayload, 'merchant_name': beforePayload['merchant_name']},
        equals(beforePayload),
      );
      expect(
        db.db.select('SELECT 1 FROM sync_pending_changes'),
        isEmpty,
      );
    });

    test('receipt enrichment never edits a confirmed row', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      final confirmed = provisionalSms(key);
      store.saveTransactions(ns, [confirmed]);
      final before = rawTransaction(db, ns, confirmed.id);

      expect(
        FinancialStore.enrichProvisionalReceiptMerchant(
          db,
          ns,
          confirmed.id,
          'Balaji Sports',
        ),
        isFalse,
      );
      expect(rawTransaction(db, ns, confirmed.id), before);
    });

    test('confirmed weak recipient is selected for safe source-key replay', () {
      const ns = 'a';
      final key = smsSourceKey(ns, _merchantRepairSender, _merchantRepairBody);
      captureMerchantRepairSms(db, ns);
      store.saveTransactions(ns, [provisionalSms(key)]);

      final candidates = store.recipientReplayCandidates(ns);
      expect(candidates, hasLength(1));
      expect(candidates.single['body'], _merchantRepairBody);
      expect(store.entities(ns, 'transactions').single['merchant_name'],
          'Balaji Sports');
    });
  });
}
