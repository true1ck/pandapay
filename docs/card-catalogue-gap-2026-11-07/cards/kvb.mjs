// Karur Vysya Bank retail Visa cards: "KVB Visa Platinum" and "KVB Visa Signature" from the candidate list. Sources (all read 2026-11-07):
//  KFS_MITC  = "Key Fact Statement cum Most Important Terms & Conditions, KVB Credit Cards" (14 pages, PDF created 20 Aug 2026), linked from the KVB credit card page as "MITC English"
//              https://www.kvb.bank.in/docs/mitc-english.pdf  (names the retail cards Platinum (Visa Platinum) and Honor (Visa Signature))
//  OLD_MITC  = the file the work queue pointed to, https://www.kvb.bank.in/docs/retail-credit-card-mitc.pdf: MITC Version 2.0 dated 4 Mar 2025 (19 pages). Superseded; used only where it shows what changed.
//  Pages     = https://www.kvb.bank.in/personal/cards/kvb-credit-cards/kvb-credit-card/kvb-platinum-credit-card/ and .../kvb-honour-credit-card/ (read in a real browser session)
//  Offers    = https://www.kvb.bank.in/credit-card-offers/retail-credit-card-offers (card type column reads "Visa Platinum, Visa Signature (Honour)")
// The KVB credit card page now lists Platinum, Honour, Oura, Samara, Alturas, Eternis and a corporate card; only Platinum and Honour are the two candidates here.
import { R, X, C, B, prov, GST } from '../lib.mjs';

const KFS_MITC = 'https://www.kvb.bank.in/docs/mitc-english.pdf';
const OLD_MITC = 'https://www.kvb.bank.in/docs/retail-credit-card-mitc.pdf';
const LIST = 'https://www.kvb.bank.in/personal/cards/kvb-credit-cards/kvb-credit-card/';
const PLAT_PAGE = 'https://www.kvb.bank.in/personal/cards/kvb-credit-cards/kvb-credit-card/kvb-platinum-credit-card/';
const HON_PAGE = 'https://www.kvb.bank.in/personal/cards/kvb-credit-cards/kvb-credit-card/kvb-honour-credit-card/';
const OFFERS = 'https://www.kvb.bank.in/credit-card-offers/retail-credit-card-offers';
const REDEEM = 'https://www.kvb.bank.in/reward-points-redemption';
const AGREEMENT = 'https://www.kvb.bank.in/card-member-agreement';

const basis = 'No KVB document read gives the rupee value of one reward point: the MITC says the construct is on the card variant page, the page states points only, the redemption page lists IVR, net or mobile banking and "redemption by cash back" through the Credit Card Cell without a rate, and the Card Member Agreement has no rewards section. Redemption costs ₹99 per request; minimum 2,000 points for the first redemption; unclaimed points lapse once in 3 years or if the minimum amount due is unpaid for more than 60 days (MITC).';

const src = (kind, url, date, read) => ({ url, kind, ...(date ? { date } : {}), read });
const sources = (pageUrl, pageKind) => [
  src('KFS cum MITC: fees, interest, forex, late fee, MAD, fuel surcharge, redemption fee, card names and Visa variants', KFS_MITC, 'PDF created 2026-08-20', 'pdftotext'),
  src(pageKind, pageUrl, null, 'rendered page text'),
  src('KVB credit card list page: the card is live with Apply Now and listed beside Oura, Samara, Alturas, Eternis and the corporate card', LIST, null, 'rendered page text'),
  src('Retail credit card offers page: card type "Visa Platinum, Visa Signature (Honour)" on every merchant offer (network evidence; the merchant offers are time-limited and not modelled)', OFFERS, null, 'rendered page text'),
  src('Reward points redemption page: IVR, internet or mobile banking, or the Credit Card Cell for cash back; no rate', REDEEM, null, 'rendered page text'),
  src('Card Member Agreement (read for reward and lounge terms: none found)', AGREEMENT, null, 'rendered page text'),
  src('Earlier MITC Version 2.0 (superseded): annual fee "Waived for 1st year" and add-on card joining fee ₹200 for retail cards; the 2026 KFS cum MITC drops both columns', OLD_MITC, 'Version 2.0 dated 2025-03-04', 'pdftotext'),
];

const fees = () => ({
  apr: { monthly_interest_rate_percent: 3.25, annual_interest_rate_percent: 39 },
  forex_markup: { markup_percent: 3.5, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: 'No separate DCC markup is stated; the 3.5% Currency Conversion Factor is described for foreign-currency transactions' },
  fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 500, max_txn_inr: 4000, monthly_waiver_cap_inr: 200 },
  cash_advance: { atm_transaction_fee_percent: 1, atm_transaction_fee_min_inr: 300, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 40 },
  category_surcharges: [
    { category_id: 'rent', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% service charge on rent payments', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'wallet_load', mcc_list: [6540, 6541], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on wallet loading transactions exceeding ₹1,000', threshold_spend_inr: 1000, effective_from: null, effective_to: null },
    { category_id: 'education_third_party', mcc_list: [8211, 8220, 8241, 8244, 8249, 8299], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on education payments made through third-party apps; payments made directly to colleges or schools on their websites or POS machines are exempt', threshold_spend_inr: null, effective_from: null, effective_to: null },
  ],
  emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 300, foreclosure_charge_percent: 3, gst_applicable: true },
  banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
  reward_redemption_fee: { fee_inr: 99, gst_applicable: true },
});

const statement = {
  grace_period_days: null,
  grace_period_void_on_revolving_balance: true,
  minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['5% of the outstanding principal (purchases and cash advance) plus 100% of interest, fees and charges, unpaid minimum due of earlier cycles, any overlimit amount, EMI and BT EMI, and GST (MITC); the card page adds "minimum of Rs.200"'] },
  late_payment_slabs: [
    { min_balance_inr: 0, max_balance_inr: 199, fee_inr: 0 },
    { min_balance_inr: 200, max_balance_inr: 500, fee_inr: 100 },
    { min_balance_inr: 501, max_balance_inr: 2500, fee_inr: 300 },
    { min_balance_inr: 2501, max_balance_inr: 10000, fee_inr: 500 },
    { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 800 },
    { min_balance_inr: 25001, max_balance_inr: null, fee_inr: 1000 },
  ],
};

const make = (v, o) => ({
  card_product: {
    ...GST, name: o.name, issuer_slug: 'karur-vysya-bank', card_type: 'credit', network: 'visa', network_tier: o.tier, application_mode: 'open',
    joining_fee_inr: 0, annual_fee_inr: o.annual, is_upi_linkable: null,
    data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: o.page, status: 'draft', verified_at: null,
    point_value_inr_baseline: null, point_value_baseline_basis: basis, point_expiry_months: null,
  },
  eligibility_engine: {
    evaluation_mode: 'guideline_only',
    notes: `KVB page: credit limit ${o.limit}; card valid 5 years; secured option against an FD is available; contactless up to ₹5,000. Eligibility rules, age and income criteria are not published on the page or in the MITC.`,
    rules: [], required_documents: [],
  },
  accrual_engine: { base_block_inr: 150, rounding_mode: null, base_points_per_block: o.base, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  reward_rules: [
    R({ id: `kvb-${v}-travel`, cat: 'travel', pri: 10, ppb: null, mult: o.travelX, cond: { wording: `${o.travelX}x rewards`, applies_to: 'domestic and international travel, hotels and air tickets', multiplier_basis: 'multiple of the base rate (assumed; the page does not say what the multiplier applies to)', per_inr_block: 150 }, reason: `${o.travelX}x rewards on domestic and international travel, hotels and air tickets (KVB ${o.tier === 'visa_platinum' ? 'Platinum' : 'Honour'} page). The resulting points per ₹150 are not stated.` }),
    R({ id: `kvb-${v}-dining`, cat: 'dining', pri: 11, ppb: null, mult: o.lifeX, cond: { wording: `${o.lifeX}x rewards`, applies_to: 'restaurants', multiplier_basis: 'multiple of the base rate (assumed)', per_inr_block: 150 }, reason: `${o.lifeX}x rewards on restaurants (page).` }),
    R({ id: `kvb-${v}-medical`, cat: 'health', pri: 11, ppb: null, mult: o.lifeX, cond: { wording: `${o.lifeX}x rewards`, applies_to: 'medical', multiplier_basis: 'multiple of the base rate (assumed)', per_inr_block: 150 }, reason: `${o.lifeX}x rewards on medical spends (page).` }),
    R({ id: `kvb-${v}-insurance`, cat: 'insurance', pri: 11, ppb: null, mult: o.lifeX, cond: { wording: `${o.lifeX}x rewards`, applies_to: 'insurance', multiplier_basis: 'multiple of the base rate (assumed)', per_inr_block: 150 }, reason: `${o.lifeX}x rewards on insurance (page).` }),
    R({ id: `kvb-${v}-movies`, cat: 'entertainment', pri: 11, ppb: null, mult: o.lifeX, cond: { wording: `${o.lifeX}x rewards`, applies_to: 'movie tickets', multiplier_basis: 'multiple of the base rate (assumed)', per_inr_block: 150 }, reason: `${o.lifeX}x rewards on movie tickets (page).` }),
    R({ id: `kvb-${v}-books`, cat: 'other', pri: 11, ppb: null, mult: o.lifeX, cond: { wording: `${o.lifeX}x rewards`, applies_to: 'books', multiplier_basis: 'multiple of the base rate (assumed)', per_inr_block: 150 }, reason: `${o.lifeX}x rewards on books (page).` }),
    R({ id: `kvb-${v}-rail-car-rental`, cat: 'travel', pri: 12, ppb: null, mult: o.lifeX, cond: { wording: `${o.lifeX}x rewards`, applies_to: 'rail tickets and car rentals', multiplier_basis: 'multiple of the base rate (assumed)', per_inr_block: 150 }, reason: `${o.lifeX}x rewards on rail tickets and car rentals (page).` }),
    R({ id: `kvb-${v}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: o.base, mult: 1, cond: { per_inr_block: 150 }, reason: `${o.base} reward points for every ₹150 spent (KVB ${o.tier === 'visa_platinum' ? 'Platinum' : 'Honour'} page). Which categories earn nothing is not stated.` }),
  ],
  cap_rules: [],
  fees_and_surcharges: fees(),
  statement_and_late_fees: statement,
  fee_waiver_and_milestones: {
    annual_fee_waiver: { threshold_spend_inr: o.waiver, period: 'card_anniversary_year', evaluation_condition: `KFS cum MITC: joining fee NIL, annual fee ₹${o.annual} + GST; from the 2nd year the fee is waived on minimum retail spends of ₹${o.waiver.toLocaleString('en-IN')} other than cash withdrawal in the previous year. Net spends exclude fuel transactions, instalments, fees, charges, GST, cash withdrawals and reversals. The 2025 MITC said the annual fee is "waived for 1st year"; the 2026 documents do not repeat that.`, excluded_category_ids: ['fuel', 'emi'], excluded_mcc_list: [], waives_fee_inr: o.annual },
    welcome_and_renewal_gift: { trigger: 'card_activation', benefit_points: o.welcome, effective_value_inr: null, condition: `${o.welcome} bonus reward points on card activation (page); conditions and credit timing are not stated, and the rupee value is unknown because the point value is not published.` },
    spend_milestones: [],
  },
  lifestyle_and_network_benefits: o.benefits,
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
  redemption_matrix: { direct_options: [{ channel: 'IVR (1800 419 6500), internet or mobile banking (Credit Cards, Rewards, Loyalty points redemption), or Credit Card Cell for cash back', redemption_type: 'other', inr_value_per_point: null, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 2000, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 99, effective_from: null, effective_to: null }], partner_transfers: [] },
  dynamic_promotions_registry: [],
  additional_data: { items: [
    { key: 'payment_return_charge', value: { rule: '2% of the Total Amount Due, minimum ₹450, on a returned payment; over-limit fee 2.5% of the over-limit amount, minimum ₹500 (an overlimit facility needs explicit consent)', source: 'KFS cum MITC (Aug 2026)' } },
    ...prov({
      sources: sources(o.page, o.pageKind),
      unverified: [
        'NAMING: the work queue names "KVB Visa Platinum" and "KVB Visa Signature" from the March 2025 MITC. KVB now sells these as "KVB Platinum Credit Card" (Visa Platinum variant, MITC card name "Platinum") and "KVB Honour Credit Card" (Visa Signature variant, MITC card name "Honor"); the retail offers page confirms "Visa Platinum, Visa Signature (Honour)". The slugs keep the queue names. The queue file is superseded by the 2026 KFS cum MITC.',
        'Value of one reward point in rupees: not stated in any KVB document read, so point_value_inr_baseline and effective_base_return_percent are null and the accelerator rules carry a multiplier but no points per block.',
        `Reward multipliers: the page says "${o.lifeX}x rewards" on restaurants, medical, books, insurance, rail tickets, movie tickets and car rentals and "${o.travelX}x rewards" on travel, hotels and air tickets without saying what the multiplier applies to; it is read as a multiple of the base ${o.base} points per ₹150, which would give ${o.base * o.lifeX} and ${o.base * o.travelX} points per ₹150, but the issuer does not state those numbers.`,
        'Categories that earn no points, any monthly or annual points cap, rounding and the minimum transaction are not stated.',
        'First-year annual fee: the March 2025 MITC said "Waived for 1st year"; the August 2026 KFS cum MITC and the card page list joining fee nil and annual fee ₹' + o.annual + ' with a waiver from the 2nd year on spend. Whether the first-year fee is billed needs a person to confirm; the 2026 documents are followed.',
        'Cash withdrawal fee conflict: the KFS cum MITC says ₹300 per transaction or 1% of the amount, whichever is higher; the card page says 2% of the cash withdrawn or ₹300, whichever is higher. The MITC value (1%) is used.',
        'Redemption conflict: the KFS cum MITC says a minimum of 800 points for later redemptions; the card page says 250. Both agree on 2,000 points for the first redemption and a ₹99 fee per request.',
        'Add-on card fee: the card page says "Free"; the March 2025 MITC said ₹200 for retail add-on cards; the 2026 MITC has no add-on fee column. Free is used; the maximum number of add-on cards is not stated.',
        'The KFS cum MITC says the retail annual-fee waiver spend counts "retail spends other than cash withdrawal in the previous year" and its note excludes fuel, instalments, fees, charges, GST, cash withdrawals and reversals; the period is read as the card anniversary year.',
        'KVB also sells Oura (Visa Platinum, ₹2,999), Samara (Visa Signature, ₹5,999), Alturas and Eternis (Visa Infinite, ₹14,999 and ₹29,999) and Visa-network corporate cards, and a co-branded KVB SBI card; none is in the candidate list, and Oura and Samara are also described as Visa Platinum and Visa Signature, so they must not be confused with these two cards.',
        'Merchant offers on the retail offers page are dated Visa coupons (many ended before 7 Nov 2026) and are not modelled.',
        ...(o.extraOpen || []),
      ],
      notes: [
        `Interest 3.25% a month (39% a year) on purchases and cash advances; interest-free period 15 to 45 days on retail purchases when the previous balance is paid in full (MITC). Payment due dates are the 5th, 10th, 15th, 20th or 25th; billing date is 15 days before the due date.`,
        'Fuel surcharge 1%, waived for single transactions of ₹500 to ₹4,000, maximum ₹200 per billing cycle (MITC and page). Forex 3.5%. Card replacement ₹199 (waived for fraud or reissue on expiry). Fee on cash payment at a branch ₹100. Cash advance limit 40% of the credit limit.',
        'EMI conversion from ₹500 at 15% to 22% depending on vintage and balance transfer from ₹10,000 at 18% (page); EMI or BT processing ₹300 or 1% of the loan, whichever is higher, and 3% foreclosure (MITC).',
        'The Platinum and Honour pages both say "Primary Security Nil (option for secured card against FD available)".',
      ],
    }),
  ] },
});

export const cards = {
  'kvb-visa-platinum': make('platinum', {
    name: 'KVB Platinum Credit Card (Visa Platinum)', tier: 'visa_platinum', annual: 599, waiver: 100000, base: 2, lifeX: 1.5, travelX: 2, welcome: 500,
    limit: 'minimum ₹0.25 lakh, maximum ₹5.00 lakh', page: PLAT_PAGE, pageKind: 'KVB Platinum Credit Card page (Features and Others tabs)',
    benefits: [],
  }),
  'kvb-visa-signature': make('honour', {
    name: 'KVB Honour Credit Card (Visa Signature)', tier: 'visa_signature', annual: 999, waiver: 300000, base: 3, lifeX: 2, travelX: 4, welcome: 700,
    limit: 'minimum ₹1.50 lakh, maximum ₹10.00 lakh', page: HON_PAGE, pageKind: 'KVB Honour Credit Card page (Features and Others tabs)',
    benefits: [
      B({ id: 'kvb-honour-lounge', cat: 'lounge', program: 'N/A', sponsor: 'Karur Vysya Bank', label: '4 complimentary airport lounge accesses within India', cond: { source: 'KVB Honour page headline', period: 'not stated', spend_criteria: 'not stated', lounge_list: 'not stated', verification: 'a nominal authorisation transaction may be made to validate the card and is generally reversed (MITC)' }, qty: 4, per: 'N/A' }),
    ],
    extraOpen: ['Lounge access: the page says only "4 Complimentary Airport lounge access within India"; the period (per year, half-year or quarter), spend criteria and lounge list are not stated anywhere, so quota_period is N/A.'],
  }),
};
