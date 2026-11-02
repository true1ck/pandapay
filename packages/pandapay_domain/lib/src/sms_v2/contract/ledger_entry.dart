import 'enums.dart';
import 'errors.dart';
import 'json_util.dart';
import 'validate.dart';

/// One side of a ledger entry: where money (or points) came from or went to.
sealed class LedgerEndpoint extends JsonValue {
  const LedgerEndpoint();

  /// Parses `{instrumentId}`, `{external}` or `{ownUnresolved}`.
  factory LedgerEndpoint.fromJson(Map<String, Object?> json) {
    if (json.length == 1) {
      if (json['instrumentId'] is String) {
        return InstrumentEndpoint(json['instrumentId'] as String);
      }
      if (json['external'] is String) return ExternalEndpoint(json['external'] as String);
      if (json['ownUnresolved'] is String) {
        return OwnUnresolvedEndpoint(InstrumentKind.fromWire(json['ownUnresolved'] as String));
      }
    }
    throw ContractException([const ContractError('ledger.endpoint_invalid', '')]);
  }
}

/// One of the user's own instruments.
final class InstrumentEndpoint extends LedgerEndpoint {
  const InstrumentEndpoint(this.instrumentId);

  final String instrumentId;

  @override
  Json toJson() => {'instrumentId': instrumentId};
}

/// A counterparty outside the user's accounts; the key is the normalised
/// merchant, UPI ID or person name.
final class ExternalEndpoint extends LedgerEndpoint {
  const ExternalEndpoint(this.counterpartyKey);

  final String counterpartyKey;

  @override
  Json toJson() => {'external': counterpartyKey};
}

/// One of the user's own instruments that the SMS does not name (for example a
/// card bill paid through CHEQ). It still counts as own to own.
final class OwnUnresolvedEndpoint extends LedgerEndpoint {
  const OwnUnresolvedEndpoint(this.kind);

  final InstrumentKind kind;

  @override
  Json toJson() => {'ownUnresolved': kind.wire};
}

/// Money or points moving between two places.
final class LedgerEntry extends JsonValue {
  const LedgerEntry({
    required this.entryId,
    required this.eventId,
    required this.from,
    required this.to,
    required this.amountMinor,
    required this.unit,
    required this.occurredAt,
    this.category,
    this.categorySource,
    required this.countsAsTransaction,
    required this.isSpend,
    required this.isIncome,
    required this.isInvestment,
  });

  /// Parses and validates [json]; throws a [ContractException] on violations.
  factory LedgerEntry.fromJson(Map<String, Object?> json) {
    final r = validateLedgerEntryJson(json);
    if (!r.ok) throw ContractException(r.errors);
    return LedgerEntry(
      entryId: json['entryId'] as String,
      eventId: json['eventId'] as String,
      from: LedgerEndpoint.fromJson(json['from'] as Json),
      to: LedgerEndpoint.fromJson(json['to'] as Json),
      amountMinor: (json['amountMinor'] as num).toInt(),
      unit: LedgerUnit.fromWire(json['unit'] as String),
      occurredAt: parseUtc(json['occurredAt'] as String),
      category: json['category'] as String?,
      categorySource: json['categorySource'] == null
          ? null
          : CategorySource.fromWire(json['categorySource'] as String),
      countsAsTransaction: json['countsAsTransaction'] as bool,
      isSpend: json['isSpend'] as bool,
      isIncome: json['isIncome'] as bool,
      isInvestment: json['isInvestment'] as bool,
    );
  }

  /// `sha256(eventId|index)`.
  final String entryId;
  final String eventId;
  final LedgerEndpoint from;
  final LedgerEndpoint to;
  final int amountMinor;
  final LedgerUnit unit;
  final DateTime occurredAt;

  /// Set only when [to] is external and the event is a spend type.
  final String? category;
  final CategorySource? categorySource;
  final bool countsAsTransaction;
  final bool isSpend;
  final bool isIncome;
  final bool isInvestment;

  @override
  Json toJson() => {
        'entryId': entryId,
        'eventId': eventId,
        'from': from.toJson(),
        'to': to.toJson(),
        'amountMinor': amountMinor,
        'unit': unit.wire,
        'occurredAt': formatUtc(occurredAt),
        'category': category,
        'categorySource': categorySource?.wire,
        'countsAsTransaction': countsAsTransaction,
        'isSpend': isSpend,
        'isIncome': isIncome,
        'isInvestment': isInvestment,
      };

  /// Checks this entry against the contract.
  ValidationResult validate() => validateLedgerEntryJson(toJson());
}
