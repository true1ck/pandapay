import 'dart:core';

/// High-precision, zero-allocation sanitizer for Indian banking narrations,
/// card swipe descriptors, and UPI reference strings.
///
/// Strips aggregator prefixes (Razorpay, Paytm, Cashfree, BillDesk, etc.),
/// NPCI UPI routing tokens (UPI/P2M/..., UPI/P2P/...), POS/ECOM tags,
/// corporate legal entity markers (Pvt Ltd, LLC), and terminal/location noise.
class IndianNarrationSanitizer {
  // Common Indian Payment Gateways & Aggregators that prepend their brand
  static final _aggregatorPrefixRe = RegExp(
    r'^(?:RAZORPAY|PAYTM|CASHFREE|BILLDESK|CCAVENUE|PAYU|INSTAMOJO|PINELABS|EZEEPAY|PHONEPE|AIRPAY|PAYKUN|OPENPLAY|DIRECTPAY|ZAAKPAY|CITRUSPAY|CCAV)\s*[*_:\-/]\s*',
    caseSensitive: false,
  );

  // Common POS / Card channel prefixes
  static final _posChannelPrefixRe = RegExp(
    r'^(?:POS(?:\s+\d+)?|ECOM(?:\s+\d+)?|IPS|EDC|MEST|PURCHASE|IMPS(?:\s*[-/]\s*\d+)?|NEFT(?:\s*[-/]\s*[A-Z0-9]+)?|RTGS(?:\s*[-/]\s*[A-Z0-9]+)?|NACH|ACH|ECS)\s*[*_:\-/]\s*',
    caseSensitive: false,
  );

  // NPCI UPI reference string patterns
  // Examples:
  // UPI/P2M/3294829384/AMAZON SELLER/BARB0...
  // UPI/P2P/4293849283/SURESH KUMAR/OKAXIS
  // UPI/REV/123456789/SWIGGY/HDFC
  static final _npciUpiRe = RegExp(
    r'^UPI\s*[/:\-]\s*(?:P2[MP]|REV|CR|DR|PAY)?\s*[/:\-]?\s*(?:\d+)?\s*[/:\-]\s*([^/]+?)\s*[/:\-]',
    caseSensitive: false,
  );

  // Corporate legal entity designations
  static final _corporateEntityRe = RegExp(
    r'\b(?:PVT\.?\s+LTD\.?|PRIVATE\s+LIMITED|LIMITED|LTD\.?|LLP|L\.L\.P\.?|INC\.?|CORP\.?|CORPORATION)\b',
    caseSensitive: false,
  );

  // Major Indian metropolitan cities and ISO country codes often attached by POS terminals
  static final _terminalLocationRe = RegExp(
    r'\b(?:BANGALORE|BENGALURU|MUMBAI|BOMBAY|DELHI|NEW\s+DELHI|NOIDA|GURGAON|GURUGRAM|HYDERABAD|SECUNDERABAD|CHENNAI|MADRAS|KOLKATA|CALCUTTA|PUNE|AHMEDABAD|JAIPUR|CHANDIGARH|KOCHI|COCHIN|IND|IN|INDIA)\b',
    caseSensitive: false,
  );

  // Terminal IDs, Merchant IDs, and sequence noise
  static final _terminalNoiseRe = RegExp(
    r'\b(?:TID|MID|REF|TXN|TRACE|TERM|AUTH)\s*[:#.-]?\s*[A-Z0-9]+\b|\b\d{6,14}\b',
    caseSensitive: false,
  );

  // Trailing punctuation & special characters
  static final _trailingJunkRe = RegExp(r'[\s\-*#_:/.,;]+$');
  static final _leadingJunkRe = RegExp(r'^[\s\-*#_:/.,;]+');
  static final _multipleSpacesRe = RegExp(r'\s{2,}');

  /// Sanitizes a raw banking or UPI narration to extract the real merchant/payee.
  static String sanitize(String rawNarration) {
    if (rawNarration.trim().isEmpty) return '';

    var text = rawNarration.trim();

    // 1. NPCI UPI Structure Extraction
    final upiMatch = _npciUpiRe.firstMatch(text);
    if (upiMatch != null) {
      final payeeToken = upiMatch.group(1);
      if (payeeToken != null && payeeToken.trim().isNotEmpty) {
        text = payeeToken.trim();
      }
    }

    // 1b. UPI QR VPA Normalization (e.g. paytmqr63650y@ptys -> Paytm QR)
    if (RegExp(r'^paytmqr\w*@\w+$', caseSensitive: false).hasMatch(text)) {
      return 'Paytm QR';
    }
    if (RegExp(r'^bharatpe\w*@\w+$', caseSensitive: false).hasMatch(text)) {
      return 'BharatPe QR';
    }

    // 2. Aggregator Shield: Strip gateway prefixes (e.g. RAZORPAY*SWIGGY -> SWIGGY)
    text = text.replaceFirst(_aggregatorPrefixRe, '');

    // 3. POS Channel Prefix (e.g. POS 412345*MCDONALDS -> MCDONALDS)
    text = text.replaceFirst(_posChannelPrefixRe, '');

    // 4. Strip Terminal / Sequence Noise
    text = text.replaceAll(_terminalNoiseRe, ' ');

    // 5. Strip Corporate Suffixes (Pvt Ltd, LLC, Inc)
    text = text.replaceAll(_corporateEntityRe, ' ');

    // 6. Strip Terminal Location Suffixes (Bangalore, Mumbai, IN)
    text = text.replaceAll(_terminalLocationRe, ' ');

    // 7. Clean whitespace and trailing punctuation
    text = text.replaceAll(_multipleSpacesRe, ' ');
    text = text.replaceFirst(_leadingJunkRe, '');
    text = text.replaceFirst(_trailingJunkRe, '');

    // If over-sanitized to empty or 1 char, fall back safely to original trimmed text
    if (text.length <= 1) {
      return rawNarration.trim();
    }

    return text;
  }
}
