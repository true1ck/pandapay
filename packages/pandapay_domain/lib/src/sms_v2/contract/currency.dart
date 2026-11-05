/// Currency precision and symbol handling shared by the rule engine and the
/// foreign payment bridge (CCR-004).
///
/// Exponents are ISO 4217 accounting minor units (SIX list one). Money in this
/// pipeline is always integer minor units; a foreign amount is never rounded.
library;

/// ISO 4217 minor-unit exponent per foreign currency code. INR is excluded: it
/// is the ledger currency, never an "original" or foreign-only amount.
/// `XXX` is the ISO "no currency" code. The engine writes it when a message
/// prints an amount behind a symbol that names no single currency (a bare
/// dollar sign), so the amount is kept and the currency is asked for.
const Map<String, int> smsForeignCurrencyExponents = <String, int>{
  'AED': 2,
  'AFN': 2,
  'ALL': 2,
  'AMD': 2,
  'AOA': 2,
  'ARS': 2,
  'AUD': 2,
  'AWG': 2,
  'AZN': 2,
  'BAM': 2,
  'BBD': 2,
  'BDT': 2,
  'BHD': 3,
  'BIF': 0,
  'BMD': 2,
  'BND': 2,
  'BOB': 2,
  'BOV': 2,
  'BRL': 2,
  'BSD': 2,
  'BTN': 2,
  'BWP': 2,
  'BYN': 2,
  'BZD': 2,
  'CAD': 2,
  'CDF': 2,
  'CHE': 2,
  'CHF': 2,
  'CHW': 2,
  'CLF': 4,
  'CLP': 0,
  'CNY': 2,
  'COP': 2,
  'COU': 2,
  'CRC': 2,
  'CUP': 2,
  'CVE': 2,
  'CZK': 2,
  'DJF': 0,
  'DKK': 2,
  'DOP': 2,
  'DZD': 2,
  'EGP': 2,
  'ERN': 2,
  'ETB': 2,
  'EUR': 2,
  'FJD': 2,
  'FKP': 2,
  'GBP': 2,
  'GEL': 2,
  'GHS': 2,
  'GIP': 2,
  'GMD': 2,
  'GNF': 0,
  'GTQ': 2,
  'GYD': 2,
  'HKD': 2,
  'HNL': 2,
  'HTG': 2,
  'HUF': 2,
  'IDR': 2,
  'ILS': 2,
  'IQD': 3,
  'IRR': 2,
  'ISK': 0,
  'JMD': 2,
  'JOD': 3,
  'JPY': 0,
  'KES': 2,
  'KGS': 2,
  'KHR': 2,
  'KMF': 0,
  'KPW': 2,
  'KRW': 0,
  'KWD': 3,
  'KYD': 2,
  'KZT': 2,
  'LAK': 2,
  'LBP': 2,
  'LKR': 2,
  'LRD': 2,
  'LSL': 2,
  'LYD': 3,
  'MAD': 2,
  'MDL': 2,
  'MGA': 2,
  'MKD': 2,
  'MMK': 2,
  'MNT': 2,
  'MOP': 2,
  'MRU': 2,
  'MUR': 2,
  'MVR': 2,
  'MWK': 2,
  'MXN': 2,
  'MXV': 2,
  'MYR': 2,
  'MZN': 2,
  'NAD': 2,
  'NGN': 2,
  'NIO': 2,
  'NOK': 2,
  'NPR': 2,
  'NZD': 2,
  'OMR': 3,
  'PAB': 2,
  'PEN': 2,
  'PGK': 2,
  'PHP': 2,
  'PKR': 2,
  'PLN': 2,
  'PYG': 0,
  'QAR': 2,
  'RON': 2,
  'RSD': 2,
  'RUB': 2,
  'RWF': 0,
  'SAR': 2,
  'SBD': 2,
  'SCR': 2,
  'SDG': 2,
  'SEK': 2,
  'SGD': 2,
  'SHP': 2,
  'SLE': 2,
  'SOS': 2,
  'SRD': 2,
  'SSP': 2,
  'STN': 2,
  'SVC': 2,
  'SYP': 2,
  'SZL': 2,
  'THB': 2,
  'TJS': 2,
  'TMT': 2,
  'TND': 3,
  'TOP': 2,
  'TRY': 2,
  'TTD': 2,
  'TWD': 2,
  'TZS': 2,
  'UAH': 2,
  'UGX': 0,
  'USD': 2,
  'USN': 2,
  'UYI': 0,
  'UYU': 2,
  'UYW': 4,
  'UZS': 2,
  'VED': 2,
  'VES': 2,
  'VND': 0,
  'VUV': 0,
  'WST': 2,
  'XAD': 2,
  'XAF': 0,
  'XCD': 2,
  'XCG': 2,
  'XOF': 0,
  'XPF': 0,
  'YER': 2,
  'ZAR': 2,
  'ZMW': 2,
  'ZWG': 2,
  'XXX': 2,
};

/// Currency symbols and prefixed marks to their code. A bare `$` or `¥` names
/// no single currency, so it maps to [smsUnknownCurrency].
const Map<String, String> _symbolCodes = <String, String>{
  'US\$': 'USD',
  'A\$': 'AUD',
  'AU\$': 'AUD',
  'C\$': 'CAD',
  'CA\$': 'CAD',
  'S\$': 'SGD',
  'HK\$': 'HKD',
  'NZ\$': 'NZD',
  '€': 'EUR',
  '£': 'GBP',
  '\$': 'XXX',
  '¥': 'XXX',
};

/// The ISO "no currency" code used for an amount whose currency is not stated.
const String smsUnknownCurrency = 'XXX';

/// Exponent for [code], or null when it is not a known foreign currency.
int? smsCurrencyExponent(String code) => smsForeignCurrencyExponents[code];

/// Normalises a printed currency token (`usd`, `US$`, `€`) to an upper-case
/// ISO code that is a known foreign currency, or null for INR and anything
/// unknown.
String? smsForeignCurrencyCode(String token) {
  final t = token.trim();
  final code = _symbolCodes[t.toUpperCase()] ?? _symbolCodes[t] ?? t.toUpperCase();
  return smsForeignCurrencyExponents.containsKey(code) ? code : null;
}

final RegExp _decimalBody = RegExp(r'^\d[\d,]*(?:\.\d+)?$');

/// Parses a printed decimal amount (`1,234.50`) into integer minor units for a
/// currency with [exponent] decimals. A trailing `.` and zeros past the
/// precision are tolerated; any other extra digit is refused rather than
/// rounded. Returns null when [text] is not an amount.
int? parseDecimalMinor(String text, int exponent) {
  var s = text.trim();
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  if (!_decimalBody.hasMatch(s)) return null;
  final parts = s.replaceAll(',', '').split('.');
  final whole = BigInt.tryParse(parts[0]);
  if (whole == null) return null;
  var frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > exponent) {
    if (frac.substring(exponent).replaceAll('0', '').isNotEmpty) return null;
    frac = frac.substring(0, exponent);
  }
  final scale = BigInt.from(10).pow(exponent);
  final minor = whole * scale + (frac.isEmpty ? BigInt.zero : BigInt.parse(frac.padRight(exponent, '0')));
  if (minor > BigInt.from(9007199254740991)) return null;
  return minor.toInt();
}
