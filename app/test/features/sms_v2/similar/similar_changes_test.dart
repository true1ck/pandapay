import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/category/category_snapshot.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/similar/similar_changes.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  const namespace = 'user:similar-changes';
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsIntakeRepository intake;
  late ReviewController controller;
  late SimilarChanges changes;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    intake = SmsIntakeRepository(database);
    SmsV2Schema.ensure(database.db);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    controller = ReviewController(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
    );
    changes = SimilarChanges(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      controller: controller,
      chunkSize: 2,
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  String receive(int day, {String? shop}) {
    final source = day.toRadixString(16).padLeft(2, '0') * 32;
    final message = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: shop == null
          ? bundle.rules.first.examples.first.body
          : bundle.rules.first.examples.first.body.replaceAll('SWIGGY', shop),
      sourceKey: source,
      observedAt: DateTime.utc(2026, 11, day, 7),
    );
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [
        namespace,
        source,
        message.sender,
        message.body,
        message.observedAt.millisecondsSinceEpoch,
      ],
    );
    final categories = CategorySnapshot.load(
      financial.database,
      namespace: namespace,
      aliases: bundle.merchantAliases,
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
      userRules: categories.userRules,
      confirmedHistory: categories.confirmedHistory,
    ).process(message);
    return source;
  }

  TransactionEntry row(String source) => financial
      .entities(namespace, 'transactions')
      .map(TransactionEntry.fromJson)
      .firstWhere((entry) => entry.sourceKey == source);

  void edit(String source, CorrectionKind kind, Map<String, Object?> patch) =>
      controller.apply(
        items: [
          LocalReviewItem(
            id: source,
            kind: 'template',
            payload: {'sourceKey': source},
            message: intake.capturedById(namespace, source),
          ),
        ],
        kind: kind,
        corrected: patch,
      );

  group('a shop name', () {
    test('is remembered for later SMS at once; earlier ones change only when asked, and Undo takes it back', () async {
      final sources = [for (var day = 1; day <= 5; day++) receive(day)];
      final edited = sources[2];
      final before = changes.snapshot(row(edited))!;
      expect(before.merchantKey, 'SWIGGY');
      edit(edited, CorrectionKind.wrongMerchant, {'merchantName': 'Corner Shop'});

      // A later SMS from the same shop already shows the person's name.
      final later = receive(6);
      expect(row(later).merchantName, 'Corner Shop');
      // The earlier ones still show what the SMS printed.
      expect(row(sources[0]).merchantName, 'SWIGGY');
      expect(row(sources[3]).merchantName, 'SWIGGY');

      final offers = changes.offers(before, shopName: 'Corner Shop');
      expect(offers, hasLength(1));
      final offer = offers.single;
      expect(offer.field, SimilarField.shopName);
      // Days 1, 2, 4, 5 and the new day 6 are the others; day 3 was edited.
      expect(offer.summary.count, 5);
      expect(offer.movesMoney, isFalse);
      expect(offer.canUndo, isTrue);

      final progress = <int>[];
      final result = await changes.apply(
        offer,
        onProgress: (done, total) => progress.add(done),
      );
      expect(result.changed, 5);
      expect(result.stopped, isFalse);
      expect(progress, [2, 4, 5], reason: 'chunks of two');
      for (final source in [...sources, later]) {
        expect(row(source).merchantName, 'Corner Shop', reason: source);
      }

      expect(changes.undo(result.changeId!), 5);
      expect(row(sources[0]).merchantName, 'SWIGGY');
      expect(row(sources[3]).merchantName, 'SWIGGY');
      expect(row(later).merchantName, 'Corner Shop',
          reason: 'the name from the edited SMS onwards is the person\'s own choice and stays');
      expect(changes.undo(result.changeId!), 0, reason: 'only once');
    });

    test('stops cleanly when asked to, keeping what was done', () async {
      final sources = [for (var day = 1; day <= 5; day++) receive(day)];
      final before = changes.snapshot(row(sources[4]))!;
      edit(sources[4], CorrectionKind.wrongMerchant, {'merchantName': 'Corner Shop'});
      final offer = changes.offers(before, shopName: 'Corner Shop').single;
      var chunks = 0;
      final result = await changes.apply(
        offer,
        shouldContinue: () => chunks++ < 1,
      );
      expect(result.stopped, isTrue);
      expect(result.changed, 2);
      final names = [for (final s in sources.take(4)) row(s).merchantName];
      expect(names.where((n) => n == 'Corner Shop'), hasLength(2));
    });

    test('nothing is offered when no other transaction shares the shop', () {
      final only = receive(1);
      final before = changes.snapshot(row(only))!;
      edit(only, CorrectionKind.wrongMerchant, {'merchantName': 'Corner Shop'});
      expect(changes.offers(before, shopName: 'Corner Shop'), isEmpty);
    });

    test('typing the printed name back removes the personal name', () {
      final first = receive(1);
      edit(first, CorrectionKind.wrongMerchant, {'merchantName': 'Corner Shop'});
      expect(receive(2), isNotEmpty);
      expect(row(receive(3)).merchantName, 'Corner Shop');
      edit(first, CorrectionKind.wrongMerchant, {'merchantName': 'SWIGGY'});
      expect(row(receive(4)).merchantName, 'SWIGGY');
    });
  });

  group('a category', () {
    test('is applied to the earlier transactions the rules had put elsewhere, not to ones the person set', () async {
      final sources = [for (var day = 1; day <= 4; day++) receive(day)];
      final groceries = TaxonomyRegistry.v1.categoryFor('groceries')!.displayName;
      // The person set one of the others by hand earlier, then fixes another.
      edit(sources[0], CorrectionKind.wrongCategory, {'category': 'dining'});
      final before = changes.snapshot(row(sources[3]))!;
      edit(sources[3], CorrectionKind.wrongCategory, {'category': 'groceries'});
      final offer = changes.offers(before, categorySlug: 'groceries').single;
      expect(offer.field, SimilarField.category);
      expect(offer.canUndo, isFalse);
      // Money still waiting to be uploaded is not touched by a category pass.
      var result = await changes.apply(offer);
      expect(result.changed, 0);
      expect(result.awaitingSync, greaterThan(0));
      // Once it has been uploaded the same offer goes through.
      database.db.execute("DELETE FROM v2_outbox WHERE kind='ledger'");
      result = await changes.apply(offer);
      expect(result.stopped, isFalse);
      expect(row(sources[1]).categoryName, groceries);
      expect(row(sources[2]).categoryName, groceries);
      expect(row(sources[3]).categoryName, groceries);
      expect(row(sources[0]).categoryName,
          TaxonomyRegistry.v1.categoryFor('dining')!.displayName,
          reason: 'the person\'s own choice is never overwritten');
    });
  });

  group('a type', () {
    test('is always asked about, and goes through the same correction as the edited one', () async {
      final sources = [for (var day = 1; day <= 4; day++) receive(day)];
      final before = changes.snapshot(row(sources[3]))!;
      expect(before.type, EventType.purchase);
      edit(sources[3], CorrectionKind.wrongKind, {'eventType': 'income'});
      final offer = changes.offers(before, eventType: EventType.income).single;
      expect(offer.field, SimilarField.type);
      expect(offer.movesMoney, isTrue);
      expect(offer.summary.count, 3);
      final result = await changes.apply(offer);
      expect(result.changed, 3);
      final events = EventStore(database.db, namespace: namespace);
      for (final source in sources) {
        final anchor = FactStore(database.db, namespace: namespace)
            .forSource(source)
            .whereType<MovementFact>()
            .first;
        expect(events.get(anchor.factId)!.type, EventType.income, reason: source);
      }
    });
  });

  String movementId(String source) => FactStore(database.db, namespace: namespace)
      .forSource(source)
      .whereType<MovementFact>()
      .first
      .factId;

  group('a type, by payee', () {
    test('is offered for the same shop only, not for every payment the rule reads', () {
      final swiggy1 = receive(1);
      receive(2, shop: 'ZOMATO');
      receive(3, shop: 'ZOMATO');
      final swiggy2 = receive(4);
      final before = changes.snapshot(row(swiggy2))!;
      edit(swiggy2, CorrectionKind.wrongKind, {'eventType': 'income'});
      final offer = changes.offers(before, eventType: EventType.income).single;
      expect(offer.field, SimilarField.type);
      expect(offer.summary.count, 1, reason: 'only the other SWIGGY payment');
      expect(changes.others(offer).map((e) => e.eventId), [movementId(swiggy1)]);
    });
  });

  group('choosing which others', () {
    test('others lists every match, newest first', () {
      final sources = [for (var day = 1; day <= 4; day++) receive(day)];
      final before = changes.snapshot(row(sources[3]))!;
      edit(sources[3], CorrectionKind.wrongKind, {'eventType': 'income'});
      final offer = changes.offers(before, eventType: EventType.income).single;
      final list = changes.others(offer);
      // Received on days 1, 2 and 3 (they print the same date): newest first.
      expect(list.map((e) => e.eventId), [
        movementId(sources[2]),
        movementId(sources[1]),
        movementId(sources[0]),
      ]);
    });

    test('apply changes only the chosen ones', () async {
      final sources = [for (var day = 1; day <= 4; day++) receive(day)];
      final before = changes.snapshot(row(sources[3]))!;
      edit(sources[3], CorrectionKind.wrongKind, {'eventType': 'income'});
      final offer = changes.offers(before, eventType: EventType.income).single;
      final facts = FactStore(database.db, namespace: namespace);
      final chosen = {for (final i in [0, 2]) movementId(sources[i])};
      final result = await changes.apply(offer, onlyEventIds: chosen);
      expect(result.changed, 2);
      final events = EventStore(database.db, namespace: namespace);
      EventType typeOf(String source) =>
          events.get(facts.forSource(source).whereType<MovementFact>().first.factId)!.type;
      expect(typeOf(sources[0]), EventType.income);
      expect(typeOf(sources[1]), EventType.purchase, reason: 'not chosen');
      expect(typeOf(sources[2]), EventType.income);
    });

    test('choosing none changes nothing', () async {
      final sources = [for (var day = 1; day <= 3; day++) receive(day)];
      final before = changes.snapshot(row(sources[2]))!;
      edit(sources[2], CorrectionKind.wrongKind, {'eventType': 'income'});
      final offer = changes.offers(before, eventType: EventType.income).single;
      final result = await changes.apply(offer, onlyEventIds: const {});
      expect(result.changed, 0);
    });
  });
}
