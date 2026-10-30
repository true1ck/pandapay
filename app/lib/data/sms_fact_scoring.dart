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
  r'\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,100}\b(?:completed(?:\s+successfully)?|recorded)\b',
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
  r'\b(?:failed|declined|unsuccessful|reversed|cancelled|pending|in\s+progress|under\s+process|is\s+scheduled|scheduled\s+for)\b',
  caseSensitive: false,
);

/// Future framing. "will be debited" is a promise, not a completed movement;
/// "shall"/"would" previously slipped through because only "will be" was
/// listed. Restricted to movement/completion verbs so a genuine debit whose
/// footer says "limit will be revised" still counts.
final RegExp _smsFutureOrTentativeRe = RegExp(
  r'\b(?:will|would|shall|should)\s+be\s+(?:auto[- ]?)?(?:debited|deducted|charged|withdrawn|paid|transferred|sent|credited|completed|recorded|processed|confirmed)\b|\b(?:will|would|shall|should)\s+(?:auto[- ]?)?(?:debit|deduct|charge|withdraw)\b|\bto\s+be\s+(?:debited|deducted|charged|withdrawn|paid|transferred)\b|\bis\s+scheduled\s+(?:to|for)\b',
  caseSensitive: false,
);

/// "Processing" is tentative only as a pending-payment predicate ("payment is
/// processing", "is being processed", "under process"). As a noun it is a
/// completed fee debit ("processing fee ... debited"), which must still count.
final RegExp _smsPendingProcessingRe = RegExp(
  r'\b(?:is|are|being|still|currently)\s+(?:currently\s+|still\s+)?(?:being\s+)?processing\b|\b(?:is|are|was|were)\s+being\s+processed\b|\bunder\s+process(?:ing)?\b',
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
  if (smsFailureOrTentativeRe.hasMatch(core) ||
      _smsFutureOrTentativeRe.hasMatch(core) ||
      _smsPendingProcessingRe.hasMatch(core)) {
    return false;
  }
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
    // Compact Indian bank token: 17Oct26.
    '$day$monthName$shortYear',
    '$day$monthName$year',
  ];
}

// ---------------------------------------------------------------------------
// Merchant identity gate (mirror of api/src/merchant_identity.js).
//
// A merchant/biller name is display evidence, not a shape-only optional field.
// A synthetic or hash-like name must not buy disambiguation/completeness points
// even when it happens to be a string. Canonical movement/refund labels emitted
// by the parser stay valid because they are grounded by their own cue words.
// ---------------------------------------------------------------------------

const Set<String> _smsCanonicalMerchantAliases = {
  'amazon pay later',
  'bank or service fee',
  'bank transfer',
  'card statement adjustment',
  'cash deposit',
  'cash withdrawal',
  'credit card bill payment',
  'gift received',
  'investment contribution',
  'investment proceeds',
  'loan disbursement',
  'loan or emi repayment',
  'money received',
  'reimbursement',
  'refund',
  'reversal',
  'reward or cashback',
  'salary',
  'transfer between own accounts',
  'wallet load',
};

const Set<String> _smsWeakMerchantExact = {
  'call',
  'completed',
  'downloaded',
  'other services',
  'payment',
  'payment receipt',
  'receipt',
  'recorded',
  'reference',
  'refno',
  'successful',
  'successfully',
  'the payment receipt',
  'view receipt',
  'your payment',
};

final RegExp _smsUrlRe = RegExp(
  r'https?:\/\/|www\.',
  caseSensitive: false,
);
final RegExp _smsBoilerplateRe = RegExp(
  r'\b(?:for\s+other\s+services|other\s+services|if\s+not\s+u|if\s+not\s+you|not\s+you|view\s+(?:the\s+)?(?:payment\s+)?(?:receipt|bill|invoice)|download\s+(?:the\s+)?(?:payment\s+)?(?:receipt|bill|invoice)|(?:has|have|had|was|were|is|are)\s+(?:been\s+)?(?:successfully\s+)?(?:recorded|completed|processed|confirmed)|call|sms\s+block|to\s+block|block\s+card|report\s+spam)\b',
  caseSensitive: false,
);
final RegExp _smsMerchantSignatureRe = RegExp(
  r'\s*[-–—]\s*(?:my\s*bill\s*book|mybillbook(?:\.in)?)\s*$',
  caseSensitive: false,
);
final RegExp _smsMerchantLetterRe = RegExp(r'\p{L}', unicode: true);
final RegExp _smsMerchantDigitRe = RegExp(r'\p{N}', unicode: true);
final RegExp _smsMerchantFragmentRe = RegExp(
  r'\b(?:payment|receipt|recorded|completed|processed|successfully|your|has|been|view|download|call|services|account|bank|other)\b',
  caseSensitive: false,
);

String _smsNormalizeWhitespace(String value) =>
    value.replaceAll(RegExp(r'\u00a0'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String _smsStripWrapping(String value) => value
    .replaceFirst(RegExp(r'''^[\s"'“”‘’()[\]{}]+''', unicode: true), '')
    .replaceFirst(RegExp(r'''[\s"'“”‘’()[\]{}]+$''', unicode: true), '')
    .replaceFirst(RegExp(r'^_+'), '')
    .replaceFirst(RegExp(r'[\s.,;:!?*-]+$', unicode: true), '')
    .trim();

String _smsCutBoilerplate(String value) {
  var text = value;
  final match = _smsBoilerplateRe.firstMatch(text);
  if (match != null) {
    text = match.start == 0 ? '' : text.substring(0, match.start).trim();
  }
  final url = _smsUrlRe.firstMatch(text);
  if (url != null) {
    text = url.start == 0 ? '' : text.substring(0, url.start).trim();
  }
  return text.replaceFirst(_smsMerchantSignatureRe, '').trim();
}

String? _smsBaseWeaknessReason(String text) {
  if (text.isEmpty) return 'empty';
  if (text.length > 120) return 'too_long';
  final lower = text.toLowerCase();
  if (_smsCanonicalMerchantAliases.contains(lower)) return null;
  if (_smsWeakMerchantExact.contains(lower)) return 'boilerplate';

  final letterCount = _smsMerchantLetterRe.allMatches(text).length;
  final digitCount = _smsMerchantDigitRe.allMatches(text).length;
  if (letterCount == 0) return digitCount >= 4 ? 'numeric_id' : null;
  if (_smsUrlRe.hasMatch(text)) return 'url';
  if (_smsBoilerplateRe.hasMatch(text)) return 'boilerplate';

  if (RegExp(
    r'^(?:ref(?:erence)?|refno|txn|utr|rrn|order\s*id|id)\b[\s:#-]*[\p{L}\p{N}-]*$',
    caseSensitive: false,
    unicode: true,
  ).hasMatch(text)) {
    return 'reference_id';
  }
  if (RegExp(r'^[A-Z]{1,4}[-#]?\d{4,}$').hasMatch(text)) {
    return 'reference_id';
  }
  if (RegExp(r'^\+?\p{N}[\p{N}\s-]{5,}$', unicode: true).hasMatch(text)) {
    return 'numeric_id';
  }

  final compact = text.replaceAll(RegExp(r'[\s_-]+'), '');
  if (RegExp(r'^[a-f0-9]{16,}$', caseSensitive: false).hasMatch(compact)) {
    return 'hash_id';
  }
  if (RegExp(
    r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)[A-Za-z0-9_-]{12,}$',
  ).hasMatch(text)) {
    return 'hash_id';
  }

  final words = text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
  if (words.length == 1 && compact.length >= 8 && digitCount > 0 && letterCount > 0) {
    final vowels = RegExp(r'[aeiou]', caseSensitive: false).allMatches(compact).length;
    final digitRatio = digitCount / compact.length;
    if (vowels <= 1 || digitRatio >= 0.4) return 'hash_id';
  }

  if (words.length >= 5 &&
      _smsMerchantFragmentRe.allMatches(text).length >= 3) {
    return 'sentence_fragment';
  }
  return null;
}

/// Display-safe merchant name, or null when the capture is an ID/boilerplate.
String? smsCleanMerchantName(String? value) {
  if (value == null) return null;
  var text = _smsNormalizeWhitespace(value);
  if (text.isEmpty) return null;
  text = _smsStripWrapping(text);
  text = _smsCutBoilerplate(text);
  text = _smsStripWrapping(text);
  if (text.isEmpty) return null;

  final lower = text.toLowerCase();
  if (_smsCanonicalMerchantAliases.contains(lower)) {
    return text;
  }
  final transfer = RegExp(
    r'^transfer\s+to\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (transfer != null) {
    final party = smsCleanMerchantName(transfer.group(1));
    if (party == null ||
        _smsBaseWeaknessReason(party) != null ||
        RegExp(r'^transfer\s+to\b', caseSensitive: false).hasMatch(party)) {
      return null;
    }
    return 'Transfer to $party';
  }
  if (_smsBaseWeaknessReason(text) != null) return null;
  return text;
}

/// True when the value cannot safely be displayed/stored as a merchant.
bool smsIsWeakMerchantName(String? value) => smsCleanMerchantName(value) == null;

String _smsNormalizeForMatch(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

bool _smsAppearsInMessage(String value, String body) {
  final normalized = _smsNormalizeForMatch(value);
  if (normalized.length < 2) return false;
  final normalizedBody = _smsNormalizeForMatch(body);
  if (normalizedBody.isEmpty) return false;
  if (normalized.length >= 4) return normalizedBody.contains(normalized);
  final escaped = RegExp.escape(value);
  return RegExp(
    '(?:^|[^\\p{L}\\p{N}])$escaped(?:\$|[^\\p{L}\\p{N}])',
    caseSensitive: false,
    unicode: true,
  ).hasMatch(body);
}

/// The transaction context each parser-emitted label actually implies. A label
/// is grounded only by its own family's wording: "Bank transfer" must not be
/// bought by the word "bank" in an ordinary card/UPI debit, "Refund" must not
/// be bought by "cashback", and "Credit card bill payment" needs a bill — not
/// just a card purchase. Explicit literal spelling of an alias is not evidence
/// either; it always goes through these semantics.
final Map<String, RegExp> _smsAliasCues = {
  'amazon pay later': RegExp(r'\b(?:pay\s+later|axio)\b', caseSensitive: false),
  'bank or service fee': RegExp(r'\b(?:fees?|charges?)\b', caseSensitive: false),
  'bank transfer': RegExp(
    r'\b(?:credited|received|deposited)\b[^.!?\n]{0,100}\bfrom\b[^.!?\n]{0,60}\b(?:bank|a\/?c\.?|account)\b|\bfrom\b[^.!?\n]{0,100}\b(?:bank|a\/?c\.?|account)\b[^.!?\n]{0,60}\b(?:credited|received|deposited)\b',
    caseSensitive: false,
  ),
  'card statement adjustment': RegExp(
    r'\b(?:card|statement)\b[^.!?\n]{0,60}\b(?:credited|adjusted|adjustment)\b|\bcredit(?:ed)?\s+to\s+(?:your\s+)?(?:\w+\s+){0,3}(?:credit\s+)?card\b',
    caseSensitive: false,
  ),
  'cash deposit': RegExp(
    r'\bcash\b[^.!?\n]{0,40}\bdeposit(?:ed)?\b|\bdeposit(?:ed)?\b[^.!?\n]{0,40}\bcash\b',
    caseSensitive: false,
  ),
  'cash withdrawal': RegExp(
    r'\b(?:cash|atm)\b[^.!?\n]{0,40}\bwithdraw(?:al|n)?\b|\bwithdraw(?:al|n)?\b[^.!?\n]{0,40}\b(?:cash|atm)\b',
    caseSensitive: false,
  ),
  'credit card bill payment': RegExp(
    r'\b(?:credit\s+card|card)\b[^.!?\n]{0,80}\bbill\b|\bbill\s+payment\b[^.!?\n]{0,60}\b(?:credit\s+)?card\b|\bcard\s+bill(?:\s+payment)?\b',
    caseSensitive: false,
  ),
  'gift received': RegExp(
    r'\bgift\b[^.!?\n]{0,40}\b(?:received|credited)\b|\b(?:received|credited)\b[^.!?\n]{0,40}\bgift\b',
    caseSensitive: false,
  ),
  'investment contribution': RegExp(
    r'\b(?:sip|systematic\s+investment|mutual\s+fund|invested\s+in)\b',
    caseSensitive: false,
  ),
  'investment proceeds': RegExp(
    r'\b(?:proceeds|redemption|redeem(?:ed)?|payout)\b[^.!?\n]{0,60}\b(?:invest|fund|mutual|broker|securities)\b|\b(?:invest|fund|mutual|broker|securities)\b[^.!?\n]{0,60}\b(?:proceeds|redemption|redeem(?:ed)?|payout)\b',
    caseSensitive: false,
  ),
  'loan disbursement': RegExp(
    r'\b(?:loan|credit\s+line)\b[^.!?\n]{0,60}\bdisburs(?:ed|ement)\b|\bdisburs(?:ed|ement)\b[^.!?\n]{0,40}\bloan\b',
    caseSensitive: false,
  ),
  'loan or emi repayment': RegExp(
    r'\b(?:emi|loan)\b[^.!?\n]{0,60}\b(?:repay(?:ment)?|repaid|paid|debited|deducted)\b|\b(?:repay(?:ment)?|repaid)\b[^.!?\n]{0,40}\b(?:emi|loan)\b',
    caseSensitive: false,
  ),
  'money received': RegExp(
    r'\b(?:credited|received|deposited)\b',
    caseSensitive: false,
  ),
  'reimbursement': RegExp(
    r'\b(?:reimburse(?:ment|d)?|expense\s+claim)\b',
    caseSensitive: false,
  ),
  'refund': RegExp(r'\b(?:refund(?:ed)?|chargeback)\b', caseSensitive: false),
  'reversal': RegExp(r'\brevers(?:al|ed)\b', caseSensitive: false),
  'reward or cashback': RegExp(
    r'\b(?:cashback|reward(?:s)?|points?|miles?)\b[^.!?\n]{0,40}\b(?:credited|received|earned|added|won)\b|\b(?:credited|received|earned|added|won)\b[^.!?\n]{0,40}\b(?:cashback|reward(?:s)?|points?|miles?)\b',
    caseSensitive: false,
  ),
  'salary': RegExp(
    r'\b(?:salary|wages?|payroll|pension)\b',
    caseSensitive: false,
  ),
  'transfer between own accounts': RegExp(
    r'\b(?:self[ -]?transfer|own\s+(?:bank\s+)?account|between\s+(?:my|your)\s+(?:bank\s+)?accounts)\b|\bfrom\s+your\b[\s\S]{0,100}\bto\s+your\b',
    caseSensitive: false,
  ),
  'wallet load': RegExp(
    r'\bwallet\b[^.!?\n]{0,40}\b(?:load(?:ed)?|top[ -]?up|credited|added)\b|\b(?:load(?:ed)?|top[ -]?up)\b[^.!?\n]{0,40}\bwallet\b',
    caseSensitive: false,
  ),
};

bool _smsMerchantGrounded(String? value, String body) {
  final cleaned = smsCleanMerchantName(value);
  if (cleaned == null) return false;
  final transfer = RegExp(
    r'^transfer\s+to\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(cleaned);
  if (transfer != null) {
    final party = smsCleanMerchantName(transfer.group(1));
    return party != null && _smsAppearsInMessage(party, body);
  }
  final cue = _smsAliasCues[cleaned.toLowerCase()];
  if (cue != null) return cue.hasMatch(body);
  return _smsAppearsInMessage(cleaned, body);
}

bool _smsMerchantText(Object? value) =>
    value is String && smsCleanMerchantName(value) != null;

final RegExp _smsReceiptOnlyRe = RegExp(
  r'\b(?:payment\s+receipt|view\s+(?:the\s+)?(?:payment\s+)?receipt|download\s+(?:the\s+)?(?:payment\s+)?receipt|e[-\s]?bill|my\s*bill\s*book|mybillbook|khatabook|okcredit|vyapar)\b',
  caseSensitive: false,
);
final RegExp _smsReceiptCompletionRe = RegExp(
  r'\byour\s+payment\s+of\s+(?:₹|rs\.?|inr)\s*[\d,]+(?:\.\d{1,2})?\s+to\s+[^.;]{1,100}?\s+(?:has|have|was|were)\s+(?:been\s+)?(?:successfully\s+)?(?:recorded|completed|processed|confirmed)\b',
  caseSensitive: false,
);

/// A receipt is independent ledger evidence only when it names the instrument
/// that actually moved money ("A/c ... debited", "card ... charged"). A
/// payment-method mention ("Paid by credit card"), a 4-digit year or card
/// digits without a debit verb are not ledger entries. Mirrors the device
/// parser's receipt settlement check.
final RegExp _smsReceiptSettlementEvidenceRe = RegExp(
  r'\b(?:a\/?c\.?|account|card|wallet)\b[^.!?\n]{0,45}\b(?:debited|deducted|charged|withdrawn)\b|\b(?:debited|deducted|charged|withdrawn)\s+(?:from|to|on|using)\s+(?:your\s+)?(?:credit\s+|debit\s+|bank\s+)?(?:a\/?c\.?|account|card|wallet)\b',
  caseSensitive: false,
);

/// A merchant receipt proves the shop recorded a payment but carries no
/// bank/card ledger identity, so it must not auto-post as a second debit.
bool smsIsReceiptOnlyMessage(String body) {
  if (!_smsReceiptOnlyRe.hasMatch(body)) return false;
  return !_smsReceiptSettlementEvidenceRe.hasMatch(body);
}

bool smsHasReceiptCompletion(String body) =>
    _smsReceiptCompletionRe.hasMatch(body);

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
      : factType == 'posted_movement'
      ? _amountInPostedTransaction(body, paymentAmount)
      : smsAmountAppears(body, smsFactAmountRupees(payload));
  if (amountEvidence) score += 0.40;
  final suffix = payload['last4'] ?? payload['accountLast4'];
  if (suffix is String && suffix.isNotEmpty && body.contains(suffix)) {
    score += 0.25;
  }
  final anchor = smsAnchorForPayload(payload);
  final parsedAnchor = DateTime.tryParse(anchor ?? '');
  final hasReceiptTime =
      (factType == 'posted_movement' || factType == 'bill_payment') &&
      parsedAnchor != null &&
      receivedAt != null &&
      parsedAnchor.difference(receivedAt).inMicroseconds.abs() <=
          const Duration(minutes: 5).inMicroseconds;
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
    r'\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,120}\b(?:completed(?:\s+successfully)?|recorded)\b',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(body)) {
    if (smsAmountAppears(match.group(0)!, amount)) return true;
  }
  return false;
}

bool _amountInPostedTransaction(String body, Object? amount) {
  if (amount is! num || !amount.isFinite || amount <= 0) return false;
  final movementOrCompletion = RegExp(
    r'\b(debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|transfer|processed|payout|settled|disbursed|invested|deposited|sent)\b|\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,100}\b(?:completed(?:\s+successfully)?|recorded)\b',
    caseSensitive: false,
  );
  final currencylessMovement = RegExp(
    r'\b(?:debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|sent)\s+(?:by|with|for|of)\s+([\d,]+(?:\.\d{1,2})?)\b',
    caseSensitive: false,
  );
  final balanceLabel = RegExp(
    r'\b(?:available|avail\.?|current|closing|remaining|ledger)\s*(?:account\s*)?(?:bal(?:ance)?|balance\s+after)\b|\b(?:bal(?:ance)?|balance\s+after)\s*(?:is|after|now|:|=)?',
    caseSensitive: false,
  );
  final clauses = smsCoreTransactionClause(body)
      .split(RegExp(r'[!?;\n]+'))
      .map((clause) => clause.trim())
      .where((clause) => clause.isNotEmpty);
  for (final clause in clauses) {
    if (!movementOrCompletion.hasMatch(clause)) continue;
    final amountMatches = [
      ..._moneyInMessageRe.allMatches(clause),
      // Currencyless Indian bank shape: "debited by 50.00".
      ...currencylessMovement.allMatches(clause),
    ];
    for (final match in amountMatches) {
      final printed = double.tryParse(
        (match.group(1) ?? '').replaceAll(',', ''),
      );
      if (printed == null || (printed - amount).abs() >= 0.005) continue;
      final before = clause.substring(
        math.max(0, match.start - 60),
        match.start,
      );
      final after = clause.substring(
        match.end,
        math.min(clause.length, match.end + 40),
      );
      final balanceMatches = balanceLabel.allMatches(before).toList();
      final movementMatches = RegExp(
        r'\b(debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|transfer|processed|payout|settled|disbursed|invested|deposited|sent)\b',
        caseSensitive: false,
      ).allMatches(before).toList();
      final lastBalance = balanceMatches.isEmpty
          ? -1
          : balanceMatches.last.start;
      final lastMovement = movementMatches.isEmpty
          ? -1
          : movementMatches.last.start;
      if (lastBalance >= 0 && lastMovement <= lastBalance) continue;
      if (RegExp(
        r'\b(?:is|as)\s+(?:your\s+|the\s+)?(?:available\s+|current\s+|closing\s+|remaining\s+)?balance\b',
        caseSensitive: false,
      ).hasMatch(after)) {
        continue;
      }
      return true;
    }
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
      if (_smsMerchantText(payload['merchant']) ||
          _smsMerchantText(payload['transferParty'])) {
        score += 0.25;
      }
      if (_hasValidCategory(payload)) score += 0.25;
      return score;
    case 'bill_obligation':
      var score = 0.0;
      if (_isFiniteNumber(payload['amountDueInr']) &&
          (payload['amountDueInr'] as num) > 0) {
        score += 0.35;
      }
      if (_validDate(payload['dueDate'])) score += 0.35;
      if (_smsMerchantText(payload['billerName'])) score += 0.30;
      return score;
    case 'mandate_lifecycle':
      var score = 0.0;
      if (_isFiniteNumber(payload['limitInr']) &&
          (payload['limitInr'] as num) > 0) {
        score += 0.40;
      }
      if (_smsMerchantText(payload['serviceName']) ||
          _smsMerchantText(payload['merchant'])) {
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
      if (_smsMerchantText(payload['billerName']) ||
          _smsMerchantText(payload['merchant'])) {
        score += 0.4;
      }
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

double _disambiguationScore(
  Map<String, dynamic> payload, [
  String? factType,
  String body = '',
]) {
  var score = 0.0;
  final hasMovementParty =
      _smsMerchantText(payload['merchant']) ||
      _smsMerchantText(payload['transferParty']);
  // Ground through merchant identity, not a raw substring: an opaque ID can
  // appear in the body and still not identify the payee.
  final evidencedParty =
      [
        payload['merchant'],
        payload['transferParty'],
        payload['billerName'],
        payload['serviceName'],
      ].whereType<String>().where((party) => party.trim().isNotEmpty).any(
        (party) => _smsMerchantGrounded(party, body),
      );
  if (factType == 'posted_movement' && hasMovementParty && evidencedParty) {
    return 1.0;
  }
  if (factType == 'bill_obligation' &&
      _smsMerchantText(payload['billerName']) &&
      _smsMerchantGrounded(payload['billerName'] as String, body)) {
    return 1.0;
  }
  if ((_smsMerchantText(payload['merchant']) ||
          _smsMerchantText(payload['billerName']) ||
          _smsMerchantText(payload['serviceName'])) &&
      evidencedParty) {
    score += 0.5;
  }
  if (factType == 'bill_payment' &&
      (_smsMerchantText(payload['merchant']) ||
          _smsMerchantText(payload['billerName'])) &&
      evidencedParty) {
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
  final bool merchantEvidenced;
  final bool completionEvidence;
  final bool receiptOnly;
  final bool receiptCompletion;
  final bool autoResolveEligible;

  const SmsFactConfidence({
    required this.fact,
    required this.composite,
    required this.model,
    required this.evidence,
    required this.completeness,
    required this.disambiguation,
    required this.isComplete,
    required this.merchantEvidenced,
    required this.completionEvidence,
    required this.receiptOnly,
    required this.receiptCompletion,
    required this.autoResolveEligible,
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
  final disambiguation = _disambiguationScore(payload, factType, body);
  final composite = _round4(
    _kModelWeight * model +
        _kEvidenceWeight * evidence +
        _kCompletenessWeight * completeness +
        _kDisambiguationWeight * disambiguation,
  );
  final receiptOnly = smsIsReceiptOnlyMessage(body);
  final receiptCompletion = smsHasReceiptCompletion(body);
  final needsLedgerGate =
      factType == 'posted_movement' || factType == 'bill_payment';
  // First non-empty value, matching the server's `a || b` fallback.
  Object? firstNonEmpty(Object? first, Object? second) =>
      first is String && first.isNotEmpty ? first : second;
  final party = factType == 'bill_payment'
      ? firstNonEmpty(payload['billerName'], payload['merchant'])
      : firstNonEmpty(payload['merchant'], payload['transferParty']);
  final merchantEvidenced =
      !needsLedgerGate ||
      (party is String && _smsMerchantGrounded(party, body));
  final completionEvidence =
      !needsLedgerGate || smsHasCompletionEvidence(body);
  final autoResolveEligible =
      merchantEvidenced && completionEvidence && !receiptOnly;
  return SmsFactConfidence(
    fact: fact,
    composite: composite,
    model: _unitScore(model),
    evidence: evidence,
    completeness: completeness,
    disambiguation: disambiguation,
    isComplete: payload['isComplete'] == true,
    merchantEvidenced: merchantEvidenced,
    completionEvidence: completionEvidence,
    receiptOnly: receiptOnly,
    receiptCompletion: receiptCompletion,
    autoResolveEligible: autoResolveEligible,
  );
}

/// Assesses a whole model result.
///
/// Auto-resolution requires at least one actionable fact, every actionable fact
/// scoring >= [kSmsAutoResolveThreshold], every actionable fact explicitly
/// marked complete by the model, and every posted/bill fact passing the
/// merchant/completion/receipt gate. A missing `isComplete` is never treated as
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
      actionable.length == 1 &&
      actionable.every(
        (entry) => entry.composite >= kSmsAutoResolveThreshold,
      ) &&
      isComplete &&
      actionable.every((entry) => entry.autoResolveEligible);

  return SmsConfidenceAssessment(
    facts: scored,
    composite: composite,
    primaryFact: primaryFact,
    isComplete: isComplete,
    autoResolvable: autoResolvable,
  );
}
