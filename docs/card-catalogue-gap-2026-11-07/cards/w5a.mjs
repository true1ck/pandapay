// Wave 5, agent W5A (15 Nov 2026): ICICI Bank and HDFC Bank cards missing from the catalogue.
// Sources, all read 2026-11-15 (plain HTTP fetch of the issuer pages worked; PDFs read with pdftotext):
//  MITC  = ICICI Most Important Terms and Conditions for credit cards, "Last updated on Nov 6th, 2026", 54 pages
//          https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/mitc_cc.pdf
//          (the rupee sign is mapped to a private glyph in this PDF; digits were decoded from the glyph run and cross-checked against the card pages)
//  BMITC = ICICI Bank Business Cards MITC, dated Oct 14, 2026, 17 pages
//          https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/mitc-terms-and-conditions-business.pdf
//  Card pages: ICICI product pages named in each entry.
//  HDFC Paytm Select Business: issuer product page (fees, cashback, FAQ) read 2026-11-15; its MITC link (mitcs.pdf) is the general HDFC KFS cum MITC and has no row for this card.
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const FETCHED = { fetched_on: '2026-11-15' };
const MITC = 'https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/mitc_cc.pdf';
const BMITC = 'https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/mitc-terms-and-conditions-business.pdf';
const mitcSrc = { url: MITC, kind: 'ICICI credit card MITC, last updated 6 Nov 2026: fee table, forex, DCC, late fee, interest, reward exclusions and caps, lounge rules', read: 'pdftotext' };
const bmitcSrc = { url: BMITC, kind: 'ICICI Business Cards MITC dated 14 Oct 2026: fee table, fuel waiver table, interest, late fee, forex', read: 'pdftotext' };

const FUEL = [1361, 3851, 5172, 5541, 5542, 5983, 9752, 5555];
const RENT = [7014, 7407, 5271, 6513];
const CASH = [6011, 6050, 6051, 6529, 6530, 6538, 6666, 7777, 9999, 6010, 3882, 6541, 6542];
const UTILITY = [4899, 4900, 4901, 3887, 4897, 5416, 5417, 4812, 4813, 4814, 4815, 4821, 4896, 4902, 3886];
const INSURANCE = [5960, 6300, 6381, 6399];
const GROCERY = [3333, 5411, 5412, 5441, 9751, 5311, 5331, 5499];
const TRANSPORT = [4111, 4112, 4784, 4131];

// MITC late-payment table (w.e.f. 15 Nov 2024), personal cards.
const LATE = [
  { min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }, { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 },
  { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 500 }, { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 600 },
  { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 900 },
  { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
];

const exclusions = (p, { fuel = true } = {}) => [
  X(`${p}-excl-rent`, 'rent', RENT, 'No reward points on rent payments (MITC, Reward Points Capping: "No reward points ... Cash and Rent categories").'),
  X(`${p}-excl-cash`, 'excluded_spend', CASH, 'No reward points on cash transactions (MITC).'),
  X(`${p}-excl-wallet`, 'wallet', [6540], 'No reward points on e-wallet reloads (MITC).'),
  ...(fuel ? [X(`${p}-excl-fuel`, 'fuel', FUEL, 'No reward points on fuel transactions (MITC).')] : []),
];

// Common personal-card fee block from the MITC (6 Nov 2026).
const iciciFees = (o) => ({
  apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
  forex_markup: { markup_percent: o.forex ?? 3.5, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: o.dcc ?? 3.5, gst_applicable: true, trigger_condition: 'MITC: 3.5% DCC fee w.e.f. 15 Jan 2026 on transactions in Indian currency at international locations or at India-located merchants registered abroad' },
  fuel_surcharge: o.fuel,
  cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
  category_surcharges: [
    { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on rent payment transactions (MCC 6513) (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'fuel', mcc_list: FUEL, fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on fuel transactions above ₹10,000 (MITC, w.e.f. 15 Nov 2024)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
    { category_id: 'utility', mcc_list: [4899, 4900, 4901, 4814, 4821], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on utility payments above ₹50,000 (MITC, w.e.f. 15 Nov 2024)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
    { category_id: 'education', mcc_list: [8211, 8220, 8241, 8244, 8249, 8299, 8493, 8494, 7911], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on education payments made through third-party apps (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'wallet', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on wallet loads of ₹5,000 or more (MITC, w.e.f. 15 Jan 2026)', threshold_spend_inr: 5000, effective_from: null, effective_to: null },
  ],
  emi_charges: { merchant_instant_emi_processing_fee_inr: 299, post_purchase_emi_processing_fee_inr: null, foreclosure_charge_percent: 3, gst_applicable: true },
  banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 550, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
  reward_redemption_fee: { fee_inr: 99, gst_applicable: true },
});

const noAddon = { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null };

const personalBase = (o) => ({
  card_product: { ...GST, name: o.name, issuer_slug: 'icici-bank', card_type: 'credit', network: null, network_tier: 'N/A', application_mode: 'open', joining_fee_inr: o.joining, annual_fee_inr: o.annual, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: o.page, status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: o.valueBasis, point_expiry_months: null },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.eligibility, rules: [], required_documents: [] },
  accrual_engine: { base_block_inr: o.block, rounding_mode: null, base_points_per_block: o.basePts, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: o.capBasis ?? null },
  fees_and_surcharges: iciciFees(o),
  statement_and_late_fees: { late_payment_slabs: LATE },
  addon_card_rules: noAddon,
});

const adaniFuel = { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 4000, monthly_waiver_cap_inr: null };

export const cards = {
  // ───────────────────────────────────────────── Adani One Signature
  'icici-adani-one-signature': {
    ...personalBase({
      name: 'Adani One ICICI Bank Signature Credit Card', joining: 5000, annual: 5000, block: 100, basePts: 1.5, fuel: adaniFuel,
      page: 'https://www.icici.bank.in/personal-banking/cards/credit-card/adani-icici-credit-card/signature-credit-card',
      valueBasis: 'Not stated: the page says points are credited to the Adani OneApp as "Adani OneApp Rewards" and gives no rupee value per point.',
      eligibility: 'Page: Indian citizen over 21; salaried with monthly income of ₹75,000 or self-employed with annual income of ₹9,00,000.',
    }),
    reward_rules: [
      ...exclusions('adani-sig'),
      R({ id: 'adani-sig-international-2', cat: 'international_spend', pri: 10, ppb: 2, mult: 2 / 1.5, cond: { transaction_type: 'international', per_inr_block: 100 }, reason: '2 points per ₹100 on international spend (issuer page).' }),
      R({ id: 'adani-sig-base-1-5', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1.5, mult: 1, cond: { per_inr_block: 100, transaction_type: 'domestic' }, reason: '1.5 points per ₹100 on domestic spend (issuer page).' }),
    ],
    cap_rules: [],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 600000, period: 'card_anniversary_year', evaluation_condition: 'Spend over ₹6 lakh and the annual fee is waived for the next year. MITC footnote: anniversary year, EMI, rent, government and education spends and fees do not count. The page FAQ says "calendar year".', excluded_category_ids: ['rent', 'government', 'education', 'emi'], excluded_mcc_list: [], waives_fee_inr: 5000 },
      welcome_and_renewal_gift: { trigger: 'spend_within_60_days_of_activation_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 5000, condition: 'Flight voucher worth ₹5,000 on ₹25,000 of spend within 60 days of card activation; only if the joining or annual fee is paid; fee-free issues are ineligible; fees, interest and bank levies do not count (page FAQ).' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'adani-sig-lounge-intl', cat: 'lounge', program: 'priority_pass', sponsor: 'ICICI Bank', label: 'International airport lounge access (Priority Pass), primary cardholder only', qty: 2, per: 'annual' }),
      B({ id: 'adani-sig-lounge-dom', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Domestic airport lounge access, primary cardholder only, on ₹75,000 spent in the preceding spends quarter (MITC: criteria from 1 Jul 2026)', cond: { preceding_quarter_spend_inr: 75000 }, qty: 4, per: 'quarter' }),
      B({ id: 'adani-sig-lounge-upgrade', cat: 'lounge', sponsor: 'Adani One', label: 'Premium lounge upgrades', qty: 16, per: 'annual' }),
      B({ id: 'adani-sig-pranaam', cat: 'other', sponsor: 'Adani One', label: 'Pranaam service at Adani-managed airports: one on activation, a second on ₹3 lakh spend', qty: 2, per: 'annual' }),
      B({ id: 'adani-sig-valet', cat: 'other', sponsor: 'Adani One', label: 'Valet parking', qty: 4, per: 'annual' }),
      B({ id: 'adani-sig-parking', cat: 'other', sponsor: 'Adani One', label: 'Premium car parking on card activation', qty: 4, per: 'annual' }),
      B({ id: 'adani-sig-porter', cat: 'other', sponsor: 'Adani One', label: 'Porter services: 2 per ₹1 lakh spent, up to 8 a year', cond: { per_spend_inr: 100000, per_block_quantity: 2 }, qty: 8, per: 'annual' }),
    ],
    dynamic_promotions_registry: [P({ id: 'adani-sig-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'buy_one_get_one', max: 500, quota: true, permanent: true, from: '2026-04-01' })],
    additional_data: { items: prov({
      extra: FETCHED,
      sources: [
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/adani-icici-credit-card/signature-credit-card', kind: 'issuer card page: fees, earn rates, benefits, FAQ (page text, no revision date)', read: 'plain HTTP fetch, page text' },
        mitcSrc,
      ],
      unverified: [
        'Network NOT STATED: neither the card page nor the MITC names a network for this card, and no card-art file naming one was found in the page source. Ask ICICI or read an issued card.',
        '"7 points per ₹100 on Adani One Ecosystem spend" is not encoded as a rule: the page does not define which merchants or MCCs make up the Adani One ecosystem ("Adani One ecosystem*, including Adani-managed airports, Trainman, gas, electricity and more" is the only wording). A person should obtain the merchant list.',
        'Value of one Adani OneApp Reward point in rupees: not stated on the page, FAQ or MITC.',
        'Reward caps: the MITC per-statement-cycle cap tables (utility, insurance, grocery, transport) do not name the Adani One cards, so no cap is stated for them either way.',
        'Annual fee waiver period: page FAQ says "calendar year", the MITC footnote says anniversary year. MITC used (newer, 6 Nov 2026). Fee waiver spend ₹6,00,000 is in both.',
        'Fuel waiver: page says 1% on all fuel at any outlet "up to ₹4,000"; whether that is the maximum transaction size or a cap is not said, and no monthly cap is stated. max_txn_inr 4,000 is the most literal reading.',
        'Forex 3.5% is the MITC default; the Adani cards are not among its listed exceptions. The page also says 3.5%.',
        'BookMyShow offer: buy one get one up to ₹500 off, twice a month, needs ₹25,000 spend in the preceding spends quarter (from 1 Apr 2026).',
      ],
      notes: ['Domestic lounge criteria: MITC says the "valid till Jun 30, 2026" waiver of the ₹75,000 criteria ended; from 1 Jul 2026 ₹75,000 per calendar quarter unlocks access in the next quarter.', 'Late payment fee is the MITC table (page says "₹100 to ₹1,300"). Interest 3.75% a month (45% a year).'],
    }) },
  },

  // ───────────────────────────────────────────── Adani One Platinum
  'icici-adani-one-platinum': {
    ...personalBase({
      name: 'Adani One ICICI Bank Platinum Credit Card', joining: 750, annual: 750, block: 100, basePts: 1, fuel: adaniFuel,
      page: 'https://www.icici.bank.in/personal-banking/cards/credit-card/adani-icici-credit-card/platinum-card',
      valueBasis: 'Not stated: points are credited to the Adani OneApp as Adani OneApp Rewards with no rupee value given.',
      eligibility: 'Eligibility not read for this card.',
    }),
    reward_rules: [
      ...exclusions('adani-plat'),
      R({ id: 'adani-plat-international-1-5', cat: 'international_spend', pri: 10, ppb: 1.5, mult: 1.5, cond: { transaction_type: 'international', per_inr_block: 100 }, reason: '1.5 points per ₹100 on international spend (issuer page).' }),
      R({ id: 'adani-plat-base-1', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100, transaction_type: 'domestic' }, reason: '1 point per ₹100 on domestic spend (issuer page).' }),
    ],
    cap_rules: [],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 300000, period: 'card_anniversary_year', evaluation_condition: 'Spend over ₹3 lakh and the annual fee is waived for the following year (page; MITC fee table 3,00,000 with the anniversary-year footnote). EMI, rent, government and education spends do not count (MITC).', excluded_category_ids: ['rent', 'government', 'education', 'emi'], excluded_mcc_list: [], waives_fee_inr: 750 },
      welcome_and_renewal_gift: { trigger: 'spend_within_60_days_of_activation_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 2000, condition: 'Flight voucher worth ₹2,000 on ₹10,000 of spend within 60 days of card activation; joining or annual fee must be paid (page).' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'adani-plat-lounge-dom', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Domestic airport lounge access, primary cardholder only, on ₹75,000 spent in the preceding spends quarter (page tile says 2 a quarter; page FAQ says 8; see open questions)', cond: { preceding_quarter_spend_inr: 75000 }, qty: 2, per: 'quarter' }),
      B({ id: 'adani-plat-lounge-upgrade', cat: 'lounge', sponsor: 'Adani One', label: 'Premium lounge upgrades', qty: 8, per: 'annual' }),
      B({ id: 'adani-plat-valet', cat: 'other', sponsor: 'Adani One', label: 'Valet parking', qty: 2, per: 'annual' }),
      B({ id: 'adani-plat-parking', cat: 'other', sponsor: 'Adani One', label: 'Premium car parking on card activation', qty: 2, per: 'annual' }),
      B({ id: 'adani-plat-porter', cat: 'other', sponsor: 'Adani One', label: 'Porter services: up to 4 a year for every ₹1 lakh spent annually', qty: 4, per: 'annual' }),
    ],
    dynamic_promotions_registry: [P({ id: 'adani-plat-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', pct: 25, max: 100, quota: true, permanent: true, from: '2026-04-01' })],
    additional_data: { items: prov({
      extra: FETCHED,
      sources: [
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/adani-icici-credit-card/platinum-card', kind: 'issuer card page: fees, earn rates, benefits, FAQ (no revision date)', read: 'plain HTTP fetch, page text' },
        mitcSrc,
      ],
      unverified: [
        'Network NOT STATED on the page or in the MITC; no card-art file naming it found.',
        '"3 points per ₹100 on Adani One Ecosystem spend" not encoded: the ecosystem merchants are not defined on the page.',
        'Value of one Adani OneApp Reward point: not stated.',
        'Domestic lounge quota conflict inside the page: the benefit tile says "2 Domestic Airport Lounge access" per quarter, the FAQ refers to "8 domestic lounge access". 2 a quarter is used; a person should confirm.',
        'MITC cap tables do not name the Adani One cards; no reward cap stated.',
        'Fuel waiver: 1% on all fuel at any outlet "up to ₹4,000"; period and whether it is a per-transaction maximum are not stated.',
        'Forex 3.5% (page and MITC default).',
      ],
      notes: ['BookMyShow: 25% off up to ₹100, twice a month, on ₹25,000 spend in the preceding spends quarter (from 1 Apr 2026).'],
    }) },
  },

  // ───────────────────────────────────────────── MakeMyTrip ICICI
  'icici-makemytrip-credit-card': {
    ...personalBase({
      name: 'MakeMyTrip ICICI Bank Credit Card', joining: 999, annual: 999, block: 100, basePts: 1, forex: 0, dcc: 0,
      fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
      page: 'https://www.icici.bank.in/personal-banking/cards/credit-card/makemytrip/makemytrip-icici-credit-card',
      valueBasis: 'Not stated as a rupee value: rewards are credited as myCash, redeemable on MakeMyTrip, not encashable (page FAQ).',
      eligibility: 'Page: Indian citizen over 21; salaried monthly income ₹20,000 or self-employed annual income at least ₹2,40,000.',
    }),
    card_product: { ...GST, name: 'MakeMyTrip ICICI Bank Credit Card', issuer_slug: 'icici-bank', card_type: 'credit', network: null, network_tier: 'N/A', application_mode: 'open', joining_fee_inr: 999, annual_fee_inr: 999, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/makemytrip/makemytrip-icici-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated as a rupee value: rewards are credited as myCash, redeemable on MakeMyTrip, not encashable (page FAQ).', point_expiry_months: 0 },
    reward_rules: [
      ...exclusions('mmt', { fuel: false }),
      X('mmt-excl-international', 'international_spend', [], 'No myCash on international transactions (page FAQ: "international transactions ... not eligible for myCash Rewards").', { transaction_type: 'international' }),
      X('mmt-excl-emi', 'emi', [], 'No myCash on EMI transactions, balance transfers and personal loan transactions (page FAQ).'),
      R({ id: 'mmt-hotel-6', cat: 'travel', pri: 10, ppb: 6, mult: 6, cond: { per_inr_block: 100, sub_category: 'hotel' }, reason: '6 points (myCash) per ₹100 on hotel booking spend (page). The page does not say whether this applies only on MakeMyTrip.' }),
      R({ id: 'mmt-flight-bus-cab-3', cat: 'travel', pri: 11, ppb: 3, mult: 3, cond: { per_inr_block: 100, sub_category: 'flight_bus_cab' }, reason: '3 points (myCash) per ₹100 on flight, bus and cab spend (page).' }),
      R({ id: 'mmt-base-1', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cap: 'mmt-insurance-cap', cond: { per_inr_block: 100 }, reason: '1 point per ₹100 on all other retail spend (page). MITC: fuel earns points on this card.' }),
    ],
    cap_rules: [C({ id: 'mmt-insurance-cap', cat: 'insurance', metric: 'total_reward_points', period: 'card_anniversary_year', points: 1000, mccs: INSURANCE, after: 'zero_accrual' })],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 300000, period: 'card_anniversary_year', evaluation_condition: 'Spend over ₹3 lakh in one year and the annual fee is waived for the next year (page; MITC fee table 3,00,000). EMI, rent, government and education spends do not count (MITC).', excluded_category_ids: ['rent', 'government', 'education', 'emi'], excluded_mcc_list: [], waives_fee_inr: 999 },
      welcome_and_renewal_gift: { trigger: 'joining_fee_paid', benefit_points: 'N/A', effective_value_inr: 1000, condition: 'MakeMyTrip voucher worth ₹1,000, valid 1 year, on paying the joining fee; a ₹1,000 hotel voucher valid 3 months on paying the annual fee (page).' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'mmt-lounge-intl', cat: 'lounge', program: 'priority_pass', sponsor: 'ICICI Bank', label: 'International airport lounge access (Priority Pass), primary cardholder only', qty: 1, per: 'annual' }),
      B({ id: 'mmt-lounge-dom', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Domestic airport lounge access, primary cardholder only, on ₹75,000 spent in the preceding spends quarter (MITC: criteria from 1 Jul 2026)', cond: { preceding_quarter_spend_inr: 75000 }, qty: 2, per: 'quarter' }),
      B({ id: 'mmt-black', cat: 'other', sponsor: 'MakeMyTrip', label: 'One-year MMTBLACK Gold membership (excluding its myCash benefit)' }),
      B({ id: 'mmt-no-cost-emi', cat: 'other', sponsor: 'MakeMyTrip', label: '3 months no-cost EMI on MakeMyTrip bookings' }),
      B({ id: 'mmt-concierge', cat: 'concierge', sponsor: 'ICICI Bank', label: '24x7 concierge (RuPay variant)' }),
    ],
    dynamic_promotions_registry: [
      P({ id: 'mmt-inox', cat: 'movie', sponsor: 'INOX', platform: 'INOX', type: 'instant_discount', pct: 25, max: 150, quota: true, permanent: true }),
      P({ id: 'mmt-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', pct: 25, max: 150, quota: true, permanent: true, from: '2026-04-01' }),
    ],
    additional_data: { items: [
      dualNetwork({
        sourceUrl: 'https://www.icici.bank.in/personal-banking/cards/credit-card/makemytrip/makemytrip-icici-credit-card',
        evidence: 'Issuer card page: "the convenience of two networks - MasterCard and RuPay"; the page card image alt text reads "MakeMyTrip ICICI Bank card ... and Mastercard logo". A cardholder gets one network or the other.',
        variants: [
          { network: 'mastercard', network_tier: 'N/A', label: 'MakeMyTrip ICICI Bank Credit Card (Mastercard)', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/makemytrip/makemytrip-icici-credit-card', evidence: 'Page: "MasterCard and RuPay"; card-art alt text names a Mastercard logo. Tier not stated.' },
          { network: 'rupay', network_tier: 'N/A', label: 'MakeMyTrip ICICI Bank Credit Card (RuPay)', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/makemytrip/makemytrip-icici-credit-card', evidence: 'Page: "MasterCard and RuPay"; concierge line says "(RuPay Variant)". Tier not stated.' },
        ],
      }),
      ...prov({
        extra: FETCHED,
        sources: [
          { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/makemytrip/makemytrip-icici-credit-card', kind: 'issuer card page: fees, earn, exclusions FAQ, lounge, networks (no revision date)', read: 'plain HTTP fetch, page text' },
          mitcSrc,
        ],
        unverified: [
          'Value of one myCash point in rupees: not stated on the page or MITC (page says "6% myCash" in the headline but gives the earn as 6 points per ₹100 hotel; 1 point = ₹1 is NOT stated).',
          'The earn rate is per ₹100 and the page headline says "up to 6% myCash"; the equivalence of a point and a myCash rupee is not stated, so no percent return is stored.',
          'Whether the 6-point hotel rate and 3-point flight/bus/cab rate apply only to MakeMyTrip bookings or to any merchant in those categories is not stated.',
          'Fuel: the page does not mention fuel; the MITC lists this card as an exception that DOES earn points on fuel, so no fuel exclusion is drafted. No fuel surcharge waiver is stated, so none is recorded.',
          'MITC cap table for utility, insurance and grocery does not list this card; the only stated cap is 1,000 reward points per anniversary year on insurance (MITC). Insurance cap period is anniversary year per the MITC.',
          'Forex and DCC: nil w.e.f. 10 Nov 2026 (MITC), not applicable to the older MakeMyTrip Platinum and Signature cards. The page also says no forex mark-up. The new card is five days old at the date of the MITC, so confirm the page is not ahead of an older MITC row.',
          'The page FAQ says Priority Pass for the "MakeMyTrip ICICI Bank Signature Credit Card"; read as a page slip for this card since the lounge text in the same FAQ names this card.',
          'Exclusion list and international exclusion come from the FAQ (rent, cash advances, late payment costs, fees, EMI, balance transfers, international transactions, personal loan).',
        ],
        notes: ['MITC lists the card in the BookMyShow-eligible set. The page and MITC both give interest 3.75% a month and late fees ₹100 to ₹1,300.'],
      }),
    ] },
  },

  // ───────────────────────────────────────────── Expressions
  'icici-expressions': {
    ...personalBase({
      name: 'ICICI Bank Expressions Credit Card', joining: 499, annual: 499, block: 100, basePts: 3, capBasis: 'statement_cycle',
      fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 4000, monthly_waiver_cap_inr: null },
      page: 'https://www.icici.bank.in/personal-banking/cards/credit-card/expressions-card',
      valueBasis: 'Not stated: the page lists reward-point categories for redemption (vouchers, appliances, electronics) with no rupee value per point.',
      eligibility: 'Page FAQ: age 21 to 65.',
    }),
    reward_rules: [
      ...exclusions('expr'),
      R({ id: 'expr-utility-insurance-1', cat: 'bills', pri: 10, ppb: 1, mult: 1 / 3, cap: 'expr-utility-cap', cond: { per_inr_block: 100, mcc_list: UTILITY }, reason: '1 point per ₹100 on utility spend (page).' }),
      R({ id: 'expr-insurance-1', cat: 'insurance', pri: 11, ppb: 1, mult: 1 / 3, cap: 'expr-insurance-cap', cond: { per_inr_block: 100, mcc_list: INSURANCE }, reason: '1 point per ₹100 on insurance spend (page).' }),
      R({ id: 'expr-retail-3', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 1, cond: { per_inr_block: 100 }, reason: '3 points per ₹100 on retail spend (page).' }),
    ],
    cap_rules: [
      C({ id: 'expr-utility-cap', cat: 'bills', metric: 'eligible_spend_amount', period: 'statement_cycle', inr: 40000, mccs: UTILITY, after: 'zero_accrual' }),
      C({ id: 'expr-insurance-cap', cat: 'insurance', metric: 'eligible_spend_amount', period: 'statement_cycle', inr: 40000, mccs: INSURANCE, after: 'zero_accrual' }),
      C({ id: 'expr-grocery-cap', cat: 'groceries', metric: 'eligible_spend_amount', period: 'statement_cycle', inr: 20000, mccs: GROCERY, after: 'zero_accrual' }),
      C({ id: 'expr-transport-cap', cat: 'travel', metric: 'eligible_spend_amount', period: 'statement_cycle', inr: 10000, mccs: TRANSPORT, after: 'zero_accrual' }),
    ],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 150000, period: 'card_anniversary_year', evaluation_condition: 'Spend over ₹1.5 lakh and the annual fee is waived for the next year (page; MITC fee table 1,50,000 with the anniversary-year footnote). EMI, rent, government and education spends do not count (MITC).', excluded_category_ids: ['rent', 'government', 'education', 'emi'], excluded_mcc_list: [], waives_fee_inr: 499 },
      welcome_and_renewal_gift: { trigger: 'N/A', benefit_points: 'N/A', effective_value_inr: 'N/A', condition: 'No welcome benefit stated on the page.' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [B({ id: 'expr-lounge-dom', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Domestic airport lounge access, primary cardholder only, on ₹75,000 spent in the preceding quarter', cond: { preceding_quarter_spend_inr: 75000 }, qty: 1, per: 'quarter' })],
    dynamic_promotions_registry: [
      P({ id: 'expr-inox', cat: 'movie', sponsor: 'INOX', platform: 'INOX', type: 'instant_discount', pct: 25, max: 100, quota: true, permanent: true }),
      P({ id: 'expr-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', pct: 25, max: 100, quota: true, permanent: true, from: '2026-04-01' }),
    ],
    additional_data: { items: prov({
      extra: FETCHED,
      sources: [
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/expressions-card', kind: 'issuer card page: fees, earn (3 per ₹100 retail, 1 utility and insurance), lounge, fuel, FAQ (no revision date)', read: 'plain HTTP fetch, page text' },
        mitcSrc,
      ],
      unverified: [
        'Network NOT STATED on the page or in the MITC; no card-art network found. Ask ICICI or read an issued card.',
        'Value of one reward point in rupees: not stated.',
        'Cap tables (MITC): utility ₹40,000, insurance ₹40,000, grocery and department store ₹20,000, transportation ₹10,000 per statement cycle for Expressions. The MITC heads the columns "Utility Spend" etc. and says "Reward Points accrued per statement cycle will be capped", so whether the ₹ figure is eligible spend or points is not fully clear; read as eligible spend. What happens above the cap (zero points) is not stated explicitly; zero_accrual is the reading of "capped".',
        'Grocery: no accelerated rate is stated for grocery; it sits in the standard 3 points per ₹100 and is subject to the ₹20,000 cap.',
        'Fuel waiver: 1% on transactions of ₹400 to ₹4,000 at HPCL pumps (page); the monthly or cycle cap is not on the page. MITC says surcharge waiver on select cards applies on spends up to ₹50,000 per statement cycle at HPCL; whether Expressions is a select card is not named in the MITC.',
        'Forex 3.5%: MITC default; not stated on the card page.',
        'Government spends are treated as utility category for fee purposes since 5 Feb 2024 (MITC); their reward treatment on this card is not stated beyond the MITC cap table.',
      ],
      notes: ['Late payment slab and interest from the MITC. Card is customisable (175+ templates, page).', 'Annual fee conflict check: page and MITC both say ₹499.'],
    }) },
  },

  // ───────────────────────────────────────────── ICICI business cards
  'icici-business-platinum': {
    ...bizBase({ name: 'ICICI Bank Platinum Business Card', joining: 999, annual: 999, slug: 'platinum-business-card', fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 }, interest: [3.75, 45] }),
    reward_rules: bizRewards('biz-plat', 200, 1, 2, 'domestic spend', 'international spend'),
    fee_waiver_and_milestones: bizWaiver(null, 999, 'No annual-fee waiver is stated for this card (page and Business MITC).'),
    lifestyle_and_network_benefits: [B({ id: 'biz-plat-lounge', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Domestic airport lounge access visits (no spend condition stated on the page)', qty: 2, per: 'quarter' })],
    insurance_and_protection: [],
    dynamic_promotions_registry: [],
    additional_data: { items: bizProv('platinum-business-card', ['Network NOT STATED for this card on its page or in the Business MITC (the MITC says only "VISA and MASTERCARD" or "AMEX" generically).', 'Value of one reward point: not stated.', 'Reward exclusions are not listed on the page or in the Business MITC for this card.', 'Fuel waiver: 1% at all fuel stations (page); Business MITC says 1% at all petrol pumps on a maximum transaction of ₹5,000 and capped at ₹500 a month. Used.', 'Personal accident death cover up to ₹25,00,000 (page).', 'Joining fee and annual fee both ₹999 (page, Business MITC).']) },
  },
  'icici-business-gold': {
    ...bizBase({ name: 'ICICI Bank Gold Business Credit Card', joining: 0, annual: 0, slug: 'gold-business-card', fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 }, interest: [3.75, 45] }),
    reward_rules: bizRewards('biz-gold', 200, 1, 2, 'domestic spend', 'international spend'),
    fee_waiver_and_milestones: bizWaiver(null, 0, 'No joining or annual fee (page: "Joining fee NIL, Annual Fee NIL (2nd year onwards)"; Business MITC: Nil, Nil).'),
    lifestyle_and_network_benefits: [],
    insurance_and_protection: [],
    dynamic_promotions_registry: [],
    additional_data: { items: bizProv('gold-business-card', ['Network NOT STATED on the page or in the Business MITC.', 'Value of one reward point: not stated.', 'Reward exclusions not listed.', 'Fuel waiver: 1% at HPCL petrol pumps, maximum transaction ₹5,000 on ICICI POS swipe machines, capped at ₹500 a month (Business MITC, page).', 'Personal accidental death insurance up to ₹10 lakh (page).']) },
  },
  'icici-business-micro': {
    ...bizBase({ name: 'ICICI Bank Business Micro Credit Card', joining: 0, annual: 0, slug: 'micro-business-credit-card', network: 'rupay', fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: 500 }, interest: [1.5, 18] }),
    reward_rules: bizRewards('biz-micro', 200, 1, 2, 'domestic spend', 'international spend'),
    fee_waiver_and_milestones: bizWaiver(null, 0, 'No joining or annual fee; a CGTMSE annual guarantee fee of 0.55% of the card limit plus GST applies (page FAQ, Business MITC).'),
    lifestyle_and_network_benefits: [],
    insurance_and_protection: [],
    dynamic_promotions_registry: [],
    additional_data: { items: bizProv('micro-business-credit-card', ['Network: the page FAQ speaks of the "ICICI Bank Business Micro RuPay Credit Card" being linked to UPI, so RuPay is read from that issuer wording; no tier stated and no network table exists. A person should confirm no other network is issued.', 'Value of one reward point: not stated.', 'Fuel waiver: 1% at HPCL pumps up to ₹500 a month (page); the Business MITC fuel table does not list the Micro card, so the transaction cap is not stated.', 'Interest 1.5% a month (18% a year) from the Business MITC for Micro; CGTMSE fee 0.55% of limit + GST; personal accidental death insurance up to ₹10 lakh (page).', 'Reward exclusions not listed.']) },
  },
  'icici-business-essential-amex': {
    ...bizBase({ name: 'ICICI Bank American Express Business Essential Credit Card', joining: 1000, annual: 1000, slug: 'essential-business-advantage-card', network: 'amex', fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 }, interest: [3.75, 45] }),
    reward_rules: [
      X('biz-ess-excl-cash', 'excluded_spend', CASH, 'No reward points on cash withdrawals (page: "except cash withdrawals, fuel, rent and utilities").'),
      X('biz-ess-excl-fuel', 'fuel', FUEL, 'No reward points on fuel (page).'),
      X('biz-ess-excl-rent', 'rent', RENT, 'No reward points on rent (page).'),
      X('biz-ess-excl-utility', 'bills', UTILITY, 'No reward points on utilities (page).'),
      R({ id: 'biz-ess-online-4', cat: 'online', channel: 'online', pri: 10, ppb: 4, mult: 4, cond: { per_inr_block: 200 }, reason: '4 points per ₹200 on online spend (page).' }),
      R({ id: 'biz-ess-dining-airline-2', cat: 'dining', pri: 11, ppb: 2, mult: 2, cond: { per_inr_block: 200, categories: ['dining', 'airlines'] }, reason: '2 points per ₹200 on dining and airline spend (page).' }),
      R({ id: 'biz-ess-base-1', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 200 }, reason: '1 point per ₹200 on other spend (page).' }),
    ],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 500000, period: 'card_anniversary_year', evaluation_condition: 'Spend ₹5,00,000 or more during an anniversary year and the annual fee is reversed for the subsequent year (Business MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 1000 },
      welcome_and_renewal_gift: { trigger: 'first_month_bill_payment', benefit_points: 1500, effective_value_inr: null, condition: '1,500 reward points on payment of the first month\'s bill; 1,500 points within 30 days of paying the annual fee (page). Rupee value of a point not stated.' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [],
    insurance_and_protection: [],
    dynamic_promotions_registry: [],
    additional_data: { items: bizProv('essential-business-advantage-card', ['Network: American Express, from the issuer page name "ICICI Bank American Express Business Essential Credit Card" and the Business MITC "AMEX" wording; no separate network statement or tier.', 'Value of one reward point: not stated.', 'Fuel waiver: 1% at HPCL pumps, maximum transaction ₹5,000, capped ₹500 a month per card (Business MITC, page).', 'Online spend (4 points per ₹200): the page does not say what counts as online, nor any cap.', 'The page says "except cash withdrawals, fuel, rent and utilities" without MCC lists; the MCC lists drafted are the personal-card MITC lists and are not stated for this card.']) },
  },
  'icici-business-ascent-amex': {
    ...bizBase({ name: 'ICICI Bank Business Ascent Credit Card (American Express)', joining: 2000, annual: 1500, slug: 'ascent-business-advantage-card', network: 'amex', fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null }, interest: [3.75, 45] }),
    reward_rules: [
      R({ id: 'biz-asc-airline-dining-4', cat: 'travel', pri: 10, ppb: 4, mult: 4 / 3, cond: { per_inr_block: 200, categories: ['airlines', 'dining'] }, reason: '4 points per ₹200 on airline and dining spend (page).' }),
      R({ id: 'biz-asc-base-3', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 1, cond: { per_inr_block: 200 }, reason: '3 points per ₹200 on other spend (page).' }),
    ],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 750000, period: 'card_anniversary_year', evaluation_condition: 'Spend ₹7,50,000 or more during an anniversary year and the annual fee is reversed for the subsequent year (Business MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 1500 },
      welcome_and_renewal_gift: { trigger: 'first_month_bill_payment', benefit_points: 3000, effective_value_inr: null, condition: '3,000 reward points on payment of the first month\'s bill; 2,000 points within 30 days of paying the annual fee (page). Rupee value of a point not stated.' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [B({ id: 'biz-asc-lounge', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Complimentary domestic airport lounge access', qty: 2, per: 'quarter' })],
    insurance_and_protection: [],
    dynamic_promotions_registry: [],
    additional_data: { items: bizProv('ascent-business-advantage-card', ['Network: American Express, from the issuer page ("exclusive American Express (AMEX) lifestyle offers", card art alt text "American Express logo").', 'Value of one reward point: not stated.', 'FEES CONFLICT: the consumer MITC (6 Nov 2026) lists "ICICI Bank Ascent American Express Credit Card" at joining ₹4,000, annual ₹1,000, waiver at ₹ spend not stated; the Business MITC (14 Oct 2026) and the business page give joining ₹2,000, annual ₹1,500, waiver at ₹7,50,000. These look like two different cards (a personal Ascent and this Business Ascent). The business figures are used because the Business MITC names the "American Express Business Ascent Card". A person should confirm the consumer Ascent is a separate product.', 'Fuel waiver: page says 1% on all petrol pumps; the Business MITC fuel table does not list the Ascent card, so no max transaction value or monthly cap is stated.', 'Reward exclusions not listed.']) },
  },

  // ───────────────────────────────────────────── HDFC Paytm Select Business
  'hdfc-paytm-select-business': {
    card_product: { ...GST, name: 'Paytm HDFC Bank Select Business Credit Card', issuer_slug: 'hdfc', card_type: 'credit', network: null, network_tier: 'N/A', application_mode: 'open', joining_fee_inr: 1000, annual_fee_inr: 500, is_upi_linkable: false, data_source_tier: 'issuer_page', source_url: 'https://www.hdfc.bank.in/business-credit-cards/paytm-select-business-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated for this card: the page says cashback is credited as CashPoints redeemable against the statement balance but gives no rupee value per CashPoint on this page.', point_expiry_months: null },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Page: self-employed, Indian national, age 21 to 65, annual ITR above ₹8,00,000.', rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: null, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('hdfc-psb-excl', 'excluded_spend', [], 'No cashback on wallet loads, fuel, EMI, rental and government spends (page, Card Reward and Redemption Program).'),
      R({ id: 'hdfc-psb-paytm-5', cat: 'online', pri: 10, cb: 5, mult: 1, cond: { merchant_group: 'paytm', stated_wording: '"5% CashBack on all purchases across Paytm"' }, reason: '5% cashback on purchases across Paytm (page); see open questions on its conflict with the 2% line.' }),
      R({ id: 'hdfc-psb-partners-3', cat: 'online', pri: 11, cb: 3, mult: 1, cap: 'hdfc-psb-grocery-cap', cond: { merchants: ['Swiggy', 'AJIO', 'BigBasket', 'Uber'] }, reason: '3% CashPoints on Swiggy, AJIO, BigBasket and Uber (page). Grocery cashback is capped at 1,000 CashPoints a month (page).' }),
      R({ id: 'hdfc-psb-paytm-other-2', cat: 'online', pri: 12, cb: 2, mult: 1, cond: { merchant_group: 'paytm_other' }, reason: '2% cashback on all other Paytm spends (page).' }),
    ],
    cap_rules: [C({ id: 'hdfc-psb-grocery-cap', cat: 'groceries', metric: 'total_reward_points', period: 'calendar_month', points: 1000, after: 'zero_accrual' })],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: null, annual_interest_rate_percent: null },
      forex_markup: { markup_percent: null, gst_applicable: null },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    },
    statement_and_late_fees: { late_payment_slabs: [] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 100000, period: 'card_anniversary_year', evaluation_condition: 'Renewal fee waived on annual non-EMI spends of ₹1 lakh in the 12-month period (page). The first-year fee is waived on ₹60,000 of non-EMI spend within 90 days of issue.', excluded_category_ids: ['emi'], excluded_mcc_list: [], waives_fee_inr: 500 },
      welcome_and_renewal_gift: { trigger: 'card_activation', benefit_points: 'N/A', effective_value_inr: 500, condition: 'Gift voucher worth ₹500 on activation and complimentary Paytm First membership (page).' },
      spend_milestones: [{ id: 'hdfc-psb-milestone-2l', label: 'Gift voucher worth ₹1,000 on spends of ₹2 lakh in a year (page)', threshold_spend_inr: 200000, reward_value_inr: 1000, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null }],
    },
    addon_card_rules: noAddon,
    lifestyle_and_network_benefits: [B({ id: 'hdfc-psb-lounge', cat: 'lounge', sponsor: 'HDFC Bank', label: 'Complimentary domestic airport lounge access', qty: 12, per: 'annual' })],
    dynamic_promotions_registry: [],
    additional_data: { items: prov({
      extra: FETCHED,
      sources: [
        { url: 'https://www.hdfc.bank.in/business-credit-cards/paytm-select-business-credit-card', kind: 'issuer product page: benefits, fees, reward programme, FAQ (no revision date)', read: 'plain HTTP fetch, page text' },
        { url: 'https://www.hdfc.bank.in/content/dam/hdfcbankpws/in/en/personal-banking/discover-products/cards/credit-cards/paytm-select-business-credit-card/mitcs.pdf', kind: 'linked MITC: general HDFC Bank KFS cum MITC (version 2.3), no row for this card', read: 'pdftotext' },
      ],
      unverified: [
        'Network NOT STATED on the page or in the linked MITC. Ask HDFC or read an issued card.',
        'Rupee value of one CashPoint: not stated on this page (the page says cashback is credited as CashPoints). Do not reuse another card\'s value.',
        'Earn rate conflict inside the page: "5% CashBack on all purchases across Paytm" and "2% CashBack on all other Paytm spends" overlap. The page does not say what the 5% applies to versus the 2%, and states no rate for spend outside Paytm and the four partner brands.',
        'Interest rate, forex markup, late fee and fuel waiver limits are in an HDFC schedule of charges that the linked MITC does not contain for this card; none are stated on the page, so they are null.',
        'FAQ milestone "1% cashpoints upon spending ₹10,000 every month (capped ₹100 a month)" appears only in the FAQ and may be older text; not modelled.',
        'Possible duplicate of live cards paytm-hdfc-bank-select (same ₹1,000 joining fee) or paytm-business-hdfc: this page is the issuer\'s own business-menu entry with a separate fee row, so it is drafted separately; a person should confirm it is a distinct product.',
        'Lounge: "12 complimentary access to domestic airport lounges in a calendar year" (page); any spend condition is under an asterisk not shown.',
      ],
      notes: ['Page: renewal fee ₹500 plus taxes from the second year.'],
    }) },
  },
};

// ───────────────────────────────────────────── business helpers (function declarations hoist)
function bizBase(o) {
  const page = `https://www.icici.bank.in/business-banking/cards/business-credit-card/${o.slug}`;
  return {
    card_product: { ...GST, name: o.name, issuer_slug: 'icici-bank', card_type: 'credit', network: o.network ?? null, network_tier: 'N/A', application_mode: 'open', joining_fee_inr: o.joining, annual_fee_inr: o.annual, is_upi_linkable: o.network === 'rupay', data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page, status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated by ICICI for this card.', point_expiry_months: null },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Business credit card for entrepreneurs, owners and self-employed professionals (page FAQ); documents: business registration, address proof, financial documents.', rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: null, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: o.interest[0], annual_interest_rate_percent: o.interest[1] },
      forex_markup: { markup_percent: 3.5, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 3.5, gst_applicable: true, trigger_condition: 'Business MITC: 1% until 24 Nov 2026, 3.5% w.e.f. 25 Nov 2026 on Indian-rupee transactions abroad or at foreign-registered merchants; 3.5% used as the standing rate' },
      fuel_surcharge: o.fuel,
      category_surcharges: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on rent payments (Business MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null }],
      banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 550, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
      reward_redemption_fee: { fee_inr: 99, gst_applicable: true },
    },
    statement_and_late_fees: { late_payment_slabs: LATE },
    addon_card_rules: noAddon,
  };
}
function bizRewards(p, block, dom, intl, domLabel, intlLabel) {
  return [
    R({ id: `${p}-international-${intl}`, cat: 'international_spend', pri: 10, ppb: intl, mult: intl / dom, cond: { transaction_type: 'international', per_inr_block: block }, reason: `${intl} points per ₹${block} on ${intlLabel} (page).` }),
    R({ id: `${p}-domestic-${dom}`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: dom, mult: 1, cond: { transaction_type: 'domestic', per_inr_block: block }, reason: `${dom} point per ₹${block} on ${domLabel} (page).` }),
  ];
}
function bizWaiver(threshold, fee, text) {
  return {
    annual_fee_waiver: { threshold_spend_inr: threshold ?? 'N/A', period: threshold ? 'card_anniversary_year' : 'N/A', evaluation_condition: text, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: threshold ? fee : 'N/A' },
    welcome_and_renewal_gift: { trigger: 'N/A', benefit_points: 'N/A', effective_value_inr: 'N/A', condition: 'No welcome benefit stated.' },
    spend_milestones: [],
  };
}
function bizProv(slug, unverified) {
  return prov({
    extra: FETCHED,
    sources: [
      { url: `https://www.icici.bank.in/business-banking/cards/business-credit-card/${slug}`, kind: 'issuer business card page: fees, earn, benefits, FAQ (no revision date)', read: 'plain HTTP fetch, page text' },
      bmitcSrc,
    ],
    unverified,
    notes: ['Late payment fee table, interest, over-limit fee, redemption fee, forex 3.5% and rent fee come from the Business MITC of 14 Oct 2026. Business card variants have corporate-liability and individual-liability forms (BCCL, BCIL).'],
  });
}
