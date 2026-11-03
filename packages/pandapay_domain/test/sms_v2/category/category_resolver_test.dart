import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:test/test.dart';

const _rulesDir = '../../rules/sms/v2';

List<CategoryRule> _loadRules() => [
      for (final j in jsonDecode(File('$_rulesDir/category_rules.json').readAsStringSync()) as List)
        CategoryRule.fromJson((j as Map).cast<String, Object?>()),
    ];

List<MerchantAlias> _loadAliases() => [
      for (final j in jsonDecode(File('$_rulesDir/merchant_aliases.json').readAsStringSync()) as List)
        MerchantAlias.fromJson((j as Map).cast<String, Object?>()),
    ];

CategoryRule _rule(
  String key,
  String category, {
  CategorySource source = CategorySource.catalogue,
  CategoryMatch match = CategoryMatch.token,
  List<String> senders = const ['*'],
  List<String> context = const [],
  int priority = 800,
}) =>
    CategoryRule(
      merchantKey: key,
      match: match,
      senders: senders,
      context: context,
      category: category,
      priority: priority,
      source: source,
    );

Counterparty _merchant(String name) => Counterparty(name: name, kind: CounterpartyKind.merchant);

void main() {
  final bundle = _loadRules();
  final aliases = _loadAliases();
  final resolver = DefaultCategoryResolver(aliases: aliases);

  CategoryDecision resolveName(String name, {String sender = 'HDFCBK', List<String> context = const []}) =>
      resolver.resolve(CategoryInput(
        counterparty: _merchant(name),
        senderBrand: sender,
        contextTokens: context,
        bundleRules: bundle,
      ));

  group('precedence, one case per row', () {
    final r = DefaultCategoryResolver();
    final userRule = _rule('ACME STORES', 'health', source: CategorySource.user, match: CategoryMatch.exact, priority: 0);
    final sharedRule = _rule('ACME STORES', 'education', source: CategorySource.shared, priority: 500);
    final catalogueRule = _rule('ACME STORES', 'fuel');
    ResolverInput input(
      List<CategoryRule> user,
      List<CategoryRule> rules,
      Map<String, String> history,
      String? ai,
    ) =>
        ResolverInput(
          counterparty: _merchant('Acme Stores'),
          senderBrand: 'HDFCBK',
          userRules: user,
          bundleRules: rules,
          confirmedHistory: history,
          aiSuggestion: ai,
        );

    test('1. the user rule beats everything, confidence 1.0', () {
      final d = r.resolve(input([userRule], [sharedRule, catalogueRule], {'ACME STORES': 'rent'}, 'travel'));
      expect(d.slug, 'health');
      expect(d.source, CategorySource.user);
      expect(d.confidence, 1.0);
    });

    test('2. a shared rule beats the catalogue, history and AI, confidence 0.95', () {
      final d = r.resolve(input([], [catalogueRule, sharedRule], {'ACME STORES': 'rent'}, 'travel'));
      expect(d.slug, 'education');
      expect(d.source, CategorySource.shared);
      expect(d.confidence, 0.95);
    });

    test('2. shared rules are ordered by priority', () {
      final d = r.resolve(input([], [
        _rule('ACME', 'rent', source: CategorySource.shared, priority: 100),
        _rule('ACME STORES', 'insurance', source: CategorySource.shared, priority: 200),
      ], {}, null));
      expect(d.slug, 'insurance');
    });

    test('3. a catalogue rule beats history and AI; exact 0.9, token 0.8', () {
      final exact = r.resolve(input([], [catalogueRule], {'ACME STORES': 'rent'}, 'travel'));
      expect(exact.slug, 'fuel');
      expect(exact.source, CategorySource.catalogue);
      expect(exact.confidence, 0.9);

      final token = r.resolve(ResolverInput(
        counterparty: _merchant('Acme Stores Koramangala'),
        senderBrand: 'HDFCBK',
        bundleRules: [catalogueRule],
      ));
      expect(token.slug, 'fuel');
      expect(token.confidence, 0.8);
    });

    test('3. the longest catalogue match wins over a shorter one with higher priority', () {
      final d = r.resolve(ResolverInput(
        counterparty: _merchant('Swiggy Instamart'),
        senderBrand: 'X',
        bundleRules: [
          _rule('SWIGGY', 'dining', priority: 900),
          _rule('SWIGGY INSTAMART', 'groceries', priority: 800),
        ],
      ));
      expect(d.slug, 'groceries');
    });

    test('4. confirmed history beats the AI suggestion, confidence 0.85', () {
      final d = r.resolve(input([], [], {'ACME STORES': 'rent'}, 'travel'));
      expect(d.slug, 'rent');
      expect(d.source, CategorySource.historyConfirmed);
      expect(d.confidence, 0.85);
    });

    test('5. the AI suggestion is used when nothing else matches, confidence 0.6', () {
      final d = r.resolve(input([], [], {}, 'travel'));
      expect(d.slug, 'travel');
      expect(d.source, CategorySource.ai);
      expect(d.confidence, 0.6);
    });

    test('5. an AI suggestion outside the taxonomy, or "other", is ignored', () {
      expect(r.resolve(input([], [], {}, 'shopping')).source, CategorySource.fallback);
      expect(r.resolve(input([], [], {}, 'other')).source, CategorySource.fallback);
    });

    test('6. no hit gives other, flagged uncertain', () {
      final d = r.resolve(input([], [], {}, null));
      expect(d.slug, 'other');
      expect(d.source, CategorySource.fallback);
      expect(d.confidence, 0);
    });

    test('a counterparty with no key skips rules and history, and can still use AI', () {
      final d = r.resolve(const ResolverInput(senderBrand: 'HDFCBK', aiSuggestion: 'dining'));
      expect(d.slug, 'dining');
      expect(d.source, CategorySource.ai);
    });

    test('rules with a slug outside the taxonomy are skipped', () {
      final d = r.resolve(input([], [_rule('ACME STORES', 'shopping'), _rule('ACME', 'fuel', priority: 100)], {}, null));
      expect(d.slug, 'fuel');
    });

    test('a bundle rule whose source is not shared or catalogue is ignored', () {
      final d = r.resolve(input([], [_rule('ACME STORES', 'fuel', source: CategorySource.user)], {}, null));
      expect(d.source, CategorySource.fallback);
    });
  });

  group('audit collisions (real rules and aliases)', () {
    test('KUBER HARDWARE is not travel', () {
      final d = resolveName('KUBER HARDWARE');
      expect(d.slug, isNot('travel'));
    });

    test('SPARK ELECTRICALS is not groceries', () {
      expect(resolveName('SPARK ELECTRICALS').slug, isNot('groceries'));
    });

    test('SHELLY BOOK STORE is not fuel', () {
      expect(resolveName('SHELLY BOOK STORE').slug, isNot('fuel'));
    });

    test('UBER EATS is dining', () {
      expect(resolveName('UBER EATS').slug, 'dining');
      expect(resolveName('UBER').slug, 'travel');
    });

    test('SWIGGY INSTAMART is groceries, SWIGGY is dining', () {
      expect(resolveName('SWIGGY INSTAMART').slug, 'groceries');
      expect(resolveName('SWIGGYINSTAMART').slug, 'groceries');
      expect(resolveName('SWIGGY').slug, 'dining');
    });

    test('an Amazon purchase on a card is online, not wallet', () {
      for (final n in ['AMAZON', 'Amazon Pay India', 'AMAZON PAY IN', 'AMZN MKTP IN', 'AMAZON SELLER SERVICES']) {
        expect(resolveName(n).slug, 'online', reason: n);
      }
    });

    test('an Amazon Pay top-up descriptor stays wallet', () {
      expect(resolveName('AMAZON PAY WALLET').slug, 'wallet');
    });

    test('INDIGO needs a context token; INDIGO PAINTS gives other', () {
      expect(resolveName('INDIGO').slug, 'other');
      expect(resolveName('INDIGO PAINTS').slug, 'other');
      expect(resolveName('INDIGO AIRLINES').slug, 'travel');
      expect(resolveName('INTERGLOBE AVIATION').slug, 'travel');
      expect(resolveName('INDIGO', context: ['FLIGHT']).slug, 'travel');
    });

    test('OLA and VI match only as a whole key', () {
      expect(resolveName('OLA').slug, 'travel');
      expect(resolveName('OLA CABS').slug, 'travel');
      expect(resolveName('VIVEK STORES').slug, 'other');
      expect(resolveName('VIJAY SALES').slug, isNot('bills'));
    });

    test('a brand inside another word does not match', () {
      expect(resolveName('KUBERA STORES').slug, 'other');
      expect(resolveName('SUBER MART').slug, 'other');
    });

    test('a brand in a footer is ignored', () {
      // Only the merchant is looked at. A footer brand reaches the resolver at
      // most as a context token, and context tokens never match a merchant.
      final d = resolver.resolve(CategoryInput(
        counterparty: _merchant('RAMESH ENTERPRISES'),
        senderBrand: 'HDFCBK',
        contextTokens: ['SWIGGY', 'UBER', 'AMAZON', 'ZOMATO'],
        bundleRules: bundle,
      ));
      expect(d.slug, 'other');
      expect(d.source, CategorySource.fallback);
    });
  });

  group('user rules and history', () {
    final base = DefaultCategoryResolver(aliases: aliases);

    test('a contextual user rule applies only in its context', () {
      final rule = _rule(
        'SWIGGY',
        'groceries',
        source: CategorySource.user,
        match: CategoryMatch.exact,
        context: ['INSTAMART'],
        priority: 0,
      );
      CategoryDecision run(List<String> ctx) => base.resolve(CategoryInput(
            counterparty: _merchant('SWIGGY'),
            senderBrand: 'HDFCBK',
            contextTokens: ctx,
            userRules: [rule],
            bundleRules: bundle,
          ));
      expect(run(['INSTAMART']).source, CategorySource.user);
      expect(run(['INSTAMART']).slug, 'groceries');
      // Outside the context it falls through to the catalogue.
      expect(run([]).source, CategorySource.catalogue);
      expect(run(['FOOD']).slug, 'dining');
    });

    test('a user rule limited to a sender applies only for that sender', () {
      final rule = _rule('ACME', 'health',
          source: CategorySource.user, match: CategoryMatch.exact, senders: ['ICICIB'], priority: 0);
      CategoryDecision run(String sender) => base.resolve(CategoryInput(
            counterparty: _merchant('ACME'),
            senderBrand: sender,
            userRules: [rule],
          ));
      expect(run('icicib').slug, 'health');
      expect(run('HDFCBK').source, CategorySource.fallback);
    });

    test('a contextual user rule beats a plain one when its context is present', () {
      final plain = _rule('ACME', 'fuel', source: CategorySource.user, match: CategoryMatch.exact, priority: 0);
      final contextual = _rule('ACME', 'rent',
          source: CategorySource.user, match: CategoryMatch.exact, context: ['MONTHLY'], priority: 0);
      CategoryDecision run(List<String> ctx) => base.resolve(CategoryInput(
            counterparty: _merchant('ACME'),
            senderBrand: 'X',
            contextTokens: ctx,
            userRules: [plain, contextual],
          ));
      expect(run(['MONTHLY']).slug, 'rent');
      expect(run([]).slug, 'fuel');
    });

    test('history is read through the merchant key, so aliases apply', () {
      final d = base.resolve(const CategoryInput(
        counterparty: Counterparty(name: 'Some Local Shop Pvt Ltd', kind: CounterpartyKind.merchant),
        senderBrand: 'X',
        confirmedHistory: {'SOME LOCAL SHOP': 'health'},
      ));
      expect(d.slug, 'health');
      expect(d.source, CategorySource.historyConfirmed);
    });

    LedgerEntry entry(String id, String key, String slug, CategorySource? source, DateTime at) => LedgerEntry(
          entryId: id,
          eventId: 'e-$id',
          from: const InstrumentEndpoint('i1'),
          to: ExternalEndpoint(key),
          amountMinor: 100,
          unit: LedgerUnit.inr,
          occurredAt: at,
          category: slug,
          categorySource: source,
          countsAsTransaction: true,
          isSpend: true,
          isIncome: false,
          isInvestment: false,
        );

    test('automatic history never wins: only user and history_confirmed entries count', () {
      final t = DateTime.utc(2026, 11, 1);
      final history = confirmedHistoryFromLedger([
        entry('1', 'KIRANA ONE', 'groceries', CategorySource.catalogue, t),
        entry('2', 'KIRANA TWO', 'groceries', CategorySource.shared, t),
        entry('3', 'KIRANA THREE', 'groceries', CategorySource.ai, t),
        entry('4', 'KIRANA FOUR', 'groceries', CategorySource.fallback, t),
        entry('5', 'KIRANA FIVE', 'groceries', CategorySource.mcc, t),
        entry('6', 'KIRANA SIX', 'groceries', null, t),
        entry('7', 'KIRANA SEVEN', 'groceries', CategorySource.user, t),
        entry('8', 'KIRANA EIGHT', 'groceries', CategorySource.historyConfirmed, t),
      ]);
      expect(history.keys.toSet(), {'KIRANA SEVEN', 'KIRANA EIGHT'});

      // An automatic entry that is newer than a confirmed one does not replace it.
      final mixed = confirmedHistoryFromLedger([
        entry('a', 'KIRANA', 'health', CategorySource.user, t),
        entry('b', 'KIRANA', 'groceries', CategorySource.catalogue, t.add(const Duration(days: 1))),
      ]);
      expect(mixed, {'KIRANA': 'health'});

      final d = base.resolve(CategoryInput(
        counterparty: _merchant('KIRANA ONE'),
        senderBrand: 'X',
        confirmedHistory: history,
      ));
      expect(d.source, CategorySource.fallback);
    });

    test('the most recent confirmed entry wins; a later correction replaces an earlier choice', () {
      final history = confirmedHistoryFromLedger([
        entry('a', 'KIRANA', 'groceries', CategorySource.user, DateTime.utc(2026, 10, 1)),
        entry('b', 'KIRANA', 'health', CategorySource.user, DateTime.utc(2026, 11, 1)),
        entry('c', 'KIRANA', 'rent', CategorySource.user, DateTime.utc(2026, 9, 1)),
      ]);
      expect(history, {'KIRANA': 'health'});
    });

    test('history skips non-external destinations and slugs outside the taxonomy', () {
      final t = DateTime.utc(2026, 11, 1);
      final own = LedgerEntry(
        entryId: 'o',
        eventId: 'eo',
        from: const InstrumentEndpoint('i1'),
        to: const InstrumentEndpoint('i2'),
        amountMinor: 1,
        unit: LedgerUnit.inr,
        occurredAt: t,
        category: 'groceries',
        categorySource: CategorySource.user,
        countsAsTransaction: false,
        isSpend: false,
        isIncome: false,
        isInvestment: false,
      );
      expect(confirmedHistoryFromLedger([own, entry('x', 'SHOP', 'shopping', CategorySource.user, t)]), isEmpty);
    });
  });

  group('event scope', () {
    final r = DefaultCategoryResolver(aliases: aliases);
    CategoryInput input(String name, {CounterpartyKind kind = CounterpartyKind.merchant, List<CategoryRule> user = const []}) =>
        CategoryInput(
          counterparty: Counterparty(name: name, kind: kind),
          senderBrand: 'HDFCBK',
          userRules: user,
          bundleRules: bundle,
        );

    test('only spend events get a category', () {
      for (final t in [
        EventType.income,
        EventType.cashback,
        EventType.p2pIn,
        EventType.ownTransfer,
        EventType.cardBillPayment,
        EventType.walletTopup,
        EventType.investment,
        EventType.ipoApplication,
        EventType.investmentWithdrawal,
        EventType.dividend,
        EventType.unknown,
      ]) {
        expect(r.decide(eventType: t, input: input('SWIGGY')), isNull, reason: t.wire);
      }
    });

    test('every spend event type returns a decision with a source', () {
      for (final t in categorisedEventTypes) {
        final d = r.decide(eventType: t, input: input('SWIGGY INSTAMART', kind: CounterpartyKind.merchant));
        expect(d, isNotNull, reason: t.wire);
        expect(d!.source, isNotNull);
      }
      final bare = r.decide(eventType: EventType.fee, input: const CategoryInput(senderBrand: 'HDFCBK'));
      expect(bare!.slug, 'other');
      expect(bare.source, CategorySource.fallback);
    });

    test('a refund inherits its linked purchase category', () {
      final purchase = r.decide(eventType: EventType.purchase, input: input('SWIGGY'))!;
      final refund = r.decide(
        eventType: EventType.refund,
        // The refund's own counterparty would give a different answer.
        input: input('UBER'),
        linkedPurchase: purchase,
      );
      expect(refund!.slug, 'dining');
      expect(refund.source, purchase.source);
      expect(refund.confidence, purchase.confidence);
    });

    test('a refund without a linked purchase runs the resolver on its own counterparty', () {
      final refund = r.decide(eventType: EventType.refund, input: input('UBER'));
      expect(refund!.slug, 'travel');
    });

    test('p2p_out stays other unless the user has a rule', () {
      final person = Counterparty(name: 'Ramesh Kumar', vpa: 'ramesh@okhdfcbank', kind: CounterpartyKind.person);
      final withoutRule = r.decide(
        eventType: EventType.p2pOut,
        input: CategoryInput(counterparty: person, senderBrand: 'X', bundleRules: bundle),
      );
      expect(withoutRule!.slug, 'other');
      expect(withoutRule.source, CategorySource.fallback);

      // Even a merchant-looking payee: the catalogue is not consulted.
      final shop = r.decide(eventType: EventType.p2pOut, input: input('SWIGGY'));
      expect(shop!.slug, 'other');

      final withRule = r.decide(
        eventType: EventType.p2pOut,
        input: CategoryInput(
          counterparty: person,
          senderBrand: 'X',
          bundleRules: bundle,
          userRules: [
            _rule('RAMESH OKHDFCBANK', 'rent', source: CategorySource.user, match: CategoryMatch.exact, priority: 0),
          ],
        ),
      );
      expect(withRule!.slug, 'rent');
      expect(withRule.source, CategorySource.user);
    });

    test('a person never becomes a merchant key', () {
      final person = Counterparty(name: 'Swiggy', vpa: 'swiggy@icici', kind: CounterpartyKind.person);
      final d = r.resolve(CategoryInput(counterparty: person, senderBrand: 'X', bundleRules: bundle));
      expect(d.source, CategorySource.fallback);
    });
  });

  group('accuracy', () {
    // Synthetic merchants as they appear in SMS, with the category a person
    // would expect. No real data.
    const labelled = <(String, String)>[
      ('SWIGGY', 'dining'),
      ('ZOMATO', 'dining'),
      ('BUNDL TECHNOLOGIES PVT LTD', 'dining'),
      ('MCDONALD\'S', 'dining'),
      ('DOMINOS PIZZA', 'dining'),
      ('STARBUCKS', 'dining'),
      ('UBER EATS', 'dining'),
      ('BLINKIT', 'groceries'),
      ('BLINK COMMERCE PRIVATE LIMITED', 'groceries'),
      ('ZEPTO', 'groceries'),
      ('BIGBASKET', 'groceries'),
      ('SWIGGY INSTAMART', 'groceries'),
      ('AVENUE SUPERMARTS LIMITED', 'groceries'),
      ('AMAZON', 'online'),
      ('AMAZON PAY IN', 'online'),
      ('AMZN MKTP IN', 'online'),
      ('FLIPKART', 'online'),
      ('FLIPKART INTERNET PRIVATE LIMITED', 'online'),
      ('MYNTRA', 'online'),
      ('NYKAA', 'online'),
      ('UBER', 'travel'),
      ('OLA', 'travel'),
      ('RAPIDO', 'travel'),
      ('IRCTC', 'travel'),
      ('MAKEMYTRIP INDIA PVT LTD', 'travel'),
      ('INTERGLOBE AVIATION LIMITED', 'travel'),
      ('NETFLIX', 'entertainment'),
      ('SPOTIFY INDIA', 'entertainment'),
      ('BOOKMYSHOW', 'entertainment'),
      ('BIGTREE ENTERTAINMENT PVT LTD', 'entertainment'),
      ('AIRTEL', 'bills'),
      ('BHARTI AIRTEL LIMITED', 'bills'),
      ('JIO', 'bills'),
      ('TATA POWER', 'bills'),
      ('BSES RAJDHANI', 'bills'),
      ('AMAZON PAY WALLET', 'wallet'),
    ];

    test('at least 95% of labelled merchants resolve to the expected category', () {
      var right = 0;
      final misses = <String>[];
      for (final (name, want) in labelled) {
        final got = resolveName(name).slug;
        if (got == want) {
          right++;
        } else {
          misses.add('$name: want $want, got $got');
        }
      }
      final accuracy = right / labelled.length;
      expect(accuracy, greaterThanOrEqualTo(0.95), reason: misses.join('; '));
      expect(misses, isEmpty);
    });
  });

  test('the resolver reuses compiled rules between calls', () {
    // Not an assertion on identity: a smoke check that 2,000 resolutions over
    // the full catalogue finish quickly.
    final sw = Stopwatch()..start();
    for (var i = 0; i < 2000; i++) {
      resolveName('SWIGGY INSTAMART KORAMANGALA');
    }
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
