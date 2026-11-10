import '../../../data/sms_gate_filter.dart';
import '../../sms_import/ios_shortcut_sms.dart';
import '../../sms_import/sms_text_hint.dart';
import '../../../data/cached_regexp.dart';

/// Whether the rules may overrule the gate's "unrelated" or "promotion" call
/// for a message from [sender].
///
/// The gate reads keywords, so it rejects some real transactions (a card spend
/// SMS with an "EMI" footer reads as a promotion). A message from a bank or
/// service header is therefore given one pass through the rules before it is
/// dropped. Contact-looking senders and promotional `-P` headers stay
/// rejected, as they are in [classifySmsV2Intake].
bool gateRejectionMayBeOverruled(String sender) {
  final bare = IosShortcutSmsBatch.senderForTriage(sender);
  if (bare.trim().isEmpty) return false;
  return !IosShortcutSmsBatch.looksLikeContactName(bare) &&
      !cachedRegExp(r'-[Pp]$').hasMatch(bare.trim());
}

/// A bank-style alert in wording the keyword lists do not know ("Rs 500 Cr on
/// 14/08", "Cash deposit of Rs 500 in A/c XX12", "Deposit of Rs 500 made in
/// your A/c"): a rupee amount, an account or card number, and a money word.
///
/// A message rejected at this gate is dropped and its text is not kept, so it
/// can never be read, reviewed or learned from. The gate is a filter for
/// messages that are plainly not about money; whether money moved is for the
/// rules and the evidence reader to decide, and what they cannot read goes to
/// review.
///
/// A masked account number beside an amount is enough by itself: a bank masks
/// an account only when it is telling its holder about that account, in
/// whatever words or language ("Aapke A/c XX8163 me Rs 2,340 jama hua"). A
/// plain number needs a money word or a printed balance as well. At most four
/// cached patterns on one message: bounded work (R3).
bool _looksLikeAccountAlert(String body) {
  if (!cachedRegExp(
    r'(?:₹|\brs\.?|\binr)\s*[:.]?\s*\d',
    caseSensitive: false,
  ).hasMatch(body)) {
    return false;
  }
  if (cachedRegExp(
    r'\b(?:a/?c|acct?|account|card)\b[^\n]{0,24}?(?:[x*•]{2,}[\s\-]?\d{2,}|\d{2,6}[x*•]{2,}\d{2,}|\bending\s+(?:with\s+|in\s+)?\d{2,}|\.{2,}\d{2,})',
    caseSensitive: false,
  ).hasMatch(body)) {
    return true;
  }
  return cachedRegExp(
        r'\b(?:a/?c|acct?|account|card)\b[^\n]{0,24}?\b\d{4,}\b',
        caseSensitive: false,
      ).hasMatch(body) &&
      cachedRegExp(
        r'\b(?:cr|dr|credit|debit|deposit|withdrawal|withdrawl|txn|transaction|transfer|trf|neft|imps|rtgs|upi|cheque|chq|cash|bal|balance)\b',
        caseSensitive: false,
      ).hasMatch(body);
}

/// Preserve security/sender exclusions and admit non-spending lifecycles.
SmsTriageResult classifySmsV2Intake(String sender, String body) {
  final previous = classifySmsTriage(sender, body);
  if (previous.kind == SmsTriageKind.financialCandidate ||
      previous.kind == SmsTriageKind.sensitive) {
    return previous;
  }
  final bare = IosShortcutSmsBatch.senderForTriage(sender);
  final gate = SmsGateFilter.evaluate(bare, body);
  if (IosShortcutSmsBatch.looksLikeContactName(bare) ||
      cachedRegExp(r'-[Pp]$').hasMatch(bare.trim())) {
    return previous;
  }
  if (!gate.passed &&
      gate.dropReason != SmsGateDropReason.noFinancialKeywords) {
    return previous;
  }
  if (previous.kind == SmsTriageKind.unrelated && _looksLikeAccountAlert(body)) {
    return const SmsTriageResult(
      SmsTriageKind.financialCandidate,
      'v2_account_alert',
    );
  }
  final lifecycle = cachedRegExp(
    r'\b(?:blocked|released|unblocked|allotted|allotment|asba|lien|mandate|points|reward\s+balance|credit\s+limit)\b',
    caseSensitive: false,
  ).hasMatch(body);
  final account = cachedRegExp(
    r'\b(?:a/?c|account|card|wallet|folio|ipo|asba|mandate|points)\b',
    caseSensitive: false,
  ).hasMatch(body);
  return lifecycle && account && cachedRegExp(r'\d').hasMatch(body)
      ? const SmsTriageResult(
          SmsTriageKind.financialCandidate,
          'v2_financial_lifecycle',
        )
      : previous;
}
