import 'foreign_money.dart';

/// Monetary roles are a safety boundary shared by built-in/downloaded parsing
/// and AI evidence. An INR balance beside a foreign charge is never its price.
class SmsAmountEvidence {
  static final _inr = RegExp(
    r'(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final _codes = currencyMinorUnits.keys
      .where(isForeignCurrency)
      .join('|');
  static final _foreign = RegExp(
    r'\b(?:' +
        _codes +
        r')\s*[:.]?\s*(?=[\d.])|(?:US\$|\$|€|£)\s*(?=[\d.])|[\d.]\s+(?:' +
        _codes +
        r')\b',
    caseSensitive: false,
  );
  static final _nonPayment = RegExp(
    r'\b(?:(?:available|avail|avl|current|closing|remaining|ledger|total|cash)\.?\s*(?:credit\s*|cash\s*|account\s*)?(?:bal(?:ance)?|lmt|limit)|credit\s+limit|(?:bal(?:ance)?|limit|lmt)|outstanding|(?:minimum|total)\s+(?:amount\s+)?due)\b',
    caseSensitive: false,
  );
  static final _movement = RegExp(
    r'\b(?:debited|deducted|spent|paid|charged|credited|received|refunded|withdrawn|transferred|settled|disbursed|deposited|billed|equivalent|converted|txn\s+amount|transaction\s+amount)\b',
    caseSensitive: false,
  );
  static final _currencyless = RegExp(
    r'\b(?:debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|sent)\s+(?:by|with|for|of)\s+([\d,]+(?:\.\d{1,2})?)\b',
    caseSensitive: false,
  );
  static bool getForeign(String body) => _foreign.hasMatch(body);
  static bool hasInr(String body) => _inr.hasMatch(body);
  static bool isPaymentMention(String body, RegExpMatch match) =>
      _paymentCandidate(body, match);

  static bool _paymentCandidate(String body, RegExpMatch match) {
    final after = body.substring(match.end);
    final amountBeforeMovement = RegExp(
      r'^\s*(?:has\s+been\s+)?(?:spent|debited|paid|charged|credited|refunded|withdrawn|transferred)\b',
      caseSensitive: false,
    ).hasMatch(after);
    final before = body.substring(0, match.start);
    final labels = _nonPayment.allMatches(before).toList();
    final movements = _movement.allMatches(before).toList();
    if (labels.isNotEmpty &&
        !amountBeforeMovement &&
        (movements.isEmpty || movements.last.start <= labels.last.start)) {
      return false;
    }
    if (RegExp(
      r'^\s*(?:(?:is|as)\s+)?(?:your\s+|the\s+)?(?:(?:available|remaining|credit|cash|closing|current)\s+)*(?:balance|bal|limit|lmt)\b',
      caseSensitive: false,
    ).hasMatch(after)) {
      return false;
    }
    return true;
  }

  static List<RegExpMatch> paymentAmounts(String body) =>
      _inr.allMatches(body).where((m) => _paymentCandidate(body, m)).toList();
  static String? firstPaymentAmount(String body) =>
      paymentAmounts(body).firstOrNull?.group(1);

  static bool permits(String body, num amount) =>
      [
        ...paymentAmounts(body),
        if (!getForeign(body)) ..._currencyless.allMatches(body),
      ].any((m) {
        final printed = num.tryParse(m.group(1)!.replaceAll(',', ''));
        return printed != null && (printed - amount).abs() < .005;
      });
  static bool isNonPaymentAmount(String body, num amount) =>
      _inr.allMatches(body).any((m) {
        final printed = num.tryParse(m.group(1)!.replaceAll(',', ''));
        return !_paymentCandidate(body, m) &&
            printed != null &&
            (printed - amount).abs() < .005;
      });

  /// A foreign-currency charge needs an independently printed INR posting.
  /// This also blocks domestic fallback from taking an INR balance/limit.
  static String? reviewReason(String body) {
    if (!getForeign(body) && _currencyless.hasMatch(body)) return null;
    if (getForeign(body) &&
        _movement.hasMatch(body) &&
        paymentAmounts(body).isEmpty) {
      return 'foreign_currency_needs_billed_inr';
    }
    if (hasInr(body) && paymentAmounts(body).isEmpty) {
      return 'transaction_amount_not_evidenced';
    }
    return null;
  }
}
