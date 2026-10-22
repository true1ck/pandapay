/// UA-5.3 (Chunk 31): pure-Dart, on-device half of SMS auto-import — no
/// platform channel, no `telephony` plugin, in this file. Kept separate
/// from the listener wiring (`sms_listener_service.dart`) for the same
/// reason UA-4 (Chunk 30) split `card_text_matcher.dart` out from
/// `card_scanner.dart`: this half is unit-testable without a device.
///
/// The actual amount/merchant/date parsing is done server-side by
/// `api/src/sms_parser.js` against the admin-managed `parser_patterns`
/// table (that's the part with real regex catalogue + telemetry). This
/// file does NOT duplicate that. What it does is a much narrower,
/// deliberately dumb job: pull a plausible last-4-digit "card ending in
/// ____" hint out of raw SMS text purely so the on-device UI can show the
/// user something ("this SMS looks like it's for a card ending 4321 — pick
/// which of your cards that is") when asking them to confirm which
/// `userCardId` a parsed SMS should be attributed to. `user_cards` has no
/// last4 column in this schema (checked db/supabase/migrations/0004 and
/// 0006), so this can never be an automatic match — it's a display hint
/// only, and callers must not treat it as a resolved card id.
library;

import '../../data/local_sms_parser.dart';

/// Returns a bare 4-digit string if [smsBody] contains a "ending NNNN" /
/// "XXNNNN" / "card NNNN" style last-4 mention, else null. Deliberately
/// conservative: multiple distinct 4-digit candidates (e.g. an OTP or a
/// reference number sitting next to the real card suffix) means "not
/// confident enough" — returns null rather than guessing which one.
String? extractLast4Hint(String smsBody) {
  // Task S-1a (D3) widened this. It previously matched `ending 4321` and
  // `XX7788` but NOT `Card x1234` — which is one of the most common shapes
  // in Indian bank SMS, and `****1234` / `...1234` / `a/c no. 1234` were
  // missed too. That mattered little when the hint was a cosmetic label,
  // but the backup importer now GROUPS messages by it to decide which card
  // each one belongs to, so a missed shape means a whole card's worth of
  // transactions falls into the anonymous bucket.
  //
  // The masking prefixes (`x`, `xx`, `*`, `.`) are matched as a repeated
  // class rather than spelled out one alternative at a time, so `x1234`,
  // `XX1234`, `****1234` and `...1234` are one rule.
  final matches = RegExp(
    r'(?:'
    r'(?:ending|ending\s+with|card(?:\s+no\.?)?|a\/c(?:\s+no\.?)?|acct?(?:\s+no\.?)?)'
    r'\s*[:\-]?\s*[x*.\s]*'
    r'|[x*]{1,2}|\*{2,}|\.{3,}'
    r')(\d{4})\b',
    caseSensitive: false,
  ).allMatches(smsBody).map((m) => m.group(1)!).toSet();

  // Still deliberately conservative: two distinct candidates (an OTP or a
  // reference number sitting next to the real suffix) means "not confident
  // enough" rather than a guess. A wrong card attribution is worse than an
  // unattributed message the user can place themselves.
  if (matches.length != 1) return null;
  return matches.first;
}

/// OTP and security alerts must never be persisted or uploaded — they often
/// contain "txn", "INR", and a card suffix that would read like spend.
bool _looksOtpOrSecurity(String lower) {
  return RegExp(
        r'\b(?:otp|one[-\s]?time password|verification code|security code|cvv|pin)\b',
      ).hasMatch(lower) ||
      RegExp(r"\b(?:do not|don't|never)\s+share\b").hasMatch(lower) ||
      RegExp(r'\bvalid\s+(?:for|till|until)\b').hasMatch(lower);
}

const _promoWords = [
  'apply now',
  'pre-approved',
  'lifetime free',
  'ltf',
  'personal loan',
  'enjoy',
  'exclusive offer',
  'get free',
  'special offer',
];

bool _looksPromotional(String lower) => _promoWords.any(lower.contains);

/// Rough client-side pre-filter for "does this look like a bank
/// transaction SMS at all" — used only to decide whether it's worth
/// forwarding to POST /transactions/from-sms in the first place (avoids
/// spamming the server/parser_failures table with every unrelated SMS a
/// device receives, e.g. OTPs, delivery notifications, spam). This is
/// intentionally loose/high-recall: the real accept/reject decision is the
/// server-side regex match, not this. A false positive here just costs one
/// extra API call; a false negative here means a real transaction is
/// silently never even attempted.
bool looksLikeTransactionSms(String smsBody) {
  final lower = smsBody.toLowerCase();

  // OTP and security alerts often contain "txn", "INR", and a card suffix.
  // Reject them before the high-recall keyword check so they never reach the
  // importer or appear in Needs Review as if they were failed transactions.
  if (_looksOtpOrSecurity(lower)) return false;

  // These alerts describe a failed, cancelled, reversed, pending, or
  // refunded attempt. They are not completed spending and must never become
  // a spend row just because they contain an amount and the word "txn".
  const nonSpendWords = [
    'declined',
    'decline',
    'failed',
    'failure',
    'cancelled',
    'canceled',
    'pending',
  ];
  if (nonSpendWords.any(lower.contains)) return false;

  // 1. Hard reject obvious promotional spam
  if (_looksPromotional(lower)) return false;

  // 2. Must contain transaction keywords
  const keywords = [
    'spent',
    'debited',
    'credited',
    'received',
    'deposited',
    'refund',
    'reversal',
    'txn',
    'transaction',
    'purchase',
    'paid',
    'used for',
    'used at',
    'charged',
    'withdrawn',
    'payment of',
    'ending with',
    'ending in',
    'card no',
    'a/c',
    'alert:',
    'inr',
    'rs.',
    'rs ',
    '₹',
  ];
  if (keywords.any(lower.contains)) return true;

  // Statement/bill alerts are not spend alerts, but they are still required
  // by the due-date engine. These messages often contain only a card suffix,
  // a due date, and a statement amount, so the old transaction-only gate
  // silently discarded them before the API could learn the card's due day.
  const dueDateWords = [
    'payment due',
    'due date',
    'due on',
    'due by',
    'minimum amount due',
    'min amt due',
    'minimum due',
    'total amount due',
    'amount payable',
    'bill payable',
    'payable by',
    'pay by',
    'pay before',
    'pay on or before',
    'payment deadline',
    'last date for payment',
    'last date',
    'statement generated',
    'statement is generated',
    'bill generated',
    'keep sufficient funds',
    'maintain sufficient balance',
    'clear funds',
  ];
  return dueDateWords.any(lower.contains);
}

/// SMS intelligence Phase 2: the capture decision for inbox entry points
/// (live delivery, background handler, incremental scan). Spend candidates
/// keep the exact [looksLikeTransactionSms] behavior; this additionally
/// captures recognized NON-spend financial messages — autopay mandate
/// registration/cancellation/failure and declined payment attempts — so
/// their typed facts reach the server instead of being silently discarded
/// on-device. Bill/statement and balance messages already pass the strict
/// gate. OTP/safety vetoes and promo rejection stay absolute.
enum SmsTriageKind {
  financialCandidate,
  promotion,
  unrelated,
  sensitive,
}

class SmsTriageResult {
  final SmsTriageKind kind;
  final String reasonCode;

  const SmsTriageResult(this.kind, this.reasonCode);
}

SmsTriageResult classifySmsTriage(String sender, String smsBody) {
  if (smsBody.trim().isEmpty) {
    return const SmsTriageResult(SmsTriageKind.unrelated, 'empty_body');
  }
  final lower = smsBody.toLowerCase();
  if (_looksOtpOrSecurity(lower) || LocalSmsParser.sensitive(smsBody)) {
    return const SmsTriageResult(SmsTriageKind.sensitive, 'security_message');
  }

  final emiSolicitation =
      RegExp(
        r'\b(?:eligible\s+for\s+conversion|convert(?:ion)?\s+(?:to|into)\s+(?:flexipay\s+)?emi|flexipay\s+emis?)\b',
      ).hasMatch(lower) &&
      !RegExp(r'\b(?:your\s+)?(?:txn|transaction)\s+of\b').hasMatch(lower);
  if (emiSolicitation) {
    return const SmsTriageResult(SmsTriageKind.promotion, 'emi_solicitation');
  }

  final strongFinancialEvidence = RegExp(
    r'\b(?:debited|credited|spent|paid|charged|transferred|withdrawn|received|deposited|refunded)\b|\b(?:txn|transaction|purchase|recharge|payment)\b[\s\S]{0,55}\b(?:successful|completed|processed)\b|\b(?:amount|payment|minimum|total)\s+due\b|\bdue\s+(?:date|on|by)\b|\b(?:statement|bill|premium)\b[\s\S]{0,100}\b(?:generated|ready|available|due)\b|\b(?:available|current|closing)\s+balance\b|\bcredit\s+limit\b',
  ).hasMatch(lower);

  final balanceSnapshotEvidence = RegExp(
    r'\b(?:available|current|closing)\s+balance\b[\s\S]{0,60}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?|\bcredit\s+limit\b[\s\S]{0,30}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?',
  ).hasMatch(lower);

  if (LocalSmsParser.isNonTransactionNoise(sender, smsBody) &&
      !balanceSnapshotEvidence) {
    return const SmsTriageResult(SmsTriageKind.promotion, 'promotional_noise');
  }

  if (strongFinancialEvidence) {
    return const SmsTriageResult(SmsTriageKind.financialCandidate, 'financial_evidence');
  }

  if (RegExp(r'\b(?:auto[-\s]?pay|e[-\s]?mandate|mandate)\b').hasMatch(lower)) {
    return const SmsTriageResult(SmsTriageKind.financialCandidate, 'mandate_lifecycle');
  }

  final failedAttempt =
      RegExp(r'\b(?:declined?|failed|failure)\b').hasMatch(lower) &&
      RegExp(r'(?:inr|rs\.|rs\s|₹)').hasMatch(lower) &&
      RegExp(
        r'\b(?:txn|transaction|purchase|payment|card|a\/?c\.?|account)\b',
      ).hasMatch(lower);
  if (failedAttempt) {
    return const SmsTriageResult(SmsTriageKind.financialCandidate, 'failed_attempt');
  }

  if (_looksPromotional(lower)) {
    return const SmsTriageResult(SmsTriageKind.promotion, 'promotional_message');
  }

  if (looksLikeTransactionSms(smsBody)) {
    return const SmsTriageResult(SmsTriageKind.financialCandidate, 'possible_financial');
  }

  return const SmsTriageResult(SmsTriageKind.unrelated, 'no_financial_signal');
}

bool capturesFinancialSms(String smsBody, {String sender = ''}) {
  return classifySmsTriage(sender, smsBody).kind == SmsTriageKind.financialCandidate;
}
