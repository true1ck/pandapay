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
    'grocery', 'groceries', 'spar', 'licious', 'fruits', 'vegetables', 'kirana',
    'blinkcommerce', 'grofers', 'kiranakart', 'innovativeretail', 'supermarketgrocery',
    'bbdaily', 'avenuesupermarts', 'relianceretail', 'reliancesmart', 'smartbazaar',
    'countrydelight', 'freshtohome', 'delightfulgourmet', 'otipy', 'milkbasket',
  ] },

  { slug: 'dining', priority: 30, patterns: [
    'ubereats', 'swiggy', 'zomato', 'dominos', 'mcdonald', 'starbucks', 'kfc',
    'eazydiner', 'restaurant', 'dining', 'cafe', 'coffee', 'bakery', 'biryani',
    'pizza', 'burger', 'food', 'sweets', 'sweetshop', 'mithai', 'confectionery',
    'abhikshapalace', 'haldiram',
    'bundltechnologies', 'bundltech', 'eternallimited', 'zomatomedia', 'jubilantfoodworks',
    'hardcastlerestaurants', 'westlife', 'connaughtplaza', 'restaurantbrandsasia',
    'devyaniinternational', 'sapphirefoods', 'tatastarbucks', 'pizzahut', 'burgerking',
    'subway', 'barbequenation', 'chaayos', 'chaipoint', 'bluetokai', 'thirdwavecoffee',
    'theobroma', 'wowmomo', 'rebelfoods', 'faasos', 'behrouzbiryani', 'box8',
  ] },

  { slug: 'online', priority: 40, patterns: [
    'amazon', 'flipkart', 'myntra', 'ajio', 'nykaa', 'meesho', 'tatacliq',
    'shopsy', 'dresses', 'garments', 'apparel', 'clothing', 'fashion',
    'fsnecommerce', 'croma', 'infinitiretail', 'reliancedigital', 'decathlon',
    'shoppersstop', 'zara', 'h&m', 'uniqlo',
  ] },

  { slug: 'fuel', priority: 45, patterns: [
    'indianoil', 'iocl',
    'bharatpetroleum', 'hindustanpetroleum', 'hpcl', 'bpcl', 'reliancepetroleum',
    'nayara', 'shell', 'jiobp', 'essar', 'petroleum', 'petrol', 'diesel',
    'fuelstation', 'fuel',
    'autofuels', 'autocare', 'petroproducts', 'petrolbunk', 'fillingstation',
    'cocooutlet', 'hpclcoco', 'bpclcoco', 'ioclcoco', 'cngstation', 'iglcng',
    'mglcng', 'tatapowerev', 'zeoncharging', 'statiq', 'chargezone', 'athergrid',
  ] },

  { slug: 'travel', priority: 50, patterns: [
    'makemytrip', 'goibibo', 'cleartrip', 'easemytrip', 'irctc', 'redbus',
    'airindia', 'indigo', 'indigoairlines', 'vistara', 'oyorooms', 'bookingcom', 'agoda',
    'olacabs', 'rapido', 'uber',
    'anitechnologies', 'roppen', 'roppentransportation', 'interglobeaviation',
    'spicejet', 'akasaair', 'fastag', 'netcfastag', 'tollplaza', 'nammayatri',
    'movingtech', 'dmrc', 'bmrcl', 'nammametro', 'abhibus', 'zingbus',
  ], exactPatterns: ['indigo'] },

  { slug: 'entertainment', priority: 60, patterns: [
    'netflix', 'hotstar', 'disneyplus', 'spotify', 'bookmyshow', 'sonyliv',
    'jiocinema', 'primevideo', 'amazonprime', 'chatgpt', 'openai', 'youtube',
    'googleone', 'gaana', 'wynk',
  ] },

  { slug: 'health', priority: 70, patterns: [
    'pharmeasy', 'netmeds', 'apollopharmacy', 'tata1mg', 'practo', 'medplus',
    'apollo', 'pharmacy', 'hospital', 'clinic', 'medical',
  ] },

  { slug: 'bills', priority: 80, patterns: [
    'airtel', 'vodafoneidea', 'tatapower', 'adanielectricity', 'bescom',
    'mahadiscom', 'bses', 'electricity', 'broadband', 'internetbill', 'dth',
    'recharge', 'waterbill', 'pipedgas', 'jiotelecom', 'jio',
    'tsspdcl', 'tsnpdcl', 'tangedco', 'uppcl', 'wbsedcl', 'dhbvn', 'pspcl',
    'kseb', 'jvvnl', 'torrentpower', 'cesc', 'ndmc', 'indraprasthagas', 'igl',
    'mahanagargas', 'mgl', 'adanigas', 'gujaratgas', 'hpgas', 'bharatgas',
    'indane', 'actfibernet', 'actcorp', 'tataplay', 'tatasky', 'dishtv', 'sundirect',
    'hathway', 'excitel',
  ] },

  // Do not use plain `rent`: normalized names such as `PARENT` contain those
  // letters and would be silently misclassified. Use known rent providers or
  // an explicit rent-pay descriptor instead.
  { slug: 'rent', priority: 90, patterns: ['nobroker', 'redgirraffe', 'rentpay', 'rental'] },
  { slug: 'investments', priority: 85, patterns: [
    'zerodha', 'groww', 'nextbillion', 'iccl', 'bse', 'upstox', 'angelone',
    'angelbroking', 'dhan', 'kuvera', 'paytmmoney', 'indmoney', '5paisa',
    'motilaloswal', 'sharekhan', 'mutualfund', 'sip',
  ] },
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

function categoryMerchantTokens(value) {
  const raw = String(value || '').normalize('NFKC').toLowerCase();
  // A provider suffix (`merchant@upi`, `merchant@ybl`, `merchant@jio`) is
  // payment-rail metadata. It must not become the merchant token that drives
  // a category assignment.
  const businessPart = raw.split('@')[0];
  return businessPart.match(/[\p{L}\p{N}]+/gu) || [];
}

function categoryPatternMatch(value, pattern) {
  const normalizedPattern = normalizeMerchant(pattern);
  if (!normalizedPattern) return null;

  const tokens = categoryMerchantTokens(value);
  if (tokens.length === 0) return null;
  const compact = normalizeMerchant(tokens.join(' '));
  if (compact === normalizedPattern) {
    return { matchType: 'exact', specificity: normalizedPattern.length };
  }

  // Certain short, overloaded brand labels are safe only when the complete
  // captured merchant is exactly that label. The explicit rule metadata keeps
  // this policy data-driven and leaves longer, distinctive forms usable.
  const exactOnly = BUILTIN_CATEGORY_RULES.some((rule) =>
    Array.isArray(rule.exactPatterns)
      && rule.exactPatterns.some((candidate) => normalizeMerchant(candidate) === normalizedPattern)
  );
  if (exactOnly) return null;

  if (tokens.includes(normalizedPattern)) {
    return { matchType: 'token', specificity: normalizedPattern.length };
  }

  // Patterns are stored compactly (for example `amazonprime`). A contiguous
  // token span allows that catalogue form to match `Amazon Prime Video` while
  // still rejecting `KUBER` for the `uber` rule.
  for (let start = 0; start < tokens.length; start += 1) {
    let joined = '';
    for (let end = start; end < tokens.length; end += 1) {
      joined += tokens[end];
      if (joined === normalizedPattern) {
        return { matchType: 'phrase', specificity: normalizedPattern.length };
      }
      if (joined.length >= normalizedPattern.length) break;
    }
  }
  return null;
}

function categoryPatternMatches(value, pattern) {
  return Boolean(categoryPatternMatch(value, pattern));
}

function inferBuiltinCategory(merchantName) {
  if (categoryMerchantTokens(merchantName).length === 0) return null;

  const matches = [];
  BUILTIN_CATEGORY_RULES.forEach((rule, ruleIndex) => {
    for (const pattern of rule.patterns) {
      const match = categoryPatternMatch(merchantName, pattern);
      if (!match) continue;
      matches.push({ rule, pattern, match, ruleIndex });
    }
  });
  matches.sort((a, b) => b.match.specificity - a.match.specificity
    || a.rule.priority - b.rule.priority
    || a.ruleIndex - b.ruleIndex);
  const best = matches[0];
  return best
    ? {
      slug: best.rule.slug,
      pattern: best.pattern,
      source: 'builtin_rule',
      matchType: best.match.matchType,
      specificity: best.match.specificity,
    }
    : null;
}

// Only markers that identify the payment party are allowed to feed a body
// fallback. Scanning all SMS text lets issuer names, offer copy, and payment
// rails masquerade as merchants when the parser did not capture a payee.
const PAYMENT_PARTY_SPAN = /\b(?:at|to|towards?|in\s+favou?r\s+of|merchant|beneficiary|payee|fvg|favou?ring|created\s+towards|initiated\s+by|subscription\s+to)\s*[:#-]?\s*([^\n,.;()]{2,120}?)(?=\s+(?:from|on|via|using|upi|ref(?:erence)?|txn(?:action)?|bal(?:ance)?|avl|available|if\s+not|call|has|have|had|was|were|is|are|processed|successful|completed|approved|date)\b|[.,;]|$)/giu;

function inferBuiltinCategoryFromMessage(messageText) {
  const body = String(messageText || '');
  if (!body.trim()) return null;
  PAYMENT_PARTY_SPAN.lastIndex = 0;
  let match;
  while ((match = PAYMENT_PARTY_SPAN.exec(body)) !== null) {
    const merchant = match[1].trim();
    if (!merchant || /^(?:rs\.?|inr|rupees?)\b/i.test(merchant)) continue;
    const inferred = inferBuiltinCategory(merchant);
    if (inferred) return { ...inferred, merchant, source: 'builtin_role_rule' };
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
  categoryPatternMatches,
  inferBuiltinCategory,
  inferBuiltinCategoryFromMessage,
  extractVpa,
  extractMcc,
};
