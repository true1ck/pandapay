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
  if (!gate.passed && gate.dropReason != SmsGateDropReason.noFinancialKeywords) {
    return previous;
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
