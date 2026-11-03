import 'package:pandapay_domain/sms_v2.dart';

int _counter = 0;

String _hex64() => (_counter++).toRadixString(16).padLeft(64, '0');

/// Synthetic mention.
InstrumentMention mention({
  InstrumentKind? kind = InstrumentKind.creditCard,
  String? issuer = 'hdfc',
  String? mask = '5678',
  int? maskLength,
  String? product,
}) => InstrumentMention(
  kind: kind,
  issuerSlug: issuer,
  maskDigits: mask,
  maskLength: maskLength ?? mask?.length,
  productName: product,
  raw: mask == null ? null : 'x$mask',
);

/// Builds a valid synthetic fact from JSON parts.
Fact fact(
  String type, {
  required String observedAt,
  String? occurredAt,
  InstrumentMention? instrument,
  Map<String, Object?>? counterparty,
  List<Map<String, Object?>> amounts = const [],
  Map<String, Object?> attrs = const {},
}) {
  return Fact.fromJson({
    'contractVersion': '2.0',
    'factId': _hex64(),
    'sourceKey': 'sms:synthetic:$_counter',
    'factType': type,
    'observedAt': observedAt,
    'occurredAt': occurredAt,
    'instrument': instrument?.toJson(),
    'counterparty': counterparty,
    'amounts': amounts,
    'references': <String, Object?>{},
    'attrs': attrs,
    'provenance': {
      'engine': 'rules',
      'ruleId': 'SYN',
      'ruleVersion': 1,
      'bundleVersion': 1,
      'engineVersion': '2.0.0',
      'appVersion': '1.0.0+1',
    },
    'evidence': <Object?>[],
    'confidence': 0.99,
  });
}

Fact balance(
  String role,
  int minor, {
  required String asOf,
  String unit = 'INR',
  InstrumentMention? instrument,
  String? observedAt,
}) => fact(
  'balance_snapshot',
  observedAt: observedAt ?? asOf,
  occurredAt: asOf,
  instrument: instrument ?? mention(),
  amounts: [
    {'role': role, 'minor': minor, 'unit': unit},
  ],
  attrs: {'asOf': asOf},
);

Fact limit(
  int minor, {
  required String at,
  String reason = 'increase',
  int? previousMinor,
  InstrumentMention? instrument,
}) => fact(
  'limit_change',
  observedAt: at,
  occurredAt: at,
  instrument: instrument ?? mention(),
  amounts: [
    {'role': 'credit_limit', 'minor': minor, 'unit': 'INR'},
  ],
  attrs: {'reason': reason, 'previousMinor': ?previousMinor},
);

Fact hint(
  String hint, {
  required String at,
  InstrumentMention? instrument,
  Map<String, Object?>? counterparty,
}) => fact(
  'instrument_hint',
  observedAt: at,
  instrument: instrument ?? mention(),
  counterparty: counterparty,
  attrs: {'hint': hint},
);

Fact movement({required String at, InstrumentMention? instrument, String direction = 'debit'}) =>
    fact(
      'movement',
      observedAt: at,
      instrument: instrument ?? mention(),
      amounts: [
        {'role': 'posted', 'minor': 10000, 'unit': 'INR'},
      ],
      attrs: {'direction': direction, 'purpose': 'purchase', 'rail': 'card'},
    );

int _idCounter = 0;

/// A stored-looking instrument for tests.
Instrument instrument({
  InstrumentKind kind = InstrumentKind.creditCard,
  String issuer = 'hdfc',
  String? mask = '5678',
  InstrumentStatus status = InstrumentStatus.confirmed,
  String? id,
  DateTime? at,
}) {
  final t = at ?? DateTime.utc(2026, 11, 1);
  return Instrument(
    instrumentId:
        id ?? '00000000-0000-4000-8000-${(_idCounter++).toRadixString(16).padLeft(12, '0')}',
    kind: kind,
    issuerSlug: issuer,
    maskDigits: mask,
    displayName: defaultDisplayName(defaultIssuerLabel(issuer), kind, mask),
    status: status,
    firstSeenAt: t,
    lastSeenAt: t,
    evidenceCount: 0,
  );
}
