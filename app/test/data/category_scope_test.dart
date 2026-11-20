import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/category_scope.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  const travel = SpendCategory(id: 'travel', slug: 'travel', name: 'Travel');
  const sip = SpendCategory(
    id: 'sip',
    slug: 'inv_sip',
    name: 'SIP',
    entryKinds: ['investment'],
  );
  const salary = SpendCategory(
    id: 'salary',
    slug: 'inc_salary',
    name: 'Salary',
    entryKinds: ['income'],
  );
  const indexFunds = SpendCategory(
    id: 'custom:1',
    slug: 'custom:index',
    name: 'Index funds',
    isCustom: true,
    parentCategoryId: 'sip',
  );
  const all = [travel, sip, salary, indexFunds];

  List<String> ids(TxnEntryKind k) =>
      categoriesForKind(all, k).map((c) => c.id).toList();

  test('each kind sees only its own categories', () {
    expect(ids(TxnEntryKind.spend), ['travel']);
    expect(ids(TxnEntryKind.refund), ['travel']);
    expect(ids(TxnEntryKind.investment), ['sip', 'custom:1']);
    expect(ids(TxnEntryKind.income), ['salary']);
    expect(ids(TxnEntryKind.transfer), isEmpty);
  });

  test('a category from another kind does not fit', () {
    expect(categoryFitsKind(all, 'travel', TxnEntryKind.investment), isFalse);
    expect(categoryFitsKind(all, 'sip', TxnEntryKind.investment), isTrue);
    expect(categoryFitsKind(all, null, TxnEntryKind.investment), isTrue);
  });

  test('entry kinds survive json and default to spend', () {
    expect(SpendCategory.fromJson(sip.toJson()).entryKinds, ['investment']);
    expect(
      SpendCategory.fromJson({'id': 'a', 'slug': 'a', 'name': 'A'}).entryKinds,
      ['spend'],
    );
  });
}
