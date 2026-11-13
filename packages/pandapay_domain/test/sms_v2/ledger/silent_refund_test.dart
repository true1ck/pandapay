import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

DateTime d(String s) => DateTime.parse(s);

LimitReading reading(String at, int rupees, {String card = 'axis4321'}) =>
    LimitReading(instrumentId: card, at: d(at), availableMinor: rupees * 100);

SpendOnCard spend(String id, String at, int rupees, {String card = 'axis4321'}) =>
    SpendOnCard(instrumentId: card, eventId: id, at: d(at), amountMinor: rupees * 100);

ExplainedCredit credit(String at, int rupees, {String card = 'axis4321'}) =>
    ExplainedCredit(instrumentId: card, at: d(at), amountMinor: rupees * 100);

void main() {
  group('detectSilentRefunds', () {
    test('the Axis case: a 78,000 spend, the limit comes back with no message', () {
      final found = detectSilentRefunds(
        readings: [
          reading('2026-10-12T10:30:00Z', 500), // after the spend
          reading('2026-11-03T12:00:00Z', 78500), // next reading, weeks later
        ],
        spends: [
          spend('s1200', '2026-10-12T10:00:00Z', 1200),
          spend('s78k', '2026-10-12T10:30:00Z', 78000),
        ],
        credits: const [],
      );
      expect(found, hasLength(1));
      expect(found.single.spendEventId, 's78k');
      expect(found.single.limitRoseByMinor, 7800000);
    });

    test('a card payment explains the rise, so nothing is suggested', () {
      final found = detectSilentRefunds(
        readings: [reading('2026-10-12T10:30:00Z', 500), reading('2026-11-03T12:00:00Z', 78500)],
        spends: [spend('s78k', '2026-10-12T10:30:00Z', 78000)],
        credits: [credit('2026-11-01T10:00:00Z', 78000)],
      );
      expect(found, isEmpty);
    });

    test('a rise that matches no spend is left alone (it may be a limit increase)', () {
      final found = detectSilentRefunds(
        readings: [reading('2026-10-12T10:30:00Z', 500), reading('2026-11-03T12:00:00Z', 50500)],
        spends: [spend('s1', '2026-10-12T10:30:00Z', 1200)],
        credits: const [],
      );
      expect(found, isEmpty);
    });

    test('a small rise is ignored (under 500 rupees)', () {
      final found = detectSilentRefunds(
        readings: [reading('2026-10-12T10:30:00Z', 1000), reading('2026-10-17T16:45:00Z', 1300)],
        spends: [spend('s1', '2026-10-12T10:30:00Z', 300)],
        credits: const [],
      );
      expect(found, isEmpty);
    });

    test('a refund within a few percent of the spend still matches, a far one does not', () {
      List<SuspectedRefund> run(int rise) => detectSilentRefunds(
        readings: [reading('2026-10-01T00:00:00Z', 1000), reading('2026-10-20T00:00:00Z', 1000 + rise)],
        spends: [spend('s1', '2026-09-30T00:00:00Z', 10000)],
        credits: const [],
      );
      expect(run(9500), hasLength(1));
      expect(run(10300), hasLength(1));
      expect(run(8000), isEmpty);
      expect(run(11000), isEmpty);
    });

    test('a spend is suggested once even if two rises could match it', () {
      final found = detectSilentRefunds(
        readings: [
          reading('2026-10-01T00:00:00Z', 1000),
          reading('2026-10-10T00:00:00Z', 11000),
          reading('2026-10-10T01:00:00Z', 1000),
          reading('2026-10-20T00:00:00Z', 11000),
        ],
        spends: [spend('s1', '2026-09-30T00:00:00Z', 10000)],
        credits: const [],
      );
      expect(found, hasLength(1));
    });

    test('a spend already refunded in the records is never suggested', () {
      final found = detectSilentRefunds(
        readings: [reading('2026-10-12T10:30:00Z', 500), reading('2026-11-03T12:00:00Z', 78500)],
        spends: [spend('s78k', '2026-10-12T10:30:00Z', 78000)],
        credits: const [],
        alreadyRefundedEventIds: {'s78k'},
      );
      expect(found, isEmpty);
    });

    test('readings and spends of different cards never mix', () {
      final found = detectSilentRefunds(
        readings: [reading('2026-10-12T10:30:00Z', 500), reading('2026-11-03T12:00:00Z', 78500)],
        spends: [spend('other', '2026-10-12T10:30:00Z', 78000, card: 'hdfc5678')],
        credits: const [],
      );
      expect(found, isEmpty);
    });

    test('a spend after the rise is not paired with it; a very old spend is not either', () {
      final later = detectSilentRefunds(
        readings: [reading('2026-10-01T00:00:00Z', 1000), reading('2026-10-20T00:00:00Z', 11000)],
        spends: [spend('s1', '2026-10-25T00:00:00Z', 10000)],
        credits: const [],
      );
      expect(later, isEmpty);
      final old = detectSilentRefunds(
        readings: [reading('2026-08-01T00:00:00Z', 1000), reading('2026-10-20T00:00:00Z', 11000)],
        spends: [spend('s1', '2026-05-01T00:00:00Z', 10000)],
        credits: const [],
      );
      expect(old, isEmpty);
    });

    test('credits given out of order still explain only the window between two readings', () {
      // 78,000 and 500 land between the readings (given latest first); a 4,000
      // credit before the first reading and one after the second do not count.
      final found = detectSilentRefunds(
        readings: [reading('2026-10-12T10:30:00Z', 500), reading('2026-11-03T12:00:00Z', 78500)],
        spends: [spend('s78k', '2026-10-12T10:30:00Z', 78000)],
        credits: [
          credit('2026-11-10T00:00:00Z', 4000),
          credit('2026-11-03T12:00:00Z', 500), // on the later reading: counts
          credit('2026-10-20T00:00:00Z', 100),
          credit('2026-10-12T10:30:00Z', 4000), // on the earlier reading: does not count
        ],
      );
      // rise 78,000; explained 600; unexplained 77,400 is within 0.9..1.05 of 78,000
      expect(found, hasLength(1));
      expect(found.single.limitRoseByMinor, 7740000);
    });

    test('empty and one-reading inputs are safe', () {
      expect(detectSilentRefunds(readings: const [], spends: const [], credits: const []), isEmpty);
      expect(
        detectSilentRefunds(
          readings: [reading('2026-10-01T00:00:00Z', 1)],
          spends: [spend('s', '2026-09-30T00:00:00Z', 100)],
          credits: const [],
        ),
        isEmpty,
      );
    });
  });
}
