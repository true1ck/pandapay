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

  /// Indian numbering: groups of 2 after the first group of 3 from the right.
  /// e.g. 1234567.89 -> "12,34,567.89"
  String format({bool compact = false, bool showSymbol = true}) {
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

    final grouped = _groupIndian(rupeePart.toString());
    final paiseStr = paisePart.toString().padLeft(2, '0');
    return '$sign$symbol$grouped.$paiseStr';
  }

  static String _trimZeros(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
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
