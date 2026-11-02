import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/foreign_payment.dart';

void main() {
  ForeignPayment? parse(String body) => ForeignPaymentExtractor.fromSms(
    namespace: 'user:a',
    sourceKey: 'a' * 64,
    sender: 'BANK-S',
    body: body,
    receivedAt: DateTime.utc(2026, 3, 5),
  );
  test(
    'original-currency prices keep accounting precision and support suffix codes',
    () {
      for (final pair in [
        ('USD 20.12', 'USD', '20.12'),
        ('IQD 20.123', 'IQD', '20.123'),
        ('PKR 20.12', 'PKR', '20.12'),
        ('20.00 EUR', 'EUR', '20'),
      ]) {
        final row = parse(
          '${pair.$1} spent using Bank Card XX1234 at SYNTHETIC. Avl Limit INR 100000.',
        )!;
        expect(row.originalCurrency, pair.$2);
        expect(row.originalAmount, pair.$3);
        expect(row.billedInr, isNull);
      }
    },
  );
  test('ambiguous symbols and malformed original amounts remain unresolved', () {
    final malformed = parse(
      'USD .00 spent using Bank Card XX1234 at SYNTHETIC. Avl Limit INR 286388.46.',
    )!;
    expect(malformed.originalAmount, isNull);
    expect(malformed.originalCurrency, 'USD');
    expect(malformed.valuationStatus, 'awaiting_amount');
    final ambiguous = parse(r'$20 spent using Bank Card XX1234 at SYNTHETIC.')!;
    expect(ambiguous.originalCurrency, isNull);
    expect(ambiguous.originalAmount, '20');
  });
  test(
    'declines, future notices, verification holds and foreign limits do not become payments',
    () {
      for (final body in [
        'USD 20 purchase declined on Card XX1234.',
        'USD 20 will be charged to Card XX1234 tomorrow.',
        'USD 20 authorization hold on Card XX1234 for purchase.',
        'USD 0.00 charged to Card XX1234 for verification.',
        'INR 50 spent using Card XX1234. Available limit USD 5000.',
        'USD 20 subscription price. Buy with your Card today.',
        'USD 2000 credited to your Bank account XX1234 by an employer.',
      ])
        expect(parse(body), isNull, reason: body);
    },
  );
  test(
    'independently printed billed INR is retained; refunds keep separate direction',
    () {
      final row = parse(
        'USD 20 spent using Bank Card XX1234 at SYNTHETIC. Billed INR 1742. Avl Limit INR 100000.',
      )!;
      expect(row.billedInr!.rupees, 1742);
      expect(
        parse('USD 5 refunded to Bank Card XX1234 for SYNTHETIC.')!.direction,
        'refund',
      );
    },
  );
}
