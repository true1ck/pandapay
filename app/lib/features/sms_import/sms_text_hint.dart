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
      RegExp(
        r'\b\d{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+\d+\s*(?:minutes?|mins?|seconds?|secs?)\b',
      ).hasMatch(lower);
}

const _promoWords = [
  'apply now',
  'pre-approved',
  'pre approved',
  'lifetime free',
  'ltf',
  'personal loan',
  'enjoy',
  'exclusive offer',
  'get free',
  'special offer',
  'festive offer',
  'limited period offer',
  'use code',
  'promo code',
  'coupon code',
  'recharge offer',
  'cashback offer',
  'win up to',
  'claim your',
  'instant loan',
  'congratulations',
  'hurry',
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

  // 2. Statement/bill alerts are required by the due-date engine.
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
  if (dueDateWords.any(lower.contains)) return true;

  // 3. Core financial movement verbs
  final hasMovementVerb = RegExp(
    r'\b(?:spent|debited|credited|withdrawn|charged|transferred|refund(?:ed)?|revers(?:al|ed)|payout|settlement|received|deposited)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  if (hasMovementVerb) return true;

  // 4. Explicit payment or card cue with amount
  // 3-pillar validation: never return true on standalone currency tokens ('rs.', 'inr', '₹')
  // or 'a/c' alone. Require an amount combined with an explicit payment/txn cue OR an explicit card cue.
  final hasCurrencyWithAmount = RegExp(
    r'(?:inr|rs\.?|rs\s|₹)\s*[\d,]+(?:\.\d{1,2})?|[\d,]+(?:\.\d{1,2})?\s*(?:inr|rs\.?|₹)',
    caseSensitive: false,
  ).hasMatch(lower);

  if (hasCurrencyWithAmount) {
    final hasPaymentCue = RegExp(
      r'\b(?:payment(?:\s+of)?|purchase(?:\s+of)?|paid|used\s+(?:for|at)|txns?|transactions?)\b',
      caseSensitive: false,
    ).hasMatch(lower);

    final hasExplicitCardCue = RegExp(
      r'\b(?:card\b[\s\S]{0,35}?(?:ending|no\.?|xx|\*{2,}|\.{3,}|\d{4})|credit\s+card|debit\s+card)\b',
      caseSensitive: false,
    ).hasMatch(lower);

    if (hasPaymentCue || hasExplicitCardCue) return true;
  }

  return false;
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

  final cleanSender = sender.trim();
  if (cleanSender.isNotEmpty) {
    // 10-digit mobile numbers are P2P chats or smishing fraud; Indian banks never send transaction alerts from them.
    final is10DigitP2p = RegExp(r'^(?:\+?91[\-\s]?|0)?[6-9]\d{9}$').hasMatch(cleanSender);
    if (is10DigitP2p) {
      return const SmsTriageResult(SmsTriageKind.unrelated, 'p2p_mobile_number');
    }

    // TRAI 140-series telemarketing CLI (10 digits starting with 140)
    final isTrai140Promo = RegExp(r'^(?:\+?91[\-\s]?|0)?140\d{7}$').hasMatch(cleanSender);
    if (isTrai140Promo) {
      return const SmsTriageResult(SmsTriageKind.promotion, 'numeric_promotional_sender');
    }

    // 6-digit numeric headers where digit 1-8 is bulk promotional SMS (TRAI DLT)
    final isNumericPromo = RegExp(r'^(?:[A-Za-z]{2}-)?\d{6}(?:-[A-Za-z])?$').hasMatch(cleanSender);
    if (isNumericPromo) {
      return const SmsTriageResult(SmsTriageKind.promotion, 'numeric_promotional_sender');
    }

    // Suffix -P / -p: Treat as promotional route. Discard unless it contains an unambiguous completed card/account transaction alert.
    final isPromotionalRoute = RegExp(r'-[Pp]$').hasMatch(cleanSender);
    if (isPromotionalRoute) {
      final isCompletedOrBill = LocalSmsParser.isCompletedTransactionOrBill(smsBody);
      if (!isCompletedOrBill) {
        return const SmsTriageResult(SmsTriageKind.promotion, 'promotional_route_sender');
      }
    }
  }

  final emiSolicitation = RegExp(
    r'\b(?:eligible\s+for\s+(?:[\w\s]{0,20}\s+)?(?:conversion|emis?)|convert(?:ed|ing)?\b[\s\S]{0,60}?\b(?:in)?to\b[\s\S]{0,20}?\b(?:smart\s+|flexipay\s+|easy\s+)?emis?|can\s+(?:now\s+)?be\s+converted\s+(?:in)?to\s+emis?|flexipay\s+emis?)\b',
  ).hasMatch(lower);
  if (emiSolicitation &&
      !RegExp(r'\b(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)\b').hasMatch(lower) &&
      !RegExp(r'\b(?:debited|spent|charged)\s*(?:by|with|for)?\s*(?:₹|rs\.?|inr)').hasMatch(lower)) {
    return const SmsTriageResult(SmsTriageKind.promotion, 'emi_solicitation');
  }

  final strongFinancialEvidence = RegExp(
    r'\b(?:debited|credited|debit|credit|spent|paid|charged|transferred|withdrawn|withdrawal|received|deposited|refund|refunded|reversal|reversed|payout|settlement|deducted|sent)\b|\b(?:txn|transaction|purchase|recharge|payment)\b[\s\S]{0,55}\b(?:successful|completed|processed)\b|\b(?:amount|payment|minimum|total)\s+due\b|\bdue\s+(?:date|on|by)\b|\b(?:statement|bill|premium)\b[\s\S]{0,100}\b(?:generated|ready|available|due)\b|\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b',
  ).hasMatch(lower) || (
    RegExp(r'\bcredit\s+limit\b').hasMatch(lower) &&
    RegExp(r'\b(?:a\/?c|account|card)\b[\s\S]{0,30}\b(?:ending|no\.?|xx|\*{2,})\b').hasMatch(lower) &&
    !RegExp(r'\b(?:apply\s+now|pre[-\s]?approved|upgrade\s+your|zero\s+joining\s+fee|no\s+annual\s+fee|lifetime\s+free)\b').hasMatch(lower)
  );

  final balanceSnapshotEvidence = RegExp(
    r'\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b[\s\S]{0,60}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?|\b(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?[\s\S]{0,40}\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b',
  ).hasMatch(lower) || (
    RegExp(r'\bcredit\s+limit\b[\s\S]{0,30}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?').hasMatch(lower) &&
    RegExp(r'\b(?:a\/?c|account|card)\b[\s\S]{0,30}\b(?:ending|no\.?|xx|\*{2,})\b').hasMatch(lower) &&
    !RegExp(r'\b(?:apply\s+now|pre[-\s]?approved|upgrade\s+your|zero\s+joining\s+fee|no\s+annual\s+fee|lifetime\s+free)\b').hasMatch(lower)
  );

  if (LocalSmsParser.isNonTransactionNoise(sender, smsBody) &&
      !balanceSnapshotEvidence) {
    return const SmsTriageResult(SmsTriageKind.promotion, 'promotional_noise');
  }

  if (LocalSmsParser.isMerchantReceiptOrEbill(smsBody)) {
    return const SmsTriageResult(
      SmsTriageKind.financialCandidate,
      'merchant_ebill_receipt',
    );
  }

  if (strongFinancialEvidence) {
    return const SmsTriageResult(SmsTriageKind.financialCandidate, 'financial_evidence');
  }

  if (RegExp(r'\b(?:auto[-\s]?pay|e[-\s]?mandate|mandate|auto[-\s]?debit|sip\b|standing\s+instruction)\b').hasMatch(lower) ||
      LocalSmsParser.isAutoPayNotice(smsBody)) {
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
