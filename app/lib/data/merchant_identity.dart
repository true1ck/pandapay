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

  // Merchant names repeat across thousands of rows and every read/save
  // cleaned them again with many regexes on the UI thread. Results depend
  // only on the input text, so they are remembered (bounded).
  static final _cleanCache = <String, String?>{};
  static final _weakCache = <String, bool>{};
  static void _bound(Map<String, Object?> cache) {
    if (cache.length > 10000) cache.clear();
  }

  /// What a row shows when the ledger could not say who the other side was.
  static const unknownMerchantLabel = 'Unknown merchant';
  static const unknownSenderLabel = 'Unknown sender';

  /// The name to show for a stored merchant [name].
  ///
  /// The ledger stores the word UNKNOWN when the message named nobody and nothing
  /// linked to it did either. Shown as it is, that reads like a bug. Money coming
  /// in has a sender, everything else a merchant, so the screen says "Unknown
  /// sender" or "Unknown merchant". Any other name, and a missing one, is returned
  /// unchanged: the caller keeps its own fallback for a row with no name at all.
  static String? displayName(String? name, {required bool incoming}) {
    if (name == null) return null;
    return name.trim().toUpperCase() == 'UNKNOWN'
        ? (incoming ? unknownSenderLabel : unknownMerchantLabel)
        : name;
  }

  static String? cleanName(String? value) {
    if (value == null) return null;
    final cached = _cleanCache[value];
    if (cached != null || _cleanCache.containsKey(value)) return cached;
    _bound(_cleanCache);
    return _cleanCache[value] = _cleanNameUncached(value);
  }

  static String? _cleanNameUncached(String value) {
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
    final cached = _weakCache[value];
    if (cached != null) return cached;
    _bound(_weakCache);
    return _weakCache[value] = _isWeakNameUncached(value);
  }

  static bool _isWeakNameUncached(String value) {
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
