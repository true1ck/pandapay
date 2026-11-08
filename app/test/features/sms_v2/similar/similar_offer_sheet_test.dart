import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/similar/similar_changes.dart';
import 'package:pandapay/features/sms_v2/similar/similar_finder.dart';
import 'package:pandapay/features/sms_v2/similar/similar_offer_sheet.dart';
import 'package:pandapay/features/sms_v2/similar/similar_runner.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

SimilarOffer _offer(SimilarField field, int count) => SimilarOffer(
  field: field,
  criteria: SimilarCriteria.shop('SWIGGY'),
  summary: SimilarSummary(count: count, examples: const []),
  eventId: 'e',
  change: const {},
  snapshot: const EditSnapshot(eventId: 'e'),
);

void main() {
  group('the words', () {
    test('say what will change, in plain language, for each kind of change', () {
      final shop = SimilarOfferWords.of(_offer(SimilarField.shopName, 12), shop: 'SWIGGY', target: 'Lunch spot');
      expect(shop.title, 'Rename 12 other transactions from SWIGGY?');
      expect(shop.body, contains('every SMS from SWIGGY shows as “Lunch spot”'));
      expect(shop.apply, 'Rename all 12');
      expect(shop.skip, 'Only from now on');

      final one = SimilarOfferWords.of(_offer(SimilarField.category, 1), shop: 'SWIGGY', target: 'Groceries');
      expect(one.title, 'Also put 1 other transaction from SWIGGY in Groceries?');
      expect(one.apply, 'Move it');
      expect(one.body, contains('Any you set yourself stay as they are'));

      final card = SimilarOfferWords.of(_offer(SimilarField.paymentMethod, 3), shop: 'SWIGGY', target: 'HDFC Regalia');
      expect(card.title, 'Move 3 other transactions to HDFC Regalia?');
      expect(card.body, contains('limits, rewards and totals'));
      expect(card.skip, 'Only this one', reason: 'money-moving changes are never applied to the rest by default');

      final type = SimilarOfferWords.of(_offer(SimilarField.type, 2), shop: 'SWIGGY', target: 'income');
      expect(type.body, contains('changes your totals'));
    });
  });

  group('the sheet', () {
    const namespace = 'user:sheet';
    late AppDatabase database;
    late FinancialStore financial;
    late RuleBundle bundle;
    late SimilarChanges changes;
    late SimilarOffer offer;

    setUp(() {
      database = AppDatabase.forTesting(sqlite3.openInMemory());
      financial = FinancialStore(database);
      SmsV2Schema.ensure(database.db);
      bundle = RuleBundle.fromJson(
        (jsonDecode(
                  File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>(),
      );
      final intake = SmsIntakeRepository(database);
      final controller = ReviewController(financial: financial, namespace: namespace, bundle: bundle);
      changes = SimilarChanges.forController(controller);
      final sources = <String>[];
      for (var day = 1; day <= 4; day++) {
        final source = day.toRadixString(16).padLeft(2, '0') * 32;
        final message = SmsMessage(
          sender: 'VM-HDFCBK-S',
          body: bundle.rules.first.examples.first.body,
          sourceKey: source,
          observedAt: DateTime.utc(2026, 11, day, 7),
        );
        database.db.execute(
          'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
          [namespace, source, message.sender, message.body, message.observedAt.millisecondsSinceEpoch],
        );
        SmsV2Pipeline(financial: financial, namespace: namespace, bundle: bundle, appVersion: '2').process(message);
        sources.add(source);
      }
      TransactionEntry row(String s) => financial
          .entities(namespace, 'transactions')
          .map(TransactionEntry.fromJson)
          .firstWhere((e) => e.sourceKey == s);
      final before = changes.snapshot(row(sources[3]))!;
      controller.apply(
        items: [
          LocalReviewItem(
            id: sources[3],
            kind: 'template',
            payload: {'sourceKey': sources[3]},
            message: intake.capturedById(namespace, sources[3]),
          ),
        ],
        kind: CorrectionKind.wrongMerchant,
        corrected: const {'merchantName': 'Corner Shop'},
      );
      offer = changes.offers(before, shopName: 'Corner Shop').single;
    });
    tearDown(() {
      financial.dispose();
      database.db.dispose();
    });

    Future<void> open(
      WidgetTester tester,
      void Function(Set<String>?) done, {
      SimilarOffer? asking,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => done(
                  await showSimilarOfferSheet(
                    context: context,
                    offer: asking ?? offer,
                    changes: changes,
                    shop: 'SWIGGY',
                    target: 'Corner Shop',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    SimilarOffer typeOffer() => SimilarOffer(
      field: SimilarField.type,
      criteria: SimilarCriteria.shopType(
        merchantKey: 'SWIGGY',
        type: EventType.purchase,
      ),
      summary: const SimilarSummary(count: 3, examples: []),
      eventId: offer.eventId,
      change: const {'eventType': 'ownTransfer'},
      snapshot: offer.snapshot,
    );

    testWidgets('lists every other transaction with a tick, all ticked for a name', (tester) async {
      Set<String>? result = {'untouched'};
      await open(tester, (value) => result = value);
      expect(find.text('Rename 3 other transactions from SWIGGY?'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(4), reason: 'select all and three rows');
      expect(find.text('3 of 3 selected'), findsOneWidget);
      expect(find.text('Rename all 3'), findsOneWidget);
      await tester.tap(find.text('Only from now on'));
      await tester.pumpAndSettle();
      expect(result, isNull, reason: 'skipping returns nothing to apply');
    });

    testWidgets('unticking one changes the count and the button, and returns just the ticked ones', (tester) async {
      Set<String>? result;
      await open(tester, (value) => result = value);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3 selected'), findsOneWidget);
      expect(find.text('Rename 2'), findsOneWidget);
      await tester.tap(find.text('Rename 2'));
      await tester.pumpAndSettle();
      expect(result, hasLength(2));
    });

    testWidgets('select all ticks or clears everything', (tester) async {
      await open(tester, (_) {});
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('0 of 3 selected'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('3 of 3 selected'), findsOneWidget);
    });

    testWidgets('a type change starts with nothing ticked and cannot be applied to none', (tester) async {
      Set<String>? result = {'untouched'};
      await open(tester, (value) => result = value, asking: typeOffer());
      expect(find.text('0 of 3 selected'), findsOneWidget);
      expect(find.text('Choose some'), findsOneWidget);
      await tester.tap(find.text('Choose some'));
      await tester.pumpAndSettle();
      expect(result, {'untouched'}, reason: 'the sheet stays open');
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      expect(find.text('Change 1'), findsOneWidget);
    });

    testWidgets('applying runs in the background: a progress bar, then a result with Undo', (tester) async {
      final done = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => applySimilarInBackground(
                  messenger: ScaffoldMessenger.of(context),
                  changes: changes,
                  offer: offer,
                  eventIds: changes.others(offer).map((e) => e.eventId).toSet(),
                  onChanged: () => done.add(1),
                ),
                child: const Text('run'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('run'));
      await tester.pump();
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialBanner), findsNothing, reason: 'the banner goes when it is done');
      expect(find.text('Changed 3 other transactions.'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget, reason: 'a shop name can be taken back');
      expect(done, isNotEmpty);
      final names = financial
          .entities(namespace, 'transactions')
          .map(TransactionEntry.fromJson)
          .map((e) => e.merchantName)
          .toList();
      expect(names, everyElement('Corner Shop'));
    });
  });
}
