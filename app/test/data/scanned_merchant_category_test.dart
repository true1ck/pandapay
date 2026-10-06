import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/scanned_merchant_category.dart';

SpendCategory category(String id, String slug) =>
    SpendCategory(id: id, slug: slug, name: slug);

void main() {
  final categories = [
    category('fuel-id', 'fuel'),
    category('dining-id', 'dining'),
    category('groceries-id', 'groceries'),
    category('online-id', 'online'),
    category('insurance-id', 'insurance'),
  ];

  test('MCC wins over merchant text', () {
    final hint = inferScannedMerchantCategory(
      merchantName: 'Paytm',
      vpa: 'paytm@upi',
      mcc: '5541',
    );

    expect(hint?.slug, 'fuel');
    expect(hint?.source, ScannedMerchantCategorySource.mcc);
    expect(
      categoryIdForScannedMerchant(
        merchantName: 'Paytm',
        vpa: 'paytm@upi',
        mcc: '5541',
        categories: categories,
      ),
      'fuel-id',
    );
  });

  test('merchant names classify common QR merchants without MCC', () {
    expect(
      categoryIdForScannedMerchant(
        merchantName: 'QUALITY FUEL STATION',
        vpa: 'merchant@okaxis',
        categories: categories,
      ),
      'fuel-id',
    );
    expect(
      categoryIdForScannedMerchant(
        merchantName: 'Abhiksha Palace',
        vpa: 'merchant@ybl',
        categories: categories,
      ),
      'dining-id',
    );
  });

  test('a meaningful VPA can classify when the display name is generic', () {
    final hint = inferScannedMerchantCategory(
      merchantName: 'Paytm',
      vpa: 'swiggy@upi',
    );

    expect(hint?.slug, 'dining');
    expect(hint?.source, ScannedMerchantCategorySource.vpa);
  });

  test('generic payment handles do not invent a category', () {
    expect(
      inferScannedMerchantCategory(merchantName: 'Paytm', vpa: 'paytm@upi'),
      isNull,
    );
    expect(
      inferScannedMerchantCategory(
        merchantName: 'Unknown local merchant',
        vpa: 'merchant@okaxis',
      ),
      isNull,
    );
  });
}
