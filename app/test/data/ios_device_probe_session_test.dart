import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_device_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  test('Shortcut acquisition produces the same shared records as Android', () {
    final iosDb = openInMemoryForTesting();
    final androidDb = openInMemoryForTesting();
    final session = IosDeviceProbeSession(iosDb);
    final androidStore = FinancialStore(androidDb);
    addTearDown(() {
      session.dispose();
      androidStore.dispose();
      androidDb.close();
    });
    final originals = [
      QueuedSms(
        sender: 'VM-ICICIB',
        body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
        receivedAt: DateTime.utc(2026, 9, 30, 14, 40),
      ),
      QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'Debit alert: INR 875.50 spent at Green Basket.',
        receivedAt: DateTime.utc(2026, 9, 29, 12),
      ),
      QueuedSms(
        sender: 'VM-HDFCBK',
        body:
            'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-09-26.',
        receivedAt: DateTime.utc(2026, 9, 16, 10),
      ),
    ];
    session.accept([
      for (var i = 0; i < originals.length; i++)
        {'id': '$i', ...originals[i].toJson(), 'senderEvidence': 'handle'},
    ]);
    SmsImportStore(
      androidStore,
    ).captureBatch(IosDeviceProbeSession.namespace, originals);
    for (final query in [
      'SELECT sender,body,received_at,processed FROM sms_captured_messages ORDER BY id',
      'SELECT sender,body,received_at FROM sms_intake ORDER BY id',
      'SELECT source_key,decision,state,reason_code,received_at FROM sms_source_decisions ORDER BY source_key',
      'SELECT entity,id,payload FROM financial_entities ORDER BY entity,id',
      'SELECT id,payload FROM local_needs_review ORDER BY id',
      'SELECT id,sender,occurred_at,facts FROM sms_facts_outbox ORDER BY id',
    ]) {
      expect(
        iosDb.db.select(query).map((r) => Map.of(r)).toList(),
        androidDb.db.select(query).map((r) => Map.of(r)).toList(),
        reason: query,
      );
    }
    expect(
      session.retainedInputs.map((r) => r.body),
      containsAll(originals.map((m) => m.body)),
    );
    expect(session.transactions, 1);
    final before = session.counts;
    // A different transport id still uses Android's canonical source key.
    session.accept([
      {'id': 'replay', ...originals.first.toJson()},
    ]);
    expect(session.counts, before);
  });

  test(
    'input with missing sender infers bank and creates shared financial state',
    () {
      final db = openInMemoryForTesting();
      final session = IosDeviceProbeSession(db);
      addTearDown(session.dispose);
      session.accept([
        {
          'id': 'inferred',
          'sender': '',
          'body': 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
          'receivedAt': '2026-09-30T14:40:51Z',
        },
      ]);
      expect(session.missingSender, 1);
      expect(session.counts.captured, 1);
      expect(session.observations, isNotEmpty);
      expect(session.retainedInputs.first.sender, 'VM-ICICIB');
    },
  );
  test(
    'per-run matches and cumulative new counts remain distinct on repeat',
    () {
      final session = IosDeviceProbeSession(openInMemoryForTesting());
      addTearDown(session.dispose);
      final row = <Object?, Object?>{
        'id': 'a',
        'runId': 'first',
        'sender': 'VM-ICICIB',
        'body':
            'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 03-03-2026.',
        'receivedAt': '2026-09-30T14:40:51Z',
        'capturedAt': '2026-10-29T10:00:00Z',
      };
      session.accept([row, row]);
      expect(session.runs['first']!.handedOff, 1);
      expect(session.runs['first']!.retainedAdded, 1);
      expect(session.transactionsForRun('first'), hasLength(1));
      final source = session.findSourceMessage(session.transactionList.single)!;
      expect(source.date, DateTime.utc(2026, 9, 30, 14, 40, 51));
      expect(source.capturedAt, DateTime.utc(2026, 10, 29, 10));
      session.accept([
        {...row, 'id': 'b', 'runId': 'second'},
      ]);
      expect(session.runs['second']!.retainedAdded, 0);
      expect(session.runs['second']!.transactionsAdded, 0);
      expect(session.runs['second']!.existing, 1);
      expect(session.transactionsForRun('second'), hasLength(1));
      expect(session.transactionsForRun('unrelated'), isEmpty);
      expect(session.counts.captured, 1);
      expect(
        session.findSourceMessage({
          'amount_inr': 250,
          'merchant_name': 'SWIGGY',
        }),
        isNull,
      );
    },
  );
  test(
    'distinct records preserve sender/body/date association and inference evidence',
    () {
      final session = IosDeviceProbeSession(openInMemoryForTesting());
      addTearDown(session.dispose);
      session.accept([
        {
          'id': 'one',
          'runId': 'run',
          'sender': 'VM-ICICIB',
          'body': 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
          'receivedAt': '2026-09-01T00:00:00Z',
        },
        {
          'id': 'two',
          'runId': 'run',
          'sender': '',
          'body': 'INR 450 spent on ICICI Bank Card XX7788 at UBER.',
          'receivedAt': '2026-09-02T00:00:00Z',
        },
        {
          'id': 'missing',
          'runId': 'run',
          'sender': '',
          'body':
              'INR 600 spent on ICICI Bank Card XX7788 at CAFE on 03-03-2026.',
        },
      ]);
      final sources = session.retainedInputs;
      expect(sources, hasLength(2));
      final uber = sources.singleWhere(
        (source) => source.body.contains('UBER'),
      );
      expect(uber.date, DateTime.utc(2026, 9, 2));
      expect(uber.senderInferred, isTrue);
      expect(session.missingDate, 1);
      expect(session.runs['run']!.missingDate, 1);
    },
  );
  test(
    'reused body keeps this run receive dates separate from canonical dedup',
    () {
      final session = IosDeviceProbeSession(openInMemoryForTesting());
      addTearDown(session.dispose);
      const body = 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.';
      Map<Object?, Object?> row(String id, String run, String date) => {
        'id': id,
        'runId': run,
        'sender': 'VM-ICICIB',
        'body': body,
        'receivedAt': date,
      };
      session.accept([row('march', 'march', '2026-03-01T00:00:00Z')]);
      session.accept([
        row('sept1', 'sept', '2026-09-01T00:00:00Z'),
        row('sept2', 'sept', '2026-09-02T00:00:00Z'),
      ]);
      final tx = session.transactionsForRun('sept').single;
      expect(session.counts.captured, 1);
      expect(
        session.sourcesForTransaction(tx, runId: 'sept').map((s) => s.date),
        [DateTime.utc(2026, 9, 1), DateTime.utc(2026, 9, 2)],
      );
      expect(session.findSourceMessage(tx, runId: 'sept'), isNull);
      expect(session.findSourceMessage(tx)!.date, DateTime.utc(2026, 3, 1));
    },
  );
}
