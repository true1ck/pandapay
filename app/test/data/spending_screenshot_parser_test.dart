import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/data/spending_screenshot_parser.dart';

void main() {
  test(
    'recognizes summary-only category screenshots without inventing rows',
    () {
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
      expect(
        parsed.categorySummaries.map((item) => item.category),
        containsAll(<String>['Unknown', 'Bills', 'Shopping']),
      );
    },
  );

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

  test('receipt photo imports one expense using the printed grand total', () {
    final parsed = parseSpendingScreenshotText('''
      PAID
      Bharathiya
      Plot no 24, Survey no 92/A
      GSTIN: 36AAWFN7032K1ZN
      Date: 16/03/26 Take Away
      Cashier: biller Bill No.: 144392
      Token No.: 162
      No. Item Qty. Price Amount
      1 Plain Dosa 1 79.00 79.00
      Total Qty: 1 Sub Total 79.00
      Gas Charge Fixed 30.00
      Grand Total ₹ 109.00
      Paid via Other UPI
    ''');

    expect(parsed.transactions, hasLength(1));
    expect(parsed.transactions.single.description, 'Bharathiya');
    expect(parsed.transactions.single.date, DateTime(2026, 3, 16));
    expect(parsed.transactions.single.amount.rupees, 109);
  });

  test(
    'receipt with multi-line item table imports its final payable total',
    () {
      final parsed = parseSpendingScreenshotText('''
      ODISHA HOTEL
      AN ODIA CUISINE SINCE 2000
      GSTIN: 21FZPPS1850H1Z4
      Date: 15/04/22
      Cashier: 1 Bill No.: 2760
      Item Qty. Price Amount
      Broiler Chicken Thali 1 380.00 380.00
      Special Veg Thali 1 300.00 300.00
      Paratha 2 30.00 60.00
      Sub Total 740.00
      CGST 2.5% 18.50
      SGST 2.5% 18.50
      Grand Total ₹777.00
      FSSAI Lic No. 1201833000205
    ''');

      expect(parsed.transactions, hasLength(1));
      expect(parsed.transactions.single.description, 'ODISHA HOTEL');
      expect(parsed.transactions.single.date, DateTime(2022, 4, 15));
      expect(parsed.transactions.single.amount.rupees, 777);
    },
  );
}
