// Named transforms for the SMS rule engine. This file is the only place they
// are implemented (see Contracts -> Rule).

/// Names a rule may list in `transforms`.
const Set<String> knownTransforms = {
  'parseAmountIndian',
  'parseDate',
  'digitsOnly',
  'sanitizeNarration',
  'upperTrim',
  'vpaFromText',
  'stripTrailingRefs',
};

final RegExp _amountPrefix = RegExp(r'^\s*(?:rs\.?|inr|₹)\s*', caseSensitive: false);
final RegExp _amountSuffix = RegExp(r'\s*(?:/-|only)\s*$', caseSensitive: false);
final RegExp _amountBody = RegExp(r'^\d[\d,]*(?:\.\d+)?$');

/// Parses an Indian-format amount such as `Rs.1,23,456.78`, `INR 85,000.00`,
/// `₹ 499`, `Rs 14250` or `Rs.5,000.00/-` and returns integer paise. Returns
/// null when [text] is not an amount. A fractional paisa is rejected rather
/// than rounded.
int? parseAmountIndian(String text) {
  var s = text.trim().replaceFirst(_amountPrefix, '').replaceFirst(_amountSuffix, '').trim();
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  if (!_amountBody.hasMatch(s)) return null;
  final parts = s.replaceAll(',', '').split('.');
  final whole = BigInt.tryParse(parts[0]);
  if (whole == null) return null;
  var frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > 2) {
    if (frac.substring(2).replaceAll('0', '').isNotEmpty) return null;
    frac = frac.substring(0, 2);
  }
  final paise = whole * BigInt.from(100) + BigInt.parse(frac.padRight(2, '0'));
  if (paise > BigInt.from(9007199254740991)) return null;
  return paise.toInt();
}

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// IST is UTC+05:30 with no daylight saving.
const Duration istOffset = Duration(hours: 5, minutes: 30);

/// Tries each of [formats] on [text] and returns the first that fits as a UTC
/// instant, reading the printed time as IST. Format letters: `yyyy`, `yy`,
/// `MM`, `MMM`, `dd`, `HH`, `mm`, `ss`; any other character matches literally.
/// The time is optional: a format without a time also accepts a trailing
/// ` HH:mm[:ss]`, and a format with a time also accepts text without one. A
/// missing time means midnight IST. Two-digit years are 2000 + yy.
DateTime? parseDate(String text, List<String> formats) {
  final t = text.trim();
  for (final f in formats) {
    final d = _parseOne(t, f);
    if (d != null) return d;
  }
  return null;
}

DateTime? _parseOne(String text, String format) {
  final direct = _tryFormat(text, format);
  if (direct != null) return direct;
  if (!format.contains('HH')) {
    for (final suffix in const [' HH:mm:ss', ' HH:mm', ':HH:mm:ss', ' HH.mm.ss']) {
      final d = _tryFormat(text, '$format$suffix');
      if (d != null) return d;
    }
  } else {
    final i = format.indexOf('HH');
    final base = format.substring(0, i).replaceFirst(RegExp(r'[\s:T]+$'), '');
    if (base.isNotEmpty) {
      final d = _tryFormat(text, base);
      if (d != null) return d;
    }
  }
  return null;
}

final Map<String, RegExp> _formatCache = {};
final Map<String, List<String>> _formatFields = {};

DateTime? _tryFormat(String text, String format) {
  var re = _formatCache[format];
  if (re == null) {
    final fields = <String>[];
    final b = StringBuffer('^');
    var i = 0;
    while (i < format.length) {
      String? tok;
      for (final k in const ['yyyy', 'MMM', 'yy', 'MM', 'dd', 'HH', 'mm', 'ss']) {
        if (format.startsWith(k, i)) {
          tok = k;
          break;
        }
      }
      if (tok == null) {
        b.write(RegExp.escape(format[i]));
        i++;
        continue;
      }
      fields.add(tok);
      b.write(switch (tok) {
        'yyyy' => r'(\d{4})',
        'MMM' => r'([A-Za-z]{3})',
        _ => r'(\d{2})',
      });
      i += tok.length;
    }
    b.write(r'$');
    re = RegExp(b.toString());
    _formatCache[format] = re;
    _formatFields[format] = fields;
  }
  final m = re.firstMatch(text);
  if (m == null) return null;
  final fields = _formatFields[format]!;
  var year = 0, month = 0, day = 0, hh = 0, mm = 0, ss = 0;
  for (var k = 0; k < fields.length; k++) {
    final v = m.group(k + 1)!;
    switch (fields[k]) {
      case 'yyyy':
        year = int.parse(v);
      case 'yy':
        year = 2000 + int.parse(v);
      case 'MMM':
        final n = _months[v.toLowerCase()];
        if (n == null) return null;
        month = n;
      case 'MM':
        month = int.parse(v);
      case 'dd':
        day = int.parse(v);
      case 'HH':
        hh = int.parse(v);
      case 'mm':
        mm = int.parse(v);
      case 'ss':
        ss = int.parse(v);
    }
  }
  if (month < 1 || month > 12 || day < 1 || hh > 23 || mm > 59 || ss > 59) return null;
  final utc = DateTime.utc(year, month, day, hh, mm, ss);
  if (utc.month != month || utc.day != day) return null; // 31 Feb and the like
  return utc.subtract(istOffset);
}

/// Keeps only the digits.
String digitsOnly(String text) => text.replaceAll(RegExp(r'\D'), '');

/// Trims, collapses inner whitespace and upper-cases.
String upperTrim(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();

final RegExp _vpa = RegExp(r'[A-Za-z0-9._\-+]{2,}@[A-Za-z][A-Za-z0-9.\-]*');

/// The first UPI id (`name@bank`) in [text], lower-cased, or null.
String? vpaFromText(String text) => _vpa.firstMatch(text)?.group(0)?.toLowerCase();

final RegExp _trailingRef = RegExp(
  r'(?:[\s,;(\-]*(?:ref(?:erence)?(?:\s*(?:no|num|number))?|utr|rrn|txn(?:\s*id)?|upi(?:\s*ref)?)\.?\s*[:#.\-]?\s*[A-Za-z0-9]{6,}\)?|[\s,;(\-]+\d{6,}\)?)\s*$',
  caseSensitive: false,
);

/// Removes trailing reference numbers, such as `SWIGGY Ref 4123456789` or
/// `ZOMATO 123456789012`.
String stripTrailingRefs(String text) {
  var s = text.trimRight();
  for (var i = 0; i < 3; i++) {
    final n = s.replaceFirst(_trailingRef, '').trimRight();
    if (n == s) break;
    s = n;
  }
  return s.trim();
}

// ---- sanitizeNarration: a faithful port of IndianNarrationSanitizer ----

final RegExp _aggregatorPrefixRe = RegExp(
  r'^(?:RAZORPAY|PAYTM|CASHFREE|BILLDESK|CCAVENUE|PAYU|INSTAMOJO|PINELABS|EZEEPAY|PHONEPE|AIRPAY|PAYKUN|OPENPLAY|DIRECTPAY|ZAAKPAY|CITRUSPAY|CCAV)\s*[*_:\-/]\s*',
  caseSensitive: false,
);
final RegExp _posChannelPrefixRe = RegExp(
  r'^(?:POS(?:\s+\d+)?|ECOM(?:\s+\d+)?|IPS|EDC|MEST|PURCHASE|IMPS(?:\s*[-/]\s*\d+)?|NEFT(?:\s*[-/]\s*[A-Z0-9]+)?|RTGS(?:\s*[-/]\s*[A-Z0-9]+)?|NACH|ACH|ECS)\s*[*_:\-/]\s*',
  caseSensitive: false,
);
final RegExp _beneficiaryPrefixRe = RegExp(
  r'^(?:FVG|FAVOURING|FAVORING|FAV|INFVO|IN\s+FAV(?:OU?R)?\s+OF)\s*[:.\-]?\s*',
  caseSensitive: false,
);
final RegExp _npciUpiRe = RegExp(
  r'^UPI\s*[/:\-]\s*(?:P2[MP]|REV|CR|DR|PAY)?\s*[/:\-]?\s*(?:\d+)?\s*[/:\-]\s*([^/]+?)(?:\s*[/:\-]|\s*$)',
  caseSensitive: false,
);
final RegExp _corporateEntityRe = RegExp(
  r'\b(?:PVT\.?\s+LTD\.?|PRIVATE\s+LIMITED|LIMITED|LTD\.?|LLP|L\.L\.P\.?|INC\.?|CORP\.?|CORPORATION)\b',
  caseSensitive: false,
);
final RegExp _terminalLocationSuffixRe = RegExp(
  r'(?:\s+(?:BANGALORE|BENGALURU|MUMBAI|BOMBAY|DELHI|NEW\s+DELHI|NOIDA|GURGAON|GURUGRAM|HYDERABAD|SECUNDERABAD|CHENNAI|MADRAS|KOLKATA|CALCUTTA|PUNE|AHMEDABAD|JAIPUR|CHANDIGARH|KOCHI|COCHIN|IND|IN|INDIA))+\s*$',
  caseSensitive: false,
);
final RegExp _terminalNoiseRe = RegExp(
  r'\b(?:TID|MID|REF|TXN|TRACE|TERM|AUTH)\s*[:#.-]?\s*[A-Z0-9]+\b|\b\d{6,14}\b',
  caseSensitive: false,
);
final RegExp _trailingJunkRe = RegExp(r'[\s\-*#_:/.,;]+$');
final RegExp _leadingJunkRe = RegExp(r'^[\s\-*#_:/.,;]+');
final RegExp _multipleSpacesRe = RegExp(r'\s{2,}');
final RegExp _onlyDigits = RegExp(r'^\d+$');
final RegExp _paytmQr = RegExp(r'^paytmqr\w*@\w+$', caseSensitive: false);
final RegExp _bharatPeQr = RegExp(r'^bharatpe\w*@\w+$', caseSensitive: false);

/// Port of `app/lib/data/indian_narration_sanitizer.dart` (kept in step until
/// WP-17 deletes the original): reduces a bank or UPI narration to the payee.
String sanitizeNarration(String rawNarration) {
  if (rawNarration.trim().isEmpty) return '';
  var text = rawNarration.trim();

  final upiMatch = _npciUpiRe.firstMatch(text);
  if (upiMatch != null) {
    final payeeToken = upiMatch.group(1);
    if (payeeToken != null &&
        payeeToken.trim().isNotEmpty &&
        !_onlyDigits.hasMatch(payeeToken.trim())) {
      text = payeeToken.trim();
    }
  }
  if (_paytmQr.hasMatch(text)) return 'Paytm QR';
  if (_bharatPeQr.hasMatch(text)) return 'BharatPe QR';

  text = text.replaceFirst(_beneficiaryPrefixRe, '');
  text = text.replaceFirst(_aggregatorPrefixRe, '');
  text = text.replaceFirst(_posChannelPrefixRe, '');
  text = text.replaceAll(_terminalNoiseRe, ' ');
  text = text.replaceAll(_corporateEntityRe, ' ');
  text = text.replaceFirst(_terminalLocationSuffixRe, '');
  text = text.replaceAll(_multipleSpacesRe, ' ');
  text = text.replaceFirst(_leadingJunkRe, '');
  text = text.replaceFirst(_trailingJunkRe, '');

  if (text.length <= 1) return rawNarration.trim();
  return text;
}

/// Applies the named string transform [name] to [value]. `parseAmountIndian`
/// and `parseDate` are value-typed; the engine applies them where the field is
/// typed, so here they return the input unchanged.
String applyStringTransform(String name, String value) {
  switch (name) {
    case 'digitsOnly':
      return digitsOnly(value);
    case 'sanitizeNarration':
      return sanitizeNarration(value);
    case 'upperTrim':
      return upperTrim(value);
    case 'vpaFromText':
      return vpaFromText(value) ?? '';
    case 'stripTrailingRefs':
      return stripTrailingRefs(value);
    default:
      return value;
  }
}
