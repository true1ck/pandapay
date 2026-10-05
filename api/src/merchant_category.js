const { normalizeMerchant } = require('./reward_math');

/**
 * High-confidence, offline merchant hints used when a merchant is not yet in
 * the database rule table. This is intentionally a conservative classifier:
 * a known category is useful, but a wrong category changes reward and spend
 * reporting. Specific brands are ordered before broad words so, for example,
 * Swiggy Instamart is groceries rather than dining and Uber Eats is dining
 * rather than travel.
 */
const BUILTIN_CATEGORY_RULES = [
  { slug: 'wallet', priority: 10, patterns: ['amazonpay', 'paytmwallet', 'phonepewallet', 'mobikwik', 'walletload'] },

  { slug: 'groceries', priority: 20, patterns: [
    'swiggyinstamart', 'instamart', 'bigbasket', 'blinkit', 'zepto', 'jiomart',
    'dmart', 'reliancefresh', 'moreretail', 'naturebasket', 'supermarket',
    'grocery', 'groceries', 'spar', 'licious',
  ] },

  { slug: 'dining', priority: 30, patterns: [
    'ubereats', 'swiggy', 'zomato', 'dominos', 'mcdonald', 'starbucks', 'kfc',
    'eazydiner', 'restaurant', 'dining', 'cafe', 'coffee', 'bakery', 'biryani',
    'pizza', 'burger', 'food', 'abhikshapalace', 'haldiram',
  ] },

  { slug: 'online', priority: 40, patterns: [
    'amazon', 'flipkart', 'myntra', 'ajio', 'nykaa', 'meesho', 'tatacliq',
    'shopsy',
  ] },

  { slug: 'fuel', priority: 45, patterns: [
    'qualityfuelstation', 'kavlekarpetroleum', 'indianoil', 'iocl',
    'bharatpetroleum', 'hindustanpetroleum', 'hpcl', 'bpcl', 'reliancepetroleum',
    'nayara', 'shell', 'jiobp', 'essar', 'petroleum', 'petrol', 'diesel',
    'fuelstation', 'fuel',
  ] },

  { slug: 'travel', priority: 50, patterns: [
    'makemytrip', 'goibibo', 'cleartrip', 'easemytrip', 'irctc', 'redbus',
    'airindia', 'indigo', 'vistara', 'oyorooms', 'bookingcom', 'agoda',
    'olacabs', 'rapido', 'uber',
  ] },

  { slug: 'entertainment', priority: 60, patterns: [
    'netflix', 'hotstar', 'disneyplus', 'spotify', 'bookmyshow', 'sonyliv',
    'jiocinema', 'primevideo', 'gaana', 'wynk',
  ] },

  { slug: 'health', priority: 70, patterns: [
    'pharmeasy', 'netmeds', 'apollopharmacy', 'tata1mg', 'practo', 'medplus',
    'apollo', 'pharmacy', 'hospital', 'clinic', 'medical',
  ] },

  { slug: 'bills', priority: 80, patterns: [
    'airtel', 'vodafoneidea', 'tatapower', 'adanielectricity', 'bescom',
    'mahadiscom', 'bses', 'electricity', 'broadband', 'internetbill', 'dth',
    'recharge', 'waterbill', 'pipedgas', 'jiotelecom', 'jio',
  ] },

  // Do not use plain `rent`: normalized names such as `PARENT` contain those
  // letters and would be silently misclassified. Use known rent providers or
  // an explicit rent-pay descriptor instead.
  { slug: 'rent', priority: 90, patterns: ['nobroker', 'redgirraffe', 'rentpay', 'rental'] },
  { slug: 'insurance', priority: 100, patterns: [
    'licindia', 'policybazaar', 'hdfclife', 'starhealth', 'icicilombard',
    'bajajallianz', 'insurance',
  ] },
  { slug: 'education', priority: 110, patterns: [
    'byjus', 'unacademy', 'udemy', 'coursera', 'upgrad', 'simplilearn',
    'school', 'college', 'academy',
  ] },
  { slug: 'government', priority: 120, patterns: [
    'parivahan', 'challan', 'municipal', 'passportseva', 'incometax', 'gst',
  ] },
];

function categoryMerchantVariants(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (!raw) return [];

  const variants = new Set();
  const normalized = normalizeMerchant(raw);
  if (normalized) variants.add(normalized);

  // UPI handles commonly arrive as `MERCHANT@upi`, `MERCHANT@ybl`, etc.
  // Keep the complete key for exact rules, but also expose the business part
  // so a rule for `swiggy` can match `swiggy@upi`.
  const beforeHandle = raw.split('@')[0];
  const handleName = normalizeMerchant(beforeHandle);
  if (handleName) variants.add(handleName);

  return [...variants];
}

function inferBuiltinCategory(merchantName) {
  const variants = categoryMerchantVariants(merchantName);
  if (variants.length === 0) return null;

  const ordered = [...BUILTIN_CATEGORY_RULES].sort((a, b) => a.priority - b.priority);
  for (const rule of ordered) {
    const matchedPattern = rule.patterns.find((pattern) =>
      variants.some((variant) => variant === pattern || variant.includes(pattern))
    );
    if (matchedPattern) {
      return { slug: rule.slug, pattern: matchedPattern, source: 'builtin_rule' };
    }
  }
  return null;
}

/**
 * Extract a payment VPA without treating the rest of an SMS as merchant
 * data. The VPA is the best free identifier available when a bank includes
 * it, because it can be joined to a verified merchant record.
 */
function extractVpa(value) {
  const match = String(value || '').match(
    /\b([a-z0-9][a-z0-9._-]{1,254}@[a-z][a-z0-9.-]{1,62})\b/i
  );
  return match ? match[1].toLowerCase() : null;
}

/** Extract an MCC when a provider includes it in the transaction alert. */
function extractMcc(value) {
  const match = String(value || '').match(
    /\b(?:mcc|merchant\s+category(?:\s+code)?)\s*[:#-]?\s*(\d{4})\b/i
  );
  return match ? match[1] : null;
}

module.exports = {
  BUILTIN_CATEGORY_RULES,
  categoryMerchantVariants,
  inferBuiltinCategory,
  extractVpa,
  extractMcc,
};
