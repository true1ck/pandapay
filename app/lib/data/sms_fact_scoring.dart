import 'dart:math' as math;

import 'sms_fact_contract.dart';

/// Device mirror of api/src/ai_fact_scoring.js — multi-signal composite
/// confidence for AI-extracted SMS facts.
///
/// S = 0.25*S_model + 0.35*S_evidence + 0.25*S_completeness + 0.15*S_disambiguation
///
/// The score never invents certainty the message does not carry: every
/// evidence component is anchored to text actually present in the body, while
/// completeness and disambiguation measure whether the extracted fact has the
/// attributes a downstream projection needs. The two implementations are
/// deliberately kept structurally identical so a device replay and a server
/// replay route the same message the same way.
const double kSmsAutoResolveThreshold = 0.85;
const double kSmsReviewThreshold = 0.45;

const double _kModelWeight = 0.25;
const double _kEvidenceWeight = 0.35;
const double _kCompletenessWeight = 0.25;
const double _kDisambiguationWeight = 0.15;

/// Fact types that may gate auto-resolution; informational facts never do.
const Set<String> smsActionableFactTypes = {
  'posted_movement',
  'bill_obligation',
  'bill_payment',
  'mandate_lifecycle',
};

/// Verbs that prove money actually moved — including the Indian families the
/// original card/UPI list missed (loan disbursement, SIP, deposit, payout).
final RegExp smsMovementVerbRe = RegExp(
  r'\b(debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|transfer|processed|payout|settled|disbursed|invested|deposited|sent)\b',
  caseSensitive: false,
);

// Some processors confirm a payment as "payment ... completed successfully"
// without using paid/debited. Require the explicit transaction noun and
// completed wording just as the API verifier does.
final RegExp smsCompletedTransactionRe = RegExp(
  r'\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,100}\bcompleted(?:\s+successfully)?\b',
  caseSensitive: false,
);

/// Marketing / operational footers appended to genuine bank alerts. Everything
/// from the first marker onwards is not part of the transaction clause, so a
/// footer word like "eligible" or "scheduled maintenance" must never
/// disqualify a real movement.
final RegExp smsFooterMarkerRe = RegExp(
  r'\b(?:you are eligible|avail loan|get flat|apply for|offer valid|terms and conditions|t&c|scheduled maintenance|maintenance window)\b',
  caseSensitive: false,
);

/// Failure / tentative language that only disqualifies the core clause.
final RegExp smsFailureOrTentativeRe = RegExp(
  r'\b(?:failed|declined|unsuccessful|reversed|cancelled|will be|to be|is scheduled|scheduled for)\b',
  caseSensitive: false,
);

final RegExp _moneyInMessageRe = RegExp(
  r'(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);

/// Returns the transaction-bearing part of a message, before any promotional
/// or maintenance footer that frequently trails Indian bank SMS.
String smsCoreTransactionClause(String body) {
  final text = body;
  final match = smsFooterMarkerRe.firstMatch(text);
  if (match == null) return text.trim();
  return text.substring(0, match.start).trim();
}

/// True when the core clause contains a completion verb and no failure or
/// tentative wording. Shared by evidence scoring and auto-resolution.
bool smsHasCompletionEvidence(String body) {
  final core = smsCoreTransactionClause(body);
  if (core.isEmpty) return false;
  if (!smsMovementVerbRe.hasMatch(core) &&
      !smsCompletedTransactionRe.hasMatch(core)) {
    return false;
  }
  if (smsFailureOrTentativeRe.hasMatch(core)) return false;
  return true;
}

/// Every rupee amount printed in the message, with Indian grouping accepted.
List<double> smsMoneyInMessage(String body) {
  final values = <double>[];
  for (final match in _moneyInMessageRe.allMatches(body)) {
    final value = double.tryParse((match.group(1) ?? '').replaceAll(',', ''));
    if (value != null && value.isFinite) values.add(value);
  }
  return values;
}

Map<String, dynamic> smsFactPayload(Map<String, dynamic> fact) {
  final payload = fact['payload'];
  if (payload is Map) return Map<String, dynamic>.from(payload);
  // Tolerate a bare payload map so callers never have to unwrap by hand.
  return fact;
}

bool smsFactIsComplete(Map<String, dynamic> fact) =>
    smsFactPayload(fact)['isComplete'] == true;

double _round4(double value) => (value * 10000).round() / 10000;

bool _isFiniteNumber(Object? value) => value is num && value.isFinite;

double _unitScore(Object? value) {
  if (!_isFiniteNumber(value)) return 0;
  final number = (value as num).toDouble();
  return math.min(1, math.max(0, number));
}

bool _shortText(Object? value) => value is String && value.trim().isNotEmpty;

bool _validDate(Object? value) =>
    value is String && DateTime.tryParse(value) != null;

/// Verbatim amount evidence. Accepts Indian grouping ("1,45,000") and decimal
/// spelling differences, but never a number that only appears inside a longer
/// identifier.
bool smsAmountAppears(String body, num? amount) {
  if (amount == null || !amount.isFinite || amount <= 0) return false;
  if (smsMoneyInMessage(
    body,
  ).any((printed) => (printed - amount).abs() < 0.005)) {
    return true;
  }
  final compact = body.replaceAll(',', '');
  final variants = <String>{'$amount'};
  if (amount == amount.roundToDouble()) {
    variants.add(amount.toDouble().toStringAsFixed(2));
  }
  for (final variant in variants) {
    var index = compact.indexOf(variant);
    while (index != -1) {
      final before = index == 0 ? null : compact[index - 1];
      final afterIndex = index + variant.length;
      final after = afterIndex >= compact.length ? null : compact[afterIndex];
      final startsAtDigitBoundary = before == null || !_isDigit(before);
      final endsAtDigitBoundary = after == null || !_isDigit(after);
      if (startsAtDigitBoundary && endsAtDigitBoundary) return true;
      index = compact.indexOf(variant, index + 1);
    }
  }
  return false;
}

bool _isDigit(String char) =>
    char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39;

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Anchor-date evidence across the formats Indian SMS actually print:
/// dd-mm-yy, dd/mm/yy, dd Mon yyyy, ISO, plus the plain "24 Oct" form.
bool smsDateAppears(String body, String? anchor) {
  if (anchor == null) return false;
  final parsed = DateTime.tryParse(anchor);
  if (parsed == null) return false;
  // The server compares both the UTC instant and its IST calendar day, since
  // device-written anchors can land at 18:30Z on the previous day.
  final variants = [
    ..._dateVariants(parsed.toUtc()),
    ..._dateVariants(parsed.toUtc().add(const Duration(minutes: 330))),
  ];
  final lower = body.toLowerCase();
  return variants.any((variant) => lower.contains(variant.toLowerCase()));
}

List<String> _dateVariants(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final year = '${date.year}';
  final shortYear = year.substring(year.length - 2);
  final monthName = _months[date.month - 1];
  return [
    '$year-$month-$day',
    '$day-$month-$shortYear',
    '$day/$month/$shortYear',
    '$day-$month-$year',
    '$day/$month/$year',
    '$day $monthName $year',
    '$day-$monthName-$year',
    '$day $monthName $shortYear',
    '$day-$monthName-$shortYear',
    '$day $monthName',
  ];
}

String? smsAnchorForPayload(Map<String, dynamic> payload) {
  for (final field in [
    'occurredAt',
    'dueDate',
    'asOfAt',
    'statementDate',
    'proposedAt',
    'nextPaymentDate',
  ]) {
    final value = payload[field];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

/// The amount that identifies a fact, preferring the field its amountRole
/// names and otherwise the first positive money field present.
double? smsFactAmountRupees(Map<String, dynamic> payload) {
  final roleField = smsAmountFieldByRole[payload['amountRole']];
  if (roleField != null) {
    final value = payload[roleField];
    if (_isFiniteNumber(value) && value > 0) {
      return value.toDouble();
    }
  }
  for (final field in smsAmountFieldByRole.values) {
    final value = payload[field];
    if (_isFiniteNumber(value) && value > 0) {
      return value.toDouble();
    }
  }
  return null;
}

double? smsPostedAmountRupees(Map<String, dynamic> payload) {
  final value = payload['amountInr'];
  if (_isFiniteNumber(value) && value > 0) {
    return value.toDouble();
  }
  return null;
}

double? smsAmountDueRupees(Map<String, dynamic> payload) {
  final value = payload['amountDueInr'];
  if (_isFiniteNumber(value) && value > 0) {
    return value.toDouble();
  }
  return null;
}

double _modelScore(Map<String, dynamic> payload) {
  final confidence = payload['confidence'];
  if (_isFiniteNumber(confidence)) {
    final value = (confidence as num).toDouble();
    if (value >= 0 && value <= 1) return value;
  }
  return 0.8;
}

double _evidenceScore(
  String factType,
  Map<String, dynamic> payload,
  String body, {
  DateTime? receivedAt,
}) {
  var score = 0.0;
  final paymentAmount = payload['amountInr'];
  final amountEvidence = factType == 'bill_payment'
      ? _amountInCompletedPayment(body, paymentAmount)
      : smsAmountAppears(body, smsFactAmountRupees(payload));
  if (amountEvidence) score += 0.40;
  final suffix = payload['last4'] ?? payload['accountLast4'];
  if (suffix is String && suffix.isNotEmpty && body.contains(suffix)) {
    score += 0.25;
  }
  final anchor = smsAnchorForPayload(payload);
  final parsedAnchor = DateTime.tryParse(anchor ?? '');
  final hasReceiptTime =
      factType == 'bill_payment' &&
      parsedAnchor != null &&
      receivedAt != null &&
      parsedAnchor.difference(receivedAt).inMinutes.abs() <= 5;
  if (smsDateAppears(body, anchor) || hasReceiptTime) score += 0.20;
  if (factType == 'posted_movement' || factType == 'bill_payment') {
    if (smsHasCompletionEvidence(body)) score += 0.15;
  } else if (factType == 'bill_obligation' || factType == 'mandate_lifecycle') {
    if (RegExp(
      r'\b(bill|due|mandate|autopay|auto.pay)\b',
      caseSensitive: false,
    ).hasMatch(body)) {
      score += 0.15;
    }
  }
  return _round4(math.min(1, score));
}

bool _amountInCompletedPayment(String body, Object? amount) {
  if (amount is! num || !amount.isFinite || amount <= 0) return false;
  final pattern = RegExp(
    r'\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,120}\bcompleted(?:\s+successfully)?\b',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(body)) {
    if (smsAmountAppears(match.group(0)!, amount)) return true;
  }
  return false;
}

bool _hasValidInstrument(Map<String, dynamic> payload) =>
    payload['instrument'] is String &&
    smsInstruments.contains(payload['instrument']);

bool _hasValidCategory(Map<String, dynamic> payload) =>
    payload['category'] is String &&
    smsSpendCategories.contains(payload['category']);

double _completenessScore(String factType, Map<String, dynamic> payload) {
  switch (factType) {
    case 'posted_movement':
      var score = 0.0;
      if (_isFiniteNumber(payload['amountInr']) &&
          (payload['amountInr'] as num) > 0) {
        score += 0.25;
      }
      if (_hasValidInstrument(payload)) score += 0.25;
      if (_shortText(payload['merchant'])) score += 0.25;
      if (_hasValidCategory(payload)) score += 0.25;
      return score;
    case 'bill_obligation':
      var score = 0.0;
      if (_isFiniteNumber(payload['amountDueInr']) &&
          (payload['amountDueInr'] as num) > 0) {
        score += 0.35;
      }
      if (_validDate(payload['dueDate'])) score += 0.35;
      if (_shortText(payload['billerName'])) score += 0.30;
      return score;
    case 'mandate_lifecycle':
      var score = 0.0;
      if (_isFiniteNumber(payload['limitInr']) &&
          (payload['limitInr'] as num) > 0) {
        score += 0.40;
      }
      if (_shortText(payload['serviceName']) ||
          _shortText(payload['merchant'])) {
        score += 0.30;
      }
      if (_shortText(payload['mandateStatus'])) score += 0.30;
      return score;
    case 'bill_payment':
      var score = 0.0;
      if (_isFiniteNumber(payload['amountInr']) &&
          (payload['amountInr'] as num) > 0) {
        score += 0.4;
      }
      if (_validDate(payload['occurredAt'])) score += 0.2;
      if (_shortText(payload['billerName']) || _shortText(payload['merchant']))
        score += 0.4;
      return score;
    case 'balance_snapshot':
      var score = 0.0;
      if (_isFiniteNumber(payload['availableBalanceInr']) &&
          (payload['availableBalanceInr'] as num) >= 0) {
        score += 0.5;
      }
      if (_validDate(payload['asOfAt'])) score += 0.25;
      if (_hasValidInstrument(payload)) score += 0.25;
      return score;
    case 'pending_or_failed_attempt':
      var score = 0.0;
      if (_shortText(payload['attemptStatus'])) score += 0.5;
      if (_validDate(payload['occurredAt'])) score += 0.5;
      return score;
    case 'card_identity_hint':
      var score = 0.0;
      if (_shortText(payload['last4']) || _shortText(payload['accountLast4'])) {
        score += 0.5;
      }
      if (_validDate(payload['asOfAt'])) score += 0.5;
      return score;
    case 'security_or_service_alert':
      var score = 0.0;
      if (_shortText(payload['alertKind'])) score += 0.5;
      if (_validDate(payload['occurredAt'])) score += 0.5;
      return score;
    case 'promotion':
      return 1;
    default:
      return 0;
  }
}

double _disambiguationScore(Map<String, dynamic> payload, [String? factType]) {
  var score = 0.0;
  if (_shortText(payload['merchant']) ||
      _shortText(payload['billerName']) ||
      _shortText(payload['serviceName'])) {
    score += 0.5;
  }
  if (factType == 'bill_payment' &&
      (_shortText(payload['merchant']) || _shortText(payload['billerName']))) {
    return 1;
  }
  if (_shortText(payload['last4']) || _shortText(payload['accountLast4'])) {
    score += 0.5;
  }
  return math.min(1, score);
}

/// One scored candidate fact. [fact] is the raw wire map so callers can use the
/// payload (and factType) without a second lookup.
class SmsFactConfidence {
  final Map<String, dynamic> fact;
  final double composite;
  final double model;
  final double evidence;
  final double completeness;
  final double disambiguation;
  final bool isComplete;

  const SmsFactConfidence({
    required this.fact,
    required this.composite,
    required this.model,
    required this.evidence,
    required this.completeness,
    required this.disambiguation,
    required this.isComplete,
  });

  String? get factType => fact['factType'] as String?;
  Map<String, dynamic> get payload => smsFactPayload(fact);
  bool get actionable =>
      factType != null && smsActionableFactTypes.contains(factType);
}

/// Whole-result assessment. Only actionable facts gate routing; informational
/// facts are scored and reported but never decide the tier.
class SmsConfidenceAssessment {
  final List<SmsFactConfidence> facts;
  final double composite;
  final Map<String, dynamic>? primaryFact;
  final bool isComplete;
  final bool autoResolvable;

  const SmsConfidenceAssessment({
    required this.facts,
    required this.composite,
    required this.primaryFact,
    required this.isComplete,
    required this.autoResolvable,
  });

  List<SmsFactConfidence> get actionableFacts =>
      facts.where((entry) => entry.actionable).toList(growable: false);
}

/// Scores one candidate fact against the redacted SMS body.
SmsFactConfidence _scoreFact(
  Map<String, dynamic> fact,
  String body, {
  DateTime? receivedAt,
}) {
  final payload = smsFactPayload(fact);
  final factType = fact['factType'] as String? ?? '';
  final model = _modelScore(payload);
  final evidence = _evidenceScore(
    factType,
    payload,
    body,
    receivedAt: receivedAt,
  );
  final completeness = _completenessScore(factType, payload);
  final disambiguation = _disambiguationScore(payload, factType);
  final composite = _round4(
    _kModelWeight * model +
        _kEvidenceWeight * evidence +
        _kCompletenessWeight * completeness +
        _kDisambiguationWeight * disambiguation,
  );
  return SmsFactConfidence(
    fact: fact,
    composite: composite,
    model: _unitScore(model),
    evidence: evidence,
    completeness: completeness,
    disambiguation: disambiguation,
    isComplete: payload['isComplete'] == true,
  );
}

/// Assesses a whole model result.
///
/// Auto-resolution requires at least one actionable fact, every actionable fact
/// scoring >= [kSmsAutoResolveThreshold], and every actionable fact explicitly
/// marked complete by the model. A missing `isComplete` is never treated as
/// complete.
SmsConfidenceAssessment assessSmsFacts(
  List<Map<String, dynamic>> facts,
  String body, {
  DateTime? receivedAt,
}) {
  final scored = facts
      .map((fact) => _scoreFact(fact, body, receivedAt: receivedAt))
      .toList();
  final actionable = scored.where((entry) => entry.actionable).toList();

  var composite = 0.0;
  Map<String, dynamic>? primaryFact;
  if (actionable.isNotEmpty) {
    var best = actionable.first;
    for (final entry in actionable.skip(1)) {
      if (entry.composite > best.composite) best = entry;
    }
    composite = best.composite;
    primaryFact = best.fact;
  }
  final isComplete =
      actionable.isNotEmpty && actionable.every((entry) => entry.isComplete);
  final autoResolvable =
      actionable.isNotEmpty &&
      actionable.every(
        (entry) => entry.composite >= kSmsAutoResolveThreshold,
      ) &&
      isComplete;

  return SmsConfidenceAssessment(
    facts: scored,
    composite: composite,
    primaryFact: primaryFact,
    isComplete: isComplete,
    autoResolvable: autoResolvable,
  );
}
