import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/sms_fact_contract.dart' show smsSpendCategories;
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/corrections/corrections_service.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/learning_signals.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:a';
const _body = 'Rs.499 spent on card xx5678 at SWIGGY.';
final _now = DateTime.utc(2026, 11, 6, 9);

Counterparty _shop(String name, {CounterpartyKind kind = CounterpartyKind.merchant}) =>
    Counterparty(name: name, kind: kind);

LearningSignal? _signal({
  String kind = 'category_choice',
  EventType type = EventType.purchase,
  Counterparty? shop,
  String sender = 'AD-HDFCBK',
  String value = 'dining',
}) => learningSignalFor(
  kind: kind,
  eventType: type,
  counterparty: shop ?? _shop('SWIGGY'),
  sender: sender,
  value: value,
);

void main() {
  group('learningSignalFor', () {
    test('a Swiggy purchase from AD-HDFCBK becomes a dining signal', () {
      final signal = _signal()!;
      expect(signal.toJson(), {
        'kind': 'category_choice',
        'senderBrand': 'HDFCBK',
        'merchantKey': 'SWIGGY',
        'value': 'dining',
      });
      expect(signal.id, 'category_choice:SWIGGY:dining');
    });

    test('only purchases are shared', () {
      for (final type in EventType.values) {
        if (type == EventType.purchase) continue;
        expect(_signal(type: type), isNull, reason: type.wire);
      }
      expect(_signal(type: EventType.income), isNull);
      expect(_signal(type: EventType.ownTransfer), isNull);
    });

    test('people and own accounts are never shared', () {
      expect(_signal(shop: _shop('RAHUL SHARMA', kind: CounterpartyKind.person)), isNull);
      expect(_signal(shop: _shop('MY SAVINGS', kind: CounterpartyKind.own)), isNull);
      expect(learningSignalFor(kind: 'category_choice', eventType: EventType.purchase, counterparty: null, sender: 'HDFCBK', value: 'dining'), isNull);
    });

    test('keys that could identify someone are dropped', () {
      expect(_signal(shop: _shop('PAYTMQR2810050501')), isNull, reason: 'digits');
      expect(_signal(shop: _shop('SHOP 12345')), isNull);
      expect(_signal(shop: _shop('RAHUL@OKAXIS')), isNull, reason: 'a UPI id');
      expect(_signal(shop: _shop('9876 5432 10 SHOP')), isNull, reason: 'a phone number split by spaces');
      expect(_signal(shop: _shop('')), isNull);
      expect(_signal(shop: _shop('S')), isNull);
      expect(_signal(shop: _shop('A' * 61)), isNull);
    });

    test('a category must be a canonical spend category', () {
      expect(_signal(value: 'my_custom_category'), isNull);
      expect(_signal(value: ''), isNull);
      expect(_signal(value: 'groceries'), isNotNull);
      expect(
        smsSpendCategories.toSet(),
        containsAll(['groceries', 'fuel', 'dining', 'online', 'other']),
      );
    });

    test('a shop name has no digits and differs from its key', () {
      final ok = _signal(kind: 'merchant_name', shop: _shop('PAYU SWIGGY'), value: 'Swiggy')!;
      expect(ok.value, 'SWIGGY');
      expect(ok.merchantKey, 'PAYU SWIGGY');
      expect(_signal(kind: 'merchant_name', shop: _shop('PAYU SWIGGY'), value: 'SWIGGY 2'), isNull);
      expect(_signal(kind: 'merchant_name', shop: _shop('SWIGGY'), value: 'swiggy'), isNull, reason: 'same as the key');
      expect(_signal(kind: 'merchant_name', shop: _shop('SWIGGY'), value: ''), isNull);
    });

    test('an uncategorised signal carries no value', () {
      final signal = _signal(kind: 'uncategorised', shop: _shop('BLINKIT'), value: 'ignored')!;
      expect(signal.value, '');
      expect(signal.id, 'uncategorised:BLINKIT:');
    });
  });

  group('on the phone', () {
    late AppDatabase db;
    late FinancialStore financial;
    late SmsIntakeRepository intake;
    late RuleBundle bundle;
    late CorrectionsService service;
    final events = <Event>[];
    final facts = <Fact>[];
    const trace = DecisionTrace(
      appVersion: '1',
      engineVersion: '2.0.0',
      bundleVersion: 1,
      outcome: 'matched',
    );

    Map<String, Object?> template() =>
        (jsonDecode(
                  File('../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json').readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();

    /// A Swiggy purchase read from its own captured message.
    Fact addPurchase(int n, {String shop = 'SWIGGY', String sender = 'AD-HDFCBK', String kind = 'merchant'}) {
      final body = '$_body Ref $n';
      final sms = QueuedSms(sender: sender, body: body, receivedAt: DateTime.utc(2026, 11, 1, 7, n));
      intake.remember(_ns, sms);
      final json = template();
      final id = sha256.convert(utf8.encode('fact$n$shop')).toString();
      json['factId'] = id;
      json['sourceKey'] = smsSourceKey(_ns, sender, body);
      json['counterparty'] = {'name': shop, 'vpa': null, 'kind': kind, 'accountMask': null};
      final fact = Fact.fromJson(json);
      FactStore(db.db, namespace: _ns).insert(fact);
      final event = Event(
        eventId: fact.factId,
        type: EventType.purchase,
        status: EventStatus.complete,
        legs: [EventLeg(factId: fact.factId, role: LegRole.debitLeg)],
        confidence: .99,
        occurredAt: fact.effectiveAt,
        amountMinor: fact.amounts.first.minor,
      );
      EventStore(db.db, namespace: _ns).upsert(event);
      facts.add(fact);
      events.add(event);
      ProjectionWriter(financial, LedgerStore(db.db, namespace: _ns)).write(
        LedgerSnapshot.project(
          events: [event],
          factsById: {fact.factId: fact},
          instrumentsById: {},
          bundle: bundle,
        ),
        factsById: {fact.factId: fact},
        instrumentsById: {},
      );
      return fact;
    }

    OutboxStore outbox() => OutboxStore(db.db, namespace: _ns);
    List<OutboxRecord> signalsQueued() => outbox().due(_now).where((r) => r.kind == 'signal').toList();

    setUp(() {
      events.clear();
      facts.clear();
      db = AppDatabase.forTesting(sqlite3.openInMemory());
      SmsV2Schema.ensure(db.db);
      financial = FinancialStore(db);
      intake = SmsIntakeRepository(db);
      bundle = RuleBundle.fromJson(
        (jsonDecode(File('assets/sms_rules/baseline_bundle.json').readAsStringSync()) as Map).cast<String, Object?>(),
      );
      service = CorrectionsService(financial: financial, namespace: _ns, bundle: bundle);
    });
    tearDown(() => db.db.dispose());

    SmsCorrection correction(Fact fact, CorrectionKind kind, Map<String, Object?> corrected, {required bool consent}) =>
        SmsCorrection(
          id: '${kind.wire}-${fact.factId.substring(0, 6)}',
          sourceKey: fact.sourceKey,
          kind: kind,
          corrected: corrected,
          trace: trace,
          factIds: [fact.factId],
          eventId: fact.factId,
          sharedLearningConsent: consent,
          message: intake.capturedById(_ns, fact.sourceKey)!.message.let(
            (m) => SmsMessage(sender: m.sender, body: m.body, observedAt: fact.observedAt, sourceKey: fact.sourceKey),
          ),
        );

    test('a category fix with sharing on queues a category_choice and shares the shop with the case', () {
      final fact = addPurchase(1);
      service.apply(correction(fact, CorrectionKind.wrongCategory, {'merchantKey': 'SWIGGY', 'category': 'groceries'}, consent: true));
      final signal = signalsQueued().single;
      expect(signal.id, 'signal:category_choice:SWIGGY:groceries');
      expect(signal.json, {'kind': 'category_choice', 'senderBrand': 'HDFCBK', 'merchantKey': 'SWIGGY', 'value': 'groceries'});
      final shared = outbox().due(_now).singleWhere((r) => r.kind == 'correction').json;
      expect((shared['corrected'] as Map)['merchantKey'], 'SWIGGY');
      expect((shared['corrected'] as Map)['category'], 'groceries');
    });

    test('nothing is queued or shared without consent, nor for a personal preference', () {
      final fact = addPurchase(1);
      service.apply(correction(fact, CorrectionKind.wrongCategory, {'merchantKey': 'SWIGGY', 'category': 'groceries'}, consent: false));
      expect(signalsQueued(), isEmpty);
      final other = addPurchase(2);
      service.apply(correction(other, CorrectionKind.preferenceOnly, {'merchantKey': 'SWIGGY', 'category': 'groceries'}, consent: true));
      expect(signalsQueued(), isEmpty);
    });

    test('a shop-name fix queues a merchant_name signal', () {
      final fact = addPurchase(1, shop: 'PAYU SWIGGY');
      service.apply(correction(fact, CorrectionKind.wrongMerchant, {'merchantName': 'Swiggy'}, consent: true));
      final signal = signalsQueued().single;
      expect(signal.id, 'signal:merchant_name:PAYU SWIGGY:SWIGGY');
    });

    test('a person payee is never shared, even with consent', () {
      final fact = addPurchase(1, shop: 'RAHUL SHARMA', kind: 'person');
      service.apply(correction(fact, CorrectionKind.wrongCategory, {'merchantKey': 'RAHUL SHARMA', 'category': 'groceries'}, consent: true));
      expect(signalsQueued(), isEmpty);
    });

    test('a bulk change of three Swiggy entries queues one signal', () {
      final three = [addPurchase(1), addPurchase(2), addPurchase(3)];
      final entries = [
        for (final fact in three)
          TransactionEntry(
            id: 't-${fact.factId.substring(0, 6)}',
            pipelineVersion: 2,
            eventId: fact.factId,
            sourceKey: fact.sourceKey,
            amount: Money.fromRupees(499),
            occurredAt: fact.effectiveAt,
            merchantName: 'SWIGGY',
            categoryId: 'cat-online',
            source: 'sms',
            status: 'active',
          ),
        // A legacy row and a row already in the chosen category teach nothing.
        TransactionEntry(id: 'legacy', amount: Money.fromRupees(1), occurredAt: _now, source: 'sms', status: 'active'),
      ];
      final signals = categoryChoiceSignalsForEntries(
        db: db.db,
        intake: intake,
        namespace: _ns,
        entries: entries,
        categorySlug: 'groceries',
      );
      expect(signals, hasLength(1));
      for (final signal in signals) {
        enqueueLearningSignal(outbox(), signal);
      }
      expect(signalsQueued(), hasLength(1));
      expect(
        categoryChoiceSignalsForEntries(
          db: db.db,
          intake: intake,
          namespace: _ns,
          entries: entries,
          categorySlug: 'groceries',
          chosenCategoryId: 'cat-online',
        ),
        isEmpty,
      );
    });

    group('upload', () {
      var consent = false;
      final posts = <Map<String, Object?>>[];
      var status = 202;

      LearningSignalUpload uploader() => LearningSignalUpload(
        intake: intake,
        queue: outbox(),
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        hasConsent: () async => consent,
        accountIsCurrent: () => true,
        taxonomyVersion: () => 1,
        clock: () => _now,
        client: MockClient((request) async {
          expect(request.url.path, '/sms/v2/learning-signals');
          posts.add((jsonDecode(request.body) as Map).cast<String, Object?>());
          return http.Response(status == 202 ? '{"accepted":1}' : '{"error":"learning_paused"}', status);
        }),
      );

      setUp(() {
        consent = false;
        posts.clear();
        status = 202;
      });

      test('a shop left in Other is queued once per shop, and only with consent', () async {
        addPurchase(1, shop: 'BLINKIT');
        addPurchase(2, shop: 'BLINKIT');
        expect(LedgerStore(db.db, namespace: _ns).categoryDecisions().values.map((d) => d.source), everyElement(CategorySource.fallback));

        await uploader().drain();
        expect(posts, isEmpty, reason: 'no consent: nothing queued or sent');
        expect(signalsQueued(), isEmpty);
        expect(SyncStateStore(db.db, namespace: _ns).get('signal:uncat:BLINKIT'), isNull);

        consent = true;
        status = 503;
        await uploader().drain();
        expect(posts, hasLength(1), reason: 'one request for the one shop');
        final item = (posts.single['items'] as List).single as Map;
        expect(item, {
          'kind': 'uncategorised',
          'senderBrand': 'HDFCBK',
          'merchantKey': 'BLINKIT',
          'value': '',
          'eventType': 'purchase',
          'taxonomyVersion': 1,
        });
        // 503 learning_paused: the signal stays queued and is retried later.
        expect(signalsQueued().length + outbox().due(_now.add(const Duration(hours: 1))).where((r) => r.kind == 'signal').length, greaterThan(0));
        expect(db.db.select("SELECT 1 FROM v2_outbox WHERE kind='signal'"), hasLength(1));
        expect(SyncStateStore(db.db, namespace: _ns).get('signal:uncat:BLINKIT'), isNotNull);

        // Later, accepted; and the shop is not queued a second time.
        status = 202;
        db.db.execute("UPDATE v2_outbox SET next_attempt_at=0 WHERE kind='signal'");
        await uploader().drain();
        expect(posts, hasLength(2));
        expect(db.db.select("SELECT 1 FROM v2_outbox WHERE kind='signal'"), isEmpty);
        await uploader().drain();
        expect(posts, hasLength(2), reason: 'already reported');
      });

      test('a categorised shop is not reported as uncategorised', () async {
        final fact = addPurchase(1, shop: 'SWIGGY');
        service.apply(correction(fact, CorrectionKind.wrongCategory, {'merchantKey': 'SWIGGY', 'category': 'groceries'}, consent: false));
        consent = true;
        await uploader().drain();
        expect(posts, isEmpty);
      });

      test('revoking empties the signal outbox and the once-per-shop markers', () async {
        final fact = addPurchase(1, shop: 'BLINKIT');
        service.apply(correction(fact, CorrectionKind.wrongCategory, {'merchantKey': 'BLINKIT', 'category': 'groceries'}, consent: true));
        consent = true;
        status = 503;
        await uploader().drain();
        expect(db.db.select("SELECT 1 FROM v2_outbox WHERE kind='signal'"), isNotEmpty);
        consent = false;
        await uploader().drain();
        expect(db.db.select("SELECT 1 FROM v2_outbox WHERE kind='signal'"), isEmpty);
        expect(db.db.select("SELECT 1 FROM v2_sync_state WHERE key LIKE 'signal:uncat:%'"), isEmpty);
      });

      test('consent is checked again after the request is prepared', () async {
        addPurchase(1, shop: 'BLINKIT');
        consent = true;
        var calls = 0;
        final flipping = LearningSignalUpload(
          intake: intake,
          queue: outbox(),
          baseUri: Uri.parse('https://api.invalid'),
          headers: () async => {},
          hasConsent: () async => ++calls < 3,
          accountIsCurrent: () => true,
          taxonomyVersion: () => 1,
          clock: () => _now,
          client: MockClient((request) async {
            fail('no request may leave once consent is withdrawn');
          }),
        );
        await flipping.drain();
        expect(db.db.select("SELECT 1 FROM v2_outbox WHERE kind='signal'"), isEmpty);
      });
    });
  });
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
