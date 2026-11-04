final maxExpenseMinor = BigInt.from(1000000000);
final maxAggregateMinor = BigInt.parse('9007199254740991');

/// Stable code and field path only; private input never appears in the error.
class SharedExpenseException implements Exception {
  final String code;
  final String field;
  const SharedExpenseException(this.code, this.field);

  @override
  String toString() => '$code at $field';
}

Never fail(String code, String field) =>
    throw SharedExpenseException(code, field);

bool matches(RegExp pattern, Object? value) =>
    value is String && pattern.firstMatch(value)?.group(0) == value;

Map<String, Object?> record(
  Object? value,
  List<String> required, {
  List<String> optional = const [],
  String field = r'$',
  String code = 'INVALID_INPUT',
}) {
  if (value is! Map ||
      required.any((key) => !value.containsKey(key)) ||
      value.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    fail(code, field);
  }
  return value.cast<String, Object?>();
}

BigInt amount(
  Object? value,
  String field, {
  BigInt? max,
  bool positive = false,
  String overflow = 'AMOUNT_LIMIT_EXCEEDED',
}) {
  if (value is! String ||
      value.length > 16 ||
      !matches(RegExp(r'^(0|[1-9][0-9]*)$'), value)) {
    fail('INVALID_AMOUNT', field);
  }
  final parsed = BigInt.parse(value);
  if (positive && parsed == BigInt.zero) fail('INVALID_AMOUNT', field);
  if (parsed > (max ?? maxExpenseMinor)) fail(overflow, field);
  return parsed;
}

String member(Object? value, String field) {
  if (value is! String ||
      value.length > 64 ||
      !matches(RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$'), value)) {
    fail('INVALID_MEMBER_ID', field);
  }
  return value;
}

void currency(Object? value) {
  if (value != 'INR') fail('UNSUPPORTED_CURRENCY', 'currency');
}

List<Object?> count(Object? value, int max, String code, String field) {
  if (value is! List || value.isEmpty || value.length > max) fail(code, field);
  return value.cast<Object?>();
}

Map<String, int> order(Object? value, Set<String> members, String field) {
  if (value is! List ||
      value.length != members.length ||
      value.toSet().length != value.length ||
      value.any((id) => id is! String || !members.contains(id))) {
    fail('INVALID_TIE_ORDER', field);
  }
  return {for (var i = 0; i < value.length; i++) value[i] as String: i};
}
