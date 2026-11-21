import 'enums.dart';
import 'errors.dart';
import 'json_util.dart';
import 'validate.dart';

/// A fact's role inside an event.
final class EventLeg extends JsonValue {
  const EventLeg({required this.factId, required this.role});

  factory EventLeg.fromJson(Json j) =>
      EventLeg(factId: j['factId'] as String, role: LegRole.fromWire(j['role'] as String));

  final String factId;
  final LegRole role;

  @override
  Json toJson() => {'factId': factId, 'role': role.wire};
}

/// One real-world thing, possibly stated by several messages.
final class Event extends JsonValue {
  Event({
    required this.eventId,
    required this.type,
    required this.status,
    required List<EventLeg> legs,
    this.linkRuleId,
    required this.confidence,
    required this.occurredAt,
    required this.amountMinor,
    this.decidedAt,
  }) : legs = List.unmodifiable(legs);

  /// Parses and validates [json]; throws a [ContractException] on violations.
  factory Event.fromJson(Map<String, Object?> json) {
    final r = validateEventJson(json);
    if (!r.ok) throw ContractException(r.errors);
    return Event(
      eventId: json['eventId'] as String,
      type: EventType.fromWire(json['type'] as String),
      status: EventStatus.fromWire(json['status'] as String),
      legs: [for (final l in json['legs'] as List) EventLeg.fromJson(l as Json)],
      linkRuleId: json['linkRuleId'] as String?,
      confidence: (json['confidence'] as num).toDouble(),
      occurredAt: parseUtc(json['occurredAt'] as String),
      amountMinor: (json['amountMinor'] as num).toInt(),
      decidedAt: json['decidedAt'] == null
          ? null
          : parseUtc(json['decidedAt'] as String),
    );
  }

  /// The `factId` of the first (anchor) leg; never changes when legs arrive.
  final String eventId;
  final EventType type;
  final EventStatus status;
  final List<EventLeg> legs;

  /// Which link rule joined the legs.
  final String? linkRuleId;
  final double confidence;

  /// From the earliest posted leg.
  final DateTime occurredAt;
  final int amountMinor;

  /// When the user last decided about this event (a correction or a confirmed
  /// receipt), on the phone's server-adjusted clock. Null for automatic
  /// changes and for decisions made before this field existed. When two
  /// devices both confirmed it differently, the later `decidedAt` wins.
  final DateTime? decidedAt;

  /// A copy with legs, status, link rule, confidence, amounts or decision time
  /// replaced.
  Event copyWith({
    EventType? type,
    EventStatus? status,
    List<EventLeg>? legs,
    String? linkRuleId,
    double? confidence,
    DateTime? occurredAt,
    int? amountMinor,
    DateTime? decidedAt,
  }) =>
      Event(
        eventId: eventId,
        type: type ?? this.type,
        status: status ?? this.status,
        legs: legs ?? this.legs,
        linkRuleId: linkRuleId ?? this.linkRuleId,
        confidence: confidence ?? this.confidence,
        occurredAt: occurredAt ?? this.occurredAt,
        amountMinor: amountMinor ?? this.amountMinor,
        decidedAt: decidedAt ?? this.decidedAt,
      );

  @override
  Json toJson() => {
        'eventId': eventId,
        'type': type.wire,
        'status': status.wire,
        'legs': [for (final l in legs) l.toJson()],
        'linkRuleId': linkRuleId,
        'confidence': confidence,
        'occurredAt': formatUtc(occurredAt),
        'amountMinor': amountMinor,
        // Omitted when unset, so an event nobody decided on is byte-identical
        // to what older builds and the server already know.
        if (decidedAt != null) 'decidedAt': formatUtc(decidedAt!),
      };

  /// Checks this event against the contract.
  ValidationResult validate() => validateEventJson(toJson());
}
