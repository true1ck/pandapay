'use strict';

// Plan C7.3 — what a CardPipeline rule's `category_id` token restricts the
// rule to.
//
// Resolution order:
//   1. CATEGORY_MAP     -> an app category slug (C8 D8c: only the 15 app slugs)
//   2. MERCHANT / GROUP -> merchant_slugs (group tokens expand via the
//                          directory's `group` field, change D6)
//   3. PLATFORM         -> platform_slugs
//   4. RAIL tokens      -> a rail (upi -> upi_qr)
//   5. all_retail / other / other_retail -> unrestricted
//   6. composite tokens (dining_movies) -> one part per mapped piece
//   7. anything else    -> unknown (the rule becomes `info`)
//
// A token that is narrower than the app category it maps to ("travel_flights"
// -> travel) is marked `broad`. Today's loader already maps those; the coverage
// report counts them so a reviewer can see where a rule is wider than its
// source.

const { groupMembers } = require('./directory');

const APP_CATEGORIES = new Set([
  'groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent', 'insurance',
  'education', 'government', 'wallet', 'entertainment', 'health', 'emi', 'other',
]);

const exact = (slug) => ({ slug, broad: false });
const broad = (slug) => ({ slug, broad: true });

const CATEGORY_MAP = {
  grocery: exact('groceries'),
  groceries: exact('groceries'),
  supermarket: exact('groceries'),
  supermarkets: exact('groceries'),
  supermarket_and_convenience: exact('groceries'),
  supermarket_retail: exact('groceries'),
  fuel: exact('fuel'),
  fuel_station: exact('fuel'),
  fuel_stations: exact('fuel'),
  petrol_pump: exact('fuel'),
  petrol_pumps: exact('fuel'),
  dining: exact('dining'),
  restaurant: exact('dining'),
  restaurants: exact('dining'),
  travel: exact('travel'),
  online: exact('online'),
  ecommerce: exact('online'),
  online_shopping: exact('online'),
  online_spend: exact('online'),
  online_spends: exact('online'),
  online_store: exact('online'),
  utility: exact('bills'),
  utilities: exact('bills'),
  bills: exact('bills'),
  bill: exact('bills'),
  bill_payment: exact('bills'),
  bill_payments: exact('bills'),
  rent: exact('rent'),
  rental: exact('rent'),
  rentals: exact('rent'),
  property_rental: exact('rent'),
  rent_property_management: exact('rent'),
  rent_payment: exact('rent'),
  insurance: exact('insurance'),
  education: exact('education'),
  government: exact('government'),
  govt: exact('government'),
  government_services: exact('government'),
  government_spend: exact('government'),
  government_tax: exact('government'),
  tax: exact('government'),
  tax_payment: exact('government'),
  wallet: exact('wallet'),
  wallet_load: exact('wallet'),
  wallet_loading: exact('wallet'),
  wallet_reload: exact('wallet'),
  entertainment: exact('entertainment'),
  health: exact('health'),
  medical: exact('health'),
  emi: exact('emi'),
  merchant_emi: exact('emi'),
  emi_conversion: exact('emi'),

  // Narrower than the app category they land in.
  travel_flights: broad('travel'),
  flights: broad('travel'),
  airlines: broad('travel'),
  travel_hotels: broad('travel'),
  travel_hotel: broad('travel'),
  hotels: broad('travel'),
  hotel: broad('travel'),
  flight: broad('travel'),
  airline: broad('travel'),
  travel_flights_hotels: broad('travel'),
  travel_flights_and_hotels: broad('travel'),
  railways: broad('travel'),
  railway: broad('travel'),
  travel_rail: broad('travel'),
  travel_railways: broad('travel'),
  travel_railway: broad('travel'),
  travel_train: broad('travel'),
  passenger_railways: broad('travel'),
  travel_transport: broad('travel'),
  transport: broad('travel'),
  transportation: broad('travel'),
  local_transport: broad('travel'),
  taxi: broad('travel'),
  car_rental: broad('travel'),
  travel_car_rental: broad('travel'),
  travel_car_rentals: broad('travel'),
  movie: broad('entertainment'),
  movies: broad('entertainment'),
  gaming: broad('entertainment'),
  digital_gaming: broad('entertainment'),
  online_gaming: broad('entertainment'),
  online_skill_based_gaming: broad('entertainment'),
  pharmacy: broad('health'),
  pharmacies: broad('health'),
  medical_supplies: broad('health'),
  hospital: broad('health'),
  fast_food: broad('dining'),
  food_delivery: broad('dining'),
  food: broad('dining'),
  bars_pubs: broad('dining'),
  telecom: broad('bills'),
  telecom_cable: broad('bills'),
  telecommunication: broad('bills'),
  recharges: broad('bills'),
  recharge: broad('bills'),
};

// Brand tokens -> merchant slugs. Slugs not yet in the directory are still
// emitted (merchant_slugs is text[], no FK) and listed as "needs directory
// entry" by the coverage report.
const MERCHANT_TOKEN_MAP = {
  swiggy: ['swiggy'],
  swiggy_app: ['swiggy'],
  zomato: ['zomato'],
  amazon: ['amazon'],
  amazon_in: ['amazon'],
  amazon_shopping: ['amazon'],
  flipkart: ['flipkart'],
  shopping_flipkart: ['flipkart'],
  myntra: ['myntra'],
  shopping_myntra: ['myntra'],
  uber: ['uber'],
  ola: ['ola'],
  shoppers_stop: ['shoppers_stop'],
  shopping_shoppers_stop: ['shoppers_stop'],
  fabindia: ['fabindia'],
  fabindia_stores: ['fabindia'],
  apollo: ['apollo'],
  apollo_healthcare: ['apollo'],
  patanjali: ['patanjali'],
  snapdeal: ['snapdeal'],
  flipkart_wholesale: ['flipkart_wholesale'],
  best_price: ['best_price'],
  samsung: ['samsung'],
  samsung_products: ['samsung'],
  samsung_purchase: ['samsung'],
  irctc: ['irctc'],
  travel_train_irctc: ['irctc'],
  lic: ['lic_india'],
  lic_premium: ['lic_india'],
  insurance_lic: ['lic_india'],
  indigo: ['indigo'],
  makemytrip: ['makemytrip'],
  easemytrip: ['easemytrip'],
  bookmyshow: ['bookmyshow'],
  pvr: ['pvr'],
  indianoil: ['indianoil'],
  hpcl: ['hpcl'],
  bpcl: ['bpcl'],
  jio_bp: ['jio_bp'],
  airtel: ['airtel'],
  tata_neu: ['tata_neu'],
  ajio: ['ajio'],
  jiomart: ['jiomart'],
  reliance_ajio_jiomart_online: ['ajio', 'jiomart'],
  nykaa: ['nykaa'],
  croma: ['croma'],
  bigbasket: ['bigbasket'],
  tanishq: ['tanishq'],
  lenskart: ['lenskart'],
  decathlon: ['decathlon'],
  marriott: ['marriott'],
  taj: ['taj'],
  emirates: ['emirates'],
  spicejet: ['spicejet'],
  air_india: ['air_india'],
  vistara: ['vistara'],
};

// Group-wide card terms ("Tata Neu partner brands"). Expanded through the
// directory's `group` field (D6) — never through parent_slug inheritance.
// `include` are the slugs added even if the directory has no group yet.
const GROUP_TOKEN_MAP = {
  tata_neu_partner: { group: 'tata', include: ['tata_neu'] },
  tata_neu_partner_brands: { group: 'tata', include: ['tata_neu'] },
  tata_neu_partners: { group: 'tata', include: ['tata_neu'] },
  landmark_stores: { group: 'landmark', include: ['landmark'] },
  landmark_group: { group: 'landmark', include: ['landmark'] },
  reliance_retail: { group: 'reliance', include: ['reliance_retail'] },
  aditya_birla_group: { group: 'aditya_birla', include: [] },
  titan: { group: 'titan', include: [] },
  titan_brands: { group: 'titan', include: [] },
  ihcl: { group: 'ihcl', include: ['taj'] },
};

const PLATFORM_TOKEN_MAP = {
  phonepe: ['phonepe_app'],
  phonepe_app: ['phonepe_app'],
  smartbuy: ['hdfc_smartbuy'],
  paytm: ['paytm_app'],
  paytm_spend: ['paytm_app'],
  paytm_app: ['paytm_app'],
  reward_multiplier: ['amex_reward_multiplier'],
  intermiles: ['intermiles_portal'],
  intermiles_portal: ['intermiles_portal'],
  kiwi: ['kiwi_app'],
  payzapp: ['payzapp'],
  smartpay: ['hdfc_smartpay'],
  bills2pay: ['bills2pay_portal'],
  first_rewards_gallery: ['idfc_rewards_gallery'],
  ishop: ['icici_ishop'],
  travel_edge: ['axis_travel_edge'],
  grab_deals: ['axis_grab_deals'],
  kotak_unbox: ['kotak_unbox'],
  smartdeal: ['bobcard_smartdeal'],
  google_pay: ['google_pay'],
  amazon_pay: ['amazon_pay'],
  cred: ['cred_app'],
};

// "Bank portal or equivalent" rail/channel values name a portal by issuer.
const ISSUER_PORTAL = {
  hdfc: 'hdfc_smartbuy',
  'hdfc-bank': 'hdfc_smartbuy',
  icici: 'icici_ishop',
  'icici-bank': 'icici_ishop',
  axis: 'axis_travel_edge',
  'axis-bank': 'axis_travel_edge',
  amex: 'amex_reward_multiplier',
  'american-express-india': 'amex_reward_multiplier',
  'american-express': 'amex_reward_multiplier',
  bobcard: 'bobcard_smartdeal',
  'bank-of-baroda': 'bobcard_smartdeal',
};

const RAIL_TOKEN_MAP = {
  upi: 'upi_qr',
  upi_qr: 'upi_qr',
  upi_spend: 'upi_qr',
  upi_scan_pay: 'upi_qr',
};

const UNRESTRICTED_TOKENS = new Set([
  'all_retail', 'other', 'other_retail', 'all_other_eligible_spend', 'all_other_eligible',
]);

// The restriction lives entirely in the rule's conditions.
function isNoCategoryToken(token) {
  return token === 'excluded_spend' || /^excluded_spend_/.test(token);
}

// Not purchases the engine scores. Rules on these become `info`.
// D14b: restricted to something a transaction context can't carry
// (international/foreign-currency spend, a birthday window). Always `info`,
// flagged depends_on_txn_attribute; never unrestricted.
const TXN_ATTRIBUTE_TOKENS = new Set([
  'international', 'international_spend', 'international_spends', 'international_retail',
  'international_transaction', 'international_transactions', 'overseas_spend', 'overseas',
  'foreign_currency', 'foreign_currency_spend', 'travel_international', 'international_ecommerce',
  'birthday_spend', 'birthday', 'weekend', 'weekend_spend', 'duty_free',
]);

const NON_PURCHASE_TOKENS = new Set([
  'cash_advance', 'cash_withdrawal', 'cash', 'cash_transaction', 'cash_transactions',
  'atm_withdrawal', 'balance_transfer', 'encash', 'fees_and_charges', 'fees', 'fees_charges',
  'card_fees', 'financial_charges', 'fees_interest', 'interest', 'disputed_transactions',
  'disputed_spend', 'repayment', 'repayments', 'loan_on_card', 'credit_card_payment',
  'quasi_cash', 'money_transfer', 'fund_transfer', 'cashback_transaction', 'cross_sell',
  'welcome_benefit', 'spend_milestone', 'doctors_day', 'flexipay',
]);

// Composite parsing vocabulary. Nouns that exist but have no app category
// (jewellery, international, ...) make a part "unmapped" without tainting
// their neighbours; qualifier words ("domestic", "select", "partner") narrow a
// neighbouring piece in a way we can't express, so they taint it.
const UNMAPPED_NOUNS = new Set([
  'departmental', 'departmental_store', 'duty_free', 'departmental_stores', 'department_store',
  'department_stores', 'international', 'jewellery', 'jewelry', 'apparel', 'apparels',
  'fashion', 'electronics', 'shopping', 'toll', 'tolls', 'fastag', 'duty_free',
  'beauty_wellness', 'personal_care', 'pet_stores', 'sports', 'books', 'advertising',
  'software_saas', 'auto', 'essentials', 'gold', 'silver', 'overseas', 'gift_vouchers',
  'gift_cards', 'wellness', 'lifestyle', 'home_decor', 'durables',
  'consumer_durables', 'irctc_air', 'cabs', 'bakery', 'alcohol', 'subscription',
  'subscriptions', 'ott',
]);
const CONNECTORS = new Set(['and', 'or', 'with', 'plus', 'n']);
const IGNORABLE = new Set(['spend', 'spends', 'categories', 'category', 'merchants', 'transactions']);

function pieceFor(key, ctx) {
  if (CATEGORY_MAP[key]) return { key, kind: 'category', categorySlug: CATEGORY_MAP[key].slug, broad: CATEGORY_MAP[key].broad };
  if (MERCHANT_TOKEN_MAP[key]) return { key, kind: 'merchant', merchantSlugs: MERCHANT_TOKEN_MAP[key] };
  if (GROUP_TOKEN_MAP[key]) return groupPiece(key, ctx);
  if (PLATFORM_TOKEN_MAP[key]) return { key, kind: 'platform', platformSlugs: PLATFORM_TOKEN_MAP[key] };
  if (UNMAPPED_NOUNS.has(key)) return { key, kind: 'unmapped_noun' };
  return null;
}

function groupPiece(key, ctx) {
  const spec = GROUP_TOKEN_MAP[key];
  const members = groupMembers(spec.group, ctx?.index);
  const slugs = [...new Set([...spec.include, ...members])].sort();
  return {
    key,
    kind: 'merchant',
    merchantSlugs: slugs,
    group: spec.group,
    groupResolved: members.length > 0,
  };
}

function parseComposite(token, ctx) {
  const words = token.split('_').filter(Boolean);
  const pieces = [];
  let i = 0;
  while (i < words.length) {
    let matched = null;
    for (let j = Math.min(words.length, i + 4); j > i; j--) {
      const key = words.slice(i, j).join('_');
      const piece = pieceFor(key, ctx);
      if (piece) {
        matched = { piece, next: j };
        break;
      }
    }
    if (matched) {
      pieces.push(matched.piece);
      i = matched.next;
      continue;
    }
    const w = words[i];
    if (!CONNECTORS.has(w) && !IGNORABLE.has(w)) pieces.push({ key: w, kind: 'qualifier' });
    i += 1;
  }
  return pieces;
}

function partFromPiece(piece) {
  if (piece.kind === 'category') return { categorySlug: piece.categorySlug, broad: piece.broad, token: piece.key };
  if (piece.kind === 'merchant') return { merchantSlugs: piece.merchantSlugs, token: piece.key, group: piece.group };
  if (piece.kind === 'platform') return { platformSlugs: piece.platformSlugs, token: piece.key };
  return null;
}

/**
 * @returns {{kind: string, parts: object[], unmapped: string[], flags: string[]}}
 *   kind: category | merchant | platform | rail | unrestricted | none |
 *         non_purchase | composite | unknown
 *   parts: one entry per positive restriction the token implies.
 */
function resolveCategoryToken(token, ctx = {}) {
  const t = typeof token === 'string' ? token.trim().toLowerCase() : '';
  const flags = [];
  if (!t || t === 'n/a') return { kind: 'unrestricted', parts: [{}], unmapped: [], flags };
  if (UNRESTRICTED_TOKENS.has(t)) return { kind: 'unrestricted', parts: [{}], unmapped: [], flags };
  if (isNoCategoryToken(t)) return { kind: 'none', parts: [{}], unmapped: [], flags };
  if (NON_PURCHASE_TOKENS.has(t)) return { kind: 'non_purchase', parts: [], unmapped: [t], flags };
  if (TXN_ATTRIBUTE_TOKENS.has(t)) return { kind: 'txn_attribute', parts: [], unmapped: [t], flags: ['depends_on_txn_attribute'] };

  const direct = pieceFor(t, ctx);
  if (direct && direct.kind !== 'unmapped_noun') {
    const part = partFromPiece(direct);
    if (direct.kind === 'category' && direct.broad) flags.push('broad_category');
    if (direct.kind === 'merchant' && direct.group && !direct.groupResolved) flags.push('group_not_in_directory');
    return { kind: direct.kind, parts: [part], unmapped: [], flags };
  }
  if (RAIL_TOKEN_MAP[t]) return { kind: 'rail', parts: [{ rail: RAIL_TOKEN_MAP[t] }], unmapped: [], flags };
  if (t === 'smartbuy_or_equivalent' || t === 'smartbuy_or_equivalent_portal') {
    const portal = ISSUER_PORTAL[ctx.issuerSlug];
    if (portal) return { kind: 'platform', parts: [{ platformSlugs: [portal], token: t }], unmapped: [], flags };
    return { kind: 'unknown', parts: [], unmapped: [t], flags };
  }
  // smartbuy_10x etc: a portal plus a multiplier tier we can't tell apart.
  if (/^smartbuy_\d+x$/.test(t)) return { kind: 'unknown', parts: [], unmapped: [t], flags };

  const pieces = parseComposite(t, ctx);
  const meaningful = pieces.filter((p) => p.kind !== 'qualifier');
  if (pieces.length >= 2 && meaningful.length >= 1) {
    const tainted = new Set();
    pieces.forEach((p, idx) => {
      if (p.kind !== 'qualifier') return;
      if (idx === 0 || idx === pieces.length - 1) {
        pieces.forEach((_, k) => tainted.add(k));
      } else {
        for (let k = idx + 1; k < pieces.length; k++) {
          if (pieces[k].kind !== 'qualifier') {
            tainted.add(k);
            break;
          }
        }
      }
    });
    const parts = [];
    const unmapped = [];
    const seen = new Set();
    pieces.forEach((p, idx) => {
      if (p.kind === 'qualifier') {
        unmapped.push(p.key);
        return;
      }
      const part = partFromPiece(p);
      if (!part || tainted.has(idx)) {
        unmapped.push(p.key);
        return;
      }
      const sig = JSON.stringify([part.categorySlug, part.merchantSlugs, part.platformSlugs]);
      if (seen.has(sig)) return;
      seen.add(sig);
      if (part.broad) flags.push('broad_category');
      parts.push(part);
    });
    if (unmapped.some((u) => TXN_ATTRIBUTE_TOKENS.has(u))) flags.push('depends_on_txn_attribute');
    if (parts.length >= 1 && (parts.length + unmapped.length) >= 2) {
      return { kind: 'composite', parts, unmapped, flags: [...new Set(flags)] };
    }
  }
  return { kind: 'unknown', parts: [], unmapped: [t], flags };
}

// Category-only lookup used for condition values such as
// excluded_categories: ["fuel", "wallet_load"].
function mapCategorySlug(token) {
  if (typeof token !== 'string') return null;
  const t = token.trim().toLowerCase().replace(/[\s-]+/g, '_');
  const hit = CATEGORY_MAP[t];
  return hit ? hit.slug : null;
}

module.exports = {
  APP_CATEGORIES,
  CATEGORY_MAP,
  GROUP_TOKEN_MAP,
  ISSUER_PORTAL,
  MERCHANT_TOKEN_MAP,
  NON_PURCHASE_TOKENS,
  PLATFORM_TOKEN_MAP,
  TXN_ATTRIBUTE_TOKENS,
  RAIL_TOKEN_MAP,
  UNRESTRICTED_TOKENS,
  isNoCategoryToken,
  mapCategorySlug,
  parseComposite,
  resolveCategoryToken,
};
