import 'validation.dart' as v;

/// Validated identity, not source ownership, funding eligibility or settlement
/// proof. Canonical source admission still requires authenticated server checks.
final class SharedExpenseSourceReference {
  final Map<String, String> _value;
  SharedExpenseSourceReference._(Map<String, String> value)
    : _value = Map.unmodifiable(value);

  String get kind => _value['kind']!;
  String get ownerAccountId => _value['ownerAccountId']!;
  String? get canonicalLegacySplitTarget => _value['canonicalTransactionId'];
  Map<String, String> toJson() => Map.of(_value);

  factory SharedExpenseSourceReference.parse(Object? value) {
    const error = 'INVALID_SOURCE_REFERENCE';
    final input = v.record(
      value,
      ['kind', 'ownerAccountId'],
      code: error,
      optional: [
        'canonicalTransactionId',
        'sourceVersion',
        'sourceKey',
        'eventId',
        'localProjectionId',
        'foreignPaymentId',
      ],
    );
    final List<String> required, optional;
    switch (input['kind']) {
      case 'legacy_transaction':
        required = [
          'kind',
          'ownerAccountId',
          'canonicalTransactionId',
          'sourceVersion',
        ];
        optional = ['sourceKey'];
      case 'sms_v2_event':
        required = ['kind', 'ownerAccountId', 'eventId'];
        optional = [
          'localProjectionId',
          'canonicalTransactionId',
          'sourceVersion',
          'sourceKey',
        ];
      case 'confirmed_foreign_payment':
        required = [
          'kind',
          'ownerAccountId',
          'foreignPaymentId',
          'canonicalTransactionId',
          'sourceVersion',
        ];
        optional = ['sourceKey'];
      default:
        v.fail(error, 'kind');
    }
    v.record(input, required, optional: optional, code: error);
    void token(String key, RegExp pattern, int max) {
      final item = input[key];
      if (item is! String || item.length > max || !v.matches(pattern, item)) {
        v.fail(error, key);
      }
    }

    for (final key in [
      'ownerAccountId',
      'canonicalTransactionId',
      'foreignPaymentId',
    ]) {
      if (input.containsKey(key)) {
        token(
          key,
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ),
          36,
        );
      }
    }
    for (final key in ['sourceVersion', 'sourceKey']) {
      if (input.containsKey(key)) {
        token(key, RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]*$'), 128);
      }
    }
    if (input['kind'] == 'sms_v2_event') {
      token('eventId', RegExp(r'^[a-f0-9]{64}$'), 64);
      if (input.containsKey('localProjectionId') &&
          input['localProjectionId'] != 'v2:${input['eventId']}') {
        v.fail(error, 'localProjectionId');
      }
      if (input.containsKey('canonicalTransactionId') !=
          input.containsKey('sourceVersion')) {
        v.fail(error, 'canonicalTransactionId');
      }
    }
    return SharedExpenseSourceReference._(input.cast<String, String>());
  }
}
