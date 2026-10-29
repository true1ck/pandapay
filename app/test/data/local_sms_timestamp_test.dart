import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';

void main() {
  const prefix = 'Union Bank of India A/c *1234 Debited Rs:25.00 on ';
  const suffix =
      ' by Mob Bk ref no SYNTHETIC, Fvg: TEST SHOP Avl Bal Rs:1000.00';
  final received = DateTime(2026, 10, 29, 22, 38, 38);

  LocalSmsObservation? parse(String date) => LocalSmsParser.parse(
    namespace: 'user:synthetic-timestamps',
    sender: 'VM-UBINBK',
    body: '$prefix$date$suffix',
    receivedAt: received,
  );

  test(
    'forwarded bank SMS preserves printed transaction time and new receive time',
    () {
      final transaction = parse('21-10-2026 01:26:04')!.transaction!;
      expect(transaction.occurredAt, DateTime(2026, 10, 21, 1, 26, 4));
      expect(transaction.smsReceivedAt, received);
      expect(
        transaction.toJson()['sms_received_at'],
        received.toIso8601String(),
      );
    },
  );

  test('date-only and invalid clock keep date-only precision', () {
    for (final stamp in [
      '21-10-2026',
      '21-10-2026 25:26:04',
      '21-10-2026 01:60:04',
    ]) {
      expect(parse(stamp)!.transaction!.occurredAt, DateTime(2026, 10, 21));
    }
  });

  test('explicit IST is interpreted independently of device timezone', () {
    expect(
      parse('21-10-2026 01:26:04 IST')!.transaction!.occurredAt.toUtc(),
      DateTime.utc(2026, 10, 20, 19, 56, 4),
    );
  });

  test('future printed date does not replace receive-time fallback', () {
    expect(parse('31-10-2026 01:26:04')!.transaction!.occurredAt, received);
  });

  test('12-hour clock and explicit offsets preserve their meaning', () {
    expect(
      parse('21-10-2026 01:26:04 PM')!.transaction!.occurredAt,
      DateTime(2026, 10, 21, 13, 26, 4),
    );
    expect(
      parse('21-10-2026 12:26 AM')!.transaction!.occurredAt,
      DateTime(2026, 10, 21, 0, 26),
    );
    expect(
      parse('21-10-2026 01:26:04 +05:30')!.transaction!.occurredAt.toUtc(),
      DateTime.utc(2026, 10, 20, 19, 56, 4),
    );
    expect(
      parse('21-10-2026 01:26:04 UTC')!.transaction!.occurredAt.toUtc(),
      DateTime.utc(2026, 10, 21, 1, 26, 4),
    );
  });
}
