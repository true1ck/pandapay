import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/upi_mcc_category.dart';

SpendCategory category(String id, String slug) =>
    SpendCategory(id: id, slug: slug, name: slug);

void main() {
  final categories = [
    category('fuel-id', 'fuel'),
    category('grocery-id', 'groceries'),
    category('dining-id', 'dining'),
    category('online-id', 'online'),
  ];

  test('maps high-confidence fuel, grocery, dining and online MCCs', () {
    expect(categoryIdForUpiMcc('5541', categories), 'fuel-id');
    expect(categoryIdForUpiMcc('5411', categories), 'grocery-id');
    expect(categoryIdForUpiMcc('5812', categories), 'dining-id');
    expect(categoryIdForUpiMcc('5311', categories), 'online-id');
  });

  test('does not guess when the MCC is missing, malformed or unsupported', () {
    expect(categoryIdForUpiMcc(null, categories), isNull);
    expect(categoryIdForUpiMcc('', categories), isNull);
    expect(categoryIdForUpiMcc('0000', categories), isNull);
    expect(categoryIdForUpiMcc('9999', categories), isNull);
    // 5999 is "Miscellaneous and Specialty Retail Stores". It is a broad
    // network classification, not proof that this is online shopping or
    // groceries, so the local resolver must leave it for a directory/provider
    // lookup instead of presenting a confident but wrong category.
    expect(categoryIdForUpiMcc('5999', categories), isNull);
  });

  test(
    'returns null when the API catalogue does not contain the mapped slug',
    () {
      expect(
        categoryIdForUpiMcc('5541', [category('other-id', 'other')]),
        isNull,
      );
    },
  );
}
