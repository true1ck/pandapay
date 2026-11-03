import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show BankAccountSummary, UserCard;
import 'package:pandapay/features/sms_v2/instruments/bank_summary_adapter.dart';
import 'package:pandapay/features/sms_v2/instruments/card_linker.dart';
import 'package:pandapay/features/sms_v2/instruments/instrument_seeder.dart';
import 'package:pandapay/features/sms_v2/instruments/issuer_slugs.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/pandapay_domain.dart'
    show CardNetwork, CardProduct, Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _cardA = '11111111-1111-4111-8111-111111111111';
const _cardB = '22222222-2222-4222-8222-222222222222';
const _cardC = '33333333-3333-4333-8333-333333333333';

CardProduct _product(String id, String name, String issuer, {String? type}) =>
    CardProduct(
      id: id,
      name: name,
      issuerName: issuer,
      cardType: type,
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
  _product('hdfc_millennia', 'HDFC Millennia', 'HDFC Bank', type: 'credit'),
  _product('hdfc_regalia', 'HDFC Regalia', 'HDFC Bank', type: 'credit'),
  _product('axis_ace', 'Axis Bank ACE', 'Axis Bank', type: 'credit'),
  _product(
    'icici_amazon_pay',
    'Amazon Pay ICICI Credit Card',
    'ICICI Bank',
    type: 'credit',
  ),
];

UserCard _card(
  String id,
  String productId, {
  String? last4,
  String name = 'Card',
  Money? limit,
  double? points,
  String? type,
}) => UserCard(
  id: id,
  cardProductId: productId,
  cardName: name,
  cardType: type,
  isDefault: false,
  last4: last4,
  creditLimit: limit,
  pointsBalance: points,
);

BankAccountSummary _acct(
  String last4,
  String issuer, {
  int? paise,
  DateTime? balanceAt,
  DateTime? smsAt,
  int count = 3,
  bool manual = false,
  DateTime? manualAt,
}) => BankAccountSummary(
  accountLast4: last4,
  issuerSlug: issuer,
  availableBalance: paise == null ? null : Money.fromPaise(paise),
  latestBalanceSmsAt: balanceAt,
  latestSmsAt: smsAt,
  smsCount: count,
  isBalanceManuallySet: manual,
  manualBalanceUpdatedAt: manualAt,
);

void main() {
  late Database db;
  late InstrumentStore store;
  var n = 0;
  String nextId() =>
      'aaaaaaaa-aaaa-4aaa-8aaa-${(n++).toRadixString(16).padLeft(12, '0')}';

  setUp(() {
    n = 0;
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    store = InstrumentStore(db, namespace: 'user:a');
  });
  tearDown(() => db.dispose());

  InstrumentSeeder seeder() => InstrumentSeeder(
    store,
    idGenerator: nextId,
    clock: () => DateTime.utc(2026, 11, 3),
  );

  group('InstrumentSeeder', () {
    test(
      'every user card becomes a confirmed credit card with its userCardId',
      () {
        final cards = [
          _card(
            _cardA,
            'hdfc_millennia',
            last4: '5678',
            name: 'HDFC Millennia',
            limit: Money.fromRupees(300000),
            points: 1200.4,
          ),
          _card(_cardB, 'axis_ace', name: 'Axis Bank ACE'),
        ];
        final report = seeder().seed(
          cards: cards,
          issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
          bankAccounts: const [],
        );
        expect(report.cardsCreated, 2);
        final a = store.findByUserCardId(_cardA)!;
        expect(a.kind, InstrumentKind.creditCard);
        expect(a.status, InstrumentStatus.confirmed);
        expect(a.issuerSlug, 'hdfc');
        expect(a.maskDigits, '5678');
        expect(a.creditLimitMinor, 30000000);
        expect(a.creditLimitSource, CreditLimitSource.user);
        expect(a.pointsBalance, 1200);
        expect(a.aliases.productNames, ['HDFC Millennia']);
        expect(a.validate().ok, isTrue, reason: '${a.validate().errors}');
        final b = store.findByUserCardId(_cardB)!;
        expect(b.issuerSlug, 'axis');
        expect(b.maskDigits, isNull);
      },
    );

    test('a debit card in the wallet becomes a debit card instrument', () {
      seeder().seed(
        cards: [_card(_cardA, 'hdfc_millennia', last4: '4321', type: 'debit')],
        issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
        bankAccounts: const [],
      );
      expect(store.findByUserCardId(_cardA)!.kind, InstrumentKind.debitCard);
    });

    test(
      'a bank account is confirmed with a manual balance, detected otherwise',
      () {
        final report = seeder().seed(
          cards: const [],
          issuerSlugOf: (_) => null,
          bankAccounts: [
            _acct(
              '1234',
              'hdfc',
              paise: 5000000,
              balanceAt: DateTime.utc(2026, 10, 30),
              smsAt: DateTime.utc(2026, 11, 1),
              count: 7,
            ),
            _acct(
              '9999',
              'sbi',
              paise: 100000,
              manual: true,
              manualAt: DateTime.utc(2026, 11, 2),
            ),
          ],
        );
        expect(report.accountsCreated, 2);
        final auto = store.findByKey(
          InstrumentKind.bankAccount,
          'hdfc',
          '1234',
        )!;
        expect(auto.status, InstrumentStatus.detected);
        expect(auto.availableMinor, 5000000);
        expect(auto.availableAt, DateTime.utc(2026, 10, 30));
        expect(auto.evidenceCount, 7);
        expect(auto.lastSeenAt, DateTime.utc(2026, 11, 1));
        final manual = store.findByKey(
          InstrumentKind.bankAccount,
          'sbi',
          '9999',
        )!;
        expect(manual.status, InstrumentStatus.confirmed);
        expect(manual.availableMinor, 100000);
      },
    );

    test('seeding twice changes nothing and marks nothing dirty again', () {
      final cards = [
        _card(
          _cardA,
          'hdfc_millennia',
          last4: '5678',
          limit: Money.fromRupees(1000),
        ),
      ];
      final accounts = [
        _acct(
          '1234',
          'hdfc',
          paise: 5000000,
          balanceAt: DateTime.utc(2026, 10, 30),
          smsAt: DateTime.utc(2026, 11, 1),
        ),
        _acct(
          '9999',
          'sbi',
          paise: 100000,
          manual: true,
          manualAt: DateTime.utc(2026, 11, 2),
        ),
      ];
      final first = seeder().seed(
        cards: cards,
        issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
        bankAccounts: accounts,
      );
      expect(first.created, 3);
      final snapshot = [for (final i in store.list()) i.toJson()];
      store.markClean([for (final i in store.list()) i.instrumentId]);

      final second = seeder().seed(
        cards: cards,
        issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
        bankAccounts: accounts,
      );
      expect(second.created, 0);
      expect(second.updated, 0);
      expect(store.count(), 3);
      expect([for (final i in store.list()) i.toJson()], snapshot);
      expect(store.dirty(), isEmpty);
    });

    test(
      'an account already detected from SMS is reused and confirmed by a manual balance',
      () {
        final detected = Instrument(
          instrumentId: nextId(),
          kind: InstrumentKind.bankAccount,
          issuerSlug: 'hdfc',
          maskDigits: '1234',
          displayName: 'HDFC account ••1234',
          status: InstrumentStatus.detected,
          firstSeenAt: DateTime.utc(2026, 11, 1),
          lastSeenAt: DateTime.utc(2026, 11, 1),
          evidenceCount: 2,
        );
        store.upsert(detected);
        final report = seeder().seed(
          cards: const [],
          issuerSlugOf: (_) => null,
          bankAccounts: [
            _acct(
              '1234',
              'hdfc',
              paise: 700,
              manual: true,
              manualAt: DateTime.utc(2026, 11, 2),
            ),
          ],
        );
        expect(report.accountsCreated, 0);
        expect(report.accountsUpdated, 1);
        expect(store.count(), 1);
        expect(
          store.get(detected.instrumentId)!.status,
          InstrumentStatus.confirmed,
        );
      },
    );

    test(
      'a card already detected from SMS is linked to its user card, not duplicated',
      () {
        final detected = Instrument(
          instrumentId: nextId(),
          kind: InstrumentKind.creditCard,
          issuerSlug: 'hdfc',
          maskDigits: '5678',
          displayName: 'HDFC credit card ••5678',
          status: InstrumentStatus.detected,
          firstSeenAt: DateTime.utc(2026, 11, 1),
          lastSeenAt: DateTime.utc(2026, 11, 1),
          evidenceCount: 2,
        );
        store.upsert(detected);
        final report = seeder().seed(
          cards: [
            _card(
              _cardA,
              'hdfc_millennia',
              last4: '5678',
              name: 'HDFC Millennia',
            ),
          ],
          issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
          bankAccounts: const [],
        );
        expect(report.cardsUpdated, 1);
        expect(store.count(), 1);
        final linked = store.get(detected.instrumentId)!;
        expect(linked.userCardId, _cardA);
        expect(linked.status, InstrumentStatus.confirmed);
      },
    );

    test(
      'two wallet cards of one issuer without last 4 stay two instruments, once',
      () {
        final cards = [
          _card(_cardA, 'hdfc_millennia'),
          _card(_cardB, 'hdfc_regalia'),
        ];
        seeder().seed(
          cards: cards,
          issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
          bankAccounts: const [],
        );
        seeder().seed(
          cards: cards,
          issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
          bankAccounts: const [],
        );
        expect(store.count(), 2);
      },
    );

    test('two wallet cards sharing issuer and last 4 are both kept', () {
      final cards = [
        _card(_cardA, 'hdfc_millennia', last4: '1111'),
        _card(_cardB, 'hdfc_regalia', last4: '1111'),
      ];
      seeder().seed(
        cards: cards,
        issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
        bankAccounts: const [],
      );
      seeder().seed(
        cards: cards,
        issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
        bankAccounts: const [],
      );
      expect(store.count(), 2);
      expect(store.findByUserCardId(_cardA), isNotNull);
      expect(store.findByUserCardId(_cardB), isNotNull);
    });

    test('rows that cannot be instruments are skipped with a reason', () {
      final report = seeder().seed(
        cards: [
          _card('local-guest-1', 'hdfc_millennia', last4: '1111'),
          _card(_cardA, 'unknown_product', last4: '2222'),
        ],
        issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
        bankAccounts: [
          _acct('4455', 'sbiupi'),
          _acct('7788', 'axio'),
          _acct('12', 'hdfc'),
        ],
      );
      expect(report.created, 0);
      expect(report.skipped.length, 5);
      expect(store.count(), 0);
    });

    test('legacy bank codes become v2 slugs', () {
      seeder().seed(
        cards: const [],
        issuerSlugOf: (_) => null,
        bankAccounts: [
          _acct('1111', 'indus'),
          _acct('2222', 'aubank'),
          _acct('3333', 'scb'),
        ],
      );
      expect(
        store
            .list(kind: InstrumentKind.bankAccount)
            .map((i) => i.issuerSlug)
            .toSet(),
        {'indusind', 'au', 'sc'},
      );
    });
  });

  group('bankAccountSummariesFromInstruments', () {
    test('seeding then adapting returns today\'s summaries', () {
      final accounts = [
        _acct(
          '1234',
          'hdfc',
          paise: 5000000,
          balanceAt: DateTime.utc(2026, 10, 30),
          smsAt: DateTime.utc(2026, 11, 1),
          count: 7,
        ),
        _acct('4321', 'icici', smsAt: DateTime.utc(2026, 10, 1), count: 2),
      ];
      seeder().seed(
        cards: const [],
        issuerSlugOf: (_) => null,
        bankAccounts: accounts,
      );
      final out = bankAccountSummariesFromInstruments(store.list());
      expect(out.map((a) => a.accountLast4), ['1234', '4321']); // newest first
      final hdfc = out.first;
      expect(hdfc.issuerSlug, 'hdfc');
      expect(hdfc.issuerShortName, 'HDFC Bank');
      expect(hdfc.availableBalance, Money.fromPaise(5000000));
      expect(hdfc.latestBalanceSmsAt, DateTime.utc(2026, 10, 30));
      expect(hdfc.latestSmsAt, DateTime.utc(2026, 11, 1));
      expect(hdfc.smsCount, 7);
      expect(hdfc.isBalanceManuallySet, isFalse);
      expect(out.last.availableBalance, isNull);
    });

    test(
      'round trip: the same summaries come back wherever today\'s answer is correct',
      () {
        final today = [
          BankAccountSummary(
            accountLast4: '1234',
            issuerSlug: 'hdfc',
            issuerShortName: 'HDFC Bank',
            availableBalance: Money.fromPaise(12345600),
            latestBalanceSmsAt: DateTime.utc(2026, 11, 1, 8),
            latestSmsAt: DateTime.utc(2026, 11, 2, 9),
            smsCount: 12,
          ),
          BankAccountSummary(
            accountLast4: '9876',
            issuerSlug: 'sbi',
            issuerShortName: 'SBI',
            availableBalance: null,
            latestSmsAt: DateTime.utc(2026, 10, 20),
            smsCount: 2,
          ),
          BankAccountSummary(
            accountLast4: '5555',
            issuerSlug: 'indus',
            issuerShortName: 'IndusInd Bank',
            availableBalance: Money.fromPaise(0),
            latestBalanceSmsAt: DateTime.utc(2026, 9, 1),
            latestSmsAt: DateTime.utc(2026, 9, 2),
            smsCount: 1,
          ),
        ];
        seeder().seed(
          cards: const [],
          issuerSlugOf: (_) => null,
          bankAccounts: today,
        );
        final back = bankAccountSummariesFromInstruments(store.list());
        expect(back.length, today.length);
        for (var i = 0; i < today.length; i++) {
          final a = today[i], b = back[i];
          expect(b.accountLast4, a.accountLast4);
          expect(b.issuerSlug, a.issuerSlug);
          expect(b.availableBalance, a.availableBalance);
          expect(b.latestBalanceSmsAt, a.latestBalanceSmsAt);
          expect(b.latestSmsAt, a.latestSmsAt);
          expect(b.smsCount, a.smsCount);
          expect(b.isBalanceManuallySet, a.isBalanceManuallySet);
        }
        // Labels are today's bankDisplayLabel for the same bank code.
        expect(back[0].issuerShortName, 'HDFC Bank');
        expect(back[1].issuerShortName, 'SBI');
      },
    );

    test('rejected and archived accounts, cards and wallets are left out', () {
      Instrument make(InstrumentKind kind, InstrumentStatus s, String mask) =>
          Instrument(
            instrumentId: nextId(),
            kind: kind,
            issuerSlug: 'hdfc',
            maskDigits: mask,
            displayName: 'x',
            status: s,
            firstSeenAt: DateTime.utc(2026, 11, 1),
            lastSeenAt: DateTime.utc(2026, 11, 1),
            evidenceCount: 1,
          );
      final out = bankAccountSummariesFromInstruments([
        make(InstrumentKind.bankAccount, InstrumentStatus.confirmed, '1111'),
        make(InstrumentKind.bankAccount, InstrumentStatus.rejected, '2222'),
        make(InstrumentKind.bankAccount, InstrumentStatus.archived, '3333'),
        make(InstrumentKind.creditCard, InstrumentStatus.confirmed, '4444'),
      ]);
      expect(out.map((a) => a.accountLast4), ['1111']);
    });

    test('a six digit mask shows its last four', () {
      seeder();
      final axis = Instrument(
        instrumentId: nextId(),
        kind: InstrumentKind.bankAccount,
        issuerSlug: 'axis',
        maskDigits: '123456',
        displayName: 'x',
        status: InstrumentStatus.detected,
        firstSeenAt: DateTime.utc(2026, 11, 1),
        lastSeenAt: DateTime.utc(2026, 11, 1),
        evidenceCount: 1,
      );
      expect(
        bankAccountSummariesFromInstruments([axis]).single.accountLast4,
        '3456',
      );
    });

    test(
      'a manual balance replaces the SMS balance and adds accounts with no SMS, as today',
      () {
        final acct = Instrument(
          instrumentId: nextId(),
          kind: InstrumentKind.bankAccount,
          issuerSlug: 'hdfc',
          maskDigits: '1234',
          displayName: 'x',
          status: InstrumentStatus.detected,
          firstSeenAt: DateTime.utc(2026, 11, 1),
          lastSeenAt: DateTime.utc(2026, 11, 1),
          evidenceCount: 1,
          availableMinor: 100,
          availableAt: DateTime.utc(2026, 11, 1),
        );
        final out = bankAccountSummariesFromInstruments(
          [acct],
          manualBalances: {
            'hdfc:1234': (
              balance: Money.fromPaise(999),
              updatedAt: DateTime.utc(2026, 11, 2),
            ),
            'sbi:5555': (
              balance: Money.fromPaise(50),
              updatedAt: DateTime.utc(2026, 11, 2),
            ),
          },
        );
        expect(out.length, 2);
        expect(out.first.availableBalance, Money.fromPaise(999));
        expect(out.first.isBalanceManuallySet, isTrue);
        expect(out.first.manualBalanceUpdatedAt, DateTime.utc(2026, 11, 2));
        expect(out.first.latestBalanceSmsAt, DateTime.utc(2026, 11, 1));
        expect(out.last.accountLast4, '5555');
        expect(out.last.issuerShortName, 'SBI');
        expect(out.last.smsCount, 0);
      },
    );
  });

  group('InstrumentCardLinker', () {
    Instrument confirmedCard(String issuer, String mask) {
      final i = Instrument(
        instrumentId: nextId(),
        kind: InstrumentKind.creditCard,
        issuerSlug: issuer,
        maskDigits: mask,
        displayName: 'x',
        status: InstrumentStatus.confirmed,
        firstSeenAt: DateTime.utc(2026, 11, 1),
        lastSeenAt: DateTime.utc(2026, 11, 1),
        evidenceCount: 1,
      );
      store.upsert(i);
      return i;
    }

    InstrumentCardLinker linker() => InstrumentCardLinker(
      store: store,
      issuerSlugOf: cardIssuerSlugFromCatalogue(_catalogue),
      catalogue: _catalogue,
    );

    test(
      'exactly one wallet card with the same issuer and last 4 is linked',
      () {
        final card = confirmedCard('hdfc', '5678');
        final wallet = [
          _card(_cardA, 'hdfc_millennia', last4: '5678'),
          _card(_cardB, 'hdfc_regalia', last4: '9999'),
          _card(_cardC, 'axis_ace', last4: '5678'),
        ];
        final r = linker().link(card, userCards: wallet);
        expect(r, isA<CardLinked>());
        expect((r as CardLinked).instrument.userCardId, _cardA);
        expect(store.get(card.instrumentId)!.userCardId, _cardA);
        expect(
          store.dirty().map((i) => i.instrumentId),
          contains(card.instrumentId),
        );
      },
    );

    test('two matching wallet cards need a product', () {
      final card = confirmedCard('hdfc', '5678');
      final r = linker().link(
        card,
        userCards: [
          _card(_cardA, 'hdfc_millennia', last4: '5678'),
          _card(_cardB, 'hdfc_regalia', last4: '5678'),
        ],
      );
      expect(r, isA<CardNeedsProduct>());
      expect(store.get(card.instrumentId)!.userCardId, isNull);
    });

    test(
      'no match returns issuer, digits and at most 3 suggestions from discovery',
      () {
        final card = confirmedCard('hdfc', '5678');
        final r = linker().link(
          card,
          userCards: [_card(_cardC, 'axis_ace', last4: '5678')],
          smsBodies: [
            'Rs 1,450.00 spent on your HDFC Millennia card ending 5678 at Amazon on 28-Aug-26',
            'Rs 300.00 spent on your HDFC Regalia card ending 5678 at Store on 29-Aug-26',
          ],
        );
        expect(r, isA<CardNeedsProduct>());
        final need = r as CardNeedsProduct;
        expect(need.issuerSlug, 'hdfc');
        expect(need.maskDigits, '5678');
        expect(need.suggestions.length, lessThanOrEqualTo(3));
        expect(need.suggestions, isNotEmpty);
        expect(
          need.suggestions.map((s) => s.cardProductId),
          everyElement(startsWith('hdfc_')),
        );
      },
    );

    test(
      'with no messages there are no suggestions, but the issuer and digits come back',
      () {
        final card = confirmedCard('icici', '4321');
        final r = linker().link(card, userCards: const []) as CardNeedsProduct;
        expect(r.issuerSlug, 'icici');
        expect(r.maskDigits, '4321');
        expect(r.suggestions, isEmpty);
      },
    );

    test('a wallet card already tied to another instrument is not taken', () {
      final first = confirmedCard('hdfc', '5678');
      final wallet = [_card(_cardA, 'hdfc_millennia', last4: '5678')];
      expect(linker().link(first, userCards: wallet), isA<CardLinked>());
      final second = confirmedCard(
        'hdfc',
        '5678'.replaceAll('8', '9'),
      ); // another card, other digits
      expect(linker().link(second, userCards: wallet), isA<CardNeedsProduct>());
      // an instrument that has the id already is left alone
      final again = store.get(first.instrumentId)!;
      expect(linker().link(again, userCards: wallet), isA<CardAlreadyLinked>());
    });

    test('the same last 4 at another issuer is never linked', () {
      final card = confirmedCard('icici', '5678');
      final r = linker().link(
        card,
        userCards: [_card(_cardA, 'hdfc_millennia', last4: '5678')],
      );
      expect(r, isA<CardNeedsProduct>());
    });
  });

  group('issuer slugs', () {
    test('catalogue issuer names map to senders.json slugs', () {
      expect(v2IssuerSlugFromName('HDFC Bank'), 'hdfc');
      expect(v2IssuerSlugFromName('Axis Bank'), 'axis');
      expect(v2IssuerSlugFromName('SBI Card'), 'sbi');
      expect(v2IssuerSlugFromName('ICICI Bank'), 'icici');
      expect(v2IssuerSlugFromName('Kotak Mahindra Bank'), 'kotak');
      expect(v2IssuerSlugFromName('IndusInd Bank'), 'indusind');
      expect(v2IssuerSlugFromName('American Express'), 'amex');
      expect(v2IssuerSlugFromName(null), isNull);
      expect(v2IssuerSlugFromName('  '), isNull);
    });
  });
}
