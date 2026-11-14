// A wallet card added (or linked) AFTER the SMS were imported must pick up the
// transactions that were already saved, and a card whose last 4 digits were
// left blank must still be paired with the card the messages found.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/instruments/card_linker.dart';
import 'package:pandapay/features/sms_v2/instruments/card_transaction_relinker.dart';
import 'package:pandapay/features/sms_v2/instruments/instrument_seeder.dart';
import 'package:pandapay/features/sms_v2/instruments/wallet_card_link.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/instrument_actions.dart';
import 'package:pandapay_domain/pandapay_domain.dart'
    show CardNetwork, CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:relink';
const _walletA = '33333333-3333-4333-8333-333333333333';
const _walletB = '44444444-4444-4444-8444-444444444444';
const _instA = '00000000-0000-4000-8000-000000000001';
const _instB = '00000000-0000-4000-8000-000000000002';

CardProduct _product(String id, String name, String issuer) => CardProduct(
  id: id,
  name: name,
  issuerName: issuer,
  cardType: 'credit',
  network: CardNetwork.visa,
  isUpiLinkable: false,
  pointValueInr: 1.0,
  rewardRules: const [],
  capRules: const [],
  milestoneRules: const [],
  feeWaiverRules: const [],
  benefits: const [],
);

final _catalogue = [
  _product('hdfc_millennia', 'HDFC Millennia', 'HDFC Bank'),
  _product('hdfc_regalia', 'HDFC Regalia', 'HDFC Bank'),
  _product('axis_ace', 'Axis Bank ACE', 'Axis Bank'),
];

UserCard _wallet(
  String id,
  String productId, {
  String? last4,
  String name = 'HDFC Millennia',
}) => UserCard(
  id: id,
  cardProductId: productId,
  cardName: name,
  cardType: 'credit',
  isDefault: false,
  last4: last4,
);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late InstrumentStore store;
  late Map<String, Object?> fixture;
  var ids = 0;
  String nextId() =>
      'aaaaaaaa-aaaa-4aaa-8aaa-${(ids++).toRadixString(16).padLeft(12, '0')}';

  setUp(() {
    ids = 0;
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    SmsV2Schema.ensure(database.db);
    store = InstrumentStore(database.db, namespace: _ns);
    fixture =
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  Instrument card(
    String id, {
    String? mask = '5678',
    String issuer = 'hdfc',
    InstrumentStatus status = InstrumentStatus.detected,
    String? userCardId,
    List<String> products = const [],
  }) => Instrument(
    instrumentId: id,
    kind: InstrumentKind.creditCard,
    issuerSlug: issuer,
    maskDigits: mask,
    displayName: mask == null ? 'HDFC credit card' : 'HDFC card ••$mask',
    status: status,
    userCardId: userCardId,
    aliases: InstrumentAliases(productNames: products),
    firstSeenAt: DateTime.utc(2026, 11, 1),
    lastSeenAt: DateTime.utc(2026, 11, 1),
    evidenceCount: 1,
  );

  /// Stores one spend fact for [instrument] and projects it the way capture
  /// does, so the display row carries whatever the instrument said at that
  /// moment. Returns the fact.
  Fact spend(Instrument instrument, {required String tag}) {
    final json = {
      ...fixture,
      'factId': tag.padRight(64, '0'),
      'sourceKey': 'sms:test:$tag',
      'instrument': {
        ...(fixture['instrument'] as Map).cast<String, Object?>(),
        'maskDigits': instrument.maskDigits,
      },
    };
    final fact = Fact.fromJson(json);
    FactStore(
      database.db,
      namespace: _ns,
    ).insert(fact, instrumentId: instrument.instrumentId);
    final event = Event(
      eventId: fact.factId,
      type: EventType.purchase,
      status: EventStatus.complete,
      legs: [EventLeg(factId: fact.factId, role: LegRole.debitLeg)],
      confidence: .99,
      occurredAt: fact.effectiveAt,
      amountMinor: fact.amounts.first.minor,
    );
    const category = CategoryDecision(
      slug: 'dining',
      source: CategorySource.user,
      confidence: 1,
    );
    final rows = DefaultLedgerProjector().project(
      event,
      {fact.factId: fact},
      {instrument.instrumentId: instrument},
      category,
    );
    ProjectionWriter(financial, LedgerStore(database.db, namespace: _ns)).write(
      LedgerSnapshot(
        entries: rows,
        events: [event],
        categoryByEvent: {event.eventId: category},
      ),
      factsById: {fact.factId: fact},
      instrumentsById: {instrument.instrumentId: instrument},
      instrumentIdByFactId: {fact.factId: instrument.instrumentId},
      categoryIdBySlug: {'dining': 'cat-dining'},
    );
    return fact;
  }

  Map<String, String?> savedCards() => {
    for (final t in financial.entities(_ns, 'transactions'))
      t['source_key'] as String: t['user_card_id'] as String?,
  };

  CardTransactionRelinker relinker() =>
      CardTransactionRelinker(financial, namespace: _ns);

  group('CardTransactionRelinker', () {
    test('a link stamps the card on the transactions already saved', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      spend(detected, tag: 'a2');
      expect(savedCards().values, everyElement(isNull));

      final linked = detected.copyWith(
        userCardId: _walletA,
        status: InstrumentStatus.confirmed,
      );
      store.upsert(linked);

      expect(relinker().relink(linked), 2);
      expect(savedCards().values, everyElement(_walletA));
    });

    test('running it again changes nothing', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      final linked = detected.copyWith(userCardId: _walletA);
      store.upsert(linked);
      expect(relinker().relink(linked), 1);
      expect(relinker().relink(linked), 0);
    });

    test('another card\'s transactions are left alone', () {
      final a = card(_instA);
      final b = card(_instB, mask: '1111');
      store.upsert(a);
      store.upsert(b);
      spend(a, tag: 'a1');
      spend(b, tag: 'b1');
      final linked = a.copyWith(userCardId: _walletA);
      store.upsert(linked);

      expect(relinker().relink(linked), 1);
      final saved = savedCards();
      expect(saved['sms:test:a1'], _walletA);
      expect(saved['sms:test:b1'], isNull);
    });

    test('a card with no wallet card stamps nothing', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      expect(relinker().relink(detected), 0);
      expect(savedCards().values, everyElement(isNull));
    });

    test('the lookups use indexes, not table scans', () {
      final plans = {
        CardTransactionRelinker.factKeysSql: [_ns, _instA],
        FinancialStore.stampSelectSql(3): [_ns, 'a', 'b', 'c', _walletA],
      };
      for (final entry in plans.entries) {
        final plan = database.db
            .select('EXPLAIN QUERY PLAN ${entry.key}', entry.value)
            .map((r) => r['detail'] as String)
            .join(' | ');
        expect(plan, contains('USING'), reason: plan);
        expect(plan, contains('INDEX'), reason: plan);
        expect(plan, isNot(contains('SCAN')), reason: plan);
      }
    });

    test('repairOnce fixes an already-linked card once, then stays quiet', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      // An older build linked the card and never touched the transactions.
      store.upsert(detected.copyWith(userCardId: _walletA));
      expect(savedCards()['sms:test:a1'], isNull);

      expect(relinker().repairOnce(), 1);
      expect(savedCards()['sms:test:a1'], _walletA);

      // A later row left blank on purpose is not touched by a second pass: the
      // marker says the repair is done.
      expect(relinker().repairOnce(), 0);
    });

    test('relinkCard follows a card whose id the server changed', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      store.upsert(detected.copyWith(userCardId: _walletB));
      expect(relinker().relinkCard(_walletB), 1);
      expect(savedCards()['sms:test:a1'], _walletB);
    });
  });

  group('InstrumentActions', () {
    InstrumentActions actions() => InstrumentActions(
      financial: financial,
      namespace: _ns,
      catalogue: _catalogue,
    );

    test('confirming a card that matches a wallet card stamps its history', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      financial.replaceCards(_ns, [_wallet(_walletA, 'hdfc_millennia', last4: '5678')]);

      expect(actions().confirm(_instA), isA<CardLinked>());
      expect(savedCards()['sms:test:a1'], _walletA);
    });

    test('choosing a card in the picker stamps its history', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      final wallet = _wallet(_walletA, 'hdfc_millennia', last4: '5678');
      financial.replaceCards(_ns, [wallet]);

      actions().attachCard(_instA, wallet);
      expect(savedCards()['sms:test:a1'], _walletA);
    });
  });

  group('InstrumentCardLinker with a wallet card that has no last 4', () {
    InstrumentCardLinker linker() => InstrumentCardLinker(
      store: store,
      issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
      catalogue: _catalogue,
    );

    test('the issuer\'s only unlinked wallet card is linked', () {
      final found = card(_instA);
      store.upsert(found);
      final r = linker().link(
        found,
        userCards: [_wallet(_walletA, 'hdfc_millennia')],
      );
      expect(r, isA<CardLinked>());
      expect(store.get(_instA)!.userCardId, _walletA);
    });

    test('two such wallet cards are a guess, so the user is asked', () {
      final found = card(_instA);
      store.upsert(found);
      final r = linker().link(
        found,
        userCards: [
          _wallet(_walletA, 'hdfc_millennia'),
          _wallet(_walletB, 'hdfc_regalia', name: 'HDFC Regalia'),
        ],
      );
      expect(r, isA<CardNeedsProduct>());
      expect(store.get(_instA)!.userCardId, isNull);
    });

    test('a wallet card of another issuer is never taken', () {
      final found = card(_instA);
      store.upsert(found);
      final r = linker().link(
        found,
        userCards: [_wallet(_walletA, 'axis_ace', name: 'Axis Bank ACE')],
      );
      expect(r, isA<CardNeedsProduct>());
    });
  });

  group('InstrumentSeeder pairs a wallet card with the card messages found', () {
    InstrumentSeeder seeder() => InstrumentSeeder(
      store,
      idGenerator: nextId,
      clock: () => DateTime.utc(2026, 11, 14),
    );
    SeedReport seed(List<UserCard> cards) => seeder().seed(
      cards: cards,
      issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
      bankAccounts: const [],
    );

    test('a wallet card without last 4 takes the one card found for that issuer',
        () {
      store.upsert(card(_instA, products: const ['Millennia']));
      final report = seed([_wallet(_walletA, 'hdfc_millennia')]);

      final cards = store.list(kind: InstrumentKind.creditCard);
      expect(cards, hasLength(1), reason: 'no second, number-less card');
      expect(cards.single.instrumentId, _instA);
      expect(cards.single.maskDigits, '5678');
      expect(cards.single.userCardId, _walletA);
      expect(cards.single.status, InstrumentStatus.confirmed);
      expect(report.linked.map((i) => i.instrumentId), [_instA]);
    });

    test('a wallet card with last 4 takes the one number-less card found', () {
      store.upsert(card(_instA, mask: null));
      final report = seed([_wallet(_walletA, 'hdfc_millennia', last4: '5678')]);

      final cards = store.list(kind: InstrumentKind.creditCard);
      expect(cards, hasLength(1));
      expect(cards.single.instrumentId, _instA);
      expect(cards.single.maskDigits, '5678');
      expect(cards.single.userCardId, _walletA);
      expect(report.linked, hasLength(1));
    });

    test('two blank wallet cards and one found card is a guess: nothing taken',
        () {
      store.upsert(card(_instA));
      seed([
        _wallet(_walletA, 'hdfc_millennia'),
        _wallet(_walletB, 'hdfc_regalia', name: 'HDFC Regalia'),
      ]);
      expect(store.get(_instA)!.userCardId, isNull);
    });

    test('two found cards and one blank wallet card is a guess: nothing taken',
        () {
      store.upsert(card(_instA));
      store.upsert(card(_instB, mask: '1111'));
      seed([_wallet(_walletA, 'hdfc_millennia')]);
      expect(store.get(_instA)!.userCardId, isNull);
      expect(store.get(_instB)!.userCardId, isNull);
    });

    test('a card with the matching last 4 keeps its card; the blank one waits',
        () {
      store.upsert(card(_instA));
      seed([
        _wallet(_walletB, 'hdfc_regalia', name: 'HDFC Regalia'),
        _wallet(_walletA, 'hdfc_millennia', last4: '5678'),
      ]);
      expect(store.get(_instA)!.userCardId, _walletA);
      expect(
        store.list(kind: InstrumentKind.creditCard).where((i) => i.userCardId == _walletB),
        hasLength(1),
        reason: 'the blank card gets its own card, not the other one\'s',
      );
    });

    test('a found card named for another product is not taken', () {
      store.upsert(card(_instA, products: const ['Regalia']));
      seed([_wallet(_walletA, 'hdfc_millennia')]);
      expect(store.get(_instA)!.userCardId, isNull);
    });

    test('a wallet card with last 4 that differs from the found card is separate',
        () {
      store.upsert(card(_instA));
      seed([_wallet(_walletA, 'hdfc_millennia', last4: '9999')]);
      expect(store.get(_instA)!.userCardId, isNull);
      expect(store.list(kind: InstrumentKind.creditCard), hasLength(2));
    });

    test('seeding twice reports the link once', () {
      store.upsert(card(_instA));
      final cards = [_wallet(_walletA, 'hdfc_millennia')];
      expect(seed(cards).linked, hasLength(1));
      expect(seed(cards).linked, isEmpty);
    });
  });

  group('linkWalletCards (called right after a card is added)', () {
    test('links the new card and stamps what was already imported', () {
      final detected = card(_instA);
      store.upsert(detected);
      spend(detected, tag: 'a1');
      financial.replaceCards(_ns, [_wallet(_walletA, 'hdfc_millennia')]);

      final stamped = linkWalletCards(financial, _ns, _catalogue);

      expect(stamped, 1);
      expect(savedCards()['sms:test:a1'], _walletA);
      expect(store.list(kind: InstrumentKind.creditCard), hasLength(1));
    });

    test('a number-less found card gains its digits and its saved rows follow',
        () {
      final found = card(_instA, mask: null);
      store.upsert(found);
      spend(found, tag: 'a1');
      expect(financial.entities(_ns, 'transactions').single['card_last4'], isNull);
      financial.replaceCards(
        _ns,
        [_wallet(_walletA, 'hdfc_millennia', last4: '5678')],
      );

      expect(linkWalletCards(financial, _ns, _catalogue), 1);

      final row = financial.entities(_ns, 'transactions').single;
      expect(row['user_card_id'], _walletA);
      expect(row['card_last4'], '5678');
    });

    test('a row that shows another number is never moved to the card', () {
      final other = card(_instB, mask: '1111');
      store.upsert(other);
      spend(other, tag: 'b1');
      // Same source key as a row of the card being linked, but its own number.
      final linked = card(_instA).copyWith(userCardId: _walletA);
      store.upsert(linked);
      database.db.execute(
        'UPDATE v2_facts SET instrument_id = ? WHERE namespace = ? AND source_key = ?',
        [_instA, _ns, 'sms:test:b1'],
      );
      expect(relinker().relink(linked), 0);
      expect(savedCards()['sms:test:b1'], isNull);
    });

    test('does nothing, and does not throw, before SMS tables exist', () {
      final plain = AppDatabase.forTesting(sqlite3.openInMemory());
      addTearDown(plain.db.dispose);
      final bare = FinancialStore(plain);
      addTearDown(bare.dispose);
      bare.replaceCards(_ns, [_wallet(_walletA, 'hdfc_millennia')]);
      expect(linkWalletCards(bare, _ns, _catalogue), 0);
    });
  });
}

