import 'catalogue_repository.dart' show SpendCategory;
import 'upi_mcc_category.dart' show categorySlugForUpiMcc;

/// Why the QR merchant was categorized. This is useful to keep the scan flow
/// explainable and makes it possible for later screens to distinguish a QR's
/// authoritative MCC from a name/VPA hint.
enum ScannedMerchantCategorySource { mcc, merchantName, vpa }

class ScannedMerchantCategoryHint {
  final String slug;
  final String pattern;
  final ScannedMerchantCategorySource source;

  const ScannedMerchantCategoryHint({
    required this.slug,
    required this.pattern,
    required this.source,
  });
}

/// Resolves category evidence that is available at QR-scan time.
///
/// The order is deliberate:
///   1. QR MCC — the strongest machine-readable signal.
///   2. The QR's payee display name — usually the actual shop/brand.
///   3. A meaningful business part of the VPA — useful when `pn` is an
///      aggregator name or missing.
///
/// Generic UPI provider handles are intentionally ignored. `paytm`, `ybl`,
/// `okaxis`, and similar handles identify the payment rail, not the business
/// category. Returning no hint is safer than showing a confident but wrong
/// category such as Insurance for a generic Paytm QR.
ScannedMerchantCategoryHint? inferScannedMerchantCategory({
  String? merchantName,
  String? vpa,
  String? mcc,
}) {
  final mccSlug = categorySlugForUpiMcc(mcc);
  if (mccSlug != null) {
    return ScannedMerchantCategoryHint(
      slug: mccSlug,
      pattern: mcc!.trim(),
      source: ScannedMerchantCategorySource.mcc,
    );
  }

  final nameHint = _inferFromValue(merchantName);
  if (nameHint != null) {
    return ScannedMerchantCategoryHint(
      slug: nameHint.slug,
      pattern: nameHint.pattern,
      source: ScannedMerchantCategorySource.merchantName,
    );
  }

  final vpaValue = _businessPartOfVpa(vpa);
  final vpaHint = _inferFromValue(vpaValue);
  if (vpaHint != null) {
    return ScannedMerchantCategoryHint(
      slug: vpaHint.slug,
      pattern: vpaHint.pattern,
      source: ScannedMerchantCategorySource.vpa,
    );
  }
  return null;
}

/// Converts a category slug into the UUID-backed category id used by reward
/// rules and transaction rows. A missing category in the catalogue is treated
/// as a data-sync issue, not as a guessed id.
String? categoryIdForScannedMerchant({
  String? merchantName,
  String? vpa,
  String? mcc,
  required List<SpendCategory> categories,
}) {
  final hint = inferScannedMerchantCategory(
    merchantName: merchantName,
    vpa: vpa,
    mcc: mcc,
  );
  if (hint == null) return null;
  for (final category in categories) {
    if (category.slug == hint.slug) return category.id;
  }
  return null;
}

class _RuleMatch {
  final String slug;
  final String pattern;
  const _RuleMatch(this.slug, this.pattern);
}

class _MerchantRule {
  final String slug;
  final List<String> patterns;
  const _MerchantRule(this.slug, this.patterns);
}

// Keep these rules conservative and ordered from specific brand signals to
// broad merchant descriptors. This is intentionally the same vocabulary as
// the server's import resolver so a QR payment and its later SMS settle into
// the same category.
const _merchantRules = <_MerchantRule>[
  _MerchantRule('wallet', [
    'amazonpay',
    'paytmwallet',
    'phonepewallet',
    'mobikwik',
    'walletload',
  ]),
  _MerchantRule('groceries', [
    'swiggyinstamart',
    'instamart',
    'bigbasket',
    'blinkit',
    'zepto',
    'jiomart',
    'dmart',
    'reliancefresh',
    'moreretail',
    'naturebasket',
    'supermarket',
    'grocery',
    'groceries',
    'spar',
    'licious',
    'fruits',
    'vegetables',
    'kirana',
  ]),
  _MerchantRule('dining', [
    'ubereats',
    'swiggy',
    'zomato',
    'dominos',
    'mcdonald',
    'starbucks',
    'kfc',
    'eazydiner',
    'restaurant',
    'dining',
    'cafe',
    'coffee',
    'bakery',
    'biryani',
    'pizza',
    'burger',
    'food',
    'sweets',
    'sweetshop',
    'mithai',
    'confectionery',
    'abhikshapalace',
    'haldiram',
  ]),
  _MerchantRule('online', [
    'amazon',
    'flipkart',
    'myntra',
    'ajio',
    'nykaa',
    'meesho',
    'tatacliq',
    'shopsy',
    'dresses',
    'garments',
    'apparel',
    'clothing',
    'fashion',
  ]),
  _MerchantRule('fuel', [
    'indianoil',
    'iocl',
    'bharatpetroleum',
    'hindustanpetroleum',
    'hpcl',
    'bpcl',
    'reliancepetroleum',
    'nayara',
    'shell',
    'jiobp',
    'essar',
    'petroleum',
    'petrol',
    'diesel',
    'fuelstation',
    'fuel',
  ]),
  _MerchantRule('travel', [
    'makemytrip',
    'goibibo',
    'cleartrip',
    'easemytrip',
    'irctc',
    'redbus',
    'airindia',
    'indigo',
    'vistara',
    'oyorooms',
    'bookingcom',
    'agoda',
    'olacabs',
    'rapido',
    'uber',
  ]),
  _MerchantRule('entertainment', [
    'netflix',
    'hotstar',
    'disneyplus',
    'spotify',
    'bookmyshow',
    'sonyliv',
    'jiocinema',
    'primevideo',
    'gaana',
    'wynk',
  ]),
  _MerchantRule('health', [
    'pharmeasy',
    'netmeds',
    'apollopharmacy',
    'tata1mg',
    'practo',
    'medplus',
    'apollo',
    'pharmacy',
    'hospital',
    'clinic',
    'medical',
  ]),
  _MerchantRule('bills', [
    'airtel',
    'vodafoneidea',
    'tatapower',
    'adanielectricity',
    'bescom',
    'mahadiscom',
    'bses',
    'electricity',
    'broadband',
    'internetbill',
    'dth',
    'recharge',
    'waterbill',
    'pipedgas',
    'jiotelecom',
    'jio',
  ]),
  _MerchantRule('rent', ['nobroker', 'redgirraffe', 'rentpay', 'rental']),
  _MerchantRule('insurance', [
    'licindia',
    'policybazaar',
    'hdfclife',
    'starhealth',
    'icicilombard',
    'bajajallianz',
    'insurance',
  ]),
  _MerchantRule('education', [
    'byjus',
    'unacademy',
    'udemy',
    'coursera',
    'upgrad',
    'simplilearn',
    'school',
    'college',
    'academy',
  ]),
  _MerchantRule('government', [
    'parivahan',
    'challan',
    'municipal',
    'passportseva',
    'incometax',
    'gst',
  ]),
];

const _genericVpaPrefixes = <String>{
  'upi',
  'paytm',
  'phonepe',
  'gpay',
  'googlepay',
  'ybl',
  'ibl',
  'axl',
  'okaxis',
  'okhdfcbank',
  'oksbi',
  'okicici',
  'icici',
  'hdfcbank',
  'sbi',
  'axisbank',
  'kotak',
  'upiapp',
};

_RuleMatch? _inferFromValue(String? value) {
  final normalized = _normalize(value);
  if (normalized.isEmpty) return null;
  for (final rule in _merchantRules) {
    for (final pattern in rule.patterns) {
      if (normalized == pattern || normalized.contains(pattern)) {
        return _RuleMatch(rule.slug, pattern);
      }
    }
  }
  return null;
}

String? _businessPartOfVpa(String? vpa) {
  final raw = vpa?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return null;
  final at = raw.indexOf('@');
  final prefix = at > 0 ? raw.substring(0, at) : raw;
  final normalized = _normalize(prefix);
  if (normalized.isEmpty || _genericVpaPrefixes.contains(normalized))
    return null;
  return prefix;
}

String _normalize(String? value) =>
    (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
