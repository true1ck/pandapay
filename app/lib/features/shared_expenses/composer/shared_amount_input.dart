import 'package:pandapay_domain/pandapay_domain.dart';

enum SharedInputState { empty, incomplete, valid, invalid }

/// Editable decimal text is separate from exact wire money. Never round an
/// invalid or unfinished edit, or silently keep its previous valid amount.
class SharedDecimalInput {
  final SharedInputState state;
  final int? units;
  const SharedDecimalInput._(this.state, [this.units]);
  bool get isValid => state == SharedInputState.valid;
  static SharedDecimalInput parse(
    String raw, {
    int precision = 2,
    int maxUnits = 1000000000,
    bool allowZero = true,
  }) {
    if (precision < 0 ||
        precision > 2 ||
        maxUnits < 0 ||
        maxUnits > 9007199254740991) {
      throw ArgumentError('Unsupported decimal range');
    }
    if (raw.length > 32) {
      return const SharedDecimalInput._(SharedInputState.invalid);
    }
    final text = raw.trim();
    if (text.isEmpty) return const SharedDecimalInput._(SharedInputState.empty);
    if (precision > 0 && RegExp(r'^[0-9]+\.$').hasMatch(text)) {
      return const SharedDecimalInput._(SharedInputState.incomplete);
    }
    final pattern = precision == 0
        ? r'^[0-9]+$'
        : '^[0-9]+(?:\\.[0-9]{1,$precision})?\$';
    if (!RegExp(pattern).hasMatch(text)) {
      return const SharedDecimalInput._(SharedInputState.invalid);
    }
    final parts = text.split('.'),
        factor = BigInt.from(
          precision == 0
              ? 1
              : precision == 1
              ? 10
              : 100,
        );
    final amount =
        BigInt.parse(parts[0]) * factor +
        BigInt.parse(
          parts.length == 1 ? '0' : parts[1].padRight(precision, '0'),
        );
    if (amount > BigInt.from(maxUnits) || !allowZero && amount == BigInt.zero) {
      return const SharedDecimalInput._(SharedInputState.invalid);
    }
    return SharedDecimalInput._(SharedInputState.valid, amount.toInt());
  }
}

/// Exact editable value, without number grouping or a floating point roundtrip.
String sharedRupeesText(Money money) {
  final amount = money.paise.abs();
  return '${money.isNegative ? '-' : ''}${amount ~/ 100}.${(amount % 100).toString().padLeft(2, '0')}';
}

/// Turns what a person typed into the plain `1234.50` form [SharedDecimalInput]
/// reads. Removes the rupee sign and spaces, and reads a comma by its shape:
///
///  * `1,200` and `1,20,000` are digit grouping, so the commas go;
///  * `12,5` and `12,50` use the comma as the decimal point (some keyboards do);
///  * anything else is left untouched so the parser reports it as invalid
///    instead of silently turning ₹12,50 into ₹1,250.
String sharedNormalizeAmountText(String raw) {
  final text = raw.replaceAll(RegExp(r'[\s\u00a0₹]'), '');
  if (!text.contains(',')) return text;
  if (text.contains('.')) {
    // `1,200.50`: commas are grouping only when they sit before the point.
    return RegExp(r'^\d{1,3}(,\d{2,3})+\.\d*$').hasMatch(text)
        ? text.replaceAll(',', '')
        : text;
  }
  if (RegExp(r'^\d+,\d{1,2}$').hasMatch(text)) return text.replaceAll(',', '.');
  if (RegExp(r'^\d{1,3}(,\d{2,3})+$').hasMatch(text)) {
    return text.replaceAll(',', '');
  }
  return text;
}
