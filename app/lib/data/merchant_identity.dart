class MerchantIdentity {
  const MerchantIdentity._();

  static final _urlRe = RegExp(
    r'(?:https?:\/\/|www\.|\b[A-Za-z0-9-]+\.(?:com|in|co|io|net|org|app|me)(?:\/|\b))',
    caseSensitive: false,
  );
  static final _letterRe = RegExp(r'\p{L}', unicode: true);
  static const _genericNames = {
    'unknown', 'unknown merchant', 'unknown payee', 'merchant unknown', 'recipient unknown', 'other',
    'merchant', 'not available', 'n/a', 'bank debit', 'bank credit',
    'bank transfer', 'money received', 'purchase', 'payment', 'transaction',
    'txn', 'transfer', 'self transfer', 'transfer between own accounts',
    'spend', 'refund', 'reversal', 'reward or cashback', 'wallet',
    'wallet load', 'cash withdrawal', 'cash deposit', 'gift received',
    'reimbursement', 'salary', 'loan or emi repayment', 'loan disbursement',
    'bank or service fee', 'investment', 'investment return',
    'investment proceeds', 'credit card', 'debit card',
    'credit card bill payment', 'card statement adjustment',
    'upi', 'imps', 'neft', 'rtgs', 'a/c', 'account', 'pos', 'ecom', 'atm',
    'qr payment', 'paytm qr', 'bharatpe qr', 'phonepe qr', 'google pay qr',
  };
  static final _genericShapeRe = RegExp(
    r'^(?:(?:bank|card|upi|wallet|merchant)\s+(?:debit|credit|payment|transaction|txn)'
    r'|(?:credit|debit)\s+card|(?:paytm|bharatpe|phonepe|google\s*pay)\s+qr)$',
    caseSensitive: false,
  );
  static final _bareIdentifierRe = RegExp(
    r'^(?:[#*]?\d+(?:[\s.,/-]\d+)*|[A-Fa-f0-9]{12,}'
    r'|(?:mid|tid|ref(?:no)?|utr|rrn|txn)[-:]?\d{6,}'
    r'|(?=[A-Za-z0-9]*\d{8})[A-Za-z0-9]{10,}'
    r'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)$',
    caseSensitive: false,
  );
  static final _boilerplateRe = RegExp(
    r'\b(?:view|click|tap|download)\b[\s\S]{0,60}\b(?:receipt|bill|invoice|link|here)\b'
    r'|^thank\s+you\b'
    r'|\bpayment\s+(?:successful|successfully|received|recorded|done)\b'
    r'|\b(?:txn|transaction)\s+(?:successful|completed)\b'
    r'|^(?:your|the)\s+(?:payment|purchase|order|transaction|txn)\b'
    r'|^(?:(?:the|your)\s+)?(?:upcoming|scheduled)\s+(?:mandate|debit|payment)\b'
    r'|^other\s+services\b',
    caseSensitive: false,
  );
  static final _metadataWithIdRe = RegExp(
    r'\s+(?:ref(?:erence)?\s*(?:no\.?|number|#)?|refno|utr(?:\s*no\.?)?'
    r'|txn(?:\s*(?:id|no\.?|ref(?:erence)?))?|transaction(?:\s*(?:id|no\.?))?'
    r'|order(?:\s*(?:id|no\.?))?|receipt(?:\s*(?:no\.?|id|#))?'
    r'|invoice(?:\s*(?:no\.?|id|#))?)'
    r'\s*[:#-]?\s*(?=[A-Za-z0-9/-]*\d)[A-Za-z0-9][A-Za-z0-9/-]*\s*$',
    caseSensitive: false,
  );
  static final _metadataKeywordOnlyRe = RegExp(
    r'\s+(?:refno|ref\s*no\.?|utr(?:\s*no\.?)?|txn\s*(?:id|no\.?)?'
    r'|receipt\s*(?:no\.?|id)?|invoice\s*(?:no\.?|id)?)\s*[.:#-]*\s*$',
    caseSensitive: false,
  );
  static final _recordedSuffixRe = RegExp(
    r'\s+(?:has|have|had|was|were|is|are)\s+(?:been\s+)?(?:successfully\s+)?'
    r'(?:recorded|received|credited|debited|paid|completed|processed|confirmed|done|captured|generated|successful)\b[\s\S]*$',
    caseSensitive: false,
  );
  static final _statusSuffixRe = RegExp(
    r'\s+(?:successful|successfully|completed|confirmed|processed|done)\s*[.!]*$',
    caseSensitive: false,
  );
  static final _signatureSuffixRe = RegExp(
    r'\s*[-–—]\s*(?:my\s*bill\s*book|mybillbook|okcredit|khata\s*book|khatabook|vyapar|paytm|phonepe|google\s*pay|bharatpe|razorpay|cashfree)\s*[.!]*$',
    caseSensitive: false,
  );
  static final _leadingJunkRe = RegExp(r'^[\s\-*#_:/.,;]+');
  static final _trailingJunkRe = RegExp(r'[\s\-*#_:/.,;]+$');
  static final _multipleSpacesRe = RegExp(r'\s{2,}');
  static final _transferToRe = RegExp(
    r'^transfer\s+to\s+(.+)$',
    caseSensitive: false,
  );

  static String? cleanName(String? value) {
    if (value == null) return null;
    var text = _normalize(value);
    for (var pass = 0; pass < 3; pass++) {
      final before = text;
      text = _normalize(text
          .replaceFirst(_metadataWithIdRe, '')
          .replaceFirst(_metadataKeywordOnlyRe, '')
          .replaceFirst(_recordedSuffixRe, '')
          .replaceFirst(_statusSuffixRe, '')
          .replaceFirst(_signatureSuffixRe, ''));
      if (text == before) break;
    }
    return isWeakName(text) ? null : text;
  }

  /// The payee of a stored `Transfer to <payee>` merchant name, or null when
  /// the name is not a P2P transfer. SMS import writes that prefix
  /// (`sms_fact_scoring.dart`), and rows that already say they are a transfer
  /// show only the payee.
  static String? transferPayee(String? value) {
    if (value == null) return null;
    final payee = _transferToRe.firstMatch(_normalize(value))?.group(1)?.trim();
    return payee == null || payee.isEmpty ? null : payee;
  }

  /// [transferPayee] where the verb has nowhere else to go: the payee when
  /// there is one, otherwise the name unchanged. Never invents a label.
  static String? payeeDisplayName(String? value) => transferPayee(value) ?? value;

  static bool isWeakName(String? value) {
    if (value == null) return true;
    final text = _normalize(value);
    return text.isEmpty || _urlRe.hasMatch(text) ||
        _boilerplateRe.hasMatch(text) ||
        _genericNames.contains(text.toLowerCase()) ||
        _genericShapeRe.hasMatch(text) || _bareIdentifierRe.hasMatch(text) ||
        !_letterRe.hasMatch(text);
  }

  static String _normalize(String value) => value
      .replaceAll(_multipleSpacesRe, ' ').trim()
      .replaceFirst(_leadingJunkRe, '')
      .replaceFirst(_trailingJunkRe, '').trim();
}
