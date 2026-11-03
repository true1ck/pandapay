import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/features/sms_v2/category/category_snapshot.dart';
import 'package:pandapay/features/sms_v2/category/confirmed_category_history.dart';
import 'package:pandapay/features/sms_v2/category/user_category_rules.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';

const _ns = 'user:test';

CategoryRule _catalogue(String key, String slug) => CategoryRule(
      merchantKey: key,
      match: CategoryMatch.token,
      senders: const ['*'],
      context: const [],
      category: slug,
      priority: 800,
      source: CategorySource.catalogue,
    );

Counterparty _merchant(String name) => Counterparty(name: name, kind: CounterpartyKind.merchant);

String _hex(String id) =>
    utf8.encode(id).map((b) => b.toRadixString(16).padLeft(2, '0')).join().padRight(64, '0');

void _insertLedger(
  AppDatabase database,
  String id, {
  required String key,
  required String slug,
  required String? source,
  DateTime? at,
  String namespace = _ns,
}) {
  final entry = LedgerEntry(
    entryId: _hex(id),
    eventId: _hex('e-$id'),
    from: const InstrumentEndpoint('3f9d5a52-1c0e-4b4e-9d57-6a7a1b0f2c11'),
    to: ExternalEndpoint(key),
    amountMinor: 100,
    unit: LedgerUnit.inr,
    occurredAt: at ?? DateTime.utc(2026, 11, 1),
    category: slug,
    categorySource: source == null ? null : CategorySource.fromWire(source),
    countsAsTransaction: true,
    isSpend: true,
    isIncome: false,
    isInvestment: false,
  );
  database.db.execute(
    'INSERT INTO v2_ledger (namespace, entry_id, event_id, occurred_at, payload) VALUES (?, ?, ?, ?, ?)',
    [namespace, _hex(id), _hex('e-$id'), entry.toJson()['occurredAt'], jsonEncode(entry.toJson())],
  );
}

void main() {
  late AppDatabase database;

  setUp(() {
    database = openInMemoryForTesting();
    SmsV2Schema.ensure(database.db);
  });

  group('UserCategoryRules', () {
    test('reads a plain legacy row as a rule for that merchant, any sender', () {
      SmsLearningFeedback(database, namespace: _ns)
          .recordCategoryCorrection(merchantOrPattern: 'Local Kirana', categorySlug: 'groceries');
      final rules = UserCategoryRules(database, namespace: _ns).load();
      expect(rules, hasLength(1));
      expect(rules.single.merchantKey, 'LOCAL KIRANA');
      expect(rules.single.category, 'groceries');
      expect(rules.single.source, CategorySource.user);
      expect(rules.single.senders, ['*']);
    });

    test('reads an old layout row (CTX) as a rule for that merchant and sender', () {
      SmsLearningFeedback(database, namespace: _ns).recordCategoryCorrection(
        merchantOrPattern: 'Bundl Technologies Pvt Ltd',
        categorySlug: 'groceries',
        sender: 'VM-HDFCBK-S',
        sampleBody: 'Rs 250 spent at BUNDL on 01-11-26',
      );
      final rules = UserCategoryRules(database, namespace: _ns).load();
      expect(rules.single.merchantKey, 'BUNDL TECHNOLOGIES');
      expect(rules.single.senders, ['HDFCBK']);
      expect(rules.single.category, 'groceries');
    });

    test('a user rule beats the catalogue through the resolver', () {
      SmsLearningFeedback(database, namespace: _ns)
          .recordCategoryCorrection(merchantOrPattern: 'SWIGGY', categorySlug: 'groceries');
      final snapshot = CategorySnapshot.load(database, namespace: _ns);
      final d = DefaultCategoryResolver().resolve(snapshot.input(
        counterparty: _merchant('Swiggy'),
        senderBrand: 'HDFCBK',
        bundleRules: [_catalogue('SWIGGY', 'dining')],
      ));
      expect(d.slug, 'groceries');
      expect(d.source, CategorySource.user);
    });

    test('rows that are not user choices, have unknown slugs, or belong to another account are skipped', () {
      final store = SmsLearningFeedback(database, namespace: _ns);
      store.recordCategoryCorrection(merchantOrPattern: 'AUTOGUESS', categorySlug: 'fuel', source: 'ai');
      store.recordCategoryCorrection(merchantOrPattern: 'WEIRD', categorySlug: 'shopping');
      SmsLearningFeedback(database, namespace: 'user:other')
          .recordCategoryCorrection(merchantOrPattern: 'THEIRS', categorySlug: 'fuel');
      store.recordCategoryCorrection(merchantOrPattern: 'MINE', categorySlug: 'fuel');
      expect(UserCategoryRules(database, namespace: _ns).load().map((r) => r.merchantKey), ['MINE']);
    });

    test('saveChoice writes the same store, so the old and new readers agree', () {
      final rules = UserCategoryRules(database, namespace: _ns);
      rules.saveChoice(merchantKey: 'Cafe Coffee Day', slug: 'Dining');
      expect(SmsLearningFeedback(database, namespace: _ns).loadRulesSync(), {'CAFE COFFEE DAY': 'dining'});
      expect(rules.load().single.category, 'dining');
    });

    test('saveChoice rejects a slug outside the taxonomy and an empty key', () {
      final rules = UserCategoryRules(database, namespace: _ns);
      expect(() => rules.saveChoice(merchantKey: 'X', slug: 'shopping'), throwsArgumentError);
      expect(() => rules.saveChoice(merchantKey: '  ', slug: 'fuel'), throwsArgumentError);
      expect(rules.load(), isEmpty);
    });

    test('a contextual choice applies only in its context', () {
      final rules = UserCategoryRules(database, namespace: _ns);
      rules.saveChoice(merchantKey: 'SWIGGY', slug: 'groceries', context: ['instamart']);
      final loaded = rules.load().single;
      expect(loaded.context, ['INSTAMART']);

      final resolver = DefaultCategoryResolver();
      final snapshot = CategorySnapshot(userRules: [loaded]);
      CategoryDecision run(List<String> ctx) => resolver.resolve(snapshot.input(
            counterparty: _merchant('SWIGGY'),
            senderBrand: 'HDFCBK',
            contextTokens: ctx,
            bundleRules: [_catalogue('SWIGGY', 'dining')],
          ));
      expect(run(['INSTAMART']).slug, 'groceries');
      expect(run([]).slug, 'dining');
    });

    test('a sender-limited choice applies only to that sender', () {
      final rules = UserCategoryRules(database, namespace: _ns);
      rules.saveChoice(merchantKey: 'ACME', slug: 'health', senderBrand: 'icicib');
      final loaded = rules.load().single;
      expect(loaded.senders, ['ICICIB']);
      final resolver = DefaultCategoryResolver();
      final snapshot = CategorySnapshot(userRules: [loaded]);
      CategoryDecision run(String sender) =>
          resolver.resolve(snapshot.input(counterparty: _merchant('ACME'), senderBrand: sender));
      expect(run('ICICIB').slug, 'health');
      expect(run('HDFCBK').source, CategorySource.fallback);
    });

    test('a later choice for the same merchant replaces the earlier one', () {
      final rules = UserCategoryRules(database, namespace: _ns);
      rules.saveChoice(merchantKey: 'ACME', slug: 'health');
      rules.saveChoice(merchantKey: 'ACME', slug: 'rent');
      expect(rules.load().map((r) => r.category), ['rent']);
    });

    test('the sink hears each choice with the canonical values', () {
      final heard = <CategoryChoice>[];
      UserCategoryRules(database, namespace: _ns, onChoice: heard.add)
          .saveChoice(merchantKey: 'acme stores', slug: 'FUEL', senderBrand: 'hdfcbk');
      expect(heard.single.merchantKey, 'ACME STORES');
      expect(heard.single.slug, 'fuel');
      expect(heard.single.senderBrand, 'HDFCBK');
    });
  });

  group('ConfirmedCategoryHistory', () {
    test('reads user and history_confirmed entries only', () {
      _insertLedger(database, '1', key: 'AUTO ONE', slug: 'groceries', source: 'catalogue');
      _insertLedger(database, '2', key: 'AUTO TWO', slug: 'groceries', source: 'ai');
      _insertLedger(database, '3', key: 'AUTO THREE', slug: 'groceries', source: 'default');
      _insertLedger(database, '4', key: 'AUTO FOUR', slug: 'groceries', source: null);
      _insertLedger(database, '5', key: 'CONFIRMED ONE', slug: 'health', source: 'user');
      _insertLedger(database, '6', key: 'CONFIRMED TWO', slug: 'fuel', source: 'history_confirmed');
      expect(ConfirmedCategoryHistory(database, namespace: _ns).load(), {
        'CONFIRMED ONE': 'health',
        'CONFIRMED TWO': 'fuel',
      });
    });

    test('automatic history never wins, even for a merchant seen many times', () {
      for (var i = 0; i < 5; i++) {
        _insertLedger(database, 'a$i', key: 'KIRANA', slug: 'groceries', source: 'catalogue');
      }
      final snapshot = CategorySnapshot.load(database, namespace: _ns);
      final d = DefaultCategoryResolver().resolve(snapshot.input(
        counterparty: _merchant('KIRANA'),
        senderBrand: 'HDFCBK',
      ));
      expect(d.source, CategorySource.fallback);
    });

    test('a confirmed entry wins through the resolver, and the latest one is used', () {
      _insertLedger(database, 'u1', key: 'KIRANA', slug: 'groceries', source: 'user', at: DateTime.utc(2026, 10, 1));
      _insertLedger(database, 'u2', key: 'KIRANA', slug: 'health', source: 'user', at: DateTime.utc(2026, 11, 1));
      final snapshot = CategorySnapshot.load(database, namespace: _ns);
      final d = DefaultCategoryResolver().resolve(snapshot.input(
        counterparty: _merchant('Kirana'),
        senderBrand: 'HDFCBK',
      ));
      expect(d.slug, 'health');
      expect(d.source, CategorySource.historyConfirmed);
    });

    test('another account\'s entries and unreadable rows are ignored', () {
      _insertLedger(database, 'x', key: 'THEIRS', slug: 'fuel', source: 'user', namespace: 'user:other');
      database.db.execute(
        'INSERT INTO v2_ledger (namespace, entry_id, event_id, occurred_at, payload) VALUES (?, ?, ?, ?, ?)',
        [_ns, 'bad', 'e', '2026-11-01T00:00:00Z', '{"categorySource":"user","oops":true}'],
      );
      expect(ConfirmedCategoryHistory(database, namespace: _ns).load(), isEmpty);
    });
  });
}
