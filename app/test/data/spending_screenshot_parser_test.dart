import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/data/spending_screenshot_parser.dart';

void main() {
  test('recognizes summary-only category screenshots without inventing rows', () {
    final parsed = parseSpendingScreenshotText('''
      All transactions
      Oct
      Categories
      Spends ₹27,162
      Unknown
      31 Spends
      ₹24,035
      Bills
      2 Spends
      ₹1,258
      Shopping
      4 Spends
      ₹1,065
    ''');

    expect(parsed.transactions, isEmpty);
    expect(parsed.isSummaryOnly, isTrue);
    expect(parsed.totalSpendRupees, 27162);
    expect(parsed.categorySummaries.map((item) => item.category), containsAll(<String>['Unknown', 'Bills', 'Shopping']));
  });

  test('preserves repeated dated rows for shared duplicate review', () {
    final parsed = parseSpendingScreenshotText('''
      15/10/2026 AMAZON PAY INDIA ₹1,234.50
      15/10/2026 AMAZON PAY INDIA ₹1,234.50
      16 Oct 2026 LOCAL STORE 80
    ''');

    expect(parsed.transactions, hasLength(3));
    expect(parsed.transactions.first.description, 'AMAZON PAY INDIA');
    expect(parsed.transactions.first.amount.rupees, 1234.5);
    expect(parsed.transactions.last.date, DateTime(2026, 10, 16));
  });
}
