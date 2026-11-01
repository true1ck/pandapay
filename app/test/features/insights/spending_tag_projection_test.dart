import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/spending_tag_projection.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry entry(
  String id,
  int paise, {
  String? categoryId,
  String? userCategoryId,
  String categoryName = 'Other',
  List<TransactionTag> tags = const [],
}) => TransactionEntry(
  id: id,
  amount: Money.fromPaise(paise),
  occurredAt: DateTime(2026, 11, 1),
  source: 'manual',
  status: 'active',
  categoryId: categoryId,
  userCategoryId: userCategoryId,
  categoryName: categoryName,
  tags: tags,
);

void main() {
  const trip = TransactionTag(id: 'trip', name: 'Trip');
  const work = TransactionTag(id: 'work', name: 'Work');

  test('resolves each visible row once and keeps overlapping tag totals', () {
    final first = entry('one', 500, categoryId: 'dining', tags: [trip, work]);
    final second = entry('two', 300, categoryId: 'travel', tags: [trip]);
    var resolutions = 0;

    final groups = projectSpendingTags(
      [first, second],
      tagsFor: (row) {
        resolutions++;
        return row.tags;
      },
    );

    expect(resolutions, 2);
    expect(groups.map((group) => group.tag.id), ['trip', 'work']);
    expect(groups.first.total.paise, 800);
    expect(groups.first.entries, [first, second]);
    expect(groups.last.total.paise, 500);
    expect(groups.first.categories.map((row) => row.categoryId), [
      'dining',
      'travel',
    ]);
    expect(groups.first.entriesForCategory(groups.first.categories.first), [
      first,
    ]);
  });

  test(
    'deduplicates a row tag but keeps last metadata and category identity',
    () {
      const renamed = TransactionTag(id: 'trip', name: 'Holiday');
      final rows = [
        entry(
          'one',
          500,
          userCategoryId: 'food',
          categoryName: 'Meals',
          tags: [trip, trip],
        ),
        entry(
          'two',
          -200,
          userCategoryId: 'food',
          categoryName: 'Meals',
          tags: [renamed],
        ),
        entry(
          'three',
          100,
          categoryId: 'food',
          categoryName: 'Meals',
          tags: [trip],
        ),
      ];
      final groups = projectSpendingTags(rows, tagsFor: (row) => row.tags);

      expect(groups.single.tag.name, 'Trip');
      expect(groups.single.total.paise, 400);
      expect(groups.single.entries.length, 3);
      expect(groups.single.categories.map((row) => row.categoryId), [
        'custom:food',
        'food',
      ]);
      expect(groups.single.categories.first.total.paise, 300);
      expect(
        groups.single.entriesForCategory(groups.single.categories.first),
        rows.take(2),
      );
      expect(() => groups.single.entries.clear(), throwsUnsupportedError);
    },
  );

  test('uses current resolver tags and ignores untagged rows', () {
    final rows = [
      entry('one', 100, tags: [trip]),
      entry('two', 200),
    ];
    final groups = projectSpendingTags(
      rows,
      tagsFor: (row) => row.id == 'one' ? [work] : [],
    );
    expect(groups.single.tag.id, 'work');
    expect(groups.single.total.paise, 100);
    expect(projectSpendingTags(rows, tagsFor: (_) => []), isEmpty);
  });
}
