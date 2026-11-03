import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:test/test.dart';

const _expected = [
  'groceries',
  'fuel',
  'dining',
  'online',
  'travel',
  'bills',
  'rent',
  'insurance',
  'education',
  'government',
  'wallet',
  'entertainment',
  'health',
  'emi',
  'other',
];

void main() {
  final registry = TaxonomyRegistry.v1;

  test('v1 has the 15 spend slugs, in order', () {
    expect(registry.version, 1);
    expect(registry.slugs, _expected);
    expect(registry.slugs, isNot(contains('income')));
    expect(registry.slugs, isNot(contains('investments')));
  });

  test('every category has a display name and an icon key', () {
    for (final c in registry.categories) {
      expect(c.displayName, isNotEmpty, reason: c.slug);
      expect(c.iconKey, isNotEmpty, reason: c.slug);
    }
  });

  test('the registry matches the ledger_entry contract: every slug fits its category pattern', () {
    final schema = jsonDecode(File('../../contracts/sms/v2/ledger_entry.schema.json').readAsStringSync()) as Map;
    final pattern = RegExp((schema['properties'] as Map)['category']['pattern'] as String);
    for (final slug in registry.slugs) {
      expect(pattern.hasMatch(slug), isTrue, reason: slug);
    }
  });

  test('the registry matches the slugs stored today (spend_categories seed)', () {
    final sql = File('../../db/supabase/migrations/0014_seed_reference.sql').readAsStringSync();
    final block = sql.substring(
      sql.indexOf('insert into spend_categories'),
      sql.indexOf('on conflict (slug)'),
    );
    final seeded = RegExp(r"\('([a-z_]+)','([^']+)'").allMatches(block).toList();
    expect([for (final m in seeded) m.group(1)], registry.slugs);
    for (final m in seeded) {
      expect(registry.categoryFor(m.group(1))!.displayName, m.group(2), reason: m.group(1));
    }
  });

  test('every category in the shipped rule files is in the registry', () {
    final rules = jsonDecode(File('../../rules/sms/v2/category_rules.json').readAsStringSync()) as List;
    for (final r in rules) {
      expect(registry.contains((r as Map)['category'] as String), isTrue, reason: '${r['merchantKey']}');
    }
  });

  test('canonicalSlug normalises case and rejects unknown slugs', () {
    expect(registry.canonicalSlug(' Dining '), 'dining');
    expect(registry.canonicalSlug('shopping'), isNull);
    expect(registry.canonicalSlug(null), isNull);
    expect(registry.contains('income'), isFalse);
  });

  group('deprecated aliases', () {
    final next = TaxonomyRegistry(version: 2, categories: const [
      TaxonomyCategory(slug: 'food', displayName: 'Food', iconKey: 'restaurant', deprecatedAliases: ['dining']),
      TaxonomyCategory(slug: 'other', displayName: 'Other', iconKey: 'category'),
    ]);

    test('a deprecated slug resolves to its replacement', () {
      expect(next.canonicalSlug('dining'), 'food');
      expect(next.contains('dining'), isFalse);
      expect(next.categoryFor('dining')!.slug, 'food');
      expect(next.deprecatedAliases, {'dining': 'food'});
    });

    test('an alias that is already a slug is rejected', () {
      expect(
        () => TaxonomyRegistry(version: 2, categories: const [
          TaxonomyCategory(slug: 'a', displayName: 'A', iconKey: 'x'),
          TaxonomyCategory(slug: 'b', displayName: 'B', iconKey: 'x', deprecatedAliases: ['a']),
        ]),
        throwsArgumentError,
      );
    });

    test('a duplicate slug is rejected', () {
      expect(
        () => TaxonomyRegistry(version: 2, categories: const [
          TaxonomyCategory(slug: 'a', displayName: 'A', iconKey: 'x'),
          TaxonomyCategory(slug: 'a', displayName: 'A2', iconKey: 'x'),
        ]),
        throwsArgumentError,
      );
    });

    test('categoryIdForSlug finds a stored row through the alias', () {
      expect(next.categoryIdForSlug('food', {'dining': 'uuid-dining'}), 'uuid-dining');
      expect(next.categoryIdForSlug('dining', {'food': 'uuid-food', 'dining': 'uuid-dining'}), 'uuid-food');
    });
  });

  group('categoryIdForSlug', () {
    final catalogue = {for (final s in _expected) s: 'id-$s'};

    test('maps a slug to the existing category id', () {
      expect(registry.categoryIdForSlug('groceries', catalogue), 'id-groceries');
      expect(registry.categoryIdForSlug('Other', catalogue), 'id-other');
    });

    test('returns null for an unknown slug or one the catalogue lacks', () {
      expect(registry.categoryIdForSlug('shopping', catalogue), isNull);
      expect(registry.categoryIdForSlug('fuel', {'groceries': 'x'}), isNull);
    });
  });
}
