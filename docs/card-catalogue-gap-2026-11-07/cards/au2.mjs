// AU Small Finance Bank cards, wave 2 (agent W1). Everything below was read on 2026-11-07.
//  KFS   = AU Key Fact Statement v1.9, 2 Nov 2026   https://www.au.bank.in/pdf/credit-card/Schedule-of-Charges-CC.pdf
//  MITC  = AU Most Important Terms and Conditions v2.23, 2 Nov 2026   https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf
//  CMA   = AU Cardmember Agreement (copy linked from the product pages, no date printed)   https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf
//  PAGE  = AU product page, hidden accordions and popups included (read from the rendered DOM)
// Helpers below are copies of the ones in au.mjs (not imported, per the wave 2 brief).
import { R, X, C, B, P, prov, GST } from '../lib.mjs';

const KFS = 'https://www.au.bank.in/pdf/credit-card/Schedule-of-Charges-CC.pdf';
const KFS_DATE = 'Key Fact Statement v1.9, 2 Nov 2026';
const MITC = 'https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf';
const MITC_DATE = 'MITC v2.23, 2 Nov 2026';
const CMA = 'https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf';
const CMA_DATE = 'Cardmember Agreement, undated copy (the copy under /pdf/credit-card/ is dated 16 May 2026 and has no Zaggle section)';
const DOM_LOUNGE = 'https://www.au.bank.in/pdf/zenith-credit-card/revision-of-usage-terms-and-conditions_jan_25-4.pdf';
const DOM_LOUNGE_DATE = 'Revision of AU Credit Card Usage Terms & Conditions, w.e.f. 10 Apr 2026';
const RAIL = 'https://www.au.bank.in/pdf/xcite-credit-card/railway-lounges.pdf';
const RAIL_DATE = 'Railway Lounge Access Program, 4 Oct 2024';
const LIST = 'https://www.au.bank.in/personal-banking/credit-cards';
const PAGE_NOTE = 'rendered page text including hidden accordions and popups';
// Wave 3 (W8): AU press releases used as network evidence.
const KOSMO_PR = 'https://www.au.bank.in/pdfs/press-release/2025/au-small-finance-bank-partners-with-kiwi-for-credit-on-upi-launches-au-kosmo-credit-card---18th-september-2025.pdf';
const ZAGGLE_PR = 'https://www.au.bank.in/pdfs/press-release/2026/Press-Release-AU--Bank-and-zaggle-Launch-Co-Branded-Credit-Car-9th-July-2026.pdf';
const NET_TRIED = 'Routes tried on 2026-11-07, none states the network: card front art on the AU credit card list tile and on the product page (images opened and read, no network mark on the front); the product page text and popups; AU KFS v1.9, MITC v2.23 and Cardmember Agreement (only the generic "VISA/RuPay"); the AU domestic lounge, Priority Pass and railway lounge T&Cs ("Visa/RuPay" generic, so the lounge programme covers Visa and RuPay cards only); the card liability insurance and welcome-benefit T&Cs; AU press releases and blogs; the AU offers site (card-level offers need a login); visa.co.in card-finder and offers pages (generic, no AU card named); npci.org.in RuPay pages (no issuer or card list); rupay.co.in offers (bot-protected, not opened). The "Visa Exclusive Offers" block is template text shared across AU pages (it also sits on the RuPay-only Kosmo page) and was not used. Needs a person: ask AU, or read the card back or a statement.';

// Fees shared by every AU retail card in the KFS (per-card values passed in).
const auFees = ({ fuelCap, forex = 3.49, cashLimit = 20, atmFee = 2.5, fuelMin = 400, emiPost = 99, apr = { m: 3.75, a: 45 } }) => ({
  apr: { monthly_interest_rate_percent: apr.m, annual_interest_rate_percent: apr.a },
  forex_markup: { markup_percent: forex, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: forex, gst_applicable: true, trigger_condition: 'KFS lists one cross-currency markup for foreign-currency, dynamic and static conversion transactions' },
  fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: fuelMin, max_txn_inr: 5000, monthly_waiver_cap_inr: fuelCap },
  cash_advance: { atm_transaction_fee_percent: atmFee, atm_transaction_fee_min_inr: atmFee === 0 ? 0 : 500, interest_applicable_from_day_one: null, daily_interest_percent: null, max_limit_percent: cashLimit },
  category_surcharges: [
    { category_id: 'fuel', mcc_list: [5172, 5541, 5542, 5552, 5983], fee_percent: 1, gst_applicable: true, trigger_condition: 'From 1 Jul 2026: 1% on the whole month\'s fuel spend when one transaction exceeds ₹10,000 or the calendar-month total exceeds ₹25,000', threshold_spend_inr: 25000, effective_from: '2026-07-01', effective_to: null },
    { category_id: 'utility', mcc_list: [4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on utility spend above ₹50,000 in a calendar month', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
    { category_id: 'education_third_party', mcc_list: [8211, 8220, 8241, 8244, 8249, 8299], fee_percent: 1, gst_applicable: true, trigger_condition: 'Education paid through third-party apps (CRED, PhonePe, Paytm, MobiKwik, Freecharge etc.), minimum ₹99 per transaction; direct school/college site or POS exempt', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: 'Domestic rental payments, minimum ₹99 per transaction; international rental has no charge', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'transportation', mcc_list: [4111, 4112, 4784], fee_percent: 1, gst_applicable: true, trigger_condition: 'From 14 Jun 2026: 1% on the whole month\'s transportation spend once it exceeds the lower of 50% of credit limit or ₹25,000; IRCTC and marquee travel partners excluded', threshold_spend_inr: 25000, effective_from: '2026-06-14', effective_to: null },
  ],
  emi_charges: { merchant_instant_emi_processing_fee_inr: 199, post_purchase_emi_processing_fee_inr: emiPost, foreclosure_charge_percent: null, gst_applicable: true },
  banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
  reward_redemption_fee: { fee_inr: 99, gst_applicable: true },
});

const auStatement = {
  grace_period_days: 50,
  grace_period_void_on_revolving_balance: null,
  minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: [
    'If previous Total Amount Due was paid on time: 5% of principal outstanding + 100% of fees/charges + 100% of interest + due EMIs + 100% annual fee (if applicable) + 100% GST',
    'If previous Total Amount Due was not paid on time: 2% of principal outstanding + the same 100% components',
  ] },
  late_payment_slabs: [],
};

const auEligibility = ({ se = [25, 65], sal = [21, 60], extra = [], notes = 'AU states these criteria are only indicative and reserves the right to approve or decline.' } = {}) => ({
  evaluation_mode: 'guideline_only',
  notes,
  rules: [
    { parameter: 'age_years_salaried', operator: '>=', threshold_value: sal[0], allowed_values: [] },
    { parameter: 'age_years_salaried', operator: '<=', threshold_value: sal[1], allowed_values: [] },
    { parameter: 'age_years_self_employed', operator: '>=', threshold_value: se[0], allowed_values: [] },
    { parameter: 'age_years_self_employed', operator: '<=', threshold_value: se[1], allowed_values: [] },
    { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] },
    ...extra,
  ],
});

const lateFee = { key: 'late_payment_fee_rule', value: { rule: '15% of Total Amount Due, minimum ₹10, maximum ₹1,300', source: `${KFS_DATE}, section 5`, note: 'Percentage fee cannot be expressed as fixed slabs, so late_payment_slabs is empty.' } };
const returnFee = { key: 'payment_return_charge', value: { rule: '2% of Total Amount Due or ₹500, whichever is higher, on return/failure of card payment (cheque, ECS/NACH, autopay)', source: `${KFS_DATE}, section 10` } };

const addon = (min = 18) => ({ max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: min });

const common = (pageUrl, fuelCap, extra = {}) => ({
  card_product: { ...GST, card_type: 'credit', issuer_slug: 'au', network: null, network_tier: null, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: pageUrl, status: 'draft', verified_at: null, point_expiry_months: 24, ...extra.card_product },
  fees_and_surcharges: auFees({ fuelCap, ...(extra.fees || {}) }),
  statement_and_late_fees: auStatement,
  addon_card_rules: addon(),
});

// Categories that earn nothing on the AU points cards (page notes and CMA 23.5.1, 23.6, 23.21). MCC lists are only published for CA/CS, so these are category-level.
const auExcl = (p, src, { wallet = false } = {}) => [
  ['rent', 'rent', [], 'Rent'], ['cash', 'cash_withdrawal', [], 'Cash'], ['quasi-cash', 'cash_withdrawal', [], 'Quasi-cash', { transaction_type: 'quasi_cash' }],
  ['education', 'education', [], 'Education'], ['govt', 'government', [], 'Government'], ['fuel', 'fuel', [], 'Fuel'],
  ['emi', 'excluded_spend', [], 'EMI transactions and conversions', { transaction_type: 'emi' }], ['bbps', 'excluded_spend', [], 'BBPS bill payments on the AU 0101 app', { platform: 'AU 0101 BBPS' }],
  ...(wallet ? [['wallet', 'wallet_load', [], 'Wallet loads']] : []),
].map(([k, cat, mccs, label, cond]) => X(`${p}-excl-${k}`, cat, mccs, `${label} earns no Reward Points (${src}). MCC list not published for this card.`, cond || {}));

// Airline MCCs from the AU CA and CS Reward Points T&C (identical in both PDFs).
const AIRLINE_MCCS = [3000, 3001, 3004, 3005, 3006, 3007, 3008, 3009, 3010, 3011, 3012, 3013, 3014, 3015, 3016, 3017, 3018, 3020, 3021, 3022, 3023, 3024, 3025, 3026, 3027, 3028, 3029, 3030, 3031, 3032, 3034, 3035, 3037, 3038, 3039, 3040, 3042, 3043, 3044, 3045, 3047, 3048, 3049, 3050, 3051, 3052, 3054, 3058, 3061, 3064, 3066, 3068, 3069, 3071, 3072, 3075, 3076, 3077, 3078, 3079, 3082, 3083, 3084, 3085, 3088, 3089, 3090, 3096, 3098, 3099, 3100, 3102, 3103, 3111, 3112, 3115, 3127, 3129, 3132, 3136, 3144, 3146, 3156, 3161, 3167, 3171, 3174, 3175, 3177, 3180, 3181, 3182, 3183, 3184, 3186, 3187, 3190, 3191, 3193, 3196, 3200, 3204, 3206, 3211, 3212, 3213, 3217, 3219, 3220, 3221, 3228, 3234, 3236, 3240, 3245, 3246, 3247, 3248, 3252, 3256, 3259, 3260, 3261, 3266, 3267, 3280, 3282, 3285, 3286, 3287, 3294, 3295, 3297, 3298, 3299, 3300, 3301];
const TRAVEL_MCCS = [4722, 4723, 4511, ...AIRLINE_MCCS];
const DINING_MCCS = [5811, 5812, 5813, 5814];
const BILL_MCCS = [4812, 4814, 4899, 4900];
const INSURANCE_MCCS = [5960, 6300];

const A = (v) => ({ base_block_inr: 100, rounding_mode: 'floor', base_cashback_percent: 'N/A', capping_period_basis: 'statement_cycle', ...v });

const UNIT_NOTE = 'Reward Points are earned on transaction amounts in multiples of ₹100 (CMA 23.22), so rounding is modelled as floor.';

// Visa partner offers that AU prints on the CA, CS and Ultra pages (MakeMyTrip, Times Prime, Alaya Stays).
const visaOffers = (p) => [
  P({ id: `${p}-mmt`, cat: 'travel', sponsor: 'MakeMyTrip', platform: 'MakeMyTrip (Visa offer link)', type: 'complimentary_flight_seats_and_hotel_discount' }),
  P({ id: `${p}-timesprime`, cat: 'entertainment', sponsor: 'Times Prime', platform: 'Times Prime (Visa offer link)', type: 'complimentary_annual_membership' }),
  P({ id: `${p}-alaya`, cat: 'travel', sponsor: 'Alaya Stays', platform: 'Alaya Stays (Visa offer link)', type: 'stay_3_pay_2_and_50pct_off_second_night' }),
];

const netCandidate = ({ network, label, sourceUrl, evidence }) => ({ network, network_tier: 'N/A', label, source_url: sourceUrl, evidence });
const partialNetwork = ({ sourceUrl, evidence, candidates }) => ({ key: 'verified_network_research', value: { finding_status: 'partial', product_status: 'active', source_url: sourceUrl, evidence, candidates } });

export const cards = {
  // ───────────────────────────────────────────────────────────── NOMO (FD-backed)
  'au-nomo': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/nomo-credit-card';
    const o = common(url, 100, { fees: { forex: 0.99, cashLimit: 50 } });
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU NOMO Credit Card', joining_fee_inr: 199, annual_fee_inr: 0, application_mode: 'open', is_upi_linkable: null, form_factors: ['nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: 0.25, point_value_baseline_basis: 'Product page FAQ: "2 Reward Points per ₹100 on retails spends (1 RP = ₹0.25)". AU Rewardz FAQ says a point\'s value depends on the card variant and redemption category, so ₹0.25 is the page\'s stated value for this card, not a guaranteed redemption rate.' },
      eligibility_engine: {
        evaluation_mode: 'all_pass',
        notes: 'Secured card. Needs a fixed deposit in the applicant\'s own sole name with AU: minimum ₹20,000, cumulative/re-invest, auto-renewed; a lien is marked on 100% of the FD value; FD created for this card is 24 months 0 days (page FAQ). Credit limit is up to 80% of the FD amount (CMA 24.1). Joint, HUF, partnership, tax-saving, third-party and no-callable FDs are not eligible. AU says the criteria are indicative.',
        rules: [
          { parameter: 'age_years', operator: '>=', threshold_value: 18, allowed_values: [] },
          { parameter: 'age_years', operator: '<=', threshold_value: 99, allowed_values: [] },
          { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] },
          { parameter: 'au_fixed_deposit_amount_inr', operator: '>=', threshold_value: 20000, allowed_values: [] },
          { parameter: 'au_fixed_deposit_sole_ownership', operator: '==', threshold_value: 1, allowed_values: [] },
        ],
      },
      accrual_engine: A({ base_points_per_block: 2, effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: 5000 }),
      reward_rules: [
        ...auExcl('nomo', 'page FAQ, CMA 23.5.1 and 23.6'),
        R({ id: 'nomo-base-2rp', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 2, cap: 'nomo-total-cycle-cap', reason: 'Page: 2 Reward Points per ₹100 on retail spends (1 RP = ₹0.25), so about 0.5% in value.' }),
        R({ id: 'nomo-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 1, cap: 'nomo-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page: 1 Reward Point on utility; CMA 23.5.1: 1 point per ₹100 on utility and telecom, at most 100 points per transaction.' }),
        R({ id: 'nomo-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 1, cap: 'nomo-total-cycle-cap', reason: 'Page: 1 Reward Point (per ₹100) on insurance.' }),
      ],
      cap_rules: [C({ id: 'nomo-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 5000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'One-time joining fee ₹199 + GST (KFS "₹199 (one time)"); page FAQ: free from the 2nd year onwards, so there is no annual fee to waive.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: 'first_transaction_within_30_days_of_card_setup', benefit_points: 500, effective_value_inr: 125, condition: '500 Reward Points on the first transaction within 30 days of card setup (page). Value ₹125 is 500 points at the page\'s ₹0.25 per point.' },
        spend_milestones: [
          { id: 'nomo-m1', label: '500 bonus Reward Points on ₹25,000 retail spend in a quarter (fuel and cash excluded)', threshold_spend_inr: 25000, reward_value_inr: 125, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null },
          { id: 'nomo-m2', label: 'Doubled quarterly bonus on ₹50,000 retail spend in a quarter ("Double it at ₹50,000"; whether 1,000 total or 500 more is not stated)', threshold_spend_inr: 50000, reward_value_inr: null, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'nomo-domestic-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge access (spend-based)', cond: { rule: 'Spend at least ₹50,000 net retail in a calendar quarter to unlock access in the next calendar quarter', primary_cardholder_only: true, validation_swipe_inr: 2, effective_from: '2026-04-10' }, qty: 2, per: 'quarter', from: '2026-04-10' }),
        B({ id: 'nomo-railway-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Railway lounge access, for the cardholder and add-on cardholders', cond: { add_on_cardholders_eligible: true, guests_chargeable: true, validation_swipe_inr: 2 }, qty: 2, per: 'quarter' }),
      ],
      dynamic_promotions_registry: [],
      redemption_matrix: { direct_options: [{ channel: 'AU Rewardz (e-vouchers, recharges, travel); value stated on the NOMO page', redemption_type: 'other', inr_value_per_point: 0.25, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 99, effective_from: null, effective_to: null }], partner_transfers: [] },
      additional_data: { items: [
        ...prov({
          sources: [
            { url, kind: 'issuer_page + FAQ', read: PAGE_NOTE },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: MITC, kind: 'MITC', date: MITC_DATE },
            { url: CMA, kind: 'Cardmember Agreement (reward caps 23.5, exclusions 23.6, secured card 24)', date: CMA_DATE },
            { url: DOM_LOUNGE, kind: 'domestic lounge T&C', date: DOM_LOUNGE_DATE },
            { url: 'https://www.au.bank.in/pdfs/nomo-credit-card/Railway%20Lounges.pdf', kind: 'railway lounge T&C', date: RAIL_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'Network: UNRESOLVED after a second sweep on 2026-11-07 (wave 3, W7). The NOMO page, KFS v1.9, MITC v2.23, the Cardmember Agreement of 16 May 2026 (secured card section 23 included) and the NOMO card art (listing tile and the page\'s nomo_card art: purple and black card with the NOMO wordmark, chip and contactless mark, no network mark) state none. The 10 Apr 2026 usage terms (NOMO is in the domestic lounge table) and the railway lounge T&C say only "Visa/RuPay" or "VISA/RuPay Credit Card", which covers every AU card. Clauses 3.14 to 3.16 of the Cardmember Agreement allow a network change at renewal ("network selection, if applicable"). visa.co.in, mastercard.co.in, npci.org.in and rupay.co.in carry no AU card list. Needs a physical NOMO card, the AU 0101 app card view, or a written answer from AU (1800 1200 1500; creditcard.support@aubank.in is the KFS grievance contact for NOMO). card_product.network left null.',
            'Cash advance limit (SETTLED, small residual): KFS v1.9 (2 Nov 2026, Credit Limit table on page 4) lists NOMO at "70% of the card limit" and directly under it "50% of the card limit (w.e.f., 7th Nov\'2025)", i.e. a dated revision that supersedes the 70% row. MITC v2.23 (also dated 2 Nov 2026, PDF built about 20 minutes before the KFS) still lists NOMO at 70% with no revision row. 50% is used because only the KFS carries the effective date and it was produced last; the MITC table looks stale. AU has not been asked to confirm; the card statement states the limit that applies to a given card.',
            'Domestic lounge: the page FAQ says 2 visits on ₹20,000 spent in the previous quarter; the page feature text and the 10 Apr 2026 T&C say ₹50,000. The T&C is used.',
            'The ₹50,000 quarterly milestone says "Double it": not stated whether the bonus becomes 1,000 points or 500 more. reward_value_inr left null.',
            'Rewardz FAQ says a point\'s value depends on card variant and redemption category; the NOMO page states ₹0.25 only.',
            'MCC lists for the exclusions are not published for this card.',
          ],
          notes: [
            UNIT_NOTE,
            'Secured card: FD of at least ₹20,000 held with AU; credit limit up to 80% of the FD (CMA 24.1); FD cannot be broken until card dues are settled and the card is closed; no partial withdrawal (page FAQ).',
            'Reward Points are capped at 5,000 per statement cycle on all MCCs (page FAQ, CMA 23.5). Points expire 2 years after accrual (CMA 23.8).',
            'Forex markup is 0.99% (KFS). Fuel surcharge waiver is up to ₹100 per statement month on ₹400 to ₹5,000 (KFS). Xpress EMI: convert transactions of ₹2,000 or more (page).',
            'Card liability cover: zero liability on lost or stolen cards, with skimming and online fraud protection (page).',
            'Interest 3.75% a month (45% a year) on all AU retail cards (KFS section 4).',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Xcite
  'au-xcite': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/swipeup-program/xcite-credit-card';
    const o = common(url, 100, { fees: { cashLimit: 40 } });
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU Xcite Credit Card', joining_fee_inr: 249, annual_fee_inr: 249, application_mode: 'open', is_upi_linkable: null, form_factors: ['nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated on the Xcite page or in the CMA/MITC. The AU Rewardz FAQ says it depends on card variant and redemption category.' },
      eligibility_engine: auEligibility(),
      accrual_engine: A({ base_points_per_block: 3, effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000 }),
      reward_rules: [
        ...auExcl('xcite', 'Xcite page note, CMA 23.5.1 and 23.6', { wallet: true }),
        X('xcite-excl-transport', 'excluded_spend', [], 'Reward Points accrual on Transportation Merchant Category Codes discontinued with effect from 1 Apr 2026 (Xcite page, rewards note). MCC list not published.', { effective_from: '2026-04-01', mcc_group: 'transportation' }),
        R({ id: 'xcite-dining-15rp', cat: 'dining', pri: 10, ppb: 15, mult: 5, cap: 'xcite-total-cycle-cap', reason: 'Page ("Check where to spend"): 15 Reward Points per ₹100 on Dining, Movies, Grocery & Departmental Stores.' }),
        R({ id: 'xcite-movies-15rp', cat: 'entertainment', pri: 10, ppb: 15, mult: 5, cap: 'xcite-total-cycle-cap', reason: 'Page: 15 Reward Points per ₹100 on Movies.' }),
        R({ id: 'xcite-grocery-15rp', cat: 'groceries', pri: 10, ppb: 15, mult: 5, cap: 'xcite-total-cycle-cap', reason: 'Page: 15 Reward Points per ₹100 on Grocery.' }),
        R({ id: 'xcite-departmental-15rp', cat: 'departmental_stores', pri: 10, ppb: 15, mult: 5, cap: 'xcite-total-cycle-cap', reason: 'Page: 15 Reward Points per ₹100 on Departmental Stores. Merchant categories are not defined by MCC on the page.' }),
        R({ id: 'xcite-days-1-5-2x', cat: 'all_retail', pri: 15, ppb: 6, mult: 2, cap: 'xcite-total-cycle-cap', cond: { day_of_month_from: 1, day_of_month_to: 5, applies_to: 'base Reward Points only', retail_spends_only: true }, reason: 'Page: "2X Reward Points on retail spends from the 1st to the 5th of every month". The page note says this applies to base Reward Points only (3 per ₹100), so 6 per ₹100 is derived as 2 x 3.' }),
        R({ id: 'xcite-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 1, cap: 'xcite-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page: 1 Reward Point per ₹100 on utility & telecom; CMA 23.5.1: at most 100 points per transaction.' }),
        R({ id: 'xcite-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 1, cap: 'xcite-total-cycle-cap', reason: 'Page: 1 Reward Point per ₹100 on insurance.' }),
        R({ id: 'xcite-base-3rp', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 3, cap: 'xcite-total-cycle-cap', reason: 'Page: 3 Reward Points per ₹100 spent online and offline.' }),
      ],
      cap_rules: [C({ id: 'xcite-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 100000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹1,00,000 retail spends in the previous card anniversary year (page, MITC). Only retail spends count.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 249 },
        welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'xcite-railway-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Railway lounge access', cond: { max_per_quarter: 2, validation_swipe_inr: 2, guests_chargeable: true }, qty: 8, per: 'annual' }),
        B({ id: 'xcite-device-protection', cat: 'insurance_related_perk', sponsor: 'AU Small Finance Bank', label: 'Complimentary device protection plan for mobiles, tablets, laptops and select electronics (no cover amount on the page)' }),
      ],
      dynamic_promotions_registry: [],
      additional_data: { items: [
        ...prov({
          sources: [
            { url, kind: 'issuer_page', read: PAGE_NOTE },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: MITC, kind: 'MITC (annual fee waiver, cash limit)', date: MITC_DATE },
            { url: CMA, kind: 'Cardmember Agreement (25,000 point cap 23.5, exclusions 23.6)', date: CMA_DATE },
            { url: RAIL, kind: 'railway lounge T&C', date: RAIL_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'Network (wave 3): STILL UNRESOLVED. The Xcite page text has no mention of Visa, RuPay or Mastercard at all (page and popups searched). ' + NET_TRIED + ' Only the sister card Xcite Ultra is named RuPay on its own page; no AU document says the Xcite series shares one network, so that is not carried over.',
            'Value of one Reward Point: not stated for Xcite (card page, KFS, MITC, CMA and the Rewardz FAQ read 2026-11-07; the FAQ says it depends on card variant and redemption category). effective_base_return_percent left null on purpose. AU\'s 2 Jun 2023 notice gives Rs 0.20 per point only for gift card/voucher redemption on all variants; not used as a card value.',
            'Whether the card is open to new applications: it is on AU\'s card list and in the KFS, but the product page shows no card-specific Apply button, only the generic Apply links.',
            'Merchant categories for the 15-point rate (dining, movies, grocery, departmental stores) are not defined by MCC.',
            'The page note "Applicable on base Reward Points only (3 Reward Points per ₹100)" sits under the earn list; read as qualifying the 2X first-five-days bonus. Confirm.',
            'No separate joining fee is stated: the KFS gives one fee table under both the joining and annual headings; both are set to ₹249.',
            'Welcome benefit: none stated.',
          ],
          notes: [
            UNIT_NOTE,
            'Points are capped at 25,000 per statement cycle on all MCCs (CMA 23.5). Points expire 2 years after accrual (CMA 23.8).',
            'Fuel surcharge waiver up to ₹100 per statement cycle on ₹400 to ₹5,000 (page, KFS). Cash limit 40% (KFS). Forex 3.49%.',
            'Add-on cards are free for life (page). Xpress EMI on ₹2,000 or more.',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Xcite ACE (cashback tiers, held)
  'au-xcite-ace': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/swipeup-program/xcite-ace-credit-card';
    const o = common(url, 100, { fees: { cashLimit: 40 } });
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU Xcite ACE Credit Card', joining_fee_inr: 749, annual_fee_inr: 749, application_mode: 'open', is_upi_linkable: null, form_factors: [], point_value_inr_baseline: 'N/A', point_value_baseline_basis: 'Cashback card: the page describes cashback on monthly spends, not points.' },
      eligibility_engine: auEligibility(),
      accrual_engine: A({ base_block_inr: null, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: null, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null }),
      reward_rules: [],
      cap_rules: [],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 200000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹2,00,000 retail spends in the previous card anniversary year (page, MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 749 },
        welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'xace-domestic-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge access (spend-based)', cond: { rule: 'Spend at least ₹50,000 net retail in a calendar quarter to unlock access in the next calendar quarter', primary_cardholder_only: true, validation_swipe_inr: 2 }, qty: 2, per: 'quarter', from: '2026-04-10' }),
        B({ id: 'xace-railway-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Railway lounge access, add-on cardholders included within the same visits', cond: { max_per_quarter: 2, add_on_cardholders_eligible: true, validation_swipe_inr: 2 }, qty: 8, per: 'annual' }),
        B({ id: 'xace-concierge', cat: 'concierge', sponsor: 'AU Small Finance Bank', label: 'Dedicated global concierge, 24x7 (travel, entertainment, leisure)' }),
        B({ id: 'xace-device-protection', cat: 'insurance_related_perk', sponsor: 'AU Small Finance Bank', label: 'Device protection plan on mobile phones and 1-year extended warranty on mobiles, tablets, laptops and white goods' }),
      ],
      dynamic_promotions_registry: [],
      additional_data: { items: [
        ...prov({
          sources: [
            { url, kind: 'issuer_page', read: PAGE_NOTE },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: MITC, kind: 'MITC (fee waiver, cash limit)', date: MITC_DATE },
            { url: DOM_LOUNGE, kind: 'domestic lounge T&C (Xcite Ace listed, 2 per quarter)', date: DOM_LOUNGE_DATE },
            { url: RAIL, kind: 'railway lounge T&C', date: RAIL_DATE },
            { url: CMA, kind: 'Cardmember Agreement (Xcite ACE is not in the Reward Points cap table 23.5)', date: CMA_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'HELD (wave 3 re-check 2026-11-07): the page publishes three monthly-spend cashback tiers ("Earn 1% Cashback on monthly spends of ₹7,500. Earn 2% Cashback on monthly spends of ₹12,500. Earn 3% Cashback on monthly spends of ₹20,000"). The page text read on 2026-11-07 now also states: "Maximum Cashback per statement cycle is ₹600"; "Statement cycle spends will be considered for product feature cashback calculation"; and that "Wallet reloads/spends, Cash, Rent, Education & Govt, EMI, Fuel, BBPS and Quasi Cash transactions will not be considered for milestone benefit". Still not stated anywhere: whether the percentage applies to the whole statement-cycle spend once a tier is reached, or only to the tier amount (₹75, ₹250, ₹600); whether tiers stack; when and how the cashback is credited. The ₹600 cap equals 3% of ₹20,000, which fits either reading, so the rate cannot be written without guessing. No terms PDF is linked from the page, and the KFS, MITC and Cardmember Agreement have no Xcite ACE cashback clause (searched for "cashback"). Written as no reward rule so the importer skips it. Needs a person: ask AU for the written Xcite ACE cashback terms, or check one statement.',
            'Network: ' + NET_TRIED,
            'Air accident cover is ₹50 lacs on the page popup; the Ultra page headline says ₹20 lacs. Not modelled.',
            'Whether the card is open to new applications: on AU\'s card list and in the KFS, but the product page shows no card-specific Apply button.',
            'No separate joining fee is stated: the KFS gives one fee table under both headings; both set to ₹749.',
          ],
          notes: [
            'Exact page tiers kept here because they are not modelled: 1% cashback on monthly spends of ₹7,500; 2% on monthly spends of ₹12,500; 3% on monthly spends of ₹20,000. Page cap: ₹600 maximum cashback per statement cycle. Excluded from the milestone: wallet reloads/spends, cash, rent, education and government, EMI, fuel, BBPS, quasi cash. Period: statement cycle (page: "Statement cycle spends will be considered").',
            'Comprehensive protection: air accident cover ₹50 lacs; card liability cover; credit shield up to ₹2 lacs; purchase protection up to ₹25,000; baggage loss and delay, flight delay, loss of passport, plane hijack (page popup). Claims on 1800 1200 1500.',
            'Fuel surcharge waiver up to ₹100 per statement cycle on ₹400 to ₹5,000 (page, KFS). Cash limit 40% (KFS). Forex 3.49%. Xpress EMI on ₹500+ transactions, ₹2,000 minimum total.',
          ],
          extra: { held: true, held_reason: 'Cashback basis is not published: the page gives tiers, a ₹600 per-cycle cap and an exclusion list, but not whether the percentage applies to the whole cycle spend or to the tier amount, nor whether tiers stack or when cashback is paid. Network also unresolved.' },
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Xcite Ultra
  'au-xcite-ultra': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/swipeup-program/xcite-ultra-credit-card';
    const o = common(url, 100, { fees: { cashLimit: 40 } });
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU Xcite Ultra Credit Card', network: 'rupay', joining_fee_inr: 749, annual_fee_inr: 749, application_mode: 'open', is_upi_linkable: null, form_factors: ['nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated for Xcite Ultra: not on the card page, the KFS, the MITC or the Cardmember Agreement. The AU Rewardz FAQ (rewardz.au.bank.in/faqs, read 2026-11-07) says the value depends on the card variant and the redemption category and points to the card product page. AU\'s 2 Jun 2023 notice sets Rs 0.20 per point for gift card/voucher redemption on all variants, but that is one redemption channel for every card, not an Ultra value, so it is not used.' },
      eligibility_engine: auEligibility(),
      accrual_engine: A({ base_points_per_block: 4, effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000 }),
      reward_rules: [
        ...auExcl('ultra', 'Xcite Ultra page note, CMA 23.5.1 and 23.6', { wallet: true }),
        X('ultra-excl-transport', 'excluded_spend', [], 'Reward Points accrual on Transportation Merchant Category Codes discontinued with effect from 10 Apr 2026 (Ultra page, rewards note). MCC list not published.', { effective_from: '2026-04-10', mcc_group: 'transportation' }),
        R({ id: 'ultra-international-12rp', cat: 'international_spend', pri: 5, ppb: 12, mult: 3, cap: 'ultra-total-cycle-cap', cond: { transaction_type: 'international' }, reason: 'Page: 12 Reward Points per ₹100 on international spends.' }),
        R({ id: 'ultra-online-8rp', cat: 'all_retail', rail: 'online', pri: 10, ppb: 8, mult: 2, cap: 'ultra-total-cycle-cap', cond: { nature: 'online' }, reason: 'Page: 8 Reward Points per ₹100 on online spends.' }),
        R({ id: 'ultra-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 0.25, cap: 'ultra-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page: 1 Reward Point per ₹100 on utility & telecom; CMA 23.5.1: at most 100 points per transaction.' }),
        R({ id: 'ultra-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 0.25, cap: 'ultra-total-cycle-cap', reason: 'Page: 1 Reward Point per ₹100 on insurance.' }),
        R({ id: 'ultra-offline-4rp', cat: 'all_retail', rail: 'pos_terminal', pri: 30, type: 'standard_accrual', ppb: 4, mult: 1, cap: 'ultra-total-cycle-cap', cond: { nature: 'offline' }, reason: 'Page: 4 Reward Points per ₹100 on offline spends.' }),
      ],
      cap_rules: [C({ id: 'ultra-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 200000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹2,00,000 retail spends in the previous card anniversary year (page, MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 749 },
        welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
        spend_milestones: [
          { id: 'ultra-m1', label: '5,000 Reward Points on ₹2.5 lakh retail spend in a card anniversary year (choose vouchers from a bouquet of brands)', threshold_spend_inr: 250000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
          { id: 'ultra-m-monthly', label: 'Additional 500 Reward Points on retail spends of ₹5,000 done between the 1st and the 5th of every calendar month (page "Additional Rewards Every Month"; rent, wallet and fuel excluded). The 1st-to-5th window cannot be expressed in this field; reward value left null because AU states no point value.', threshold_spend_inr: 5000, reward_value_inr: null, period: 'calendar_month', is_repeatable: true, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'ultra-domestic-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge access (spend-based)', cond: { rule: 'Spend at least ₹50,000 net retail in a calendar quarter to unlock access in the next calendar quarter', primary_cardholder_only: true, validation_swipe_inr: 2 }, qty: 2, per: 'quarter', from: '2026-04-10' }),
        B({ id: 'ultra-railway-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Railway lounge access, add-on cardholders included within the same visits', cond: { max_per_quarter: 2, add_on_cardholders_eligible: true, validation_swipe_inr: 2 }, qty: 8, per: 'annual' }),
        B({ id: 'ultra-concierge', cat: 'concierge', sponsor: 'AU Small Finance Bank', label: 'Dedicated global concierge, 24x7' }),
        B({ id: 'ultra-device-protection', cat: 'insurance_related_perk', sponsor: 'AU Small Finance Bank', label: 'Device protection plan on mobile phones and 1-year extended warranty on mobiles, tablets, laptops and white goods' }),
      ],
      dynamic_promotions_registry: visaOffers('ultra').filter((p) => !p.promo_id.endsWith('-mmt')),
      additional_data: { items: [
        { key: 'verified_network_research', value: { finding_status: 'resolved', product_status: 'active', source_url: url, evidence: 'AU Xcite Ultra product page (re-read 2026-11-07), "Curated Offers" block: "RuPay Offer: Enjoy now amazing offers available on your Xcite Ultra RuPay Credit Card" (link to rupay.co.in/domestic-offers). The card name is written into that sentence, whereas the same block on the Kosmo page still carries the template name "ABC Pro RuPay Credit Card", so the Ultra text was edited for this card. This page has no "Visa Exclusive Offers" heading (the CA and CS pages do). The Times Prime and Alaya Stays links on this page are Visa-programme links, but the Kosmo page, which AU\'s own 18 Sep 2025 press release says is "Built on the RuPay network", carries the same Visa-programme block, so those links do not point to a Visa variant. Network set to rupay on the strength of AU\'s own page text naming the card.', candidates: [
          netCandidate({ network: 'rupay', label: 'Xcite Ultra RuPay Credit Card', sourceUrl: url, evidence: 'Page text: "your Xcite Ultra RuPay Credit Card".' }),
        ] } },
        ...prov({
          sources: [
            { url, kind: 'issuer_page', read: PAGE_NOTE },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: MITC, kind: 'MITC (fee waiver, cash limit)', date: MITC_DATE },
            { url: CMA, kind: 'Cardmember Agreement (25,000 point cap 23.5, exclusions 23.6)', date: CMA_DATE },
            { url: DOM_LOUNGE, kind: 'domestic lounge T&C (Xcite Ultra listed, 2 per quarter)', date: DOM_LOUNGE_DATE },
            { url: 'https://rewardz.au.bank.in/faqs', kind: 'AU Rewardz FAQ ("value of Reward Points depends on the Credit Card variant and the category"), read for the point-value check', date: '2026-11-07' },
            { url: 'https://www.au.bank.in/ausfb-reward-points-ausfb-credit-card-reward-points-usage-tnc_2ndjune23.pdf', kind: 'AU Reward Points usage notice, Rs 0.20 per point for vouchers on all variants (not a card value)', date: '2023-06-02, effective 2023-07-05' },
            { url: 'https://www.au.bank.in/pdfs/press-release/2025/au-small-finance-bank-partners-with-kiwi-for-credit-on-upi-launches-au-kosmo-credit-card---18th-september-2025.pdf', kind: 'AU press release on the Kosmo card ("Built on the RuPay network"); shows the Visa-programme offer block on AU pages is template text', date: '2025-09-18' },
            { url: RAIL, kind: 'railway lounge T&C', date: RAIL_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'Network (wave 3): RESOLVED as rupay from AU\'s own page text "your Xcite Ultra RuPay Credit Card". Residual risk: no AU document says Ultra is issued only on RuPay; the card front art (list tile and product page) carries no network mark, and the KFS, MITC, CMA, lounge and railway T&Cs say only "Visa/RuPay". If AU ever shows a Visa Ultra, switch to dualNetwork.',
            'Value of one Reward Point: not stated by AU for Xcite Ultra (card page, KFS, MITC, CMA, Rewardz FAQ read 2026-11-07). point_value_inr_baseline and effective_base_return_percent left null on purpose. AU\'s 2 Jun 2023 notice gives Rs 0.20 per point only for gift card/voucher redemption on all variants; not used as a card value.',
            'Welcome benefit: the page headline mentions "Exclusive Welcome and Milestone Benefits" but lists only the milestone and a monthly bonus. No welcome benefit recorded.',
            'Monthly bonus "additional 500 Reward Points on retail spends of ₹5,000 done between 1st to 5th of every calendar month" is recorded as a calendar_month milestone (the importer accepts that period) with reward value null. The 1st-to-5th window cannot be expressed, so an engine would test the whole month against the ₹5,000 threshold; keep the value null.',
            'Air accident cover: ₹20 lacs on the page headline, ₹50 lacs in the popup. Not modelled.',
            'Whether international online spend earns 12 or 8 per ₹100: the page lists them separately; international is given priority.',
            'Page note excludes only Rent, Wallet and Fuel; CMA 23.5.1 and 23.6 also exclude education, government, BBPS, EMI and cash. The wider list is used.',
            'Whether the card is open to new applications: on AU\'s card list and in the KFS, but the product page shows no card-specific Apply button.',
            'No separate joining fee is stated: the KFS gives one fee table under both headings; both set to ₹749.',
          ],
          notes: [
            UNIT_NOTE,
            'Points capped at 25,000 per statement cycle on all MCCs (CMA 23.5). Points expire 2 years after accrual (CMA 23.8).',
            'Curated offers on the page: Times Prime complimentary annual membership; Alaya Stays "stay 3 pay 2" and 50% off the second night; RuPay offers via rupay.co.in (modelled as partner offers, not reward rates).',
            'Comprehensive protection cover: credit shield up to ₹2 lacs; purchase protection up to ₹25,000; card liability cover; baggage loss/delay, flight delay, loss of passport, plane hijack.',
            'Fuel surcharge waiver up to ₹100 per statement cycle on ₹400 to ₹5,000 (page, KFS). Cash limit 40%. Forex 3.49%. Add-on cards free for life.',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Kosmo (held)
  'au-kosmo': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/kosmo-credit-card';
    const o = common(url, 100);
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU Kosmo Credit Card', network: 'rupay', joining_fee_inr: 0, annual_fee_inr: 0, application_mode: 'open', is_upi_linkable: true, form_factors: ['virtual_card', 'nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: null, point_value_baseline_basis: 'AU publishes no rate or value for Kiwi rewards.' },
      eligibility_engine: auEligibility(),
      accrual_engine: A({ base_block_inr: null, rounding_mode: null, base_points_per_block: null, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null }),
      reward_rules: [],
      cap_rules: [],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: no joining or annual fee (page and KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [],
      dynamic_promotions_registry: [],
      additional_data: { items: [
        { key: 'verified_network_research', value: { finding_status: 'resolved', product_status: 'active', source_url: KOSMO_PR, evidence: 'AU Small Finance Bank press release dated 18 Sep 2025 (AU\'s own document): headline "New RuPay-powered credit card", body "Built on the RuPay network, this card offers a fully digital onboarding journey, seamless UPI integration"; the AU Executive Director says the AU KOSMO Credit Card "complements the existing RuPay Card portfolio". Supported by the AU product page FAQ, which tells Kosmo holders to create a UPI PIN "when linking your RuPay Credit Card to any UPI app". The Visa-offer block on the Kosmo page is template text (the RuPay block beside it still names "ABC Pro").', candidates: [
          netCandidate({ network: 'rupay', label: 'AU Kosmo Credit Card', sourceUrl: KOSMO_PR, evidence: 'AU press release 18 Sep 2025: "Built on the RuPay network".' }),
        ] } },
        ...prov({
          sources: [
            { url, kind: 'issuer_page + FAQ', read: PAGE_NOTE },
            { url: KFS, kind: 'KFS (lifetime free, 3.49% forex, ₹100 fuel waiver, 20% cash limit)', date: KFS_DATE },
            { url: MITC, kind: 'MITC', date: MITC_DATE },
            { url: CMA, kind: 'Cardmember Agreement (no Kosmo or Kiwi reward section found; re-searched in wave 3 for "Kosmo", "Kiwi")', date: CMA_DATE },
            { url: KOSMO_PR, kind: 'AU press release: AU partners with Kiwi, launches AU KOSMO Credit Card ("Built on the RuPay network"; "Earn rewards on every spend ... via the Kiwi app"; no rate)', date: '2025-09-18' },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'HELD (wave 3 re-check 2026-11-07): AU still publishes no reward rate. The page says only "Earn Kiwi rewards on every UPI Scan & Pay" and "Kiwi rewards on eCom, POS & contactless transactions"; the AU press release says only "Earn rewards on every spend - UPI, retail, or online ... via the Kiwi app"; the Cardmember Agreement, KFS, MITC and the AU Rewardz site have no Kosmo or Kiwi rewards clause. No Kiwi or Kosmo rewards T&C is hosted or linked on au.bank.in. No reward rule written so the importer skips it. For a person to decide: Kiwi (the co-brand partner, gokiwi.in/cards/aubank/) prints "1.5% Cashback on UPI scan & pay" and "0.5% Cashback on online spends" for this card, with no cap, exclusion list, rupee value or POS/contactless rate and no linked rewards policy. That is a partner statement, not an AU document, so it was NOT used. Ask AU or Kiwi for the written Kiwi Rewards Policy for the KOSMO card if the partner source is to be accepted.',
            'Network (wave 3): RESOLVED as rupay from AU\'s own press release of 18 Sep 2025 ("Built on the RuPay network"). The earlier doubt came from a template Visa-offer popup on the page, which is shared template text.',
            'Fuel surcharge waiver cap: the product page and KFS say ₹100 per statement cycle; a template popup on the same page says ₹250. KFS used.',
            'The "RuPay Offer" popup on this page names the "ABC Pro RuPay Credit Card", so it is copied template text, not Kosmo terms.',
          ],
          notes: [
            'Kiwi rewards are not earned on cash, rent, education & govt, insurance, EMI, fuel and BBPS transactions (page note). Not written as rules, to keep the card with no earn logic.',
            'Rewards earned in a statement cycle are credited to the Kiwi account on statement generation and viewed in the Kiwi app (page FAQ). Apply through the Kiwi app (page FAQ).',
            'Forex 3.49%, cash limit 20%, fuel waiver up to ₹100 per statement month on ₹400 to ₹5,000 (KFS). Add-on cards offered; Xpress EMI on ₹500+ transactions with ₹2,000 minimum total.',
          ],
          extra: { held: true, held_reason: 'AU publishes no Kiwi reward rate for the card.' },
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Zaggle (held: percentage unit undefined)
  'au-zaggle': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/au-zaggle-credit-card';
    const o = common(url, 100);
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU Zaggle Credit Card', joining_fee_inr: 0, annual_fee_inr: 0, application_mode: 'open', is_upi_linkable: true, form_factors: ['virtual_card', 'nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: 0.25, point_value_baseline_basis: 'Cardmember Agreement (Zaggle rewards): "Each 1 Zagg Coin shall be equivalent to 1 Reward Point. Each Reward Point shall carry a redemption value of ₹0.25". Product page repeats "1 Zagg Coin = ₹0.25". Points valid 24 months from accrual.' },
      eligibility_engine: auEligibility({ extra: [{ parameter: 'zagg_money_app_registered_user', operator: '==', threshold_value: 1, allowed_values: [] }], notes: 'Apply through the zagg.money app. A customer can apply for only one network variant (page FAQ). The UPI mobile number must match the card mobile number. AU says the criteria are only indicative.' }),
      accrual_engine: A({ base_block_inr: null, rounding_mode: null, base_points_per_block: null, effective_base_return_percent: null, cycle_accrual_ceiling_points: 2000 }),
      reward_rules: [],
      cap_rules: [C({ id: 'zaggle-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 2000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: no joining or annual fee (page and KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [],
      dynamic_promotions_registry: [],
      redemption_matrix: { direct_options: [{ channel: 'zagg.money app: statement credit / cashback, minimum 1,000 Reward Points, posted about 30 days after the request', redemption_type: 'statement_credit', inr_value_per_point: 0.25, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 1000, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 'N/A', effective_from: null, effective_to: null }], partner_transfers: [] },
      additional_data: { items: [
        { key: 'verified_network_research', value: { finding_status: 'resolved', product_status: 'active', source_url: url, evidence: 'AU press release of 9 Jul 2026 (AU\'s own document, newer than the Cardmember Agreement copy): the AU Zaggle Co-Branded Retail Credit Card is "Available on both Visa and RuPay networks", "offers customers the flexibility to choose their preferred payment network". AU product page: reward blocks for "AU Zaggle Visa Credit Card" and "AU Zaggle RuPay Credit Card"; FAQ: "you can apply for only one network variant of the card". Cardmember Agreement section 23.33 has separate earning structures "A. AU Zaggle RuPay Credit Card" and "B. AU Zaggle Visa Credit Card".', candidates: [
          netCandidate({ network: 'visa', label: 'AU Zaggle Visa Credit Card', sourceUrl: CMA, evidence: 'CMA 23.33 B: Visa variant earns 8% Zagg Coins on contactless up to ₹5,000, 4% on e-commerce, 2% on other retail. Page shows the same variant.' }),
          netCandidate({ network: 'rupay', label: 'AU Zaggle RuPay Credit Card', sourceUrl: CMA, evidence: 'CMA 23.33 A: RuPay variant earns 4%/8% on zagg.money UPI, 2% on other UPI apps and 2% on other retail. Page shows the same variant.' }),
        ] } },
        ...prov({
          sources: [
            { url, kind: 'issuer_page + FAQ', read: PAGE_NOTE },
            { url: CMA, kind: 'Cardmember Agreement section 23.33 (Zaggle reward structure, cap, minimum, value, redemption)', date: CMA_DATE },
            { url: ZAGGLE_PR, kind: 'AU press release: AU Zaggle co-branded card "Available on both Visa and RuPay networks"; "Zagg Coins can be converted into cashback through the zagg.money app"; gives no coins-per-₹100 definition', date: '2026-07-09' },
            { url: KFS, kind: 'KFS (lifetime free, 3.49% forex, ₹100 fuel waiver, 20% cash limit)', date: KFS_DATE },
            { url: MITC, kind: 'MITC', date: MITC_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'HELD (wave 3 re-check 2026-11-07): AU states rates as "X% Zagg Coins" and gives the value of a coin (₹0.25) but never says how many coins one percent means per ₹100 spent. Searched and read: the AU product page and FAQ (re-read), Cardmember Agreement 23.33, the AU press releases of 22 Sep 2025 and 9 Jul 2026, the KFS and MITC. None defines the unit. CMA 23.22 says only that Reward Points "as may be applicable on the credit card variant" are earned "for transaction amounts in multiples of ₹100", which does not map a percentage to coins. Leads for a person (NOT used as facts): Zaggle\'s own rewards policy (zagg.money/rewards-policy) says "3% of the transaction amount will be credited as Zagg Coins" for the YES Bank Zagg card, but it states it does not cover the AU card; and the 2,000-coin cycle cap fits a per-₹100 reading far better than a percent-of-value reading. Ask AU or Zaggle for the AU Zaggle rewards terms, or check a live statement, before writing rules. If 8% meant 8 coins per ₹100 the value is 2%; if it meant 8% of spend the value is 8%. No reward rule written so the importer does not guess; the structure is kept in notes below.',
            'Network: both variants are issued and named by AU, so this is resolved as dual; the importer reads verified_network_research.',
            'Whether the ₹99 + GST redemption fee in the KFS applies to Zagg Coin redemption through the zagg.money app: not stated for this program.',
            'The CMA copy carrying the Zaggle clause is undated; the dated copy under /pdf/credit-card/ (16 May 2026) lacks it.',
            'Page says Visa contactless earns 8% on transactions between ₹500 and ₹5,000 and 2% above ₹5,000; the CMA says 8% on contactless "not exceeding ₹5,000" with a ₹500 minimum for any earn. Consistent, noted for completeness.',
          ],
          notes: [
            'Structure as published (not modelled). RuPay variant: 4% Zagg Coins on zagg.money UPI up to ₹10,000 cumulative statement-cycle spend; 8% on the part above ₹10,000; 2% on UPI through other UPI apps; 2% on all other eligible retail. Visa variant: 8% on contactless of ₹500 to ₹5,000, 2% on contactless above ₹5,000; 4% on e-commerce; 2% on all other eligible retail. Page also lists 2% on POS and 2% on RuPay e-commerce.',
            'Reward Points accrue only on eligible retail transactions of ₹500 or more. Capped at 2,000 Reward Points per statement cycle. Credited to the zagg.money account on statement generation. Valid 24 months from accrual (CMA 23.33; page FAQ says 2 years from the statement credit month).',
            'Redemption only through the zagg.money app, minimum 1,000 points, as statement credit about 30 days after the request; once redeemed it cannot be reversed (CMA 23.33).',
            'Forex 3.49%, cash limit 20%, fuel surcharge waiver 1% up to ₹100 per statement cycle on ₹400 to ₹5,000 (page, KFS). Contactless payments up to ₹5,000.',
            'AU and Zaggle have a revenue sharing agreement as co-brand partners (page).',
          ],
          extra: { held: true, held_reason: 'Reward percentages are stated in Zagg Coins with no definition of coins per ₹100.' },
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── CA Metal
  'au-ca-metal': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/ca-credit-card';
    const T = 'https://www.au.bank.in/pdf/ca-credit-card/AU-CA-Credit-Card-Reward-Points-Terms-and-Conditions.pdf';
    const o = common(url, 250, { fees: { forex: 1.99, emiPost: 0, apr: { m: 2.99, a: 35.88 } }, card_product: { card_tier: null } });
    const EX = 'AU CA Reward Points T&C, 6 Mar 2026';
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU CA Metal Credit Card', joining_fee_inr: 0, annual_fee_inr: 0, application_mode: 'open', is_upi_linkable: null, form_factors: ['physical_metal', 'nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated for this card. The AU Rewardz FAQ says it depends on card variant and redemption category.' },
      eligibility_engine: auEligibility({ se: [25, 75], sal: [21, 60], notes: 'Page names the card as exclusive for Chartered Accountants but lists no membership proof; add-on cardholders 18+. AU says the criteria are only indicative.' }),
      accrual_engine: A({ base_points_per_block: 2, effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000 }),
      reward_rules: [
        X('ca-excl-fuel', 'fuel', [5983, 5541, 5542, 5172], `Fuel earns nothing (${EX}).`),
        X('ca-excl-rent', 'rent', [6513], `Rent earns nothing (${EX}).`),
        X('ca-excl-wallet', 'wallet_load', [6540], `Wallet loads earn nothing (${EX}).`),
        X('ca-excl-cash', 'cash_withdrawal', [6010, 6011], `Cash earns nothing (${EX}).`),
        X('ca-excl-education', 'education', [8211, 8220, 8241, 8244, 8249, 8299], `Education earns nothing (${EX}).`),
        X('ca-excl-govt', 'government', [9211, 9222, 9223, 9311, 9399, 9402, 9405, 9950], `Government earns nothing (${EX}). MCC 9311 is also listed under Tax Payments (8 points): the T&C conflicts with itself, exclusion wins here.`),
        X('ca-excl-bbps', 'excluded_spend', [], 'BBPS bill payments on the AU 0101 app earn nothing (T&C exclusions).', { platform: 'AU 0101 BBPS' }),
        X('ca-excl-emi', 'excluded_spend', [], 'EMI and quasi-cash transactions earn nothing (page note).', { transaction_type: 'emi_or_quasi_cash' }),
        X('ca-excl-transport', 'excluded_spend', [], 'Reward Points accrual on Transportation MCCs was discontinued from 1 Apr 2026 (page).', { effective_from: '2026-04-01', mcc_group: 'transportation' }),
        R({ id: 'ca-dining-8rp', cat: 'dining', pri: 10, ppb: 8, mult: 4, cap: 'ca-accelerated-cycle-cap', cond: { mcc_list: DINING_MCCS }, reason: `8 Reward Points per ₹100 on dining: restaurants 5811-5813 and QSR 5814 (${EX}).` }),
        R({ id: 'ca-travel-8rp', cat: 'travel', pri: 10, ppb: 8, mult: 4, cap: 'ca-accelerated-cycle-cap', cond: { mcc_list: TRAVEL_MCCS, otas: 'only airline and hotel bookings through online travel agencies; bus, train and cab bookings via OTAs earn nothing' }, reason: `8 Reward Points per ₹100 on travel: airline MCCs, 4722, 4723 and 4511 (${EX}).` }),
        R({ id: 'ca-tax-8rp', cat: 'government', pri: 10, ppb: 8, mult: 4, cap: 'ca-accelerated-cycle-cap', cond: { mcc_list: [9311, 7276] }, reason: `8 Reward Points per ₹100 on tax payments, MCCs 9311 and 7276 (${EX}). 9311 is also in the exclusion list.` }),
        R({ id: 'ca-software-8rp', cat: 'other', pri: 10, ppb: 8, mult: 4, cap: 'ca-accelerated-cycle-cap', cond: { mcc_list: [5734, 5045], category_label: 'software purchases' }, reason: `8 Reward Points per ₹100 on software purchases, MCCs 5734 and 5045 (${EX}).` }),
        R({ id: 'ca-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 0.5, cap: 'ca-total-cycle-cap', cond: { mcc_list: BILL_MCCS, max_points_per_transaction: 100 }, reason: `1 Reward Point per ₹100 on telecom and utilities (MCCs 4812, 4814, 4899, 4900), at most 100 points per transaction (${EX}; page).` }),
        R({ id: 'ca-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 0.5, cap: 'ca-total-cycle-cap', cond: { mcc_list: INSURANCE_MCCS }, reason: `1 Reward Point per ₹100 on insurance (MCCs 5960, 6300) (${EX}).` }),
        R({ id: 'ca-base-2rp', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cap: 'ca-total-cycle-cap', reason: `2 Reward Points per ₹100 on all other retail MCCs (${EX}).` }),
      ],
      cap_rules: [
        C({ id: 'ca-accelerated-cycle-cap', cat: 'dining', metric: 'total_reward_points', period: 'statement_cycle', points: 5000, after: 'zero_accrual', parent: 'ca-total-cycle-cap' }),
        C({ id: 'ca-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' }),
      ],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: no joining or annual fee (page and KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: 'spend_5000_within_30_days_of_card_activation', benefit_points: 2000, effective_value_inr: null, condition: '2,000 bonus Reward Points on ₹5,000 spends within 30 days of card activation, credited within 3 working days; plus a SwiggyOne Quarterly Dining Membership on ₹10,000 spends within 30 days of activation. Primary cardholder only (AU CA Welcome Benefit T&C, 6 Jan 2026).' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'ca-domestic-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge access', cond: { rule: 'Lounge T&C: spend at least ₹50,000 net retail in a calendar quarter to unlock access in the next quarter (for CA and CS from 1 Oct 2026). Page: access only if the card stays purchase-active during the quarter.', primary_cardholder_only: true, validation_swipe_inr: 2 }, qty: 2, per: 'quarter', from: '2026-10-01' }),
        B({ id: 'ca-concierge', cat: 'concierge', sponsor: 'AU Small Finance Bank', label: 'Dedicated global concierge, 24x7 (1800 210 0298)' }),
        B({ id: 'ca-swiggyone', cat: 'other', sponsor: 'Swiggy', label: 'SwiggyOne Quarterly Dining Membership as a welcome benefit on ₹10,000 spend within 30 days of activation', cond: { welcome_benefit: true } }),
      ],
      dynamic_promotions_registry: [
        P({ id: 'ca-icai-25pct', cat: 'other', sponsor: 'ICAI annual membership fee paid with the card', platform: 'ICAI membership renewal', type: 'cashback', pct: 25, quota: true }),
        ...visaOffers('ca'),
      ],
      additional_data: { items: [
        partialNetwork({ sourceUrl: url, evidence: 'Page popup titled "Visa Exclusive Offers" lists MakeMyTrip, Times Prime and Alaya Stays offers through Visa-branded partner links. The card image on the page is "without name" and shows no network logo. The same popup appears on the CS page.', candidates: [
          netCandidate({ network: 'visa', label: 'AU CA Metal Credit Card', sourceUrl: url, evidence: 'Popup heading "Visa Exclusive Offers" on the product page; no AU document states the network outright.' }),
        ] }),
        ...prov({
          sources: [
            { url, kind: 'issuer_page + FAQ + popups', read: PAGE_NOTE },
            { url: T, kind: 'AU CA Credit Card Reward Points T&C (earn rates, MCC lists, exclusions)', date: '2026-03-06', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/ca-credit-card/ca-card-welcome-benefits-terms-and-conditions.pdf', kind: 'welcome benefit T&C', date: '2026-01-06', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/ca-credit-card/ca-card-icai-membership-tnc.pdf', kind: 'ICAI membership fee benefit T&C', date: '2026-06-02', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/zenith-plus-credit-card/au-small-finance-bank-cc-airport-lounge-terms-conditions.pdf', kind: 'airport lounge program T&C (CA and CS from 1 Oct 2026)', date: 'undated; revision w.e.f. 10 Apr 2026', read: 'pdftotext' },
            { url: KFS, kind: 'KFS (lifetime free, 1.99% forex, 2.99% interest, ₹250 fuel waiver, zero Xpress EMI fee)', date: KFS_DATE },
            { url: CMA, kind: 'Cardmember Agreement (25,000 cap and 5,000 cap for CA/CS in 23.5)', date: CMA_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'Network (wave 3): STILL UNRESOLVED; card_product.network left null, one Visa candidate kept as a hint only. The CA page carries a "Visa Exclusive Offers" block (MakeMyTrip Visa Signature offer, Times Prime and Alaya Stays Visa-programme links) and no RuPay block, which points to Visa, but the same block is template text on AU pages (it also sits on the RuPay-only Kosmo page), so it is not accepted as evidence. The card art on the list tile and the product page ("CA_Credit_Card_new-version-without-name") shows no network mark. ' + NET_TRIED,
            'Value of one AU Reward Point: not stated for this card (CA reward T&C of 6 Mar 2026, welcome and ICAI T&Cs, KFS, MITC, CMA and the Rewardz FAQ read; the FAQ says it depends on card variant and redemption category). Left null on purpose. AU\'s 2 Jun 2023 notice gives Rs 0.20 per point only for gift card/voucher redemption on all variants; not used as a card value.',
            'MCC 9311 appears in both the 8-point Tax Payments list and the Education & Govt exclusion list; modelled as excluded.',
            'Cap after the 5,000-point cycle limit on the 8-point categories: the T&C and CMA only say the maximum is 5,000 per cycle, not whether spend then earns 2 points. Modelled as zero accrual for those categories.',
            'Lounge: the page says access needs the card to stay "purchase-active"; the lounge T&C says ₹50,000 retail spend in the previous calendar quarter, effective for CA and CS from 1 Oct 2026. T&C used.',
            'Eligibility: the page does not state that ICAI membership must be shown. Left as a general retail eligibility.',
            'The page "Know more" on Transportation accrual (discontinued from 1 Apr 2026) was not separately read.',
          ],
          notes: [
            UNIT_NOTE,
            'Page figures: 8 points on dining, travel, tax payments and software; 2 points on retail; 1 point on utility, telecom and insurance; max 100 points per utility/telecom transaction; max 5,000 points per cycle on the 8-point categories (page note and CMA).',
            'ICAI benefit: flat 25% cashback on the annual ICAI membership fee paid with the card, calculated on the fee excluding GST, once per card anniversary year, primary cardholder, credited within 60 days (ICAI T&C, 2 Jun 2026).',
            'Protection (page): air accident cover ₹50 lacs; card liability cover; credit shield up to ₹5 lacs; purchase protection up to ₹25,000; baggage and flight delay, loss of passport, plane hijack.',
            'Fuel surcharge waiver up to ₹250 per statement cycle on ₹400 to ₹5,000. Zero processing fee on Xpress EMI (KFS). Forex 1.99%. Interest 2.99% a month (35.88% a year). Cash limit 20%.',
            'Visa offers on the page: MakeMyTrip 2 complimentary domestic flight seat bookings (max ₹350 each as written) and flat 15% off select hotels as MyCash; Times Prime complimentary annual membership; Alaya Stays 3 nights for 2 and 50% off the second night.',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── CS
  'au-cs': (() => {
    const url = 'https://www.au.bank.in/personal-banking/credit-cards/au-cs-credit-card';
    const T = 'https://www.au.bank.in/pdfs/au-cs-credit-card/AU-CS-Credit-Card-Reward-Points-Terms-and-Conditions.pdf';
    const o = common(url, 250, { fees: { forex: 1.99, emiPost: 0, apr: { m: 2.99, a: 35.88 } } });
    const EX = 'AU CS Reward Points T&C (undated)';
    return {
      ...o,
      card_product: { ...o.card_product, name: 'AU CS Credit Card', joining_fee_inr: 0, annual_fee_inr: 0, application_mode: 'open', is_upi_linkable: null, form_factors: ['nfc_contactless'], contactless_pin_free_limit_inr: 5000, point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated for this card. The AU Rewardz FAQ says it depends on card variant and redemption category.' },
      eligibility_engine: auEligibility({ se: [25, 65], sal: [21, 60], notes: 'Page names the card as for Company Secretaries but lists no membership proof; add-on cardholders 18+. AU says the criteria are only indicative.' }),
      accrual_engine: A({ base_points_per_block: 2, effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000 }),
      reward_rules: [
        X('cs-excl-fuel', 'fuel', [5983, 5541, 5542, 5172], `Fuel earns nothing (${EX}).`),
        X('cs-excl-rent', 'rent', [6513], `Rent earns nothing (${EX}).`),
        X('cs-excl-wallet', 'wallet_load', [6540], `Wallet loads earn nothing (${EX}).`),
        X('cs-excl-cash', 'cash_withdrawal', [6010, 6011], `Cash earns nothing (${EX}).`),
        X('cs-excl-education', 'education', [8211, 8220, 8241, 8244, 8249, 8299], `Education earns nothing (${EX}).`),
        X('cs-excl-govt', 'government', [9211, 9222, 9223, 9311, 9399, 9402, 9405, 9950], `Government earns nothing (${EX}). MCC 9311 is also listed under Tax Payments (8 points): the T&C conflicts with itself, exclusion wins here.`),
        X('cs-excl-bbps', 'excluded_spend', [], 'BBPS bill payments on the AU 0101 app earn nothing (T&C exclusions).', { platform: 'AU 0101 BBPS' }),
        X('cs-excl-emi', 'excluded_spend', [], 'EMI and quasi-cash transactions earn nothing (page note).', { transaction_type: 'emi_or_quasi_cash' }),
        X('cs-excl-transport', 'excluded_spend', [], 'Transportation earns nothing (page note).', { mcc_group: 'transportation' }),
        R({ id: 'cs-dining-8rp', cat: 'dining', pri: 10, ppb: 8, mult: 4, cap: 'cs-accelerated-cycle-cap', cond: { mcc_list: DINING_MCCS }, reason: `8 Reward Points per ₹100 on dining: restaurants 5811-5813 and QSR 5814 (${EX}).` }),
        R({ id: 'cs-travel-8rp', cat: 'travel', pri: 10, ppb: 8, mult: 4, cap: 'cs-accelerated-cycle-cap', cond: { mcc_list: TRAVEL_MCCS, otas: 'only airline and hotel bookings through online travel agencies; bus, train and cab bookings via OTAs earn nothing' }, reason: `8 Reward Points per ₹100 on travel: airline MCCs, 4722, 4723 and 4511 (${EX}).` }),
        R({ id: 'cs-tax-8rp', cat: 'government', pri: 10, ppb: 8, mult: 4, cap: 'cs-accelerated-cycle-cap', cond: { mcc_list: [9311, 7276] }, reason: `8 Reward Points per ₹100 on tax payments, MCCs 9311 and 7276 (${EX}). 9311 is also in the exclusion list.` }),
        R({ id: 'cs-software-8rp', cat: 'other', pri: 10, ppb: 8, mult: 4, cap: 'cs-accelerated-cycle-cap', cond: { mcc_list: [5734, 5045], category_label: 'software purchases' }, reason: `8 Reward Points per ₹100 on software purchases, MCCs 5734 and 5045 (${EX}).` }),
        R({ id: 'cs-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 0.5, cap: 'cs-total-cycle-cap', cond: { mcc_list: BILL_MCCS, max_points_per_transaction: 100 }, reason: `1 Reward Point per ₹100 on telecom and utilities (MCCs 4812, 4814, 4899, 4900), at most 100 points per transaction (${EX}; page).` }),
        R({ id: 'cs-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 0.5, cap: 'cs-total-cycle-cap', cond: { mcc_list: INSURANCE_MCCS }, reason: `1 Reward Point per ₹100 on insurance (MCCs 5960, 6300) (${EX}).` }),
        R({ id: 'cs-base-2rp', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cap: 'cs-total-cycle-cap', reason: `2 Reward Points per ₹100 on all other retail spends (${EX}).` }),
      ],
      cap_rules: [
        C({ id: 'cs-accelerated-cycle-cap', cat: 'dining', metric: 'total_reward_points', period: 'statement_cycle', points: 5000, after: 'zero_accrual', parent: 'cs-total-cycle-cap' }),
        C({ id: 'cs-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' }),
      ],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: no joining or annual fee (page and KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: 'spend_5000_within_30_days_of_card_activation', benefit_points: 2000, effective_value_inr: null, condition: '2,000 bonus Reward Points on ₹5,000 spends within 30 days of card activation, credited within 3 working days; plus a SwiggyOne Quarterly Dining Membership on ₹10,000 spends within 30 days of activation. Primary cardholder (AU CS Welcome Benefit T&C, undated).' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'cs-domestic-lounge', cat: 'lounge', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge access', cond: { rule: 'Lounge T&C: spend at least ₹50,000 net retail in a calendar quarter to unlock access in the next quarter (for CA and CS from 1 Oct 2026). Page: access only if the card stays purchase-active during the quarter.', primary_cardholder_only: true, validation_swipe_inr: 2 }, qty: 2, per: 'quarter', from: '2026-10-01' }),
        B({ id: 'cs-concierge', cat: 'concierge', sponsor: 'AU Small Finance Bank', label: 'Dedicated concierge, 24x7 (1800 210 0298)' }),
        B({ id: 'cs-swiggyone', cat: 'other', sponsor: 'Swiggy', label: 'SwiggyOne Quarterly Dining Membership as a welcome benefit on ₹10,000 spend within 30 days of activation', cond: { welcome_benefit: true } }),
      ],
      dynamic_promotions_registry: [
        P({ id: 'cs-icsi-25pct', cat: 'other', sponsor: 'ICSI annual membership fee paid with the card', platform: 'ICSI membership renewal', type: 'cashback', pct: 25, quota: true }),
        ...visaOffers('cs'),
      ],
      additional_data: { items: [
        partialNetwork({ sourceUrl: url, evidence: 'Page popup titled "Visa Exclusive Offers" lists MakeMyTrip, Times Prime and Alaya Stays through Visa-branded partner links. The card image file on the page is named "CS_Credit_Card Op3_without-VISA", meaning a Visa logo was edited out of the art. No AU document states the network outright.', candidates: [
          netCandidate({ network: 'visa', label: 'AU CS Credit Card', sourceUrl: url, evidence: 'Popup heading "Visa Exclusive Offers"; card art asset name "without-VISA".' }),
        ] }),
        ...prov({
          sources: [
            { url, kind: 'issuer_page + FAQ + popups', read: PAGE_NOTE },
            { url: T, kind: 'AU CS Credit Card Reward Points T&C (earn rates, MCC lists, exclusions)', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdfs/au-cs-credit-card/CS_Card-welcome-benefits-terms-and-conditions.pdf', kind: 'welcome benefit T&C', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdfs/au-cs-credit-card/CS-Card-ICSI-Membership-Fee-Benefit-Terms-and-Conditions.pdf', kind: 'ICSI membership fee benefit T&C', date: '2026-06-04', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/zenith-plus-credit-card/au-small-finance-bank-cc-airport-lounge-terms-conditions.pdf', kind: 'airport lounge program T&C (CA and CS from 1 Oct 2026)', date: 'undated; revision w.e.f. 10 Apr 2026', read: 'pdftotext' },
            { url: KFS, kind: 'KFS (lifetime free, 1.99% forex, 2.99% interest, ₹250 fuel waiver, zero Xpress EMI fee)', date: KFS_DATE },
            { url: CMA, kind: 'Cardmember Agreement (25,000 cap and 5,000 cap for CA/CS in 23.5)', date: CMA_DATE },
            { url: LIST, kind: 'AU current credit card list (card is listed)', date: '2026-11-07' },
          ],
          unverified: [
            'Network (wave 3): STILL UNRESOLVED; card_product.network left null, one Visa candidate kept as a hint only. The CS page carries the "Visa Exclusive Offers" block and no RuPay block, and the card image asset is named "CS_Credit_Card Op3_without-VISA" (a Visa logo was edited out of that art file), which points to Visa, but the offers block is template text shared across AU pages and a file name is not a network mark. The card art as displayed (list tile and product page) shows no network mark. ' + NET_TRIED,
            'Value of one AU Reward Point: not stated for this card (CS reward T&C, welcome and ICSI T&Cs, KFS, MITC, CMA and the Rewardz FAQ read; the FAQ says it depends on card variant and redemption category). Left null on purpose. AU\'s 2 Jun 2023 notice gives Rs 0.20 per point only for gift card/voucher redemption on all variants; not used as a card value.',
            'MCC 9311 appears in both the 8-point Tax Payments list and the Education & Govt exclusion list; modelled as excluded.',
            'Cap after the 5,000-point cycle limit on the 8-point categories: not stated. Modelled as zero accrual for those categories.',
            'Lounge: the page says access needs the card to stay "purchase-active"; the lounge T&C says ₹50,000 retail spend in the previous quarter, effective for CA and CS from 1 Oct 2026. T&C used.',
            'The reward T&C and welcome T&C carry no date.',
          ],
          notes: [
            UNIT_NOTE,
            'Page figures: 8 points on dining, travel, tax payments and software; 2 points on retail; 1 point on utility, telecom and insurance; max 100 points per utility/telecom transaction; max 5,000 points per cycle on the 8-point categories.',
            'ICSI benefit: flat 25% cashback on the annual ICSI membership fee paid with the card, calculated on the fee excluding GST, once per card anniversary year, primary cardholder, credited within 60 days (ICSI T&C, 4 Jun 2026).',
            'Protection (page): air accident cover ₹50 lacs; card liability cover; credit shield up to ₹5 lacs; purchase protection up to ₹25,000; baggage and flight delay, loss of passport, plane hijack.',
            'Fuel surcharge waiver up to ₹250 per statement cycle on ₹400 to ₹5,000. Zero processing fee on Xpress EMI (KFS). Forex 1.99%. Interest 2.99% a month (35.88% a year). Cash limit 20%.',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),
};
