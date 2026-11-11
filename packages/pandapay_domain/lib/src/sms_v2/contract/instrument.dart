import 'enums.dart';
import 'errors.dart';
import 'json_util.dart';
import 'validate.dart';

/// Other names an instrument is known by.
final class InstrumentAliases extends JsonValue {
  InstrumentAliases({
    List<String> senders = const [],
    List<String> vpas = const [],
    List<String> productNames = const [],
  })  : senders = List.unmodifiable(senders),
        vpas = List.unmodifiable(vpas),
        productNames = List.unmodifiable(productNames);

  factory InstrumentAliases.fromJson(Json j) => InstrumentAliases(
        senders: (j['senders'] as List).cast<String>(),
        vpas: (j['vpas'] as List).cast<String>(),
        productNames: (j['productNames'] as List).cast<String>(),
      );

  final List<String> senders;
  final List<String> vpas;
  final List<String> productNames;

  @override
  Json toJson() => {'senders': [...senders], 'vpas': [...vpas], 'productNames': [...productNames]};
}

/// One account, card or wallet the user owns. The identity key is
/// `(profile, kind, issuerSlug, maskDigits)`.
final class Instrument extends JsonValue {
  Instrument({
    required this.instrumentId,
    required this.kind,
    required this.issuerSlug,
    this.maskDigits,
    this.maskLength,
    required this.displayName,
    required this.status,
    this.userCardId,
    this.parentInstrumentId,
    InstrumentAliases? aliases,
    this.creditLimitMinor,
    this.creditLimitSource,
    this.creditLimitAt,
    this.availableMinor,
    this.availableAt,
    this.pointsBalance,
    this.pointsAt,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.evidenceCount,
  }) : aliases = aliases ?? InstrumentAliases();

  /// Parses and validates [json]; throws a [ContractException] on violations.
  factory Instrument.fromJson(Map<String, Object?> json) {
    final r = validateInstrumentJson(json);
    if (!r.ok) throw ContractException(r.errors);
    DateTime? t(String k) => json[k] == null ? null : parseUtc(json[k] as String);
    return Instrument(
      instrumentId: json['instrumentId'] as String,
      kind: InstrumentKind.fromWire(json['kind'] as String),
      issuerSlug: json['issuerSlug'] as String,
      maskDigits: json['maskDigits'] as String?,
      maskLength: (json['maskLength'] as num?)?.toInt(),
      displayName: json['displayName'] as String,
      status: InstrumentStatus.fromWire(json['status'] as String),
      userCardId: json['userCardId'] as String?,
      parentInstrumentId: json['parentInstrumentId'] as String?,
      aliases: InstrumentAliases.fromJson(json['aliases'] as Json),
      creditLimitMinor: (json['creditLimitMinor'] as num?)?.toInt(),
      creditLimitSource: json['creditLimitSource'] == null
          ? null
          : CreditLimitSource.fromWire(json['creditLimitSource'] as String),
      creditLimitAt: t('creditLimitAt'),
      availableMinor: (json['availableMinor'] as num?)?.toInt(),
      availableAt: t('availableAt'),
      pointsBalance: (json['pointsBalance'] as num?)?.toInt(),
      pointsAt: t('pointsAt'),
      firstSeenAt: parseUtc(json['firstSeenAt'] as String),
      lastSeenAt: parseUtc(json['lastSeenAt'] as String),
      evidenceCount: (json['evidenceCount'] as num).toInt(),
    );
  }

  /// A UUID v4, created on the phone at detection; the server keeps it.
  final String instrumentId;
  final InstrumentKind kind;
  final String issuerSlug;
  final String? maskDigits;
  final int? maskLength;
  final String displayName;
  final InstrumentStatus status;

  /// Link to the existing `user_cards` row, so the rewards engine keeps working.
  final String? userCardId;

  /// Debit card or UPI handle: its bank account.
  final String? parentInstrumentId;
  final InstrumentAliases aliases;

  /// A user-entered limit is never overwritten by SMS.
  final int? creditLimitMinor;
  final CreditLimitSource? creditLimitSource;
  final DateTime? creditLimitAt;
  final int? availableMinor;
  final DateTime? availableAt;
  final int? pointsBalance;
  final DateTime? pointsAt;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final int evidenceCount;

  /// A copy with the given fields replaced. Pass `null` explicitly through the
  /// `clear*` flags to null a nullable field.
  Instrument copyWith({
    String? maskDigits,
    int? maskLength,
    InstrumentStatus? status,
    String? displayName,
    String? userCardId,
    String? parentInstrumentId,
    InstrumentAliases? aliases,
    int? creditLimitMinor,
    CreditLimitSource? creditLimitSource,
    DateTime? creditLimitAt,
    int? availableMinor,
    DateTime? availableAt,
    int? pointsBalance,
    DateTime? pointsAt,
    DateTime? firstSeenAt,
    DateTime? lastSeenAt,
    int? evidenceCount,
  }) =>
      Instrument(
        instrumentId: instrumentId,
        kind: kind,
        issuerSlug: issuerSlug,
        maskDigits: maskDigits ?? this.maskDigits,
        maskLength: maskLength ?? this.maskLength,
        displayName: displayName ?? this.displayName,
        status: status ?? this.status,
        userCardId: userCardId ?? this.userCardId,
        parentInstrumentId: parentInstrumentId ?? this.parentInstrumentId,
        aliases: aliases ?? this.aliases,
        creditLimitMinor: creditLimitMinor ?? this.creditLimitMinor,
        creditLimitSource: creditLimitSource ?? this.creditLimitSource,
        creditLimitAt: creditLimitAt ?? this.creditLimitAt,
        availableMinor: availableMinor ?? this.availableMinor,
        availableAt: availableAt ?? this.availableAt,
        pointsBalance: pointsBalance ?? this.pointsBalance,
        pointsAt: pointsAt ?? this.pointsAt,
        firstSeenAt: firstSeenAt ?? this.firstSeenAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        evidenceCount: evidenceCount ?? this.evidenceCount,
      );

  @override
  Json toJson() => {
        'instrumentId': instrumentId,
        'kind': kind.wire,
        'issuerSlug': issuerSlug,
        'maskDigits': maskDigits,
        'maskLength': maskLength,
        'displayName': displayName,
        'status': status.wire,
        'userCardId': userCardId,
        'parentInstrumentId': parentInstrumentId,
        'aliases': aliases.toJson(),
        'creditLimitMinor': creditLimitMinor,
        'creditLimitSource': creditLimitSource?.wire,
        'creditLimitAt': creditLimitAt == null ? null : formatUtc(creditLimitAt!),
        'availableMinor': availableMinor,
        'availableAt': availableAt == null ? null : formatUtc(availableAt!),
        'pointsBalance': pointsBalance,
        'pointsAt': pointsAt == null ? null : formatUtc(pointsAt!),
        'firstSeenAt': formatUtc(firstSeenAt),
        'lastSeenAt': formatUtc(lastSeenAt),
        'evidenceCount': evidenceCount,
      };

  /// Checks this instrument against the contract.
  ValidationResult validate() => validateInstrumentJson(toJson());
}
