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

  /// A copy with legs, status, link rule, confidence or amounts replaced.
  Event copyWith({
    EventType? type,
    EventStatus? status,
    List<EventLeg>? legs,
    String? linkRuleId,
    double? confidence,
    DateTime? occurredAt,
    int? amountMinor,
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
      };

  /// Checks this event against the contract.
  ValidationResult validate() => validateEventJson(toJson());
}
