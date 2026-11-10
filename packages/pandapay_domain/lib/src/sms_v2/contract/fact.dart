import 'enums.dart';
import 'errors.dart';
import 'json_util.dart';
import 'types.dart';
import 'validate.dart';

/// The fields every fact carries, apart from `factType` and `attrs`.
final class FactEnvelope {
  FactEnvelope({
    required this.factId,
    required this.sourceKey,
    required this.observedAt,
    this.occurredAt,
    this.instrument,
    this.counterparty,
    List<Amount> amounts = const [],
    Map<String, String> references = const {},
    required this.provenance,
    List<Span> evidence = const [],
    required this.confidence,
  })  : amounts = List.unmodifiable(amounts),
        references = Map.unmodifiable(references),
        evidence = List.unmodifiable(evidence);

  /// `sha256(sourceKey|ruleId|emitIndex)` as hex.
  final String factId;
  final String sourceKey;
  final DateTime observedAt;

  /// The time printed in the SMS; null when none is printed.
  final DateTime? occurredAt;
  final InstrumentMention? instrument;
  final Counterparty? counterparty;
  final List<Amount> amounts;
  final Map<String, String> references;
  final Provenance provenance;

  /// Character offsets in the original body. Never uploaded.
  final List<Span> evidence;
  final double confidence;

  factory FactEnvelope.fromJson(Json j) => FactEnvelope(
        factId: j['factId'] as String,
        sourceKey: j['sourceKey'] as String,
        observedAt: parseUtc(j['observedAt'] as String),
        occurredAt: j['occurredAt'] == null ? null : parseUtc(j['occurredAt'] as String),
        instrument: j['instrument'] == null
            ? null
            : InstrumentMention.fromJson(j['instrument'] as Json),
        counterparty:
            j['counterparty'] == null ? null : Counterparty.fromJson(j['counterparty'] as Json),
        amounts: [for (final a in j['amounts'] as List) Amount.fromJson(a as Json)],
        references: {
          for (final e in (j['references'] as Map).entries) e.key as String: e.value as String,
        },
        provenance: Provenance.fromJson(j['provenance'] as Json),
        evidence: [for (final s in j['evidence'] as List) Span.fromJson(s as Json)],
        confidence: (j['confidence'] as num).toDouble(),
      );
}

/// A reading below this is shown to the person for confirmation; the app asks
/// at the same value. At or above it the reading is acted on without asking.
const double kConfidentRead = 0.7;

/// One thing a message states. Facts never decide totals; the linker and
/// ledger do.
sealed class Fact extends JsonValue {
  Fact(this.envelope);

  /// Contract version stamped on every fact in this release.
  static const String contractVersion = '2.0';

  /// Parses and validates [json]. Throws a [ContractException] when it breaks
  /// the contract.
  factory Fact.fromJson(Map<String, Object?> json) {
    final r = validateFactJson(json);
    if (!r.ok) throw ContractException(r.errors);
    final e = FactEnvelope.fromJson(json);
    final a = json['attrs'] as Json;
    switch (FactType.fromWire(json['factType'] as String)) {
      case FactType.movement:
        return MovementFact(e,
            direction: Direction.fromWire(a['direction'] as String),
            purpose: MovementPurpose.fromWire(a['purpose'] as String),
            rail: Rail.fromWire(a['rail'] as String),
            mandateRef: a['mandateRef'] as String?,
            evidenceOnly: a['evidenceOnly'] as bool?);
      case FactType.attempt:
        return AttemptFact(e,
            status: AttemptStatus.fromWire(a['status'] as String),
            direction: Direction.fromWire(a['direction'] as String),
            purpose: MovementPurpose.fromWire(a['purpose'] as String),
            dueAt: a['dueAt'] == null ? null : parseUtc(a['dueAt'] as String));
      case FactType.hold:
        return HoldFact(e,
            phase: HoldPhase.fromWire(a['phase'] as String),
            purpose: HoldPurpose.fromWire(a['purpose'] as String),
            issueName: a['issueName'] as String?);
      case FactType.balanceSnapshot:
        return BalanceSnapshotFact(e, asOf: parseUtc(a['asOf'] as String));
      case FactType.limitChange:
        return LimitChangeFact(e,
            previousMinor: (a['previousMinor'] as num?)?.toInt(),
            reason: LimitChangeReason.fromWire(a['reason'] as String));
      case FactType.billDue:
        return BillDueFact(e,
            dueDate: a['dueDate'] as String,
            statementDate: a['statementDate'] as String?,
            billerName: a['billerName'] as String?);
      case FactType.mandate:
        return MandateFact(e,
            phase: MandatePhase.fromWire(a['phase'] as String),
            frequency: a['frequency'] as String?,
            merchantName: a['merchantName'] as String?,
            oneTime: a['oneTime'] as bool?,
            mandatePurpose: a['mandatePurpose'] == null
                ? null
                : MandatePurpose.fromWire(a['mandatePurpose'] as String));
      case FactType.reward:
        return RewardFact(e,
            program: a['program'] as String?,
            expiresAt: a['expiresAt'] == null ? null : parseUtc(a['expiresAt'] as String));
      case FactType.instrumentHint:
        return InstrumentHintFact(e, hint: InstrumentHintKind.fromWire(a['hint'] as String));
      case FactType.info:
        return InfoFact(e,
            category: InfoCategory.fromWire(a['category'] as String),
            amountMinor: (a['amountMinor'] as num?)?.toInt());
    }
  }

  final FactEnvelope envelope;

  FactType get factType;

  /// The type-specific `attrs` object.
  Json get attrsJson;

  String get factId => envelope.factId;
  String get sourceKey => envelope.sourceKey;
  DateTime get observedAt => envelope.observedAt;
  DateTime? get occurredAt => envelope.occurredAt;
  InstrumentMention? get instrument => envelope.instrument;
  Counterparty? get counterparty => envelope.counterparty;
  List<Amount> get amounts => envelope.amounts;
  Map<String, String> get references => envelope.references;
  Provenance get provenance => envelope.provenance;
  List<Span> get evidence => envelope.evidence;
  double get confidence => envelope.confidence;

  /// The amount with [role], or null.
  Amount? amount(AmountRole role) {
    for (final a in envelope.amounts) {
      if (a.role == role) return a;
    }
    return null;
  }

  /// The time to use for ordering: `occurredAt`, else `observedAt`.
  DateTime get effectiveAt => envelope.occurredAt ?? envelope.observedAt;

  @override
  Json toJson() => {
        'contractVersion': contractVersion,
        'factId': envelope.factId,
        'sourceKey': envelope.sourceKey,
        'factType': factType.wire,
        'observedAt': formatUtc(envelope.observedAt),
        'occurredAt': envelope.occurredAt == null ? null : formatUtc(envelope.occurredAt!),
        'instrument': envelope.instrument?.toJson(),
        'counterparty': envelope.counterparty?.toJson(),
        'amounts': [for (final a in envelope.amounts) a.toJson()],
        'references': {...envelope.references},
        'attrs': attrsJson,
        'provenance': envelope.provenance.toJson(),
        'evidence': [for (final s in envelope.evidence) s.toJson()],
        'confidence': envelope.confidence,
      };

  /// Checks this fact against the contract. Returns the same codes as the
  /// server.
  ValidationResult validate() => validateFactJson(toJson());
}

/// Money actually moved.
final class MovementFact extends Fact {
  MovementFact(
    super.envelope, {
    required this.direction,
    required this.purpose,
    required this.rail,
    this.mandateRef,
    this.evidenceOnly,
  });

  final Direction direction;
  final MovementPurpose purpose;
  final Rail rail;
  final String? mandateRef;

  /// True for a biller's or app's receipt, which never counts as money on its
  /// own.
  final bool? evidenceOnly;

  @override
  FactType get factType => FactType.movement;

  @override
  Json get attrsJson => {
        'direction': direction.wire,
        'purpose': purpose.wire,
        'rail': rail.wire,
        if (mandateRef != null) 'mandateRef': mandateRef,
        if (evidenceOnly != null) 'evidenceOnly': evidenceOnly,
      };
}

/// Did not move, or not yet.
final class AttemptFact extends Fact {
  AttemptFact(
    super.envelope, {
    required this.status,
    required this.direction,
    required this.purpose,
    this.dueAt,
  });

  final AttemptStatus status;
  final Direction direction;
  final MovementPurpose purpose;
  final DateTime? dueAt;

  @override
  FactType get factType => FactType.attempt;

  @override
  Json get attrsJson => {
        'status': status.wire,
        'direction': direction.wire,
        'purpose': purpose.wire,
        if (dueAt != null) 'dueAt': formatUtc(dueAt!),
      };
}

/// Money blocked, not moved.
final class HoldFact extends Fact {
  HoldFact(super.envelope, {required this.phase, required this.purpose, this.issueName});

  final HoldPhase phase;
  final HoldPurpose purpose;
  final String? issueName;

  @override
  FactType get factType => FactType.hold;

  @override
  Json get attrsJson => {
        'phase': phase.wire,
        'purpose': purpose.wire,
        if (issueName != null) 'issueName': issueName,
      };
}

/// A balance at a point in time.
final class BalanceSnapshotFact extends Fact {
  BalanceSnapshotFact(super.envelope, {required this.asOf});

  final DateTime asOf;

  @override
  FactType get factType => FactType.balanceSnapshot;

  @override
  Json get attrsJson => {'asOf': formatUtc(asOf)};
}

/// A card or loan limit changed.
final class LimitChangeFact extends Fact {
  LimitChangeFact(super.envelope, {this.previousMinor, required this.reason});

  final int? previousMinor;
  final LimitChangeReason reason;

  @override
  FactType get factType => FactType.limitChange;

  @override
  Json get attrsJson => {
        if (previousMinor != null) 'previousMinor': previousMinor,
        'reason': reason.wire,
      };
}

/// An amount owed by a date.
final class BillDueFact extends Fact {
  BillDueFact(super.envelope, {required this.dueDate, this.statementDate, this.billerName});

  /// `YYYY-MM-DD`.
  final String dueDate;
  final String? statementDate;
  final String? billerName;

  @override
  FactType get factType => FactType.billDue;

  @override
  Json get attrsJson => {
        'dueDate': dueDate,
        if (statementDate != null) 'statementDate': statementDate,
        if (billerName != null) 'billerName': billerName,
      };
}

/// A standing instruction changed. A one-time or IPO mandate never becomes a
/// subscription.
final class MandateFact extends Fact {
  MandateFact(
    super.envelope, {
    required this.phase,
    this.frequency,
    this.merchantName,
    this.oneTime,
    this.mandatePurpose,
  });

  final MandatePhase phase;
  final String? frequency;
  final String? merchantName;
  final bool? oneTime;
  final MandatePurpose? mandatePurpose;

  @override
  FactType get factType => FactType.mandate;

  @override
  Json get attrsJson => {
        'phase': phase.wire,
        if (frequency != null) 'frequency': frequency,
        if (merchantName != null) 'merchantName': merchantName,
        if (oneTime != null) 'oneTime': oneTime,
        if (mandatePurpose != null) 'mandatePurpose': mandatePurpose!.wire,
      };
}

/// Points earned or redeemed.
final class RewardFact extends Fact {
  RewardFact(super.envelope, {this.program, this.expiresAt});

  final String? program;
  final DateTime? expiresAt;

  @override
  FactType get factType => FactType.reward;

  @override
  Json get attrsJson => {
        if (program != null) 'program': program,
        if (expiresAt != null) 'expiresAt': formatUtc(expiresAt!),
      };
}

/// Identity only, no money.
final class InstrumentHintFact extends Fact {
  InstrumentHintFact(super.envelope, {required this.hint});

  final InstrumentHintKind hint;

  @override
  FactType get factType => FactType.instrumentHint;

  @override
  Json get attrsJson => {'hint': hint.wire};
}

/// Not financial. Never stored or uploaded; only counted.
///
/// [amountMinor] is an optional printed amount in paise (CCR-002), for example
/// the blocked amount in an IPO application notice. It is informational only:
/// it is not an `amounts` entry, so the linker, ledger and totals never see it.
final class InfoFact extends Fact {
  InfoFact(super.envelope, {required this.category, this.amountMinor});

  final InfoCategory category;
  final int? amountMinor;

  @override
  FactType get factType => FactType.info;

  @override
  Json get attrsJson => {'category': category.wire, if (amountMinor != null) 'amountMinor': amountMinor};
}
