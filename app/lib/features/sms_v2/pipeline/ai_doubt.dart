import 'package:pandapay_domain/sms_v2.dart';

import 'review_content.dart';

/// Below this a reading is a question for the person. It is the threshold the
/// pipeline has always used to raise a review item (`confidence < .7`).
const double kAiConfidenceFloor = .7;

/// Why an AI reading is not settled: the AI itself was unsure, or the reading
/// looks wrong next to its own message.
enum AiDoubt {
  /// At least one fact was read with confidence below [kAiConfidenceFloor].
  lowConfidence,

  /// The message's own words say the money went one way and the AI read it the
  /// other (for example "credited" in the message, a debit in the reading).
  directionConflict,

  /// The AI booked money that moved, but the message says it has not (a future
  /// debit, a schedule, a request, a pending payment), or is a kind of message
  /// that never moves money (declined, OTP, promotion).
  notMovedYet,

  /// The person moved it back to Needs review themselves (Fix).
  reopened,
}

/// True when every money movement the AI read goes the other way from what the
/// message's words say. Deliberately narrow, so it asks the person only when
/// it is fairly sure:
///  * only a message whose words are clearly money in or clearly money out has
///    a direction ([wordingDirection]); declined, security, mandate, bill,
///    promotion, balance and mixed-verb messages never conflict;
///  * only real movements are compared (a receipt or other evidence-only
///    movement never counts as the money);
///  * one movement that agrees with the words is enough to call it consistent.
/// What it cannot see: a message that carries no clear verb, a reading that is
/// wrong about the amount, the shop or the account rather than the direction,
/// and a message from which a wrong second movement was read next to a right one.
bool readingContradictsWording(String body, Iterable<Fact> facts) {
  final said = wordingDirection(body);
  if (said == null) return false;
  final moves = [
    for (final fact in facts)
      if (fact is MovementFact && fact.evidenceOnly != true) fact,
  ];
  return moves.isNotEmpty && moves.every((m) => m.direction != said);
}

/// True when the AI read a real money movement from a message that says money has
/// not moved, or that is of a kind that never moves it ([saysNotYetMoved],
/// [isNeverAMovement]): it would otherwise enter the totals as a spend or an
/// income. Same classifier as the Needs review chips, no extra wording here.
bool readingBooksUnmovedMoney(String body, Iterable<Fact> facts) {
  final moves = facts.any(
    (fact) => fact is MovementFact && fact.evidenceOnly != true,
  );
  return moves && (saysNotYetMoved(body) || isNeverAMovement(body));
}

/// Whether the person should look at an AI reading, and why. Null is a reading
/// the AI was sure about: it needs no question. [body] is the message text,
/// when it is on the phone; without it only confidence can be judged.
AiDoubt? aiDoubtOf(Iterable<Fact> aiFacts, {String? body}) {
  final facts = aiFacts.toList();
  if (facts.any((fact) => fact.confidence < kAiConfidenceFloor)) {
    return AiDoubt.lowConfidence;
  }
  if (body != null && readingContradictsWording(body, facts)) {
    return AiDoubt.directionConflict;
  }
  if (body != null && readingBooksUnmovedMoney(body, facts)) {
    return AiDoubt.notMovedYet;
  }
  return null;
}
