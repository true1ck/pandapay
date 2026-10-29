import 'local_sms_parser.dart';
import 'sms_security_policy.dart';

enum SmsGateAction { pass, drop }

enum SmsGateDropReason {
  emptyOrMalformed,
  otpOrSecurity,
  telemarketingOrP2p,
  dematOrSecuritiesAlert,
  promotionalNoise,
  noFinancialKeywords,
}

class SmsGateVerdict {
  final SmsGateAction action;
  final SmsGateDropReason? dropReason;
  final String normalizedSender;

  bool get shouldPass => action == SmsGateAction.pass;
  bool get passed => action == SmsGateAction.pass;

  const SmsGateVerdict.pass({required this.normalizedSender})
      : action = SmsGateAction.pass,
        dropReason = null;

  const SmsGateVerdict.drop(this.dropReason, {this.normalizedSender = ''})
      : action = SmsGateAction.drop;
}

/// 5-Gate ultra-fast triage filter that executes before regex parsing.
/// Drops 70-80% of bulk non-financial SMS in < 0.1ms without touching SQLite.
class SmsGateFilter {
  // Regex for stripping TRAI DLT carrier prefixes (e.g. VK-, AD-, JD-, BZ-)
  // and route suffixes (e.g. -S, -P, -T, -G, -B).
  static final _dltPrefixRe = RegExp(r'^[A-Za-z]{2}-');
  static final _dltSuffixRe = RegExp(r'-[A-Za-z]$');

  // TRAI telemarketing 140-series CLI, Indian 10-digit mobile phone numbers,
  // and 6-digit numeric promotional sender headers
  static final _p2pOrTelemarketingRe = RegExp(
    r'^(?:\+?91[\-\s]?|0)?(?:140\d{7}|[6-9]\d{9})$|^(?:[A-Za-z]{2}-)?\d{6}(?:-[A-Za-z])?$',
  );

  // Device registration remains an independent security veto.
  static final _registrationSecurityRe = RegExp(
    r'\bregistration\s+alert\s*:\s*device\s+name\b',
    caseSensitive: false,
  );

  // Gate 4: Demat, CDSL/NSDL depository share movements & broker noise
  static final _dematDepositoryRe = RegExp(
    r'\b(?:cdsl|nsdl)\s*:\s*(?:debit|credit)\s+in\s+a/?c\b[\s\S]{0,40}\b(?:etf|bees|shares?|units?|mf)\b|'
    r'\b(?:cdsl|nsdl)\s*:\s*(?:unpledge|pledge)\b|'
    r'\b(?:updated\s+(?:your\s+)?address\s+(?:under|of)\s+folio|address\s+in\s+folio[^\w\n]*\w+\s+(?:is|has\s+been)\s+updated|based\s+on\s+(?:the\s+)?feed\s+received\s+from\s+kra)\b|'
    r'\b(?:bse\s+trade\s+confirmation|welcome\s+to\s+nse,\s+you\s+have\s+been\s+registered\b|registered\s+with\s+[\w\s]+in\s+segment(?:\(s\))?|traded\s+value\s+for\b|unsolicited\s+tips|online\s+investment\s+scams)\b',
    caseSensitive: false,
  );

  // Early operational/promotional noise patterns
  static final _earlyNoiseRe = RegExp(
    r'\bdue\s+to\s+scheduled\s+maintenance\b[\s\S]{0,80}\b(?:paused|unavailable|interrupted)\b|'
    r'\bregistration\s+alert\s*:\s*device\s+name\b|'
    r'\bcoupons?\s+expire\b|'
    r'\b(?:order\b[\s\S]{0,40}\b(?:is\s+)?dispatched\s+through|order\s+(?:is\s+)?dispatched\s+through|we\s+have\s+received\s+your\s+order\s+id)\b|'
    r'\blifetime[- ]free\s+credit\s+card\s+facility\s+has\s+been\s+enabled\b|'
    r'\b(?:two\s+wheeler|car|motor|vehicle)?\s*insurance\s+for\b[\s\S]{0,50}\b(?:has\s+expired|expires\s+today|will\s+expire)\b|'
    r'\b(?:two\s+wheeler|car|motor|vehicle)?\s*insurance\s+expired\b|'
    r'\b(?:betting\s+(?:site|app)|gullybet|casino|slots|aviator|cockfight|fancy\s+bet|teen\s+patti|online\s+gambling)\b',
    caseSensitive: false,
  );

  // Fast indicator tokens: at least one must exist for a financial message
  static final _currencyOrAmountIndicatorRe = RegExp(
    r'(?:₹|rs\.?|inr|usd|eur|gbp|\$)\s*[:.]?\s*[\d,]+|\b(?:amount|amt|total|bal|balance|limit)\b',
    caseSensitive: false,
  );

  static final _movementVerbIndicatorRe = RegExp(
    r'\b(?:debited|credited|spent|paid|charged|transferred|withdrawn|withdrawal|received|deposited|refund|refunded|reversal|reversed|due|autopay|mandate|bill|statement|invoice)\b',
    caseSensitive: false,
  );

  static final _balanceSnapshotRe = RegExp(
    r'\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b[\s\S]{0,60}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?|\b(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?[\s\S]{0,40}\b(?:available|current|closing|avl|avail)\s+(?:bal(?:ance)?|limit)\b|\bcredit\s+limit\b[\s\S]{0,30}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?',
    caseSensitive: false,
  );

  /// Strips TRAI DLT 2-character prefix and route suffix to return canonical bank identifier.
  /// Example: 'VK-HDFCBK-S' -> 'HDFCBK', 'AD-ICICIB' -> 'ICICIB'.
  static String cleanDltHeader(String sender) {
    var cleaned = sender.trim();
    cleaned = cleaned.replaceFirst(_dltPrefixRe, '');
    cleaned = cleaned.replaceFirst(_dltSuffixRe, '');
    return cleaned.toUpperCase();
  }

  /// Evaluates an SMS through the 5 gates in order of computational cost.
  static SmsGateVerdict evaluate(String sender, String body) {
    // Gate 1: Length & character bounds
    if (body.isEmpty || body.length > 20000) {
      return const SmsGateVerdict.drop(SmsGateDropReason.emptyOrMalformed);
    }

    final trimmedSender = sender.trim();

    // Gate 2: Security & OTP veto (never persists or processes security secrets)
    if (SmsSecurityPolicy.sensitive(body) ||
        _registrationSecurityRe.hasMatch(body)) {
      return const SmsGateVerdict.drop(SmsGateDropReason.otpOrSecurity);
    }

    // Gate 3: Sender header validation (reject P2P 10-digit numbers & 140 telemarketing)
    if (trimmedSender.isNotEmpty && _p2pOrTelemarketingRe.hasMatch(trimmedSender)) {
      return const SmsGateVerdict.drop(SmsGateDropReason.telemarketingOrP2p);
    }

    // Check promotional route suffix (-P)
    final actionableInsuranceRenewal =
        LocalSmsParser.isActionableInsuranceRenewal(body);
    final isPromoRoute = RegExp(r'-[Pp]$').hasMatch(trimmedSender);
    if (isPromoRoute &&
        !LocalSmsParser.isCompletedTransactionOrBill(body) &&
        !actionableInsuranceRenewal) {
      return const SmsGateVerdict.drop(SmsGateDropReason.promotionalNoise);
    }

    // Gate 4: Demat depository & securities non-cash movement
    if (_dematDepositoryRe.hasMatch(body)) {
      return const SmsGateVerdict.drop(SmsGateDropReason.dematOrSecuritiesAlert);
    }

    if (_earlyNoiseRe.hasMatch(body) &&
        !_balanceSnapshotRe.hasMatch(body) &&
        !actionableInsuranceRenewal) {
      return const SmsGateVerdict.drop(SmsGateDropReason.promotionalNoise);
    }

    // Gate 5: Fast Financial Indicators check (currency or transaction verbs)
    final hasAmountOrBalance = _currencyOrAmountIndicatorRe.hasMatch(body);
    final hasMovementVerb = _movementVerbIndicatorRe.hasMatch(body);

    if (!hasAmountOrBalance &&
        !hasMovementVerb &&
        !actionableInsuranceRenewal) {
      return const SmsGateVerdict.drop(SmsGateDropReason.noFinancialKeywords);
    }

    // If it is known non-transaction noise (e.g. general service notices, app ads)
    if (LocalSmsParser.isNonTransactionNoise(sender, body) &&
        !_balanceSnapshotRe.hasMatch(body)) {
      return const SmsGateVerdict.drop(SmsGateDropReason.promotionalNoise);
    }

    return SmsGateVerdict.pass(normalizedSender: cleanDltHeader(sender));
  }
}
