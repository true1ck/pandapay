import '../../../data/sms_gate_filter.dart';
import '../../sms_import/ios_shortcut_sms.dart';
import '../../sms_import/sms_text_hint.dart';
import '../../../data/cached_regexp.dart';

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
