import '../contract/enums.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/json_util.dart';

/// How many limit changes an instrument remembers.
const int maxLimitHistory = 5;

/// One credit-limit change learned from an SMS.
final class LimitChangeRecord extends JsonValue {
  const LimitChangeRecord({
    required this.minor,
    this.previousMinor,
    required this.at,
    required this.reason,
  });

  factory LimitChangeRecord.fromJson(Json j) => LimitChangeRecord(
    minor: (j['minor'] as num).toInt(),
    previousMinor: (j['previousMinor'] as num?)?.toInt(),
    at: parseUtc(j['at'] as String),
    reason: LimitChangeReason.fromWire(j['reason'] as String),
  );

  /// The new limit, in paise.
  final int minor;

  /// The limit before the change, when the SMS or the instrument knew it.
  final int? previousMinor;
  final DateTime at;
  final LimitChangeReason reason;

  @override
  Json toJson() => {
    'minor': minor,
    'previousMinor': previousMinor,
    'at': formatUtc(at),
    'reason': reason.wire,
  };
}

/// An instrument after a fact, with its short limit history.
///
/// `limitHistory` lives beside the [Instrument] (the frozen contract has no
/// field for it); the app store keeps it with the instrument row. Oldest
/// first, at most [maxLimitHistory] entries.
final class InstrumentUpdate {
  const InstrumentUpdate(this.instrument, this.limitHistory);
  final Instrument instrument;
  final List<LimitChangeRecord> limitHistory;
}

/// Applies one fact to one instrument and returns the new instrument. Pure:
/// nothing is read from the clock or stored.
///
/// - `balance_snapshot` sets `available*` (roles `available_balance` and
///   `available_credit`) or `points*` (`points_balance`), only when its
///   `asOf` is newer than the stored time. Arrival order does not matter.
/// - `limit_change` sets the credit limit with source `sms`, unless the stored
///   source is `user`, and ignores a change older than the stored limit.
/// - `instrument_hint` adds the product name and a linked UPI ID.
/// - Every fact moves `lastSeenAt` forward and adds 1 to `evidenceCount`.
///
/// [senderBrand], when given, is added to the instrument's sender aliases.
Instrument applyFactToInstrument(Instrument instrument, Fact fact, {String? senderBrand}) =>
    applyFact(instrument, fact, senderBrand: senderBrand).instrument;

/// Like [applyFactToInstrument], and also carries the limit history.
InstrumentUpdate applyFact(
  Instrument instrument,
  Fact fact, {
  List<LimitChangeRecord> limitHistory = const [],
  String? senderBrand,
}) {
  var next = instrument;
  var history = limitHistory;

  switch (fact) {
    case BalanceSnapshotFact():
      next = _applyBalance(next, fact);
    case LimitChangeFact():
      final r = _applyLimit(next, fact, history);
      next = r.instrument;
      history = r.limitHistory;
    case InstrumentHintFact():
      next = _applyHint(next, fact);
    default:
      break;
  }

  final brand = senderBrand?.trim();
  if (brand != null && brand.isNotEmpty && !next.aliases.senders.contains(brand)) {
    next = next.copyWith(
      aliases: InstrumentAliases(
        senders: [...next.aliases.senders, brand],
        vpas: next.aliases.vpas,
        productNames: next.aliases.productNames,
      ),
    );
  }

  final seen = fact.observedAt.toUtc();
  next = next.copyWith(
    firstSeenAt: seen.isBefore(next.firstSeenAt) ? seen : next.firstSeenAt,
    lastSeenAt: seen.isAfter(next.lastSeenAt) ? seen : next.lastSeenAt,
    evidenceCount: next.evidenceCount + 1,
  );
  return InstrumentUpdate(next, List.unmodifiable(history));
}

Instrument _applyBalance(Instrument i, BalanceSnapshotFact fact) {
  final asOf = fact.asOf.toUtc();
  final available =
      fact.amount(AmountRole.availableBalance) ?? fact.amount(AmountRole.availableCredit);
  if (available != null) {
    final stored = i.availableAt;
    if (stored == null || asOf.isAfter(stored)) {
      i = i.copyWith(availableMinor: available.minor, availableAt: asOf);
    }
  }
  final points = fact.amount(AmountRole.pointsBalance);
  if (points != null) {
    final stored = i.pointsAt;
    if (stored == null || asOf.isAfter(stored)) {
      i = i.copyWith(pointsBalance: points.minor, pointsAt: asOf);
    }
  }
  return i;
}

InstrumentUpdate _applyLimit(Instrument i, LimitChangeFact fact, List<LimitChangeRecord> history) {
  final limit = fact.amount(AmountRole.creditLimit);
  if (limit == null || i.creditLimitSource == CreditLimitSource.user) {
    return InstrumentUpdate(i, history);
  }
  final at = fact.effectiveAt.toUtc();
  final stored = i.creditLimitAt;
  if (stored != null && at.isBefore(stored)) return InstrumentUpdate(i, history);

  final changed = i.creditLimitMinor != limit.minor;
  final next = i.copyWith(
    creditLimitMinor: limit.minor,
    creditLimitSource: CreditLimitSource.sms,
    creditLimitAt: at,
  );
  if (!changed) return InstrumentUpdate(next, history);
  final record = LimitChangeRecord(
    minor: limit.minor,
    previousMinor: fact.previousMinor ?? i.creditLimitMinor,
    at: at,
    reason: fact.reason,
  );
  final all = [...history, record];
  final trimmed = all.length > maxLimitHistory ? all.sublist(all.length - maxLimitHistory) : all;
  return InstrumentUpdate(next, trimmed);
}

Instrument _applyHint(Instrument i, InstrumentHintFact fact) {
  var productNames = i.aliases.productNames;
  var vpas = i.aliases.vpas;

  final product = fact.instrument?.productName?.trim();
  if (product != null && product.isNotEmpty) {
    final lower = product.toLowerCase();
    if (!productNames.any((p) => p.toLowerCase() == lower)) {
      productNames = [...productNames, product];
    }
  }
  if (fact.hint == InstrumentHintKind.linkedUpi) {
    final vpa = fact.counterparty?.vpa?.trim().toLowerCase();
    if (vpa != null && vpa.isNotEmpty && !vpas.contains(vpa)) {
      vpas = [...vpas, vpa];
    }
  }
  if (identical(productNames, i.aliases.productNames) && identical(vpas, i.aliases.vpas)) return i;
  return i.copyWith(
    aliases: InstrumentAliases(senders: i.aliases.senders, vpas: vpas, productNames: productNames),
  );
}
