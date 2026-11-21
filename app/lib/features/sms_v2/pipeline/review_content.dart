import 'package:pandapay_domain/sms_v2.dart' show Direction;

import '../../../data/cached_regexp.dart';

// Pure Dart (no Flutter, no providers): the capture pipeline and the review screens share this one wording
// classifier. It moved here from ui/review_clustering.dart, which still exports it.

/// What a message says it is, read from its wording. A hint for labels,
/// filters and totals, never a decision about the money.
enum ReviewContent {
  declined('Declined or failed'),
  security('Security or OTP notice'),
  promotion('Promotion'),
  mandate('Mandate or AutoPay'),
  bill('Bill or due date'),
  balance('Balance update'),
  credit('Money in'),
  debit('Money out'),
  other('Other');

  const ReviewContent(this.label);
  final String label;

  /// Only real movements have an amount worth adding up. A declined payment,
  /// an upcoming mandate or a balance never moved the money it mentions.
  bool get summable => this == credit || this == debit;
}

final _declined = cachedRegExp(
  r'\b(declined|failed|failure|unsuccessful|not successful|rejected|could not be processed|insufficient (?:balance|funds))\b',
  caseSensitive: false,
);
final _security = cachedRegExp(
  r'\botp\b|verification code|one[- ]?time password|do not share|never share|\bcvv\b|login (?:alert|attempt)|password',
  caseSensitive: false,
);
final _promotion = cachedRegExp(
  r'pre-?approved|\boffer\b|apply now|limited time|t&c|terms apply|click here|congratulations|\bwin\b|\bcoupon\b',
  caseSensitive: false,
);
final _mandate = cachedRegExp(
  r'\bmandate\b|auto-?pay|auto[- ]?debit|standing instruction|\bnach\b|e-?mandate',
  caseSensitive: false,
);
final _bill = cachedRegExp(
  r'\bbill\b|statement|minimum (?:amount )?due|total (?:amount )?due|due date|payment due|outstanding',
  caseSensitive: false,
);
final _credit = cachedRegExp(
  r'\b(credited|received|refund(?:ed)?|cashback|deposited|reversed|reversal)\b',
  caseSensitive: false,
);
final _debit = cachedRegExp(
  r'\b(debited|spent|purchase|paid|withdrawn|deducted|charged|txn of|transaction of|used for|sent to|transferred|payment of)\b|\bsent\s+(?:rs\.?|inr|₹)',
  caseSensitive: false,
);
/// Money sent or transferred TO the person ("John sent Rs 300 to you", "Rs 1000
/// transferred to your account"): the debit words in it describe the other side.
final _inbound = cachedRegExp(
  r'\b(?:sent|transferred)\b[^.\n]{0,40}?\bto (?:you|your (?:a/c|account|acc\w*))\b',
  caseSensitive: false,
);
/// The words of [_credit] that mean money coming back (a refund, a reversal,
/// cashback): a message that has them AND a debit verb is about the credit.
final _comingBack = cachedRegExp(
  r'\b(?:refund(?:ed)?|cashback|reversed|reversal)\b',
  caseSensitive: false,
);
/// Money that has not moved (yet): a future debit, a schedule, a request waiting
/// for approval, a pending payment.
final _notYetMoved = cachedRegExp(
  r'\bwill be (?:debited|charged|deducted|auto-?debited|collected|processed)\b|\bscheduled\b|\bupcoming\b|\brequested\b|\bcollect request\b|\bpending\b',
  caseSensitive: false,
);
final _balance = cachedRegExp(
  r'\b(?:avl|available|a/c|account) ?(?:bal|balance)\b|\bbalance\b',
  caseSensitive: false,
);

/// The content type of a message body. Order matters: a declined payment that
/// also says "Not you? Call" is declined, not a security notice.
ReviewContent classifyReviewContent(String body) {
  if (_declined.hasMatch(body)) return ReviewContent.declined;
  if (_security.hasMatch(body)) return ReviewContent.security;
  if (_mandate.hasMatch(body)) return ReviewContent.mandate;
  if (_bill.hasMatch(body)) return ReviewContent.bill;
  if (_promotion.hasMatch(body) &&
      !_debit.hasMatch(body) &&
      !_credit.hasMatch(body)) {
    return ReviewContent.promotion;
  }
  // Money sent TO the person reads with debit words ("sent ... to you"): those
  // describe the other side, so they are left out of the debit test.
  final inbound = _inbound.firstMatch(body);
  final debitText = inbound == null ? body : body.replaceAll(_inbound, ' ');
  final isCredit = _credit.hasMatch(body) || inbound != null;
  final isDebit = _debit.hasMatch(debitText);
  if (isDebit && !isCredit) return ReviewContent.debit;
  if (isCredit && !isDebit) return ReviewContent.credit;
  // Both verbs ("debited ... will be credited"): the first one is the event.
  if (isDebit && isCredit) {
    final d = _debit.firstMatch(debitText)!.start;
    final c = _credit.firstMatch(body)?.start ?? inbound!.start;
    return d < c ? ReviewContent.debit : ReviewContent.credit;
  }
  // A balance notice only mentions a balance. A message with an amount before
  // its "Avl Bal" is describing something that happened to the money in a
  // wording we do not know, so it must not be filed as a harmless balance
  // update (where it would sit under the alerts that can be dismissed in
  // bulk).
  final balance = _balance.firstMatch(body);
  if (balance != null) {
    final amount = _amount.firstMatch(body);
    if (amount == null || amount.start > balance.start) {
      return ReviewContent.balance;
    }
  }
  return ReviewContent.other;
}

final _amount = cachedRegExp(
  r'(?:₹|\brs\.?|\binr)\s*([\d,]+(?:\.\d{1,2})?)(?!\d)',
  caseSensitive: false,
);

/// The direction the message's own words give the money, or null when they do
/// not give one clearly. Only a message that [classifyReviewContent] files as
/// money in or money out, and that uses the verbs of just one of the two (a
/// message with both "debited" and "credited" is not clear), has a direction.
/// A hint for spotting an AI reading that contradicts its message, never a
/// decision about the money.
Direction? wordingDirection(String body) {
  final content = classifyReviewContent(body);
  if (content != ReviewContent.debit && content != ReviewContent.credit) {
    return null;
  }
  final inbound = _inbound.hasMatch(body);
  final isCredit = _credit.hasMatch(body) || inbound;
  final isDebit = _debit.hasMatch(inbound ? body.replaceAll(_inbound, ' ') : body);
  // A refund, a reversal or cashback beside a debit verb ("debited ... was
  // reversed and credited back") is money coming back.
  if (isCredit && isDebit && _comingBack.hasMatch(body)) return Direction.credit;
  if (isCredit == isDebit) return null;
  return isCredit ? Direction.credit : Direction.debit;
}

/// True when the message says the money has not moved (yet): a future debit, a
/// schedule, a request, a pending payment. A reading that books such a message
/// as money that moved is unsure.
bool saysNotYetMoved(String body) => _notYetMoved.hasMatch(body);

/// True for a kind of message that never moves money by itself (a declined
/// payment, an OTP or security notice, a promotion). A mandate or a bill is
/// left out on purpose: a real charge is often worded as one.
bool isNeverAMovement(String body) => switch (classifyReviewContent(body)) {
  ReviewContent.declined ||
  ReviewContent.security ||
  ReviewContent.promotion => true,
  _ => false,
};
