// The ledger read model is rebuilt on every revision bump and ~12 providers
// derive from it (docs/PERFORMANCE_RULEBOOK.md section 4, item 3). These tests
// pin the three guarantees the rebuild relies on:
//   1. the cached read returns exactly what a plain uncached read returns;
//   2. only new or changed rows are decoded again;
//   3. nothing downstream rebuilds when the content did not change.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/json_fingerprint.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/row_decode_cache.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../support/ledger_dataset.dart';

LedgerReadModel cachedRead(Dataset d) => loadLedgerReadModel(
  db: d.database.db,
  financialStore: d.store,
  namespace: ns,
);

void main() {
  late Dataset d;
  setUp(() {
    d = Dataset(30)..open();
    d.seed();
  });
  tearDown(() => d.close());

  group('cached read returns exactly the uncached content', () {
    test('first read', () {
      expect(describe(cachedRead(d)), describe(plainRead(d)));
    });

    test('after edits, deletes and a refund-shaped category row', () {
      cachedRead(d); // warm
      // Edit a ledger row, an event, a transaction and an instrument.
      d.ledger.replaceForEvent(hex(0x10000 + 4), [
        d.entryFor(4, amount: 777, category: 'travel'),
      ], dirty: false);
      d.events.upsert(d.eventFor(5, amount: 999), dirty: false);
      d.store.saveTransactions(ns, [d.transactionFor(6, note: 'edited')]);
      d.instruments.upsert(d.instrument(1, status: InstrumentStatus.detected));
      // Delete one event's rows.
      d.ledger.replaceForEvent(hex(0x10000 + 7), const []);
      d.database.db.execute('DELETE FROM v2_events WHERE event_id=?', [
        hex(0x10000 + 7),
      ]);
      // A refund row persists its category on the wire fields (CCR-003).
      final refund = LedgerEntry(
        entryId: hex(0x59999),
        eventId: hex(0x19999),
        from: const ExternalEndpoint('SWIGGY'),
        to: const OwnUnresolvedEndpoint(InstrumentKind.creditCard),
        amountMinor: 500,
        unit: LedgerUnit.inr,
        occurredAt: DateTime.utc(2026, 11, 2),
        category: 'dining',
        categorySource: CategorySource.user,
        countsAsTransaction: true,
        isSpend: false,
        isIncome: false,
        isInvestment: false,
      );
      d.ledger.replaceForEvent(refund.eventId, [refund]);
      expect(describe(cachedRead(d)), describe(plainRead(d)));
      // A third read with nothing changed is still the same content.
      expect(describe(cachedRead(d)), describe(plainRead(d)));
    });
  });

  group('only new or changed rows are decoded', () {
    test('a second read of unchanged data decodes nothing', () {
      final first = cachedRead(d);
      final before = RowDecodeCache.decodeCount;
      final second = cachedRead(d);
      expect(RowDecodeCache.decodeCount - before, 0);
      expect(second.sameContentAs(first), isTrue);
      // Same instances, not equal copies.
      expect(identical(second.ledger.entries.first, first.ledger.entries.first), isTrue);
      expect(identical(second.facts.first, first.facts.first), isTrue);
      expect(identical(second.transactions.first, first.transactions.first), isTrue);
    });

    test('one edited row of each kind costs one decode each', () {
      final first = cachedRead(d);
      d.ledger.replaceForEvent(hex(0x10000 + 4), [
        d.entryFor(4, amount: 777),
      ], dirty: false);
      d.events.upsert(d.eventFor(5, amount: 999), dirty: false);
      d.store.saveTransactions(ns, [d.transactionFor(6, note: 'edited')]);
      d.instruments.upsert(d.instrument(1, status: InstrumentStatus.detected));
      final before = RowDecodeCache.decodeCount;
      final second = cachedRead(d);
      expect(RowDecodeCache.decodeCount - before, 4);
      expect(second.sameContentAs(first), isFalse);
      // Everything else was reused.
      final unchanged = second.ledger.entries
          .where((e) => first.ledger.entries.any((o) => identical(o, e)))
          .length;
      expect(unchanged, d.n - 1);
    });

    test('a new fact is the only fact parsed', () {
      cachedRead(d);
      d.facts.insert(d.factFor(500));
      final before = RowDecodeCache.decodeCount;
      final model = cachedRead(d);
      // Facts are cached by FactStore itself; nothing else is parsed.
      expect(RowDecodeCache.decodeCount - before, 0);
      expect(model.facts.length, d.n + 1);
    });
  });

  group('LedgerModelSource', () {
    test('a burst of stale marks is one read; unchanged content tells no one', () async {
      final source = LedgerModelSource(() => cachedRead(d));
      var notified = 0;
      source.addListener(() => notified++);
      final first = source.read();
      expect(source.reads, 1);

      source.markStale();
      source.markStale();
      source.markStale();
      await Future<void>.delayed(Duration.zero);
      expect(source.reads, 2, reason: 'three bumps in one turn, one re-read');
      expect(notified, 0, reason: 'nothing changed');
      expect(identical(source.read(), first), isTrue);
      expect(source.reads, 2);

      d.store.saveTransactions(ns, [d.transactionFor(1, note: 'edited')]);
      source.markStale();
      source.markStale();
      await Future<void>.delayed(Duration.zero);
      expect(notified, 1);
      expect(identical(source.read(), first), isFalse);
      expect(source.reads, 3, reason: 'the notified rebuild reads nothing');
      expect(source.takeNotified(), isTrue);
      expect(source.takeNotified(), isFalse);
    });

    test('force re-reads yet keeps the instance when nothing changed', () {
      final source = LedgerModelSource(() => cachedRead(d));
      final first = source.read();
      expect(identical(source.read(force: true), first), isTrue);
      expect(source.reads, 2);
    });
  });

  group('downstream providers', () {
    test('rebuild only when the ledger content changes', () {
      fakeAsync((async) {
        final container = ProviderContainer(
          overrides: [
            cacheNamespaceProvider.overrideWithValue(ns),
            responseCacheProvider.overrideWith((ref) async => d.cache),
          ],
        );
        addTearDown(container.dispose);
        var derivedBuilds = 0;
        final derived = FutureProvider<int>((ref) async {
          derivedBuilds++;
          return (await ref.watch(smsV2LedgerReadModelProvider.future))
              .transactions
              .length;
        });
        final values = <int>[];
        container.listen<AsyncValue<int>>(
          derived,
          (_, next) => next.whenData(values.add),
          fireImmediately: true,
        );
        async.flushMicrotasks();
        expect(values.last, d.n);
        final built = derivedBuilds;

        // Revision bumps with no data change: nothing downstream rebuilds.
        for (final entity in const ['transactions', 'observations', 'cards']) {
          d.store.notifyExternalChanges(ns, [entity]);
          async.flushMicrotasks();
        }
        async.elapse(financialRefreshWindow);
        async.flushMicrotasks();
        expect(derivedBuilds, built, reason: 'content did not change');

        // A real change rebuilds it once, with the new content.
        d.store.saveTransactions(ns, [d.transactionFor(d.n + 1)]);
        async.elapse(financialRefreshWindow);
        async.flushMicrotasks();
        expect(values.last, d.n + 1);
        expect(derivedBuilds, built + 1);

        // ref.invalidate still forces a fresh read (retry buttons).
        container.invalidate(smsV2LedgerReadModelProvider);
        async.flushMicrotasks();
        expect(values.last, d.n + 1);
      });
    });
  });

  group('review count', () {
    test('equals the length of the full review list', () async {
      // Ten uncategorised purchases at one merchant (>= 2 prompts the user),
      // two confirmed cards with an unresolved card-bill payment, and open
      // review rows of two kinds.
      final dataset = Dataset(10, merchant: 'UNKNOWNSHOP')..open();
      addTearDown(dataset.close);
      dataset.seed();
      for (var i = 0; i < dataset.n; i++) {
        dataset.ledger.replaceForEvent(
          hex(0x10000 + i),
          [dataset.entryFor(i, category: 'other')],
          dirty: false,
          category: const CategoryDecision(
            slug: 'other',
            source: CategorySource.fallback,
            confidence: 0.5,
          ),
        );
      }
      final billFact = Fact.fromJson({
        ...fixture('fact/movement.card_spend.json'),
        'factId': hex(0x70001),
        'sourceKey': 'sms:synthetic:bill',
      });
      dataset.facts.insert(billFact);
      dataset.events.upsert(
        Event(
          eventId: billFact.factId,
          type: EventType.cardBillPayment,
          status: EventStatus.complete,
          legs: [EventLeg(factId: billFact.factId, role: LegRole.debitLeg)],
          confidence: 1,
          occurredAt: DateTime.utc(2026, 11, 3),
          amountMinor: 100000,
        ),
        dirty: false,
      );
      dataset.ledger.replaceForEvent(billFact.factId, [
        LedgerEntry(
          entryId: hex(0x71001),
          eventId: billFact.factId,
          from: const OwnUnresolvedEndpoint(InstrumentKind.bankAccount),
          to: const OwnUnresolvedEndpoint(InstrumentKind.creditCard),
          amountMinor: 100000,
          unit: LedgerUnit.inr,
          occurredAt: DateTime.utc(2026, 11, 3),
          countsAsTransaction: false,
          isSpend: false,
          isIncome: false,
          isInvestment: false,
        ),
      ], dirty: false);
      for (final (id, kind, status) in const [
        ('r1', 'template', 'open'),
        ('r2', 'link', 'open'),
        ('r3', 'template', 'resolved'),
      ]) {
        dataset.database.db.execute(
          'INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)',
          [ns, id, kind, jsonEncode({'sourceKey': 'sms:synthetic:1'}), status],
        );
      }

      final container = ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWithValue(ns),
          responseCacheProvider.overrideWith((ref) async => dataset.cache),
        ],
      );
      addTearDown(container.dispose);
      final items = await container.read(reviewItemsProvider.future);
      final count = await container.read(reviewItemCountProvider.future);
      expect(items.map((i) => i.kind).toSet(), {
        'bill_target',
        'template',
        'link',
        'category',
      });
      expect(count, items.length);
      expect(count, 1 + 2 + 10);
      expect(await container.read(needsReviewCountProvider.future), items.length);

      // Resolving an item notifies no revision; screens invalidate the list,
      // and the badge must follow without the badge building the list itself.
      dataset.database.db.execute(
        "UPDATE v2_review_items SET status='resolved' WHERE review_id='r1'",
      );
      container.invalidate(reviewItemsProvider);
      final after = await container.read(reviewItemsProvider.future);
      await Future<void>.delayed(Duration.zero);
      final countAfter = await container.read(reviewItemCountProvider.future);
      expect(countAfter, after.length);
      expect(countAfter, count - 1);
      expect(
        await container.read(needsReviewCountProvider.future),
        after.length,
      );
    });
  });

  group('jsonFingerprint', () {
    test('equal documents match; any change, type or order difference does not', () {
      Map<String, Object?> doc() => {
        'a': 'x',
        'n': 5,
        'f': 1.5,
        't': true,
        'z': null,
        'l': [1, 'two', {'k': 'v'}],
      };
      expect(jsonFingerprint(doc()), jsonFingerprint(doc()));
      expect(jsonFingerprint({...doc(), 'a': 'y'}), isNot(jsonFingerprint(doc())));
      expect(jsonFingerprint({'v': 1}), isNot(jsonFingerprint({'v': '1'})));
      expect(jsonFingerprint({'v': 1}), isNot(jsonFingerprint({'v': true})));
      expect(jsonFingerprint({'v': null}), isNot(jsonFingerprint({'v': 'null'})));
      expect(jsonFingerprint({'v': []}), isNot(jsonFingerprint({'v': {}})));
      expect(
        jsonFingerprint({'a': 1, 'b': 2}),
        isNot(jsonFingerprint({'b': 2, 'a': 1})),
      );
      expect(
        jsonFingerprint({'ab': 'c'}),
        isNot(jsonFingerprint({'a': 'bc'})),
      );
    });
  });
}
