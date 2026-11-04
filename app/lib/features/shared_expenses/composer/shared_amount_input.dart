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
