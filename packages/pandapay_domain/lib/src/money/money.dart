/// H6 (Appearance): the spec's only two documented number-grouping options
/// (§Localization: "Indian number formatting (lakh/crore)") — [lakhCrore]
/// is the existing default (groups of 2 after the first 3 from the right),
/// [international] is the plain groups-of-3 alternative.
enum MoneyNumberFormat { lakhCrore, international }

/// Indian Rupee amount stored as an integer number of paise.
///
/// Never use `double` for currency — paise avoids float rounding entirely.
/// product-plan §17 / Userappimplementation_plan.md UA-0.2.1.
class Money {
  /// Integer paise. Negative values represent a debit/refund.
  final int paise;

  const Money.fromPaise(this.paise);

  const Money.zero() : paise = 0;

  factory Money.fromRupees(num rupees) {
    return Money.fromPaise((rupees * 100).round());
  }

  double get rupees => paise / 100;

  bool get isNegative => paise < 0;
  bool get isZero => paise == 0;

  Money operator +(Money other) => Money.fromPaise(paise + other.paise);
  Money operator -(Money other) => Money.fromPaise(paise - other.paise);
  Money operator -() => Money.fromPaise(-paise);
  Money operator *(num factor) => Money.fromPaise((paise * factor).round());

  bool operator <(Money other) => paise < other.paise;
  bool operator <=(Money other) => paise <= other.paise;
  bool operator >(Money other) => paise > other.paise;
  bool operator >=(Money other) => paise >= other.paise;

  @override
  bool operator ==(Object other) => other is Money && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;

  /// Indian numbering by default: groups of 2 after the first group of 3
  /// from the right, e.g. 1234567.89 -> "12,34,567.89". Pass
  /// `format: MoneyNumberFormat.international` for plain groups-of-3
  /// (H6/Appearance's number-format toggle) — e.g. "1,234,567.89".
  /// [compact] (Cr/L/K suffixes) is Indian-numbering-specific and ignores
  /// [format] — there's no equivalent short form defined for international
  /// grouping in this app.
  /// [hidePaise] drops the `.00` when the amount is a whole number of
  /// rupees — the design deck writes headline figures as "₹125"/"₹1,842",
  /// never "₹125.00", and a two-decimal tail on a 44pt display number eats
  /// a third of the width for no information. Non-zero paise are always
  /// shown regardless, so nothing is ever silently rounded away.
  String format({
    bool compact = false,
    bool showSymbol = true,
    bool hidePaise = false,
    MoneyNumberFormat format = MoneyNumberFormat.lakhCrore,
  }) {
    final negative = paise < 0;
    final absPaise = paise.abs();
    final rupeePart = absPaise ~/ 100;
    final paisePart = absPaise % 100;

    final symbol = showSymbol ? '₹' : '';
    final sign = negative ? '-' : '';

    if (compact) {
      final value = absPaise / 100;
      String compactStr;
      if (value >= 10000000) {
        compactStr = '${_trimZeros(value / 10000000)}Cr';
      } else if (value >= 100000) {
        compactStr = '${_trimZeros(value / 100000)}L';
      } else if (value >= 1000) {
        compactStr = '${_trimZeros(value / 1000)}K';
      } else {
        compactStr = _trimZeros(value);
      }
      return '$sign$symbol$compactStr';
    }

    final grouped = format == MoneyNumberFormat.international
        ? _groupInternational(rupeePart.toString())
        : _groupIndian(rupeePart.toString());
    if (hidePaise && paisePart == 0) return '$sign$symbol$grouped';
    final paiseStr = paisePart.toString().padLeft(2, '0');
    return '$sign$symbol$grouped.$paiseStr';
  }

  static String _trimZeros(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// Plain groups-of-3 from the right, e.g. "1234567" -> "1,234,567".
  static String _groupInternational(String digits) {
    if (digits.length <= 3) return digits;
    final groups = <String>[];
    var rest = digits;
    while (rest.length > 3) {
      groups.insert(0, rest.substring(rest.length - 3));
      rest = rest.substring(0, rest.length - 3);
    }
    groups.insert(0, rest);
    return groups.join(',');
  }

  static String _groupIndian(String digits) {
    if (digits.length <= 3) return digits;
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    return '${groups.join(',')},$last3';
  }

  @override
  String toString() => format();
}
