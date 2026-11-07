// RBL Bank co-brand cards, batch B (W4b): BankBazaar SaveMax, Paisabazaar Duet Plus, Movies & More, IRCTC RBL Bank.
// Sources read 2026-11-07, RBL documents and RBL pages only (partner sites were not used as sources).
//  SOC   = RBL Schedule of Charges, footer ref RBL-CC-SOC-V2-04-06-2026 (4 Jun 2026). The PDF was created 4 Jun 2026 and is served with last-modified 29 Aug 2026.
//  MITC  = Most Important Terms and Conditions cum Key Fact Statement, footer ref RBL-CC-MITC-V2-29-10-2026 (29 Oct 2026; served last-modified 30 Oct 2026), 57 pages.
//  CMA   = RBL Bank Credit Card Cardmember Agreement, footer ref RBL-CC-CMA-27-10-2026 (27 Oct 2026), 33 pages.
//  LIST  = RBL credit card list page ("Showing 64 Cards") and NETWORK GUIDE page, both rendered 2026-11-07.
//  Per-card T&Cs carry no printed date; the PDF creation dates are quoted next to each one.
// Not drafted (see wave2/W4b.json): BankBazaar SaveMax Pro (page says "sourced through invite only"), Popcorn (page says existing cards transitioned from 20 Dec 2025),
// LazyPay (not on RBL's current card list or network guide, no product page).
// Helpers are copied in spirit from cards/rbl.mjs, nothing is imported from it.
import { R, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const SOC = 'https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf';
const MITC = 'https://webassets.rbl.bank.in/document/Credit%20Cards/RBL-MITC-final.pdf';
const CMA = 'https://webassets.rbl.bank.in/document/credit-cards/rbl-cc-cardmember-agreement.pdf';
const LIST = 'https://www.rbl.bank.in/personal-banking/cards/credit-cards/category';
const GUIDE = 'https://www.rbl.bank.in/personal-banking/cards/credit-cards/network-guide';
const BMS = 'https://webassets.rbl.bank.in/document/offer-pdfs/bms-offers.pdf';
const page = (s) => `https://www.rbl.bank.in/personal-banking/cards/credit-cards/${s}`;

// Excluded-category MCC table, identical in every product T&C read (spelled with leading zeros in the PDFs).
const MCC = {
  railways: [66, 4011, 4112],
  fuel: [32, 2541, 4001, 5542, 5541, 5172],
  utilities: [4900],
  wallet: [6540],
  quasi: [6050, 6051, 4829],
  rent: [6513],
  insurance: [6300, 6310],
  education: [8220, 8244, 8249, 8211, 8241, 8299],
  govt: [9400, 1490, 2490, 2995, 7800, 9406, 9222, 9405, 9399, 9211, 9402, 9401, 9311, 9223],
  contracted: [1711, 1740, 763, 1520, 742, 1761, 1799, 1750, 1731, 1771, 780],
  cash: [6011, 6010],
  misc: [5960],
};
// key -> [PandaPay category token, MCC list, label]. Tokens with no close app category (railways, contracted, misc, cash) stay info-only on purpose,
// so an exclusion can never switch off a real category such as flights.
const EX = {
  fuel: ['fuel', MCC.fuel, 'Fuel and auto'],
  utilities: ['bills', MCC.utilities, 'Utilities'],
  insurance: ['insurance', MCC.insurance, 'Insurance'],
  railways: ['excluded_spend', MCC.railways, 'Railways'],
  rent: ['rent', MCC.rent, 'Real estate and rental'],
  wallet: ['wallet', MCC.wallet, 'Wallet and service providers'],
  govt: ['government', MCC.govt, 'Government services'],
  cash: ['cash_withdrawal', MCC.cash, 'Cash'],
  quasi: ['cash_withdrawal', MCC.quasi, 'Quasi-cash'],
  education: ['education', MCC.education, 'Education'],
  contracted: ['excluded_spend', MCC.contracted, 'Contracted services'],
  misc: ['excluded_spend', MCC.misc, 'Miscellaneous (5960)'],
  bills2pay: ['bills', [], 'Bills2Pay (utility bills paid through the RBL MyBank app or Internet banking; no MCC)'],
  emi: ['emi', [], 'EMI conversion of retail transactions (Split-N-Pay and EMI requested at POS, web or app)'],
};
const excl = (prefix, keys, src, from = {}) => keys.map((k) => {
  const [cat, mccs, label] = EX[k];
  return R({ id: `${prefix}-excl-${k}`, cat, pri: 2, type: 'exclusion', mult: 0, cond: mccs.length ? { mcc_list: mccs } : {}, reason: `${label} earns no ${src.what} (${src.ref}).`, from: from[k] ?? null });
});
const excludedMccs = (keys) => keys.flatMap((k) => EX[k][1]);

// Fees that are the same on every RBL card (SOC + MITC). `fuel` is overridden where the product T&C gives a surcharge waiver.
const NO_FUEL_WAIVER = { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null };
const fees = ({ fuel = NO_FUEL_WAIVER, redemption = { fee_inr: 99, gst_applicable: true, exempted_channels: [], notes: 'MITC: INR 99 + GST on redemption of reward points earned on RBL credit cards.' } } = {}) => ({
  apr: { monthly_interest_rate_percent: 3.99, annual_interest_rate_percent: 47.88 },
  forex_markup: { markup_percent: 3.5, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: 3.5, gst_applicable: true, trigger_condition: 'SOC: markup up to 3.5% on foreign currency, dynamic and static conversion transactions; also on rupee transactions at an international location or at India-located merchants registered overseas (MITC: 3.5% on all cards except Nova, Insignia, iGlobe, World Xclusive, World Safari family and Lumiere)' },
  fuel_surcharge: fuel,
  cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
  category_surcharges: [
    { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on all rental transactions, no cap stated (SOC, MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'fuel', mcc_list: MCC.fuel, fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on each fuel and auto transaction above INR 10,000, at most INR 3,000 per transaction; the amount includes the surcharge (MITC)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
    { category_id: 'bills', mcc_list: [4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on aggregate utility spend above INR 50,000 in a month per card (SOC, MITC)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
    { category_id: 'education', mcc_list: MCC.education, fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on education payments made through third-party apps such as Cred, PhonePe, Paytm, Mobikwik, Freecharge; payments on the school or college website or its POS carry no fee (SOC, MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'other', mcc_list: [4784, 4111, 4131], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on FASTag loading and toll payments above INR 10,000 per transaction per card (SOC, MITC)', threshold_spend_inr: 10000, effective_from: '2026-01-07', effective_to: null },
  ],
  emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: null, foreclosure_charge_percent: null, gst_applicable: true },
  banking_penalties: { overlimit_charge: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, auto_debit_bounce_charge_inr: 500, cheque_bounce_charge_inr: 500 },
  reward_redemption_fee: redemption,
});

const statement = () => ({
  grace_period_days: 50,
  grace_period_void_on_revolving_balance: true,
  minimum_amount_due_mad: { calculation_mode: 'max', components: [
    'Total GST + current month EMI debits',
    'Higher of (100% of fees and charges + 5% of retail spends, cash advance and interest) or INR 200',
    'Previously unpaid minimum amount due, if any',
    'Overlimit utilisation amount, if any',
    'If this sum exceeds the total amount due, the minimum due equals the total amount due',
  ] },
  late_payment_slabs: [],
});

// Items every RBL card needs but the universal schema cannot hold.
const extraItems = () => [
  { key: 'late_payment_fee_rule', value: { rule: '12.5% of the outstanding amount (statement total amount due less net payments), minimum INR 5, maximum INR 1,300, plus 18% GST; levied only when the account stays past due for more than 3 days after the payment due date', source: 'MITC RBL-CC-MITC-V2-29-10-2026 section A.v (effective 17 Oct 2025); SOC RBL-CC-SOC-V2-04-06-2026', note: 'A percentage fee cannot be expressed as fixed slabs, so late_payment_slabs is empty.' } },
  { key: 'merchant_emi_processing_fee_rule', value: { rule: '1.5% of the amount or INR 150, whichever is higher, on EMI conversions done at the merchant outlet, website or app; plus 18% GST', source: 'MITC section A.iii; SOC', note: 'emi_charges has no percentage field, so merchant_instant_emi_processing_fee_inr is null. Post-purchase EMI and foreclosure charges are not stated in the MITC text read.' } },
  { key: 'finance_charge_bands', value: { rule: 'Up to 3.99% per month (47.88% a year). MITC bands by CIBIL score: above 775 = 3.35% a month, 725 to 775 = 3.85%, below 725 = 3.99%. Interest-free period up to 50 days, not available if the previous balance was not paid in full or cash was withdrawn.', source: 'MITC section A.iv and A.iii.c; SOC', note: 'The draft stores the 3.99% maximum. The band a given cardholder gets is not published per card.' } },
];

const SHARED_UNVERIFIED = [
  'Interest: the SOC and MITC give "up to 3.99% a month" and score bands (3.35%, 3.85%, 3.99%); no per-card rate is published, so the 3.99% maximum is stored.',
  'The per-card T&C carries no printed revision date. PDF creation dates are quoted in the sources list; the SOC (4 Jun 2026), MITC (29 Oct 2026) and Cardmember Agreement (27 Oct 2026) carry footer reference codes with dates.',
  'Joining fee: the MITC says "Joining Fee NIL" and charges the first-year membership fee after the first debit transaction. joining_fee_inr here repeats the SOC "Annual Fee (1st Year)" so the first-year cost is visible, the same convention as the Shoppers Stop overlay.',
];

const commonSources = (pageUrl, pageKind) => [
  { url: pageUrl, kind: pageKind, read: 'rendered page text, fetched 2026-11-07' },
  { url: SOC, kind: 'Schedule of Charges, footer RBL-CC-SOC-V2-04-06-2026 (4 Jun 2026): membership fee, finance charge, late fee, cash advance, forex markup, redemption fee, 1% category fees', read: 'pdftotext' },
  { url: MITC, kind: 'MITC cum KFS, footer RBL-CC-MITC-V2-29-10-2026 (29 Oct 2026): per-card fee and waiver, add-on fee, grace period, minimum due, late fee, interest bands', read: 'pdftotext' },
  { url: CMA, kind: 'Cardmember Agreement, footer RBL-CC-CMA-27-10-2026 (27 Oct 2026): points reversal 12.9, 24-month points expiry 12.19, primary-only redemption 12.21', read: 'pdftotext' },
  { url: LIST, kind: 'RBL current credit card list ("Showing 64 Cards"): product is on the list, with "Know more" only unless stated otherwise per card', read: 'rendered page text, fetched 2026-11-07' },
  { url: GUIDE, kind: 'RBL network availability guide: which networks each card is issued on', read: 'rendered page text, fetched 2026-11-07' },
];

const baseAddon = { max_addon_cards: null, fee_per_card_inr: 200, separate_priority_pass: 'N/A', lounge_quota_shared: 'N/A', reward_points_pooled: null, min_age_years: null };
const reversal = { mode: 'proportional_deduction', negative_balance_allowed: null, negative_balance_settlement: null };
const portalRedemption = { channel: 'RBL Rewards portal (rblrewards.rbl.bank.in) and RBL MyBank app: catalogue, vouchers, travel, shopping', redemption_type: 'partner_catalogue', inr_value_per_point: null, max_bill_percentage_payable_via_points: null, min_points_per_txn: null, cycle_points_burn_cap: null, redemption_fee_inr: 99, effective_from: null, effective_to: null };

export const cards = {
  // ───────────────────────────────────────────── BankBazaar SaveMax
  'rbl-bank-bankbazaar-savemax': {
    card_product: {
      ...GST, name: 'RBL Bank BankBazaar SaveMax Credit Card', issuer_slug: 'rbl', network: null, card_type: 'credit', application_mode: null,
      joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('rbl-bank-bankbazaar-savemax-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated in the SaveMax T&C, MITC, SOC, Cardmember Agreement or on the issuer page. The RBL Rewards portal (login required) was not read, so the rupee value of one reward point is unknown.',
      point_expiry_months: 24,
    },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle', reversal_policy: reversal },
    reward_rules: [
      ...excl('rbl-savemax', ['fuel', 'utilities', 'insurance', 'railways', 'rent', 'wallet', 'govt', 'cash', 'quasi', 'education', 'contracted', 'misc', 'bills2pay', 'emi'], { what: 'base reward points', ref: 'SaveMax T&C 3.3.1 and issuer page' },
        { cash: '2024-10-15', quasi: '2024-10-15', education: '2024-10-15', contracted: '2024-10-15', misc: '2024-10-15', bills2pay: '2024-10-15' }),
      R({ id: 'rbl-savemax-grocery-5x', cat: 'groceries', pri: 10, ppb: 5, mult: 5, cap: 'rbl-savemax-grocery-cap', cond: { per_inr_block: 100, merchant_category: 'grocery shopping (the T&C gives no MCC list for grocery)' }, reason: '5 reward points per INR 100 on all grocery shopping, up to 1,000 reward points a month (T&C 3.3).' }),
      R({ id: 'rbl-savemax-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 reward point per INR 100 on every other valid retail transaction outside the excluded categories (T&C 3.3).' }),
    ],
    cap_rules: [
      C({ id: 'rbl-savemax-grocery-cap', cat: 'groceries', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'downgrade_to_base_rate', afterPpb: 1 }),
    ],
    fees_and_surcharges: fees(),
    statement_and_late_fees: statement(),
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Joining and annual membership fee are NIL (SOC, MITC; issuer page: "comes to you FREE").', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'N/A', benefit_points: 'N/A', effective_value_inr: 'N/A', condition: 'No welcome benefit is stated in the SaveMax T&C or on the issuer page.' },
      spend_milestones: [],
    },
    addon_card_rules: { ...baseAddon },
    lifestyle_and_network_benefits: [],
    dynamic_promotions_registry: [
      P({ id: 'rbl-savemax-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow website or app', type: 'instant_discount', pct: 10, max: 100, quota: true }),
      P({ id: 'rbl-savemax-zomato', cat: 'dining', sponsor: 'Zomato', platform: 'Zomato', type: 'cashback', pct: 10, max: 100, quota: true }),
    ],
    redemption_matrix: { direct_options: [portalRedemption], partner_transfers: [] },
    additional_data: { items: [
      dualNetwork({
        sourceUrl: GUIDE,
        evidence: 'RBL network availability guide: "Bankbazaar SaveMax Credit Card" is ticked for MasterCard and Visa. The issuer page also says "available on MasterCard & VISA network."',
        variants: [
          { network: 'mastercard', network_tier: 'N/A', label: 'RBL Bank BankBazaar SaveMax (Mastercard)', source_url: GUIDE, evidence: 'Network guide row ticked for MasterCard; page: available on MasterCard & VISA network.' },
          { network: 'visa', network_tier: 'N/A', label: 'RBL Bank BankBazaar SaveMax (Visa)', source_url: GUIDE, evidence: 'Network guide row ticked for Visa; page: available on MasterCard & VISA network.' },
        ],
      }),
      ...extraItems(),
      ...prov({
        sources: [
          ...commonSources(page('rbl-bank-bankbazaar-savemax-credit-card'), 'issuer product page (benefits, excluded-MCC table, fees tab)'),
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/tnc-bankbazaar-savemax-credit-card.pdf', kind: 'SaveMax T&C (5 pages; no printed date, PDF created 18 Dec 2025): sections 3.1 to 3.3, 3.3.1', read: 'pdftotext' },
          { url: BMS, kind: 'RBL BookMyShow offers guide (16 pages; PDF created 6 Jan 2026): confirms "BankBazaar Savemax: 10% discount, up to Rs. 100, all days, once a month"', read: 'pdftotext' },
        ],
        unverified: [
          'Value of one reward point in rupees is not stated in any RBL document read, so the effective return cannot be computed. The RBL Rewards portal is login-gated and was not read.',
          'The T&C does not define "grocery" by MCC or merchant list, so the 5x rule has no MCC list.',
          'After the 1,000-point monthly grocery cap the T&C does not say whether spend falls back to the base 1 point per INR 100. Modelled as downgrade_to_base_rate at 1 point; needs review.',
          'The cap wording is "up to a maximum of 1000 rewards points on this category in one month". Modelled as total points in the grocery category per billing cycle ("one month is defined as one billing cycle").',
          'Whether new applications are accepted is not stated: RBL lists the card with "Know more" only (no Apply Now) and the page links to no application form; application_mode is left null. Partner (BankBazaar) pages were deliberately not used.',
          'Points expiry: the Cardmember Agreement 12.19 says points not redeemed within 24 months expire; the SaveMax T&C does not override it. Stored as 24.',
          'Zomato cashback is "awarded to card accounts within 10 days"; whether Zomato spend also earns reward points is not stated.',
          'Fuel surcharge is levied by the merchant bank at actual (SOC); the T&C states no waiver for this card.',
          ...SHARED_UNVERIFIED,
        ],
        notes: [
          'Offers: 10% discount on BookMyShow up to INR 100, once a calendar month, primary card only; 10% cashback on Zomato up to INR 100 a month, add-on cards included (T&C 3.1, 3.2).',
          'Base exclusions: the first group (fuel and auto, utilities, insurance, railways, rent, wallet, government, EMI) is the original list; cash, quasi-cash, education, contracted services, miscellaneous and Bills2Pay were added with effect from 15 Oct 2024 (T&C 3.3 and page). Modelled with effective_from 2024-10-15.',
          'Exclusion categories with no close PandaPay category (railways, contracted services, miscellaneous, cash) use info-only tokens so they cannot switch off a real app category.',
          'Issuer page: a free monthly credit advisory report is available at the partner site; not a card feature, not modelled.',
          'SaveMax Pro (same partner) is not in this overlay: its page says "This card can be sourced through invite only."',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── Paisabazaar Duet Plus
  'rbl-bank-paisabazaar-duet-plus': {
    card_product: {
      ...GST, name: 'RBL Bank Paisabazaar Duet Plus Credit Card', issuer_slug: 'rbl', network: 'mastercard', card_type: 'credit', application_mode: 'open',
      joining_fee_inr: 1499, annual_fee_inr: 1499, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('rbl-bank-paisabazaar-duet-plus-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: 'N/A', point_value_baseline_basis: 'Cashback card: the page says "No points. Just Cashback."', point_expiry_months: 'N/A',
    },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 'N/A', rounding_mode: 'floor', base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: 'calendar_month' },
    reward_rules: [
      ...excl('rbl-duet-plus', ['fuel', 'railways', 'utilities', 'wallet', 'rent', 'govt', 'insurance', 'cash', 'quasi', 'education', 'contracted', 'misc', 'bills2pay', 'emi'], { what: 'cashback', ref: 'T&C 3.2 and 3.7, issuer page' }),
      R({ id: 'rbl-duet-plus-dining-2-5pct', cat: 'dining', pri: 10, cb: 2.5, mult: 1, cap: 'rbl-duet-plus-travel-dining-cap', cond: { mcc_list: [5812, 5814], minimum_transaction_inr: 100 }, reason: '2.5% cashback on dining (restaurants and fast food MCCs 5812, 5814), shared INR 200 a month cap with travel (T&C 3.2, 3.7).' }),
      R({ id: 'rbl-duet-plus-travel-2-5pct', cat: 'travel', pri: 10, cb: 2.5, mult: 1, cap: 'rbl-duet-plus-travel-dining-cap', cond: { mcc_list: [4111, 4511, 4582, 3000, 3005, 3009, 3020, 3026, 3032, 3034, 3040, 3058, 3075, 3136, 3236, 3246], minimum_transaction_inr: 100 }, reason: '2.5% cashback on travel (commuter transport 4111, airlines 4511 and 3000-series airline MCCs, airports 4582), shared INR 200 a month cap with dining (T&C 3.2, 3.7).' }),
      R({ id: 'rbl-duet-plus-other-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cap: 'rbl-duet-plus-other-cap', cond: { minimum_transaction_inr: 100 }, reason: '1% cashback on other eligible retail and online spends, INR 300 a month cap; no cashback below INR 100 per transaction; decimals rounded down (T&C 3.2).' }),
    ],
    cap_rules: [
      C({ id: 'rbl-duet-plus-total-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'calendar_month', inr: 500, after: 'zero_accrual' }),
      C({ id: 'rbl-duet-plus-travel-dining-cap', cat: 'dining', metric: 'total_reward_points', period: 'calendar_month', inr: 200, after: 'downgrade_to_base_rate', parent: 'rbl-duet-plus-total-cap' }),
      C({ id: 'rbl-duet-plus-other-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'calendar_month', inr: 300, after: 'zero_accrual', parent: 'rbl-duet-plus-total-cap' }),
    ],
    fees_and_surcharges: fees({
      fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 500, max_txn_inr: 4000, monthly_waiver_cap_inr: 100 },
      redemption: { fee_inr: 0, gst_applicable: null, exempted_channels: [], notes: 'Cashback card with no points to redeem (page: "No points. Just Cashback."); cashback is credited to the card account. The MITC INR 99 + GST redemption fee applies to reward points, so it does not apply here.' },
    }),
    statement_and_late_fees: statement(),
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 400000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee of INR 1,499 (plus GST) for the next membership year is waived when eligible retail spend in the membership year is INR 4,00,000 or more (T&C 3.6, page, MITC). Fuel and auto, utilities, insurance, quasi-cash, railways, rent, education, wallet, government, contracted services, cash, miscellaneous, Bills2Pay, EMI conversions, fees, charges and GST do not count.', excluded_category_ids: ['fuel', 'bills', 'insurance', 'cash_withdrawal', 'excluded_spend', 'rent', 'education', 'wallet', 'government', 'emi'], excluded_mcc_list: excludedMccs(['fuel', 'utilities', 'insurance', 'quasi', 'railways', 'rent', 'education', 'wallet', 'govt', 'contracted', 'cash', 'misc']), waives_fee_inr: 1499 },
      welcome_and_renewal_gift: { trigger: 'first_transaction_within_30_days_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 250, condition: 'One-time INR 250 cashback for a card purchase within 30 days of issuance and payment of the annual membership fee by the payment due date; credited within 2 weeks of purchase settlement; debited again if net spend within the 30 days falls to nil; paid accounts only (T&C 3.1).' },
      spend_milestones: [],
    },
    addon_card_rules: { ...baseAddon },
    lifestyle_and_network_benefits: [
      B({ id: 'rbl-duet-plus-bms', cat: 'movie', sponsor: 'BookMyShow', label: 'Weekend movie ticket offer: INR 200 discount or one free ticket, whichever is lower, once a month', cond: { days: 'Saturday and Sunday shows', primary_card_only: true, pay_in_full_for_at_least_one_ticket: true, platform: 'BookMyShow app or website' }, qty: 1, per: 'calendar_month' }),
    ],
    dynamic_promotions_registry: [],
    redemption_matrix: { direct_options: [], partner_transfers: [] },
    additional_data: { items: [
      ...extraItems(),
      ...prov({
        sources: [
          ...commonSources(page('rbl-bank-paisabazaar-duet-plus-credit-card'), 'issuer product page (cashback, welcome, BookMyShow, fuel surcharge, fees tab, excluded-MCC table)'),
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/paisabazaar-duet-plus-cc-tnc.pdf', kind: 'Duet Plus T&C (6 pages; no printed date, PDF created 18 Dec 2025): 3.1 welcome, 3.2 cashback, 3.3 BookMyShow, 3.5 fuel, 3.6 fee waiver, 3.7 MCC table', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/credit-line-paisabazaar-role-responsibilities.pdf', kind: 'Co-brand partner roles document (PDF created 15 Aug 2025): Paisabazaar markets and solicits applications; KYC is done by RBL', read: 'pdftotext' },
          { url: BMS, kind: 'RBL BookMyShow offers guide (PDF created 6 Jan 2026): "Paisabazaar Duet Plus: buy 1 get 1, up to Rs. 200, Saturday and Sunday, once a month"', read: 'pdftotext' },
        ],
        unverified: [
          'Annual fee waiver: the SOC (4 Jun 2026) shows INR 1,499 for both years with no waiver marker, while the issuer page, T&C 3.6 and the MITC (29 Oct 2026) all state the waiver on INR 4 lakh spend in the previous membership year. The three newer sources are used.',
          'The "Travel and Dining" MCC list (T&C 3.7) holds only commuter transport 4111, airlines (4511 and the 3000-series), airports 4582 and restaurants and fast food (5812, 5814). Hotels and travel agencies are not in it although the page says "all travel and dining transactions".',
          'Contracted services appear in the excluded-MCC table on the page and in T&C 3.7 but not in the category list of T&C 3.2; treated as excluded.',
          'The INR 500 combined monthly maximum is stated on the page only; the T&C states the two sub-caps (INR 200 and INR 300). Both are modelled, with the INR 500 total as parent.',
          'Cap period is the calendar month (page and T&C), while the fee tables use the billing cycle; modelled as calendar_month.',
          'Whether new applications are open: RBL lists the card with "Know more" only, but the partner roles document says Paisabazaar solicits applications. application_mode set to open on that basis; confirm.',
          'The Xpress Cash instant-loan facility has its own terms (https://webassets.rbl.bank.in/pdfs/Emailer/terms-xpress-cash.pdf) which were not read; not modelled.',
          ...SHARED_UNVERIFIED,
        ],
        notes: [
          'Cashback card: no points. Network is Mastercard only (RBL network guide and issuer page).',
          'Cashback is credited within 2 weeks of settlement; the minimum eligible transaction is INR 100; amounts are rounded down (T&C 3.2).',
          'Fuel surcharge reversal: 1% up to INR 100 a month on fuel purchases between INR 500 and INR 4,000 (excluding the surcharge); purchases of INR 499 or less pay a INR 10 surcharge, purchases of INR 4,001 or more pay 1% with no reversal; GST is not reversed (T&C 3.5).',
          'Weekend BookMyShow offer: INR 200 off or one free ticket (whichever is lower) on Saturday and Sunday shows, once a month, primary card only; the free ticket requires paying in full for at least one other ticket (T&C 3.3).',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── Movies & More
  'rbl-bank-movies-and-more': {
    card_product: {
      ...GST, name: 'RBL Bank Movies & More Credit Card', issuer_slug: 'rbl', network: 'mastercard', card_type: 'credit', application_mode: null,
      joining_fee_inr: 1000, annual_fee_inr: 1000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('rbl-bank-movies-and-more-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated in the Movies & More T&C, MITC, SOC, Cardmember Agreement or on the issuer page. The RBL Rewards portal (login required) was not read, so the rupee value of one reward point is unknown.',
      point_expiry_months: 24,
    },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle', reversal_policy: reversal },
    reward_rules: [
      ...excl('rbl-mm', ['fuel', 'railways', 'utilities', 'wallet', 'rent', 'govt', 'insurance', 'cash', 'quasi', 'education', 'contracted', 'misc', 'bills2pay', 'emi'], { what: 'base or accelerated reward points', ref: 'T&C 3.3 vi and 3.8, issuer page' }),
      R({ id: 'rbl-mm-dining-wednesday-20', cat: 'dining', pri: 10, ppb: 20, mult: 20, cap: 'rbl-mm-dining-cap', cond: { per_inr_block: 100, weekday: 'Wednesday', merchant_category: 'dining outlets identified by network MCC' }, reason: '20 reward points per INR 100 on dining on Wednesdays only; up to 1,000 points a billing month, then 1 point per INR 100 (T&C 3.3).' }),
      R({ id: 'rbl-mm-bookmyshow-10', cat: 'entertainment', pri: 10, ppb: 10, mult: 10, cap: 'rbl-mm-select-merchants-cap', cond: { per_inr_block: 100, merchants: ['BookMyShow website and mobile app'] }, reason: '10 reward points per INR 100 on BookMyShow; shares the 1,000-point monthly cap with Pizza Hut and KFC, then 1 point per INR 100 (T&C 3.3).' }),
      R({ id: 'rbl-mm-pizzahut-kfc-10', cat: 'dining', pri: 10, ppb: 10, mult: 10, cap: 'rbl-mm-select-merchants-cap', cond: { per_inr_block: 100, merchants: ['Pizza Hut outlets', 'KFC outlets'], identification: 'by the dining MCC allotted by the network; RBL gives no points if the outlet is registered under another MCC' }, reason: '10 reward points per INR 100 at Pizza Hut and KFC; shares the 1,000-point monthly cap with BookMyShow (T&C 3.3).' }),
      R({ id: 'rbl-mm-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 reward point per INR 100 on every other valid retail purchase outside the excluded categories (T&C 3.3 v).' }),
    ],
    cap_rules: [
      C({ id: 'rbl-mm-dining-cap', cat: 'dining', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'downgrade_to_base_rate', afterPpb: 1 }),
      C({ id: 'rbl-mm-select-merchants-cap', cat: 'entertainment', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'downgrade_to_base_rate', afterPpb: 1 }),
    ],
    fees_and_surcharges: fees({ fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 500, max_txn_inr: 4000, monthly_waiver_cap_inr: 100 } }),
    statement_and_late_fees: statement(),
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 150000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee of INR 1,000 (plus GST) is waived for the next year when eligible spend in the preceding anniversary year is INR 1,50,000 or more (T&C 3.6, page, MITC, SOC). Fuel and auto, railways, utilities, wallet, rent, government, insurance, cash, quasi-cash, education, miscellaneous, Bills2Pay and EMI conversions do not count.', excluded_category_ids: ['fuel', 'excluded_spend', 'bills', 'wallet', 'rent', 'government', 'insurance', 'cash_withdrawal', 'education', 'emi'], excluded_mcc_list: excludedMccs(['fuel', 'railways', 'utilities', 'wallet', 'rent', 'govt', 'insurance', 'cash', 'quasi', 'education', 'misc']), waives_fee_inr: 1000 },
      welcome_and_renewal_gift: { trigger: 'first_transaction_within_30_days_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 1000, condition: 'Four BookMyShow movie tickets worth INR 1,000 (INR 1,000 discount or 4 free tickets, whichever is lower): two transactions of up to INR 500 each, minimum two tickets per transaction. Needs a valid retail transaction within 30 days of issuance and payment of the first-year fee by the first payment due date; valid 60 days after the first statement (T&C 3.1, page).' },
      spend_milestones: [
        { id: 'rbl-mm-milestone-2l', label: '5,000 bonus reward points on valid purchases of INR 2 lakh or more in the billing year', threshold_spend_inr: 200000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        { id: 'rbl-mm-milestone-3-5l', label: 'Additional 10,000 bonus reward points on valid purchases of INR 3.5 lakh or more in the billing year (15,000 in total)', threshold_spend_inr: 350000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
      ],
    },
    addon_card_rules: { ...baseAddon },
    lifestyle_and_network_benefits: [
      B({ id: 'rbl-mm-monthly-1000', cat: 'movie', sponsor: 'BookMyShow', label: 'Monthly movie offer, lower tier: INR 250 off (or one ticket, whichever is lower) on INR 10,000 to under 15,000 spend in the billing cycle; one monthly offer per cycle, the higher tier replaces this one', cond: { monthly_spend_ge_inr: 10000, monthly_spend_lt_inr: 15000, single_transaction: true }, qty: 1, per: 'calendar_month' }),
      B({ id: 'rbl-mm-monthly-1500', cat: 'movie', sponsor: 'BookMyShow', label: 'Monthly movie offer, higher tier: INR 500 off (or two tickets, whichever is lower) on INR 15,000 or more spend in the billing cycle, single transaction', cond: { monthly_spend_ge_inr: 15000, single_transaction: true, max_tickets: 2 }, qty: 1, per: 'calendar_month' }),
    ],
    dynamic_promotions_registry: [
      P({ id: 'rbl-mm-bms-10pct', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow website or app', type: 'instant_discount', pct: 10, max: 100, quota: true }),
    ],
    redemption_matrix: { direct_options: [portalRedemption], partner_transfers: [] },
    additional_data: { items: [
      ...extraItems(),
      ...prov({
        sources: [
          ...commonSources(page('rbl-bank-movies-and-more-credit-card'), 'issuer product page (welcome, monthly, milestones, rewards, fuel, fees)'),
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/terms-conditions-movies-more.pdf', kind: 'Movies & More T&C (7 pages; no printed date, PDF created 15 May 2026): 3.1 welcome, 3.2 monthly, 3.3 points, 3.4 milestones, 3.5 fuel, 3.6 fee waiver, 3.7 BookMyShow discount, 3.8 MCC table', read: 'pdftotext' },
          { url: BMS, kind: 'RBL BookMyShow offers guide (PDF created 6 Jan 2026): monthly INR 250 / INR 500 tiers and "10% discount, up to Rs. 100, 15 times a year"', read: 'pdftotext' },
        ],
        unverified: [
          'Value of one reward point in rupees is not stated in any RBL document read, so the effective return cannot be computed. The RBL Rewards portal is login-gated and was not read.',
          'Cap wording is "a maximum of 1000 accelerated reward points per month (1000 on dining and 1000 on the select merchants)". Modelled as total points under each accelerator per billing cycle; it could instead mean bonus points above the base rate. After the cap the T&C says spend earns the base 1 point per INR 100 (T&C 3.3 iii), which is modelled.',
          'T&C 3.2 says the monthly offer applies on booking a minimum of 2 tickets, yet the INR 250 tier is for one ticket (page and BookMyShow guide). The page and guide figures are modelled.',
          'Contracted services appear in the T&C 3.8 table and the page footnote but not in the category list of T&C 3.3 vi; treated as excluded.',
          'Whether new applications are accepted: RBL lists the card with "Know more" only (no Apply Now) and the page has no application link. application_mode is left null. No discontinuation notice was found on the page (unlike Popcorn).',
          'T&C 4.4 refers to "the Play Credit Card" and 3.1 iv names the shared BookMyShow offer "Popcorn, Fun Plus, Movies & More, Blockbuster"; these look like copy-paste in the T&C and do not change the terms read.',
          'Milestone year is "one year from the date of card issuance" (T&C 3.4 v); spend of add-on cards counts (3.4 vii). Stored as card_anniversary_year.',
          'Points expiry: the Cardmember Agreement 12.19 says points not redeemed within 24 months expire; the product T&C does not override it. Stored as 24.',
          ...SHARED_UNVERIFIED,
        ],
        notes: [
          'Network is Mastercard only (RBL network guide and issuer page).',
          'Bonus points are credited within 30 days of the transaction or of crossing the milestone threshold (T&C 3.3 vii, 3.4 vi).',
          'Fuel surcharge waiver: 1% up to INR 100 a month on fuel purchases between INR 500 and INR 4,000; INR 499 or less pays a INR 10 surcharge, INR 4,001 or more pays 1% with no waiver; GST is not reversed (T&C 3.5).',
          'The 10% BookMyShow discount (up to INR 100 per booking, 15 times in a calendar year, primary card only) is a separate benefit from the monthly tier offers (T&C 3.7).',
          'If the customer holds another RBL card, the credit limit of the new card merges with the existing limit (T&C 4.10); not modelled.',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── IRCTC RBL Bank
  'rbl-bank-irctc': {
    card_product: {
      ...GST, name: 'RBL Bank IRCTC Credit Card', issuer_slug: 'rbl', network: null, card_type: 'credit', application_mode: 'open',
      joining_fee_inr: 500, annual_fee_inr: 500, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('irctc-rbl-bank-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: 1, point_value_baseline_basis: 'T&C 3.2 e and FAQ: 1 reward point = INR 1 when redeemed on the IRCTC website or app for train tickets (Pay by Points, minimum INR 200). The value on the RBL Rewards portal is not stated, so this baseline holds only for IRCTC train bookings. is_upi_linkable is true for the RuPay variant only.',
      point_expiry_months: 24,
    },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Individuals aged 21 to 70, subject to the Bank\'s internal policy (IRCTC FAQ).', rules: [
      { parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] },
      { parameter: 'age_years', operator: '<=', threshold_value: 70, allowed_values: [] },
    ], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle', reversal_policy: reversal },
    reward_rules: [
      ...excl('rbl-irctc', ['fuel', 'utilities', 'insurance', 'quasi', 'rent', 'education', 'wallet', 'govt', 'contracted', 'cash', 'misc', 'bills2pay', 'emi'], { what: 'reward points or quarterly milestone credit', ref: 'T&C 3.2 and 3.9' }),
      R({ id: 'rbl-irctc-excl-upi-small', cat: 'upi', pri: 2, type: 'exclusion', rail: 'upi_qr', mult: 0, cond: { transaction_amount_lt_inr: 2000, rail: 'upi', variant: 'RuPay', merchant: 'small merchants with turnover of INR 20 lakh or less in the previous financial year', mode: 'offline' }, reason: 'Offline UPI transactions under INR 2,000 at small merchants on the RBL RuPay credit card earn no reward points, voucher or milestone benefit (T&C 3.7).' }),
      R({ id: 'rbl-irctc-train-5', cat: 'travel', pri: 10, ppb: 5, mult: 5, channel: 'irctc_website_app', cap: 'rbl-irctc-train-cap', cond: { per_inr_block: 200, merchant: 'IRCTC website or IRCTC mobile app', booking: 'train tickets, all classes' }, reason: '5 reward points per INR 200 on train tickets of all classes booked on the IRCTC website or app; up to 1,000 points a billing cycle (T&C 3.2 b).' }),
      R({ id: 'rbl-irctc-fastag-3', cat: 'travel', pri: 11, ppb: 3, mult: 3, channel: 'rbl_digital_ncmc_uts', cap: 'rbl-irctc-fastag-cap', cond: { per_inr_block: 200, spend: 'FASTag recharge from RBL Bank digital channels, NCMC reload, UTS app (local train tickets)' }, reason: '3 reward points per INR 200 on FASTag recharge via RBL digital channels, NCMC reload and the UTS app; up to 1,000 points a billing cycle (T&C 3.2 c, FAQ).' }),
      R({ id: 'rbl-irctc-flight-hotel-2', cat: 'travel', pri: 12, ppb: 2, mult: 2, channel: 'irctc_website_app', cap: 'rbl-irctc-flight-hotel-cap', cond: { per_inr_block: 200, merchant: 'IRCTC website or IRCTC mobile app', booking: 'flights, hotels and tourism' }, reason: '2 reward points per INR 200 on flights, hotels and tourism booked on the IRCTC website or app; up to 1,000 points a billing cycle (T&C 3.2 d, FAQ).' }),
      R({ id: 'rbl-irctc-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 200 }, reason: '1 reward point per INR 200 on all other spends outside the excluded categories, fees, charges and GST (T&C 3.2 a).' }),
    ],
    cap_rules: [
      C({ id: 'rbl-irctc-train-cap', cat: 'travel', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'zero_accrual' }),
      C({ id: 'rbl-irctc-fastag-cap', cat: 'travel', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'zero_accrual' }),
      C({ id: 'rbl-irctc-flight-hotel-cap', cat: 'travel', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'zero_accrual' }),
    ],
    fees_and_surcharges: fees({
      redemption: { fee_inr: 0, gst_applicable: true, exempted_channels: [], notes: 'MITC (29 Oct 2026) lists the IRCTC Credit Card among cards for which the INR 99 + GST redemption fee is not applicable; the SOC (4 Jun 2026) list does not include it. The MITC bracket layout is ambiguous.' },
    }),
    statement_and_late_fees: statement(),
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'INR 500 + GST in the first year and INR 500 + GST renewal from the second year; no spend waiver is stated (SOC, MITC, FAQ).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'first_transaction_within_30_days_and_fee_paid', benefit_points: 500, effective_value_inr: null, condition: '500 reward points for an eligible retail transaction above INR 500 within 30 days of issuance and payment of the membership fee by the payment due date; credited within 60 days of issuance; once per cardmember (T&C 3.1). The FAQ says "INR 500 and above".' },
      spend_milestones: [
        { id: 'rbl-irctc-quarterly-75k', label: '500 bonus reward points on eligible spend of INR 75,000 in a calendar quarter', threshold_spend_inr: 75000, reward_value_inr: null, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null },
      ],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 200, separate_priority_pass: 'N/A', lounge_quota_shared: false, reward_points_pooled: true, min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: 'rbl-irctc-railway-lounge', cat: 'lounge', sponsor: 'IRCTC / RBL Bank (DreamFolks)', label: 'Complimentary IRCTC Executive Lounge access at select railway stations: 8 visits a year, at most 2 per calendar quarter, primary cardholder only', cond: { annual_visits: 8, max_per_quarter: 2, primary_cardholder_only: true, valid_train_ticket_required: true, validation_charge_inr: { rupay: 2, mastercard: 25, note: 'debited and later refunded' }, stay_hours: 2 }, qty: 2, per: 'quarter' }),
      B({ id: 'rbl-irctc-1pct-surcharge-waiver', cat: 'other', sponsor: 'IRCTC / RBL Bank', label: '1% transaction charge on IRCTC train ticket booking reversed: bookings up to INR 5,000, at most INR 200 a month', cond: { max_booking_inr: 5000, max_waiver_inr_per_month: 200, channel: 'irctc.co.in or IRCTC app', reversed_on_cancellation_refund: true } }),
    ],
    insurance_and_protection: [
      { cover_type: 'other', coverage_inr: 5000, coverage_usd: 'N/A', claim_condition: 'Complimentary train cancellation protection up to INR 5,000, only where the Indian Railways cancels the train within 24 hours of the scheduled departure; AC 1A/2A/3A and chair car bookings on IRCTC booked with the primary card in the primary cardholder\'s name; alternate travel within 48 hours paid on the same card; one claim per 6 months; claim within 7 days of the alternate journey (train cancellation protection document, June 2026).', effective_from: null, effective_to: null },
    ],
    dynamic_promotions_registry: [],
    redemption_matrix: {
      direct_options: [
        { channel: 'IRCTC website or app, Pay by Points for train tickets', redemption_type: 'other', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 200, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      ],
      partner_transfers: [],
    },
    additional_data: { items: [
      dualNetwork({
        sourceUrl: GUIDE,
        evidence: 'RBL network availability guide: "IRCTC RBL Bank Credit Card" is ticked for MasterCard and RuPay (not Visa). T&C 3.6 d sets lounge validation charges for both RuPay (INR 2) and MasterCard (INR 25); the page lists NCMC and UPI features for the RuPay variant only.',
        variants: [
          { network: 'mastercard', network_tier: 'N/A', label: 'IRCTC RBL Bank Credit Card (Mastercard)', source_url: GUIDE, evidence: 'Network guide row ticked for MasterCard; T&C 3.6 d INR 25 lounge validation on MasterCard.' },
          { network: 'rupay', network_tier: 'N/A', label: 'IRCTC RBL Bank Credit Card (RuPay)', source_url: GUIDE, evidence: 'Network guide row ticked for RuPay; page: "For Rupay Variant only: Tap & Transit (NCMC), Scan and Pay (UPI)".' },
        ],
      }),
      ...extraItems(),
      ...prov({
        sources: [
          ...commonSources(page('irctc-rbl-bank-credit-card'), 'issuer product page (welcome, rewards, lounge, cancellation protection, UPI and NCMC, fee)'),
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/tnc-irctc-rbl-bank-rupay-credit-card.pdf', kind: 'IRCTC RBL Bank Credit Card T&C (8 pages; no printed date, PDF created 18 May 2026): 3.1 welcome, 3.2 rewards, 3.3 milestone, 3.4 cancellation shield, 3.5 transaction-charge waiver, 3.6 lounge, 3.7 UPI, 3.9 exclusions', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/irctc-rbl-bank-credit-card-faqs.pdf', kind: 'IRCTC card FAQs (7 pages; PDF created 10 Jun 2026): fees, eligibility 21 to 70, points valid 2 years, 1 point = INR 1 on train tickets, lounge, due date', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/irctc-cc-complimentary-railway-lounge-access.pdf', kind: 'IRCTC Executive Lounge programme Q&A (PDF created 10 Jun 2026): 8 visits a year, 2 per quarter, INR 2 / INR 25 validation', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/irctc-cc-train-cancellation-protection.pdf', kind: 'Train cancellation protection terms (PDF created 11 Jun 2026)', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/irctc-executive-lounge-list.pdf', kind: 'IRCTC Executive Lounge list (PDF created 22 Jan 2026): 10 outlets in Asansol, Chennai, Delhi, Jaipur, Kolkata, Madurai, Varanasi, Bhopal', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/redemption-process-via-pay-by-points-irctc-cc.pdf', kind: 'Pay by Points redemption guide (PDF created 7 Nov 2024): partial payment, manual redeem amount above INR 200', read: 'pdftotext' },
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/irctc-rbl-bank-credit-card-role-responsibilities.pdf', kind: 'Co-brand partner roles document (PDF created 11 Jun 2026): IRCTC and RBL jointly market and distribute the card', read: 'pdftotext' },
        ],
        unverified: [
          'The INR 1 per point value applies to IRCTC train ticket redemption only (FAQ: "for Train ticket bookings only"). The value on the RBL Rewards portal is not stated, so effective_base_return_percent is null.',
          'The 1,000-point monthly cap is repeated in T&C 3.2 b, c and d, so it is modelled as one cap per accelerated feature; the FAQ speaks of "the monthly cycle capping of 1,000 Reward Points" and could mean a single shared cap. After the cap the FAQ says no points are awarded (zero_accrual).',
          'Which variant a new applicant receives (Mastercard or RuPay) is not stated; network is left null with both variants in verified_network_research.',
          'Redemption fee: the MITC (29 Oct 2026) appears to exempt the IRCTC card from the INR 99 + GST fee, the SOC (4 Jun 2026) does not list it, and the MITC bracket is mis-nested. Stored as 0 with this caveat.',
          'Lounge entitlement: T&C 3.6 says 2 per calendar quarter; the page, FAQ and programme Q&A say 8 a year with at most 2 per quarter. Both are consistent with 2 per quarter, stored as quota 2 per quarter with the annual 8 in the conditions.',
          'Train cancellation protection: T&C 3.4 (May 2026) allows up to 3 claim attempts in 6 months and excludes unreserved and non-AC classes; the June 2026 protection document says AC 1A/2A/3A and chair car only, and does not mention attempts. The newer document is modelled. The cover is described as ex-gratia, not insurance.',
          'Welcome benefit: T&C says "above INR 500", the FAQ and page say "INR 500 and above". Not resolved.',
          'The IRCTC FAQ says the payment due date is 20 days after the statement date; the MITC says the interest-free period is up to 50 days. Both stored as stated (grace period 50 is the MITC maximum).',
          'Railway ticket surcharge: SOC says IRCTC service charges plus payment-gateway charges (up to 1.8% of the ticket) are levied by IRCTC and the merchant bank; the card reverses 1% on bookings up to INR 5,000, capped at INR 200 a month. Fuel surcharge is levied by the merchant bank at actual and the T&C states no waiver.',
          'Points expiry stored as 24 months: FAQ "valid for a period of 2 years from the date of earning unless otherwise communicated" and Cardmember Agreement 12.19.',
          ...SHARED_UNVERIFIED,
        ],
        notes: [
          'Railways (MCC 66, 4011, 4112) is not in the IRCTC card exclusion table, unlike the other RBL cards, because IRCTC train bookings are the accelerated category.',
          'Add-on cards link to the primary cardholder\'s IRCTC loyalty number and all points accrue to the primary account, redeemable by the primary cardholder only (page note, CMA 12.21). Lounge access is primary only.',
          'RuPay variant only: NCMC tap-and-transit and UPI scan-and-pay (credit card on UPI). The page states no points on offline UPI transactions under INR 2,000 at small merchants (T&C 3.7).',
          'Lounge visit includes 2 hours, one buffet meal, tea and coffee, Wi-Fi and a changing room; guests are chargeable. The lounge list holds 10 outlets in 8 cities (list created 22 Jan 2026).',
        ],
      }),
    ] },
  },
};
