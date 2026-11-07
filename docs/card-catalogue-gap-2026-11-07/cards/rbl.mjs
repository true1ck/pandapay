// RBL Bank Shoppers Stop cards. Sources (read 2026-11-07):
//  TNC  = https://webassets.rbl.bank.in/document/credit-cards/tnc-rbl-bank-shoppers-stop-{gold|platinum|black}-credit-card.pdf (9-10 pages each, pdftotext)
//  SOC  = RBL Schedule of Charges https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf
//  Page = rendered issuer product page
import { R, X, C, B, prov, GST } from '../lib.mjs';

const SOC = 'https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf';
const tnc = (v) => `https://webassets.rbl.bank.in/document/credit-cards/tnc-rbl-bank-shoppers-stop-${v}-credit-card.pdf`;

// Exclusion MCCs are the same table in all three T&Cs (section 4.5).
const EXCL = [
  ['fuel', 'fuel', [32, 2541, 4001, 5542, 5541, 5172], 'Fuel and auto'],
  ['utilities', 'utility', [4900], 'Utilities'],
  ['insurance', 'insurance', [6300, 6310, 5960], 'Insurance and miscellaneous (5960)'],
  ['quasi-cash', 'cash_withdrawal', [6050, 6051, 4829, 6011, 6010], 'Quasi-cash and cash'],
  ['railways', 'excluded_spend', [66, 4011, 4112], 'Railways'],
  ['rent', 'rent', [6513], 'Real estate and rental'],
  ['education', 'education', [8220, 8244, 8249, 8211, 8241, 8299], 'Education'],
  ['wallets', 'wallet_load', [6540], 'Wallets and service providers'],
  ['government', 'government', [9400, 1490, 2490, 2995, 7800, 9406, 9222, 9405, 9399, 9211, 9402, 9401, 9311, 9223], 'Government services'],
  ['contracted', 'excluded_spend', [1711, 1740, 763, 1520, 742, 1761, 1799, 1750, 1731, 1771, 780], 'Contracted services'],
  ['emi', 'emi', [], 'EMI conversion of retail transactions (Split-N-Pay and EMI at POS/web/app), fees, charges and GST'],
];

const make = (v, o) => {
  const slug = `rbl-bank-shoppers-stop-${v}`;
  const ssRate = o.ssPer200;
  return {
    card_product: { ...GST, card_type: 'credit', network: 'visa', application_mode: 'open', joining_fee_inr: o.fee, annual_fee_inr: o.fee, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: `https://www.rbl.bank.in/personal-banking/cards/credit-cards/rbl-bank-shoppers-stop-${v}-credit-card`, status: 'draft', verified_at: null, point_value_inr_baseline: o.ssValue, point_value_baseline_basis: `T&C 4.2: 1 point = ₹${o.ssValue.toFixed(2)} at Shoppers Stop and up to ₹${o.portalValue.toFixed(2)} on the RBL Rewards Portal. Baseline is the Shoppers Stop value; the portal value is much lower.` },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: 'floor', base_points_per_block: 4, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      ...EXCL.map(([k, cat, mccs, label]) => X(`rbl-ss-${v}-excl-${k}`, cat, mccs, `${label} earns no reward points (T&C 4.5).`)),
      R({ id: `rbl-ss-${v}-ss-universe`, cat: 'all_retail', pri: 10, ppb: ssRate, mult: ssRate, channel: 'shoppers_stop', cap: `rbl-ss-${v}-ss-cap`, cond: { merchant: 'Shoppers Stop universe', per_inr_block: 200, multiples_of_inr: 200 }, reason: `${ssRate} reward points per ₹200 in the Shoppers Stop universe; multiples of ₹200 only, no points on the remainder (T&C 4.2).` }),
      R({ id: `rbl-ss-${v}-other`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 4, mult: 4, cap: `rbl-ss-${v}-other-cap`, cond: { per_inr_block: 200, multiples_of_inr: 200 }, reason: '4 reward points per ₹200 on all other eligible spends (T&C 4.2).' }),
    ],
    cap_rules: [
      C({ id: `rbl-ss-${v}-ss-cap`, cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 1500, after: 'downgrade_to_base_rate', afterPpb: 4 }),
      C({ id: `rbl-ss-${v}-other-cap`, cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 500, after: 'zero_accrual' }),
    ],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.99, annual_interest_rate_percent: 47.88 },
      forex_markup: { markup_percent: 3.5, gst_applicable: null },
      dynamic_currency_conversion_dcc: { fee_percent: 3.5, gst_applicable: null, trigger_condition: 'Schedule of Charges: up to 3.5% on foreign currency, dynamic and static conversion transactions' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: null, daily_interest_percent: null, max_limit_percent: null },
      category_surcharges: [
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: null, trigger_condition: '1% fee on all rental transactions (Schedule of Charges)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: null, trigger_condition: '1% fee on each fuel and auto transaction above ₹10,000, capped (Schedule of Charges)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
      ],
      banking_penalties: { overlimit_charge: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
    },
    statement_and_late_fees: { late_payment_slabs: [] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'The Schedule of Charges lists the same fee for year 1 and year 2 onwards with no spend waiver. The first-year fee must be paid within 60 days for the welcome benefits.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'first_transaction_within_30_days_and_fee_paid', benefit_points: 'N/A', effective_value_inr: o.welcomeValue, condition: o.welcomeText },
      spend_milestones: [
        { id: `rbl-ss-${v}-quarterly`, label: `Shoppers Stop voucher worth ₹${o.qVoucher} on ₹${o.qSpend.toLocaleString('en-IN')} eligible spend in the previous calendar quarter`, threshold_spend_inr: o.qSpend, reward_value_inr: o.qVoucher, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null },
        { id: `rbl-ss-${v}-annual`, label: `Shoppers Stop voucher worth ₹${o.aVoucher} on ₹${o.aSpend.toLocaleString('en-IN')} eligible spend in an anniversary year`, threshold_spend_inr: o.aSpend, reward_value_inr: o.aVoucher, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
      ],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: `rbl-ss-${v}-membership`, cat: 'other', sponsor: 'Shoppers Stop', label: o.membership, cond: { activated_months: 12 }, value: o.membershipValue }),
    ],
    additional_data: { items: prov({
      sources: [
        { url: tnc(v), kind: 'Card T&C (welcome, earn, caps, milestones, exclusions)', read: 'pdftotext' },
        { url: SOC, kind: 'Schedule of Charges (annual fee, finance charge, forex, cash advance)', read: 'pdftotext' },
        { url: `https://www.rbl.bank.in/personal-banking/cards/credit-cards/rbl-bank-shoppers-stop-${v}-credit-card`, kind: 'issuer page', read: 'rendered page text' },
      ],
      unverified: [
        'Network is carried over from the Nov 5 draft (visa); neither the T&C nor the page read this session states it.',
        'Neither the T&C nor the Schedule of Charges carries a revision date.',
        'Cap period: the T&C says "monthly cap... reset at the start of each billing cycle"; modelled as statement_cycle.',
        'After the 1,500-point Shoppers Stop cap the T&C does not say whether spend falls back to the 4-per-₹200 rate; modelled as downgrade_to_base_rate, which needs review.',
        'Late fee slabs, over-limit fee (stated NIL) and the fuel fee cap were not extracted in detail from the Schedule of Charges.',
      ],
      notes: [
        `Quarterly bonus: 1,000 reward points per calendar quarter on one single ₹20,000+ purchase in a Shoppers Stop store, only if the previous quarter's eligible spend was ₹${o.bonusPrevQ.toLocaleString('en-IN')}; not valid in the End of Season Sale (T&C 4.4). Event bonus, not modelled as a rate.`,
        'Reward points redeem at Shoppers Stop at the higher value and on the RBL Rewards Portal at up to the lower value (T&C 4.2).',
        'Welcome benefits are gated on a first valid transaction within 30 days and the annual fee being paid within 60 days (T&C 4.1). Vouchers are valid 90 days.',
        'Milestone spend excludes every category in the exclusion table (T&C 4.3).',
      ],
    }) },
  };
};

export const cards = {
  'rbl-bank-shoppers-stop-gold': make('gold', { tier: 'entry', fee: 1000, ssPer200: 10, ssValue: 0.25, portalValue: 0.10, qSpend: 100000, qVoucher: 500, aSpend: 350000, aVoucher: 1000, bonusPrevQ: 50000, welcomeValue: 1750, welcomeText: 'Complimentary gift worth up to ₹1,000 redeemable at Shoppers Stop branded stores (valid 90 days) plus a Shoppers Stop First Citizen Golden Glow membership worth ₹750 for 12 months. The issuer page advertises "free Shoppers Stop vouchers ₹3,000" in total including milestones.', membership: 'Shoppers Stop First Citizen Golden Glow membership', membershipValue: 750 }),
  'rbl-bank-shoppers-stop-platinum': make('platinum', { tier: 'mid', fee: 5000, ssPer200: 10, ssValue: 0.5, portalValue: 0.25, qSpend: 150000, qVoucher: 1000, aSpend: 500000, aVoucher: 1500, bonusPrevQ: 50000, welcomeValue: 5500, welcomeText: 'Shoppers Stop voucher worth ₹2,000 plus a complimentary gift worth up to ₹2,000 (both valid 90 days) and a First Citizen Platinum Aura membership worth ₹1,500 for 12 months.', membership: 'Shoppers Stop First Citizen Platinum Aura membership', membershipValue: 1500 }),
  'rbl-bank-shoppers-stop-black': make('black', { tier: 'premium', fee: 10000, ssPer200: 15, ssValue: 1, portalValue: 0.25, qSpend: 250000, qVoucher: 1500, aSpend: 800000, aVoucher: 2500, bonusPrevQ: 75000, welcomeValue: 10500, welcomeText: 'Shoppers Stop voucher worth ₹3,000 plus a complimentary gift worth up to ₹3,000 (both valid 90 days) and a First Citizen Black Card membership worth ₹4,500 for 12 months.', membership: 'Shoppers Stop First Citizen Black Card membership', membershipValue: 4500 }),
};
