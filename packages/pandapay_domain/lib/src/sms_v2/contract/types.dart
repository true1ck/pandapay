import 'enums.dart';
import 'json_util.dart';

/// Original currency amount of a foreign spend.
final class OriginalAmount extends JsonValue {
  const OriginalAmount({required this.minor, required this.currency});

  factory OriginalAmount.fromJson(Json j) =>
      OriginalAmount(minor: (j['minor'] as num).toInt(), currency: j['currency'] as String);

  final int minor;
  final String currency;

  @override
  Json toJson() => {'minor': minor, 'currency': currency};
}

/// A quantity with a role. `minor` is paise for INR and whole points for POINTS.
final class Amount extends JsonValue {
  const Amount({required this.role, required this.minor, required this.unit, this.original});

  factory Amount.fromJson(Json j) => Amount(
        role: AmountRole.fromWire(j['role'] as String),
        minor: (j['minor'] as num).toInt(),
        unit: j['unit'] as String,
        original: j['original'] == null
            ? null
            : OriginalAmount.fromJson(j['original'] as Json),
      );

  final AmountRole role;
  final int minor;

  /// `INR`, `POINTS` or an ISO currency code.
  final String unit;
  final OriginalAmount? original;

  @override
  Json toJson() => {
        'role': role.wire,
        'minor': minor,
        'unit': unit,
        if (original != null) 'original': original!.toJson(),
      };
}

/// Which of the user's accounts or cards a message is about. Any field may be
/// null. `raw` stays on the phone.
final class InstrumentMention extends JsonValue {
  const InstrumentMention({
    this.kind,
    this.issuerSlug,
    this.maskDigits,
    this.maskLength,
    this.productName,
    this.raw,
  });

  factory InstrumentMention.fromJson(Json j) => InstrumentMention(
        kind: j['kind'] == null ? null : InstrumentKind.fromWire(j['kind'] as String),
        issuerSlug: j['issuerSlug'] as String?,
        maskDigits: j['maskDigits'] as String?,
        maskLength: (j['maskLength'] as num?)?.toInt(),
        productName: j['productName'] as String?,
        raw: j['raw'] as String?,
      );

  final InstrumentKind? kind;
  final String? issuerSlug;
  final String? maskDigits;
  final int? maskLength;
  final String? productName;
  final String? raw;

  @override
  Json toJson() => {
        'kind': kind?.wire,
        'issuerSlug': issuerSlug,
        'maskDigits': maskDigits,
        'maskLength': maskLength,
        'productName': productName,
        'raw': raw,
      };
}

/// The other side of a movement.
final class Counterparty extends JsonValue {
  const Counterparty({this.name, this.vpa, this.kind, this.accountMask});

  factory Counterparty.fromJson(Json j) => Counterparty(
        name: j['name'] as String?,
        vpa: j['vpa'] as String?,
        kind: j['kind'] == null ? null : CounterpartyKind.fromWire(j['kind'] as String),
        accountMask: j['accountMask'] as String?,
      );

  final String? name;
  final String? vpa;
  final CounterpartyKind? kind;
  final String? accountMask;

  @override
  Json toJson() => {
        'name': name,
        'vpa': vpa,
        'kind': kind?.wire,
        'accountMask': accountMask,
      };
}

/// Who produced a fact.
final class Provenance extends JsonValue {
  const Provenance({
    required this.engine,
    required this.ruleId,
    required this.ruleVersion,
    required this.bundleVersion,
    required this.engineVersion,
    required this.appVersion,
    this.model,
  });

  factory Provenance.fromJson(Json j) => Provenance(
        engine: Engine.fromWire(j['engine'] as String),
        ruleId: j['ruleId'] as String,
        ruleVersion: (j['ruleVersion'] as num).toInt(),
        bundleVersion: (j['bundleVersion'] as num).toInt(),
        engineVersion: j['engineVersion'] as String,
        appVersion: j['appVersion'] as String,
        model: j['model'] as String?,
      );

  final Engine engine;
  final String ruleId;
  final int ruleVersion;
  final int bundleVersion;
  final String engineVersion;
  final String appVersion;
  final String? model;

  @override
  Json toJson() => {
        'engine': engine.wire,
        'ruleId': ruleId,
        'ruleVersion': ruleVersion,
        'bundleVersion': bundleVersion,
        'engineVersion': engineVersion,
        'appVersion': appVersion,
        if (model != null) 'model': model,
      };
}

/// A character range in the original body that justified a field. Stays on the
/// phone and is never uploaded.
final class Span extends JsonValue {
  const Span({required this.field, required this.start, required this.end});

  factory Span.fromJson(Json j) => Span(
        field: j['field'] as String,
        start: (j['start'] as num).toInt(),
        end: (j['end'] as num).toInt(),
      );

  final String field;
  final int start;
  final int end;

  @override
  Json toJson() => {'field': field, 'start': start, 'end': end};
}
