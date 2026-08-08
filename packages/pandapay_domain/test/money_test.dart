import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Money construction', () {
    test('fromRupees converts to paise', () {
      expect(Money.fromRupees(100).paise, 10000);
      expect(Money.fromRupees(99.99).paise, 9999);
      expect(Money.zero().paise, 0);
    });

    test('fromRupees rounds fractional paise', () {
      expect(Money.fromRupees(1.5).paise, 150);
      expect(Money.fromRupees(1.01).paise, 101);
    });
  });

  group('Money arithmetic', () {
    test('add/subtract are paise-exact', () {
      final a = Money.fromRupees(10.50);
      final b = Money.fromRupees(5.25);
      expect((a + b).paise, 1575);
      expect((a - b).paise, 525);
      expect((-a).paise, -1050);
    });

    test('multiply by a rate', () {
      final spend = Money.fromRupees(1000);
      expect((spend * 0.05).paise, 5000); // 5% of ₹1000 = ₹50
    });

    test('comparisons', () {
      final a = Money.fromRupees(10);
      final b = Money.fromRupees(20);
      expect(a < b, isTrue);
      expect(b > a, isTrue);
      expect(a <= a, isTrue);
      expect(a == Money.fromRupees(10), isTrue);
    });
  });

  group('Indian lakh/crore formatting', () {
    test('groups digits in the Indian numbering system', () {
      expect(Money.fromRupees(1234567.89).format(), '₹12,34,567.89');
      expect(Money.fromRupees(1000).format(), '₹1,000.00');
      expect(Money.fromRupees(100).format(), '₹100.00');
      expect(Money.fromRupees(0).format(), '₹0.00');
      expect(Money.fromRupees(12345678).format(), '₹1,23,45,678.00');
    });

    test('negative amounts carry a leading sign before the symbol', () {
      expect(Money.fromRupees(-500).format(), '-₹500.00');
    });

    test('compact formatting uses Cr/L/K suffixes', () {
      expect(Money.fromRupees(150000000).format(compact: true), '₹15Cr');
      expect(Money.fromRupees(250000).format(compact: true), '₹2.5L');
      expect(Money.fromRupees(4500).format(compact: true), '₹4.5K');
      expect(Money.fromRupees(500).format(compact: true), '₹500');
    });

    test('showSymbol: false omits the rupee sign', () {
      expect(Money.fromRupees(100).format(showSymbol: false), '100.00');
    });
  });

  group('H6 Appearance: international number-format toggle', () {
    test('groups digits in plain groups-of-3', () {
      expect(
        Money.fromRupees(1234567.89).format(format: MoneyNumberFormat.international),
        '₹1,234,567.89',
      );
      expect(Money.fromRupees(1000).format(format: MoneyNumberFormat.international), '₹1,000.00');
      expect(Money.fromRupees(100).format(format: MoneyNumberFormat.international), '₹100.00');
      expect(Money.fromRupees(12345678).format(format: MoneyNumberFormat.international), '₹12,345,678.00');
    });

    test('negative amounts and showSymbol:false still work under international grouping', () {
      expect(Money.fromRupees(-500).format(format: MoneyNumberFormat.international), '-₹500.00');
      expect(
        Money.fromRupees(1234567).format(format: MoneyNumberFormat.international, showSymbol: false),
        '1,234,567.00',
      );
    });

    test('default parameter keeps every existing call site unchanged (lakh/crore)', () {
      expect(Money.fromRupees(1234567.89).format(), '₹12,34,567.89');
    });
  });

  group('Money round-trip property test (UA-0.2.4 DoD)', () {
    test('formatting a paise value and re-parsing its digits round-trips '
        'across 0 to 10^9 and negative values', () {
      final rnd = List<int>.generate(500, (i) => i);
      for (final seed in rnd) {
        // Deterministic pseudo-random spread across the required range.
        final magnitude = (seed * 2654435761) % 1000000000;
        for (final sign in [1, -1]) {
          final paise = magnitude * sign;
          final money = Money.fromPaise(paise);
          final formatted = money.format();

          // Strip symbol/sign/commas, reconstruct paise, compare.
          final cleaned = formatted.replaceAll('₹', '').replaceAll(',', '');
          final negative = cleaned.startsWith('-');
          final unsigned = negative ? cleaned.substring(1) : cleaned;
          final parts = unsigned.split('.');
          final reconstructedRupees = int.parse(parts[0]);
          final reconstructedPaise = int.parse(parts[1]);
          final reconstructed =
              (reconstructedRupees * 100 + reconstructedPaise) *
                  (negative ? -1 : 1);

          expect(reconstructed, paise,
              reason: 'round-trip failed for paise=$paise ("$formatted")');
        }
      }
    });

    test('boundary values round-trip', () {
      for (final paise in [0, 1, -1, 99, 100, -100, 1000000000, -1000000000]) {
        final money = Money.fromPaise(paise);
        expect(Money.fromRupees(money.rupees).paise, closeTo(paise, 1));
      }
    });
  });
}
