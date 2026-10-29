import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_device_probe_summary.dart';

void main() {
  Map<String, Object> row(String body) => {
    'id': 'test',
    'body': body,
    'sender': 'VM-HDFCBK',
    'capturedAt': '2026-10-26T10:00:00Z',
    'receivedAt': '2026-08-01T04:00:00Z',
  };

  test('real-shape input needs no synthetic marker and keeps original date', () {
    final result = IosDeviceProbeSummary.fromMap(
      row(
        'Rs 349.00 spent on HDFC Bank Card ending 1234 at BUNDL TECHNOLOGIES.',
      ),
    );
    expect(result.event, 'transaction');
    expect(result.amount, '₹349.00');
    expect(result.merchant, 'BUNDL TECHNOLOGIES');
    expect(result.originalDate, DateTime.utc(2026, 8, 1, 4));
    expect(result.senderKnown, isTrue);
  });

  test('security and promotion inputs do not produce financial summaries', () {
    expect(
      IosDeviceProbeSummary.fromMap(
        row('OTP 000000 for Rs 349 at TEST STORE. Do not share.'),
      ).event,
      'ignored',
    );
    expect(
      IosDeviceProbeSummary.fromMap(
        row('Enjoy an exclusive offer! Apply now for 10% off.'),
      ).event,
      'ignored',
    );
  });

  test('unresolved transaction keeps review amount and merchant suggestions', () {
    final result = IosDeviceProbeSummary.fromMap(
      row('Debit alert: INR 875.50 spent at Green Basket.'),
    );
    expect(result.event, 'unknown');
    expect(result.amount, '₹875.50');
    expect(result.merchant, 'Green Basket');
  });
}
