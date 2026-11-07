// The nine cards from the 2026-10-17 catalogue-gap batch, re-read against current issuer documents on 2026-11-07.
// Stable Money x2: Suryoday KFS effective 5 Oct 2026 + cashback FAQ + "changes from 5 Oct 2026" notice (pdftotext)
// slice: slice credit card MITC page (rendered), https://slice.bank.in/cc-mitc/
// OneCard SBM: "The SBM One co-branded Credit Card" MITC, Sep 2025 file (pdftotext)
// Federal Scapia: Scapia Federal Credit Card Cardholder Agreement (73 pages, pdftotext)
// Jupiter Edge+: Edge CSB Bank / Edge+ CSB Bank MITC page (rendered), uploaded 30 Oct 2026
// CRED IndusInd: CRED terms, Section Z (rendered page, 7 Nov 2026)
// IOB: IOB credit card Schedule of Charges (pdftotext); IOB credit card page (rendered)
import { R, X, C, B, prov, dualNetwork, GST } from '../lib.mjs';

const SSFB = 'https://suryoday.bank.in/personal/cards/credit-cards/secured-credit-card/';
const CASHBACK_DOC = 'https://suryoday.bank.in/assets/pdf/stablemoney-suryoday-sfb-credit-card-cashback.pdf';

const ssfbExcl = [
  ['wallet', 'wallet_load', [4814, 6540], 'Wallet recharges'],
  ['financial', 'excluded_spend', [4829, 6012, 6050, 6051, 6300, 6381, 6399, 6531, 6532, 6533, 6534, 6535, 6611, 6760, 7276], 'Financial institutions'],
  ['government', 'government', [8111, 9211, 9222, 9223, 9311, 9321, 9313, 9314, 9399, 9402, 9405, 9411, 8398], 'Government services and charities'],
  ['insurance', 'insurance', [5960, 6300, 6381, 6399], 'Insurance'],
  ['railway', 'excluded_spend', [4112], 'Railway'],
  ['cash-investments', 'cash_withdrawal', [6010, 6011, 6012, 6211], 'Mutual funds and manual or automated cash'],
  ['education', 'education', [8299, 8211, 8220, 8241, 8244, 8249], 'Education'],
  ['transport', 'excluded_spend', [4111, 4119, 4121, 4131, 4214, 4789, 4784], 'Transport'],
  ['fuel', 'fuel', [5541, 5542, 5983], 'Fuel'],
  ['utilities', 'utility', [4900], 'Electric, gas, sanitary and water utilities'],
  ['rent', 'rent', [6513], 'Real estate agents and managers, rentals'],
];

const stableMoney = (variant, o) => ({
  card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, form_factors: ['virtual_card', 'physical_plastic'], data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: SSFB, status: 'draft', verified_at: null },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'FD-backed secured card: needs an existing un-liened, non-corporate, non-tax-saver FD with Suryoday SFB; age above 18 and below 80; resident individual (issuer page). Credit limit is tied to the FD; the bank may liquidate the FD if the account is more than 60 days overdue or the outstanding reaches 98% of the FD value.', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 18, allowed_values: [] }, { parameter: 'age_years', operator: '<=', threshold_value: 80, allowed_values: [] }, { parameter: 'suryoday_fd', operator: '==', threshold_value: 1, allowed_values: [] }], required_documents: [] },
  accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: 0.5, effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
  reward_rules: [
    ...ssfbExcl.map(([k, cat, mccs, label]) => X(`ssfb-${variant}-excl-${k}`, cat, mccs, `${label} earns no cashback (Stable Money cashback FAQ, excluded MCC table).`)),
    R({ id: `ssfb-${variant}-cashback-0-5`, cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 0.5, mult: 1, cap: `ssfb-${variant}-cashback-cap`, reason: '0.5% cashback on each eligible transaction (cashback FAQ).' }),
  ],
  cap_rules: [C({ id: `ssfb-${variant}-cashback-cap`, cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', inr: 3000, after: 'zero_accrual' })],
  fees_and_surcharges: {
    apr: { monthly_interest_rate_percent: 2.95, annual_interest_rate_percent: 35.4 },
    forex_markup: { markup_percent: 0, gst_applicable: true },
    dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: null },
    fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 8000, monthly_waiver_cap_inr: 40000 },
    cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: null, daily_interest_percent: null, max_limit_percent: 20 },
    category_surcharges: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% surcharge on rental payments under MCC 6513', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 300, foreclosure_charge_percent: 3, gst_applicable: true },
    banking_penalties: { overlimit_charge: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
  },
  statement_and_late_fees: { minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['10% of billed amount', 'plus EMIs and any overdue and over-limit amounts'] }, late_payment_slabs: [] },
  fee_waiver_and_milestones: {
    annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Joining and annual fees are NIL (KFS effective 5 Oct 2026). The older KFS (26 May 2026) charged ₹150 + GST, waived at ₹50,000 spend; it is superseded.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
    welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
    spend_milestones: [],
  },
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
  lifestyle_and_network_benefits: [],
  additional_data: { items: [
    { key: 'late_payment_fee_rule', value: { rule: '₹250 or 1% of the outstanding amount, whichever is lower, + GST', source: `Suryoday ${variant} KFS effective 5 Oct 2026` } },
    ...prov({
      sources: [
        { url: `https://suryoday.bank.in/assets/pdf/kfs-ssfb-rupay-${variant}-credit-card-5oct.pdf`, kind: `Suryoday ${variant} RuPay KFS effective 5 Oct 2026`, read: 'pdftotext' },
        { url: CASHBACK_DOC, kind: 'Stable Money cashback FAQ (0.5%, ₹3,000 cycle cap, excluded MCCs); undated, example uses May 2025 dates', read: 'pdftotext' },
        { url: 'https://suryoday.bank.in/assets/pdf/stable-money-credit-card-5oct2026.pdf', kind: 'Changes applicable from 5 Oct 2026 (second-card fees, closure fee, recovery)', read: 'pdftotext' },
        { url: SSFB, kind: 'issuer page listing the current documents', read: 'rendered page text' },
      ],
      unverified: [
        'The cashback FAQ is undated and its worked example uses May 2025 dates; the issuer page says 0.5% cashback is effective from 1 Aug (year not shown). Treat the cap and MCC list as current but confirm.',
        `${variant === 'select' ? 'RuPay Select' : 'RuPay Platinum'} network benefits (lounge, golf, spa, health checks) are not in the KFS and were not modelled.`,
        'MITC (5 Oct 2026) was fetched for the card but not read in full.',
      ],
      notes: [
        'The Nov 5 correction is confirmed: with the 5 Oct 2026 KFS the annual fee is nil and the foreign currency surcharge is NIL. The earlier ₹150 / 2.5% values came from the 26 May 2026 KFS.',
        'Cashback is limited to ₹3,000 per billing cycle; excluded MCCs are listed in the cashback FAQ.',
        `Second card issuance fee (incl. GST) from 5 Oct 2026: ${o.second}. Early closure or limit-reduction fee ₹150 incl. GST within 3 months.`,
        'Fuel surcharge waiver is limited to ₹40,000 a calendar month with no single transaction above ₹8,000.',
      ],
    }),
  ] },
});

export const cards = {
  'suryoday-stable-money-rupay-select': stableMoney('select', { second: 'virtual or physical Select card ₹500' }),
  'stable-money-suryoday-rupay-platinum': stableMoney('platinum', { second: 'virtual Platinum ₹150, physical Platinum ₹250' }),

  // ───────────────────────────────────────────── slice
  'slice-small-finance-bank-upi-credit-card': {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://slice.bank.in/credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: 0.01, point_value_baseline_basis: 'MITC: monies redeem for cash into the slice savings account at 1% of balance up to ₹3,00,000, 1.5% for ₹3,00,001-₹5,00,000, 2% above ₹5,00,000 and 3% only with both a ₹5,00,000 monies balance and a ₹5,00,000 average quarterly savings balance. 1 monies per ₹1 at the 1% slab is ₹0.01 per monies.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Earlier research recorded a minimum age of 18; not re-read.', rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 1, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('slice-excl-fuel', 'fuel', [5541, 5542, 5983, 5172], 'Fuel earns no monies (MITC exclusion table).'),
      X('slice-excl-transport', 'excluded_spend', [4111, 4112, 4784, 4789], 'Railways, transit and transportation earn no monies.'),
      X('slice-excl-telecom-utility', 'utility', [4814, 4900], 'Telecom and utility payments earn no monies.'),
      X('slice-excl-education', 'education', [8211, 8220, 8241, 8244, 8249, 8299], 'Education earns no monies.'),
      X('slice-excl-government', 'government', [9211, 9222, 9311, 9405, 9399, 9402], 'Government and post office earn no monies.'),
      X('slice-excl-rent', 'rent', [6513, 7349], 'Rent payments and property management earn no monies.'),
      X('slice-excl-wallet', 'wallet_load', [6539, 6540], 'Wallet loading earns no monies.'),
      X('slice-excl-gaming', 'gaming', [5816, 7800, 7801, 7802, 7995], 'Online gaming and gambling earn no monies.'),
      X('slice-excl-insurance', 'insurance', [5960, 6300, 6381, 3429, 6529], 'Insurance earns no monies.'),
      X('slice-excl-finance', 'excluded_spend', [6012, 6541, 6051, 820, 821, 822, 823, 824, 825, 763, 780, 5260], 'Financial institutions, quasi-cash and agriculture earn no monies.'),
      X('slice-excl-cash', 'cash_withdrawal', [6010], 'Cash withdrawal earns no monies.'),
      X('slice-excl-emi', 'emi', [], 'Transactions converted to EMI ("sliced") earn no monies.'),
      X('slice-excl-international', 'international_spend', [], 'International transactions earn no monies.'),
      R({ id: 'slice-monies-1', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, reason: '1 monies per ₹1 spent on eligible transactions on the slice credit card, directly or via UPI. Value depends on the redemption slab, from 1% to 3%.' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.5, annual_interest_rate_percent: 42 },
      forex_markup: { markup_percent: 0, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 0, gst_applicable: true, trigger_condition: 'MITC: DCC mark-up ₹0' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 2, waiver_percent: 0, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
      category_surcharges: [
        { category_id: 'fuel', mcc_list: [5541, 5542, 5983, 5172], fee_percent: 2, gst_applicable: true, trigger_condition: '2% (minimum ₹10) when cumulative fuel spend in a statement cycle exceeds ₹25,000', threshold_spend_inr: 25000, effective_from: null, effective_to: null },
        { category_id: 'utility', mcc_list: [4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (minimum ₹10) on utility spend above ₹25,000', threshold_spend_inr: 25000, effective_from: null, effective_to: null },
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (minimum ₹10) on rent spend above ₹10,000', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
        { category_id: 'education_third_party', mcc_list: [8211, 8220, 8241, 8244, 8249, 8299], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (minimum ₹10) on education payments via third-party apps', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'wallet_load', mcc_list: [6539, 6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (minimum ₹10) on wallet loading', threshold_spend_inr: null, effective_from: null, effective_to: null },
      ],
      emi_charges: { merchant_instant_emi_processing_fee_inr: 0, post_purchase_emi_processing_fee_inr: 0, foreclosure_charge_percent: 3.5, gst_applicable: true },
    },
    statement_and_late_fees: { late_payment_slabs: [
      { min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 500 }, { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 600 },
      { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 900 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
    ] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No joining or annual fee (MITC). slice reserves the right to levy renewal fees on card renewal.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    redemption_matrix: { direct_options: [
      { channel: 'Cash to slice savings account, monies balance up to ₹3,00,000', redemption_type: 'cashback', inr_value_per_point: 0.01, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      { channel: 'Cash to slice savings account, balance ₹3,00,001 to ₹5,00,000', redemption_type: 'cashback', inr_value_per_point: 0.015, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      { channel: 'Cash to slice savings account, balance above ₹5,00,000', redemption_type: 'cashback', inr_value_per_point: 0.02, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
    ], partner_transfers: [] },
    additional_data: { items: prov({
      sources: [
        { url: 'https://slice.bank.in/cc-mitc/', kind: 'slice credit card MITC (fees, finance charges, late fee, monies, exclusion MCCs)', read: 'rendered page text' },
        { url: 'https://slice.bank.in/credit-card', kind: 'product page ("upto 3% cashback", zero joining, annual and forex charges)', read: 'rendered page text' },
      ],
      unverified: [
        'Network (settled 2026-11-07, W6): RuPay. The slice MITC page (https://slice.bank.in/cc-mitc/) section (iv) Statement disputes resolution names "the respective card network (Rupay)" and section J Tap/Scan and Pay says "The scan and pay feature is exclusively available on RuPay credit cards"; no other network is named anywhere on the MITC or on https://slice.bank.in/credit-card, and the card art shows no network logo. A person may still want to confirm RuPay tier (the MITC states none).',
        'The page headline "up to 3% cashback" is the top redemption slab, which needs a ₹5,00,000 monies balance AND a ₹5,00,000 average quarterly savings balance. The base is 1%.',
        'The MITC page shows no revision date; the page was read on 2026-11-07.',
        '"Slice Super Card" is an alias of this product, not a second card.',
        'The fuel row says "2% (min ₹10) on spends above ₹25,000" in one place and applies it to cumulative statement-cycle spend in another; the cycle reading is used.',
      ],
      notes: ['Bank transfer from the credit limit: 2.5% fee (minimum ₹25) plus GST (not in the universal schema).', 'monies are forfeited if the card is closed or inactive for a continuous year.'],
    }) },
  },

  // ───────────────────────────────────────────── OneCard (SBM)
  'sbm-bank-india-onecard-metal': {
    card_product: { ...GST, card_type: 'credit', network: 'visa', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: null, form_factors: ['virtual_card', 'physical_plastic', 'physical_metal'], data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.sbm.bank.in/personal-banking/cards/secured-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'No SBM document states what one OneCard reward point is worth: the Cardholder Agreement says points repay earlier purchases ("Pay with points") or are redeemed for offers in the OneCard app, and the bank may change the conversion rate. Points do not expire unless the card is unused for 365 days.', point_expiry_months: 0 },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'SBM MITC (29 Oct 2026): secured card against a fixed deposit of at least ₹5,000 (or as decided by the Bank) opened in the OneCard app in a single name; the FD is liened and auto-renews. A metal card is issued for a cumulative FD above ₹50,000 or as decided by the Bank; the FD can be topped up 9 times in the app.', rules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 5000, allowed_values: [] }], required_documents: [] },
    accrual_engine: { base_block_inr: 50, rounding_mode: 'N/A', base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('onecard-excl-transfers', 'excluded_spend', [], 'Money transfers earn no reward points (Cardholder Agreement clause 20, Earn Reward Points b).'),
      X('onecard-excl-rent', 'rent', [6513], 'Rent payments earn no reward points (clause 20 I.b).'),
      X('onecard-excl-fuel', 'fuel', [5541, 5542], 'Fuel purchases earn no reward points (clauses 8.7 and 20 I.b; MCCs assumed, the text names fuel without codes).'),
      X('onecard-excl-cash', 'cash_withdrawal', [6010, 6011], 'Cash withdrawals earn no reward points (clause 20 I.b).'),
      X('onecard-excl-wallet', 'wallet_load', [6540], 'Digital wallet loading and top-up earn no reward points (clause 20 I.b).'),
      R({ id: 'onecard-excl-bills-utilities', cat: 'utility', pri: 2, type: 'exclusion', mult: 0, from: '2026-07-30', reason: 'Effective 30 Jul 2026 reward points no longer accrue for bills and utilities, and these are ineligible for 5X (clause 20 I.b).' }),
      R({ id: 'onecard-5x-top-2-categories', cat: 'all_retail', pri: 10, ppb: 5, mult: 5, cond: { top_categories_in_month: 2, minimum_categories_in_month: 3, minimum_spend_per_category_inr: 750, bonus_credited: '10th of the following month' }, reason: '5X rewards (5 points per ₹50) on the top 2 spend categories of the month, only when the month has purchases in at least 3 categories with at least ₹750 in each of the 3 (clause 20 I.e). Bonus points are credited on the 10th of the next month.' }),
      R({ id: 'onecard-base-1-per-50', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 50, fractional_points_below_block: true }, reason: '1 reward point on every ₹50 of regular purchases across any category; below ₹50 fractional points are credited (₹25 earns 0.5 point) (clause 20 I.c-d; SBM reward details).' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 1, gst_applicable: true },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: 400 },
      category_surcharges: [
        { category_id: 'rent', mcc_list: [6513], fee_percent: 2, gst_applicable: true, trigger_condition: '2% on rent paid at third-party apps and merchants, over and above their convenience fee (SBM MITC 29 Oct 2026; the KFS w.e.f. 29 Jun 2026 and the Cardholder Agreement of 30 Jun 2026 say 1%)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'wallet_load', mcc_list: [6540], fee_percent: 2, gst_applicable: true, trigger_condition: '2% on the full amount of fund transfers to wallets or bank accounts once monthly transfers exceed ₹10,000 (SBM MITC 29 Oct 2026; the KFS and Cardholder Agreement say 1%)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
      ],
      banking_penalties: { overlimit_charge: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
      reward_redemption_fee: { fee_inr: 0, gst_applicable: null },
    },
    statement_and_late_fees: { grace_period_days: 48, grace_period_void_on_revolving_balance: null, late_payment_slabs: [
      { min_balance_inr: 0, max_balance_inr: 250, fee_inr: 0 }, { min_balance_inr: 251, max_balance_inr: 1000, fee_inr: 250 }, { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 500 }, { min_balance_inr: 5001, max_balance_inr: 25000, fee_inr: 1000 }, { min_balance_inr: 25001, max_balance_inr: null, fee_inr: 1250 },
    ] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Joining, annual and primary issuance fees are Nil. The metal card costs ₹3,000 as an add-on issuance and ₹3,000 if cancelled within 6 months of virtual card activation (MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 3000, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.sbm.bank.in/personal-banking/cards/secured-credit-card', kind: 'SBM secured credit card page (read 7 Nov 2026): lists "SBM OneCard Credit Card" with KFS, T&C, Cardholder Agreement and Reward Points links, so the card is still sold; card image consumer-onecard.webp shows a Visa Signature card', read: 'page text; card image viewed' },
        { url: 'https://www.sbm.bank.in/pdf/notice-board/SBM-one-card-MITC.pdf', kind: 'SBM OneCard MITC, 32 pages (SBM file dated 29 Oct 2026): fees (rent 2%, fund transfer 2%), FD minimum ₹5,000, metal card for cumulative FD above ₹50,000, RuPay floater card earns no rewards', read: 'pdftotext' },
        { url: 'https://www.sbm.bank.in/pdf/kfs/One-Card-KFS.pdf', kind: 'SBM One co-branded Credit Card KFS, w.e.f. 29 Jun 2026 (SBM file dated 12 Oct 2026): fees, interest, late fee, metal card fees', read: 'pdftotext' },
        { url: 'https://www.sbm.bank.in/pdf/notice-board/Card-Holder-Agreement-SBM-One-Credit-Card.pdf', kind: 'SBM One co-branded Credit Card Cardholder Agreement, 28 pages (SBM file dated 30 Jun 2026): clause 20 reward earn rules and exclusions, clause 8.7 fuel waiver, Visa acceptance and Visa exchange rate wording', read: 'pdftotext' },
        { url: 'https://www.sbm.bank.in/pdf/notice-board/RP-details.pdf', kind: 'SBM OneCard reward point details, 1 page (PDF created 20 Feb 2024, SBM file dated 12 May 2026): 1 point per ₹50, 5X on top 2 categories', read: 'pdftotext' },
        { url: 'https://assets.getonecard.app/assets/legal/SBM_MITC_English_Sep2025.pdf', kind: 'Earlier read: SBM One co-branded credit card MITC on the partner site (file dated Sep 2025); superseded by the SBM-hosted documents above', read: 'pdftotext' },
      ],
      unverified: [
        'Point value: no SBM document states what one OneCard reward point is worth, so point_value_inr_baseline is null and the earn rate (1 point per ₹50, 5X on the top 2 categories) cannot be turned into a percentage return.',
        'Reward clause conflict: clause 20 I.b says bills and utilities earn nothing from 30 Jul 2026 and are ineligible for 5X, while clause 20 III.i still talks about 5X on Education, Bills & Utilities and Insurance with incremental rewards capped at 25,000 points. The cap period is not stated, so no cap rule is written and the bills exclusion is modelled.',
        'The 5X rule depends on the cardholder\'s monthly mix of categories, which a ranking engine cannot see; modelled as stated with the ₹750 per-category minimum.',
        'Network: Visa for the physical card (the Cardholder Agreement says it is acceptable where Visa is accepted and converts foreign spends at Visa rates; the page card image shows Visa Signature). The virtual card is "VISA/RuPay powered" and a RuPay floater card exists but earns no rewards. SBM does not publish a separate metal card image or state that the metal card uses a different network.',
        'Fee conflict: the KFS (w.e.f. 29 Jun 2026) and Cardholder Agreement (30 Jun 2026) say rent and wallet/fund-transfer fees are 1%; the MITC (29 Oct 2026, later) says 2%. 2% is used. The over limit fee is 0 in the KFS and MITC; the older partner-hosted MITC had a 2.5% fee.',
        'OneCard has several issuing banks; this record is the SBM variant only. Do not merge another issuer\'s terms.',
        'The OneCard marketing page says "lifetime free"; the SBM KFS adds metal-card charges (₹3,000 add-on issuance, replacement and 6-month cancellation), so a blanket no-fee statement is wrong.',
        'Is the metal card sold: yes as a tier of the SBM secured OneCard. SBM\'s MITC says a metal card is issued to cardholders with a cumulative FD above ₹50,000 or as decided by the Bank; there is no separate application or product page for it on SBM\'s site.',
      ],
      notes: ['Interest-free period up to 48 days; finance charge 3.75% a month (45% a year). Forex mark-up 1%. Fuel waiver 1% capped at ₹400 a month.', 'Card replacement: first plastic card nil, second ₹145, third onward ₹500, metal ₹3,000.'],
    }) },
  },

  // ───────────────────────────────────────────── Federal Scapia
  'federal-bank-scapia-credit-card': {
    card_product: { ...GST, card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.federal.bank.in/scapia', status: 'draft', verified_at: null, point_value_inr_baseline: 0.2, point_value_baseline_basis: 'Federal Bank product page https://www.federal.bank.in/scapia (read 2026-11-07): "1 reward = 1 Scapia Coin" with the footnote "5 Scapia coins = ₹1", so one reward/coin is ₹0.20. The Federal Cardholder Agreement itself gives the 1 reward = 1 coin ratio but no rupee value; the Axis and BOBCARD Scapia terms agree on 5 coins = ₹1. The coin value is set by Scapia and can change.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 10, base_cashback_percent: 'N/A', effective_base_return_percent: 2, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('fscapia-excl', 'excluded_spend', [], 'Money transfers, rent, cash withdrawals, EMI transactions, forex transactions, education and school fees, utility, telecom and cable spends earn nothing (Cardholder Agreement, Earn Rewards b).'),
      R({ id: 'fscapia-travel-20', cat: 'travel', pri: 5, ppb: 20, mult: 20, channel: 'scapia_app', cond: { platform: 'Scapia app', purchases: 'travel' }, reason: '20% rewards on travel purchases made on the Scapia app (Agreement e).' }),
      R({ id: 'fscapia-visa-10', cat: 'all_retail', pri: 20, type: 'standard_accrual', ppb: 10, mult: 10, cond: { variant: 'Visa', minimum_transaction_inr: 20 }, reason: '10% rewards on every purchase of ₹20 and above on the Visa card (Agreement d).' }),
      R({ id: 'fscapia-rupay-5', cat: 'all_retail', pri: 21, type: 'standard_accrual', ppb: 5, mult: 5, cond: { variant: 'RuPay', minimum_transaction_inr: 500 }, reason: '5% rewards on eligible spends of more than ₹500 on the RuPay card (Agreement d).' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 0, gst_applicable: null },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 10 },
      category_surcharges: [
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on rent, max ₹3,000 per transaction (MITC row 18)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'wallet', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on wallet load, max ₹3,000 per transaction (MITC row 18)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: 'Fuel spends over ₹50,000 in a month: 1% + GST convenience fee, max ₹3,000 per transaction (MITC row 16)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
        { category_id: 'bills', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: 'Utility spends over ₹50,000 in a month: 1% + GST convenience fee, max ₹3,000 per transaction (MITC row 17)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
      ],
      emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 99, foreclosure_charge_percent: 2, gst_applicable: true },
      banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
      reward_redemption_fee: { fee_inr: 0, gst_applicable: null },
    },
    statement_and_late_fees: {
      late_payment_slabs: [
        { min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }, { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 500 },
        { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 600 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 750 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 950 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1000 },
      ],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No joining or annual fee: Nil in the Scapia Federal MITC (version 10, 27 Feb 2026, rows 3 and 4) and in the Federal Bank schedule of charges (file dated Feb 2026); the Federal page says "Zero joining and annual fees".', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    additional_data: { items: [
      dualNetwork({
        sourceUrl: 'https://www.federal.bank.in/documents/d/guest/cardholder_agreement-v11-30_04_26',
        evidence: 'Federal Scapia Cardholder Agreement (v11, 30 Apr 2026) describes a Scapia Federal Visa card and a Scapia Federal RuPay card on one account with different earn rates.',
        variants: [
          { network: 'visa', network_tier: 'N/A', label: 'Scapia Federal Credit Card (Visa)', source_url: 'https://www.federal.bank.in/documents/d/guest/cardholder_agreement-v11-30_04_26', evidence: 'Agreement d: 10% rewards on purchases of ₹20 and above.' },
          { network: 'rupay', network_tier: 'N/A', label: 'Scapia Federal Credit Card (RuPay)', source_url: 'https://www.federal.bank.in/documents/d/guest/cardholder_agreement-v11-30_04_26', evidence: 'Agreement d: 5% rewards on eligible spends of more than ₹500.' },
        ],
      }),
      ...prov({
        sources: [
          { url: 'https://www.federal.bank.in/documents/d/guest/cardholder_agreement-v11-30_04_26', kind: 'Scapia Federal Credit Card Cardholder Agreement v11, 30 Apr 2026, 73 pages (earn rewards, zero forex)', read: 'pdftotext' },
          { url: 'https://www.federal.bank.in/documents/d/guest/mitc-v10-27_02_26', kind: 'Scapia Federal Credit Card MITC, "Version (10) 27.02.2026", 27 pages (joining/annual Nil, APR 45%, forex 0%, late fee slabs, fuel waiver, cash advance, EMI)', date: '2026-02-27', read: 'pdftotext' },
          { url: 'https://www.federal.bank.in/documents/d/guest/credit-card-charges', kind: 'Federal Bank schedule of charges for credit cards, section 4 "Scapia Credit Card" (file dated Feb 2026): joining/annual Nil, forex Nil, APR 45% (3.75% a month)', read: 'pdftotext' },
          { url: 'https://www.federal.bank.in/scapia', kind: 'Federal Scapia product page: "Zero joining and annual fees", "Zero forex markup", 10% rewards on VISA, 5% on RuPay spends of Rs 500 or more, 5 Scapia coins = Rs 1', read: 'rendered page text in built-in browser' },
        ],
        unverified: [
          'Fee and interest figures (joining Nil, annual Nil, APR 45% a year / 3.75% a month, forex 0%, late fee slabs, fuel waiver max ₹500 a month) come from MITC version 10 dated 27 Feb 2026 and the Feb 2026 schedule of charges, and agree with the live product page. The Federal page now links MITC v11 (30 Apr 2026), but that PDF sits behind a bot check and was not opened; a person should confirm v11 did not change fees or the interest rate.',
          'Earn rules were read from Cardholder Agreement v11 (30 Apr 2026). The Federal page now links Agreement v14 (23 Oct 2026) and v13 (20 Jun 2026), which were not read; check whether the 10% (Visa) and 5% (RuPay, above ₹500) rates, the exclusions and the ₹20,000 monthly spend condition for airport privileges still hold. The product page text still shows 10% on VISA and 5% on RuPay of Rs 500 or more.',
          'Lounge access and other benefits: the page says unlimited domestic lounge, dining, shopping or spa on spending ₹20,000 every preceding month; the benefit quota and exact conditions are in the Agreement and were not modelled.',
          'Interest: the Federal charges schedule says the APR on other Federal cards moves with average balance; for Scapia it states a flat 45% (3.75% a month).',
          'The older partner material that mentioned zero fees could not be matched to a Federal Bank document; the zero fees are now confirmed by the MITC, the schedule of charges and the Federal page.',
          'Post-purchase EMI interest is 14% to 20% a year; in-store EMI 16% (Pinelabs) and 15.99% (PayU). Merchant instant EMI processing fee is left null because the MITC gives ₹99 for in-store and 1% or ₹99 for online platforms.',
        ],
        notes: ['The headline "10% / 5% / 20% rewards" are Scapia-coin percentages; at 5 coins = ₹1 (Federal page footnote, also the Axis and BOBCARD terms) the value is about 2% (Visa), 1% (RuPay) and 4% (20% travel on the Scapia app).', 'Zero forex mark-up (Agreement Benefits 2; MITC row 22).'],
      }),
    ] },
  },

  // ───────────────────────────────────────────── Jupiter Edge+ CSB RuPay
  'csb-bank-jupiter-edge-plus-rupay': {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 999, annual_fee_inr: 0, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.csb.bank.in/csb-bank-edge-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: 0.14, point_value_baseline_basis: 'CSB-hosted Edge/Edge+ T&C (PDF created 5 Sep 2026), Redemption Slabs: 1 Jewel = ₹0.20 when redeemed for Jupiter Flights, Jupiter Store, Brand Vouchers or Digital Gold; 1 Jewel = ₹0.14 for Statement Credit, Bill Payments or Cash/Cash-equivalent. Baseline uses the lower, cash-equivalent value. Jupiter or the bank may change the rates; the app shows the rate at redemption. Jewels do not expire except after 365 days of card inactivity or 90 days of unpaid dues.', point_expiry_months: null },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 5, base_cashback_percent: 'N/A', effective_base_return_percent: 0.7, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('csb-edge-plus-excl-fuel', 'fuel', [5983, 5172, 5542, 5541], 'Fuel earns no Jewels (T&C Rewards Programme, ineligible MCC list).'),
      X('csb-edge-plus-excl-government', 'government', [9211, 9222, 9223, 9311, 9399], 'Government-related transactions, fines, tax and court payments earn no Jewels.'),
      X('csb-edge-plus-excl-rent', 'rent', [6513], 'Rent payments earn no Jewels.'),
      X('csb-edge-plus-excl-utility', 'bills', [4900, 4814, 4816, 4899], 'Utility bill payments (electricity, gas, telecom, cable and similar) earn no Jewels.'),
      X('csb-edge-plus-excl-wallet', 'wallet', [6540], 'Wallet loads, gift or prepaid card loads and voucher purchases earn no Jewels.'),
      X('csb-edge-plus-excl-cash', 'other', [6010, 6011, 6051, 4829], 'Cash advances, quasi-cash and wire transfers earn no Jewels.'),
      X('csb-edge-plus-excl-insurance', 'insurance', [6381, 6300], 'Insurance premiums and sales earn no Jewels.'),
      X('csb-edge-plus-excl-emi', 'emi', [], 'All types of EMI transactions (EasyEMI, SmartEMI, Dial-an-EMI and similar), payment of outstanding balances and card fees and charges earn no Jewels.'),
      X('csb-edge-plus-excl-other-mcc', 'other', [5816, 5933, 5935, 6012, 6211, 7995, 7800, 7801, 7802, 8651, 8661, 7276, 7322, 4784, 8111, 8351, 8398, 8641, 5817, 7273, 7994, 8931], 'Digital games, pawn shops, salvage yards, financial institutions, brokers, gambling and lotteries, political and religious organisations, tax preparation, debt collection, tolls, legal, child-care, charity, associations, digital apps, dating, arcades and accounting earn no Jewels (T&C MCC table).'),
      R({ id: 'csb-edge-plus-shopping-50', cat: 'online', rail: 'upi_qr', channel: 'jupiter_upi_app', pri: 5, ppb: 50, mult: 10, cap: 'csb-edge-plus-shopping-category-cap', from: '2026-10-05', cond: { brands: ['Amazon', 'Flipkart', 'Myntra', 'Tata Cliq', 'Ajio', 'Nykaa', 'Croma', 'Reliance Digital', 'Trent Retail / Tata Retail', 'Reliance Retail'], platform: 'Jupiter UPI app only (UPI Intent, Scan and Pay, UPI Collect)', cycle_statement_spend_gt_inr: 15000, jewels_per_inr_100_if_threshold_missed: 5, instant_jewels_per_inr_100: 5, remaining_jewels_credited_at_cycle_end_per_inr_100: 45, transaction_level_cap_jewels: 1000 }, reason: '50% Jewels (50 per ₹100) on the listed shopping brands from 5 Oct 2026, only when that billing cycle\'s qualified spend exceeds ₹15,000; otherwise 5% (5 per ₹100). 5% is credited instantly, the other 45% at cycle end and cancelled if cycle spend is ₹15,000 or less (T&C Edge+ rewards structure).' }),
      R({ id: 'csb-edge-plus-travel-25', cat: 'travel', rail: 'upi_qr', channel: 'jupiter_upi_app', pri: 6, ppb: 25, mult: 5, from: '2026-10-05', cond: { brands: ['Jupiter Flights'], platform: 'Jupiter UPI app only' }, reason: '25% Jewels (25 per ₹100) on flights booked through Jupiter Flights; no maximum is listed from 5 Oct 2026 (5,000 Jewels per cycle applied until 4 Oct 2026) (T&C).' }),
      R({ id: 'csb-edge-plus-others-5', cat: 'all_retail', rail: 'upi_qr', channel: 'jupiter_upi_app', pri: 30, type: 'standard_accrual', ppb: 5, mult: 1, cond: { platform: 'Jupiter UPI app only (UPI Intent, Scan and Pay, UPI Collect)', applies_to: 'every eligible spend outside the shopping and travel brands, including other categories at those brands' }, reason: '5% Jewels (5 per ₹100) on all other eligible spends (T&C category "Others"). T&C 3a limits Jewel earning to transactions on the Jupiter UPI app.' }),
    ],
    cap_rules: [
      C({ id: 'csb-edge-plus-shopping-category-cap', cat: 'online', metric: 'total_reward_points', period: 'statement_cycle', points: 10000, after: 'downgrade_to_base_rate', afterPpb: 5 }),
      C({ id: 'csb-edge-plus-shopping-merchant-cap', cat: 'online', metric: 'total_reward_points', period: 'statement_cycle', points: 3000, after: 'downgrade_to_base_rate', afterPpb: 5, parent: 'csb-edge-plus-shopping-category-cap' }),
    ],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 3.5, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 1, gst_applicable: true, trigger_condition: 'MITC: 1.0% on every DCC transaction' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 3000, monthly_waiver_cap_inr: null },
      category_surcharges: [
        { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fuel transaction fee on the amount above ₹10,000, or on monthly fuel spends above ₹50,000 when higher', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction amount, minimum fee ₹149', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'wallet_load', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction amount on wallet top-ups', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'education_third_party', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction amount on education payments made on third-party websites or apps', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'utility', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction amount on utility payments above ₹20,000 or when monthly spends are above ₹50,000', threshold_spend_inr: 20000, effective_from: null, effective_to: null },
      ],
      emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 99, foreclosure_charge_percent: 3, gst_applicable: true },
      banking_penalties: { overlimit_charge: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, auto_debit_bounce_charge_inr: 0, cheque_bounce_charge_inr: null },
    },
    statement_and_late_fees: { grace_period_days: null, grace_period_void_on_revolving_balance: null, minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['All outstanding EMI instalments due in the cycle (principal, interest, taxes, processing fee)', '100% of interest', '100% of charges and fees', '100% of government taxes', '2% of fresh principal outstanding', 'Entire unpaid minimum amount due of earlier cycles', 'If the result is below ₹500 the minimum amount due is ₹500; if the total amount due is below ₹500 it equals the total amount due (KFS and T&C)'] }, late_payment_slabs: [] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Annual membership fee is Nil; Edge+ RuPay joining fee ₹999 one time (MITC uploaded 30 Oct 2026). The CSB product page advertises ₹499 joining fee "for first 2 lakh users".', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    additional_data: { items: [
      { key: 'late_payment_fee_rule', value: { rule: '5% of the outstanding amount due, minimum ₹250, maximum ₹2,000', source: 'CSB Edge / Edge+ MITC (updated 25 Aug 2026, uploaded 30 Oct 2026) and KFS (5 Nov 2025)' } },
      ...prov({
        sources: [
          { url: 'https://www.csb.bank.in/csb-bank-edge-credit-card', kind: 'CSB Bank product page "Edge+ CSB Bank RuPay Credit Card" (live with Apply now; read 2026-11-07): headline 10% / 5% / 1% cashback, ₹499 joining fee for first 2 lakh users', read: 'rendered page text' },
          { url: 'https://www.csb.bank.in/pdf/edge-csb-bank-ruPay-credit-card-mitc_2025.pdf', kind: 'Edge CSB / Edge+ CSB RuPay / Edge+ CSB Mastercard MITC, updated 25 Aug 2026, fees applicable from 7 Sep 2026, uploaded 30 Oct 2026 (25 pages)', read: 'pdftotext' },
          { url: 'https://www.csb.bank.in/pdf/edge_csb_bank_credit_card_terms_and_conditions_2025.pdf', kind: 'Edge CSB / Edge+ CSB T&C (PDF created 5 Sep 2026): Jewel earn rates, caps, redemption slabs, ineligible MCC list', read: 'pdftotext' },
          { url: 'https://www.csb.bank.in/pdf/key_fact_statement_edge_csb_bank_credit_card_2025.pdf', kind: 'Edge CSB / Edge+ CSB KFS updated 5 Nov 2025, charges from 6 Dec 2025 (agrees with the MITC on fees)', read: 'pdftotext' },
        ],
        unverified: [
          'Earn only on the Jupiter UPI app: T&C 3a says the Edge+ RuPay card earns Jewels "only for transactions on the Jupiter UPI App" (UPI Intent, Scan and Pay, UPI Collect) and not on other UPI apps. The CSB page headline says 1% cashback on "all online & offline spends". The three rules are written for Jupiter UPI only; whether card swipe or online card spends earn anything needs a person.',
          'Jewel value: ₹0.20 each for Jupiter Flights, Jupiter Store, Brand Vouchers and Digital Gold; ₹0.14 each for statement credit, bill payments and cash. Baseline uses ₹0.14 (0.7% on the 5-Jewel base rate). At ₹0.20 the T&C rates equal the page headline 10% shopping, 5% travel and 1% other.',
          'Rates changed on 5 Oct 2026: the T&C lists the structure to 4 Oct 2026 (shopping 50% Jewels always, travel capped at 5,000 Jewels per cycle) and from 5 Oct 2026 (shopping 50% only when cycle spend is above ₹15,000, else 5%; travel uncapped). Only the current structure is modelled.',
          'Shopping merchant cap 3,000 Jewels and transaction-level cap 1,000 Jewels per statement cycle are in the T&C; the schema has no per-transaction period, so the 1,000 sits in the rule conditions and only the 10,000 category cap and 3,000 merchant cap are cap rows. What earns after a cap is hit is not stated; downgrade to the 5-Jewel rate is assumed.',
          'Joining fee: ₹999 + GST in the MITC and KFS; the CSB page says ₹499 for the first 2 lakh users. ₹999 is used.',
          'Fuel surcharge waiver: 1% with a maximum of ₹100, on spends of ₹400 to ₹3,000 (MITC footnote); the period for the ₹100 maximum is not stated, so monthly_waiver_cap_inr is null. The page-level surcharge is ₹10 up to ₹400 and 1% above.',
          'Insurance and concierge benefit (personal accident and total permanent disability up to ₹2 lakh, 24/7 concierge) is "limited to Platinum Variant Card (BIN 653038)"; whether Edge+ RuPay is that BIN is not stated, so it is not modelled.',
          'The MITC covers three cards (Edge CSB RuPay joining nil; Edge+ CSB RuPay ₹999; Edge+ CSB Mastercard ₹999 with nil forex). This draft is the Edge+ RuPay card only. The non-plus Edge card (flat 2% Jewels, ₹250 welcome voucher) is a separate product not in the catalogue.',
          'Rounding mode and the Jewel crediting delay are not stated. Minimum redemption threshold is shown in the Jupiter app, not in the documents.',
        ],
        notes: ['Card replacement ₹249. Interest 3.75% a month (45% a year), interest-free period 13 to 47 days. EMI processing ₹99 or 1% of the converted amount, whichever is higher; foreclosure 3% of remaining principal. Overlimit transactions are not allowed. Jewels earned in a cycle are locked and earning pauses while the minimum amount due is unpaid.', 'Held in the earlier pass for lack of a reward rate; the rates are now stated in the CSB-hosted T&C, so the card can be imported once the open questions above are cleared.'],
      }),
    ] },
  },

  // ───────────────────────────────────────────── CRED IndusInd RuPay
  'indusind-bank-cred-rupay': {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 499, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.indusind.bank.in/content/dam/indusind-corporate/credit-cards/MITC_Premium.pdf', status: 'draft', verified_at: null, point_value_inr_baseline: 0.5, point_value_baseline_basis: 'CRED Section Z Part II 5.1, re-read 2026-11-07 (page "Last updated on 28 October 2026"): 1 CRED Reward Point = ₹1 on flights, hotels, CRED Store and select CRED Pay partner merchants; ₹0.50 on utility and credit-card bill payments made in the CRED app. The IndusInd launch press release (15 Sep 2025) also says every point is equivalent to a rupee on the main redemption routes. Baseline uses the lower value. Redemption is a CRED programme term, not an IndusInd Bank term.', point_expiry_months: 24 },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'CRED Section Z: at least 18, resident of India, existing CRED user, active CRED membership throughout, bank creditworthiness checks.', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 18, allowed_values: [] }, { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] }, { parameter: 'cred_member', operator: '==', threshold_value: 1, allowed_values: [] }], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: 'round', base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('cred-excl-fuel', 'fuel', [5983, 5172, 5542, 5541], 'Fuel earns no points (Section Z 3.1).'),
      X('cred-excl-education', 'education', [5111, 5192, 5943, 8211, 8220, 8241, 8244, 8249, 8299, 8351], 'Education earns no points.'),
      X('cred-excl-government', 'government', [9211, 9222, 9232, 9311, 9399, 9402, 8931], 'Government institutions, services and charges earn no points.'),
      X('cred-excl-wallet', 'wallet_load', [6540, 6538, 8999, 6541], 'Wallet loads and prepaid instruments earn no points.'),
      X('cred-excl-rent', 'rent', [6513, 6012, 6051], 'Rent payments earn no points.'),
      X('cred-excl-gold', 'excluded_spend', [5412], 'Digital gold earns no points (Section Z 3.1).'),
      X('cred-excl-tolls', 'excluded_spend', [9399, 4784], 'FASTag, tolls, road and bridge fees earn no points (Section Z 3.1, read in full 2026-11-07).'),
      X('cred-excl-cbdc', 'excluded_spend', [7411], 'CBDC earns no points (Section Z 3.1).'),
      X('cred-excl-jewellery', 'excluded_spend', [5944, 5094, 5051], 'Jewellery purchases earn no points (Section Z 3.1).'),
      X('cred-excl-cash-forex', 'cash_withdrawal', [6010, 6011, 6012, 6051], 'Forex retail and quasi-cash transactions earn no points (Section Z 3.1).'),
      X('cred-excl-emi', 'emi', [], 'Transactions converted to EMI (at the time of transaction or later), cash advances and withdrawals, loan payments, balance transfers and bank fees and charges earn no points (Section Z 3.1 c).'),
      R({ id: 'cred-5pct-online', cat: 'online', rail: 'online', pri: 10, ppb: 5, mult: 5, cap: 'cred-5pct-cap', cond: { minimum_transaction_inr: 100, includes: ['online spends (e-commerce)', 'CRED Flights and Hotels', 'CRED Store', 'select CRED Pay', 'gift cards on the CRED app', 'online UPI through the CRED app'] }, reason: '5% rewards = 5 CRED points per ₹100 on online spends and listed in-app transactions; capped at 5,000 points per billing cycle.' }),
      R({ id: 'cred-upi-scan-1pct', cat: 'upi', rail: 'upi_qr', pri: 15, ppb: 1, mult: 1, channel: 'cred_app', cap: 'cred-scan-pay-cap', cond: { minimum_transaction_inr: 100, platform: 'CRED app Scan and Pay' }, reason: '1% = 1 CRED point per ₹100 on Scan and Pay UPI through the CRED app; capped at 500 points per billing cycle.' }),
      R({ id: 'cred-1pct-other', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { minimum_transaction_inr: 100, includes: ['insurance and utility payments via the CRED app', 'travel outside the CRED app', 'gift cards outside the CRED app', 'international transactions', 'all other eligible spends'] }, reason: '1% = 1 CRED point per ₹100 on everything else not excluded.' }),
    ],
    cap_rules: [
      C({ id: 'cred-5pct-cap', cat: 'online', metric: 'total_reward_points', period: 'statement_cycle', points: 5000, after: 'downgrade_to_base_rate', afterPpb: 1 }),
      C({ id: 'cred-scan-pay-cap', cat: 'upi', metric: 'total_reward_points', period: 'statement_cycle', points: 500, after: 'zero_accrual' }),
    ],
    redemption_matrix: { direct_options: [
      { channel: 'CRED app: flight bookings', redemption_type: 'flight_hotel_booking', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 70, min_points_per_txn: 1, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      { channel: 'CRED app: hotel bookings', redemption_type: 'flight_hotel_booking', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 70, min_points_per_txn: 1, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      { channel: 'CRED Store purchases and select CRED Pay partner merchants', redemption_type: 'partner_catalogue', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 70, min_points_per_txn: 1, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      { channel: 'Utility and credit card bill payments made within the CRED app', redemption_type: 'other', inr_value_per_point: 0.5, max_bill_percentage_payable_via_points: 100, min_points_per_txn: 1, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
    ], partner_transfers: [] },
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.95, annual_interest_rate_percent: 47.4 },
      forex_markup: { markup_percent: 3.5, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 2, gst_applicable: true, trigger_condition: 'Effective 15 June 2026: 2% + GST on INR transactions made at an international location or at merchants in India registered overseas (1% until 14 June 2026); CRED IndusInd Bank RuPay Credit Card is named in the 2% list (MITC, DCC row).' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 300, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
      category_surcharges: [
        { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: 'Effective 15 June 2026: 1% + GST on cumulative fuel transactions above ₹30,000 in a statement cycle; CRED IndusInd Bank RuPay is in the ₹30,000 group (MITC, Fuel Transactions)', threshold_spend_inr: 30000, effective_from: '2026-06-15', effective_to: null },
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on each rent payment through third-party merchants; the exemption list does not name this card (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'bills', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on cumulative utility payments above ₹25,000 in a statement cycle (MITC)', threshold_spend_inr: 25000, effective_from: null, effective_to: null },
        { category_id: 'wallet', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on cumulative wallet loading above ₹20,000 in a statement cycle (MITC)', threshold_spend_inr: 20000, effective_from: null, effective_to: null },
        { category_id: 'education', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on cumulative education payments through third-party websites and apps above ₹45,000 in a statement cycle (MITC)', threshold_spend_inr: 45000, effective_from: null, effective_to: null },
        { category_id: 'travel', mcc_list: [4111, 4112, 4784, 4131], fee_percent: 1, gst_applicable: true, trigger_condition: 'Effective 15 June 2026: 1% + GST on cumulative transport spends (MCCs 4111, 4112, 4784, 4131) above ₹40,000 in a statement cycle (MITC, Transaction fees on Transport)', threshold_spend_inr: 40000, effective_from: '2026-06-15', effective_to: null },
      ],
      banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
      reward_redemption_fee: { fee_inr: 0, gst_applicable: null },
    },
    statement_and_late_fees: {
      late_payment_slabs: [
        { min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 500 },
        { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 600 }, { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 900 },
        { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
      ],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'IndusInd MITC fee table (file "MITC-Premium Card Consolidated_13.10.2026"): joining fee NIL, annual fee ₹499 with waiver condition "NA", add-on card fee NIL. Footnote: the annual fee is not applicable for targeted "Lifetime Free" limited-time promotions. The MITC header says actual fees are conveyed at the time of application.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: 18 },
    lifestyle_and_network_benefits: [],
    additional_data: { items: prov({
      sources: [
        { url: 'https://cred.club/terms', kind: 'CRED terms, Section Z Part II Rewards (earn rates, cap, exclusions, redemption values, 70% limit, 2-year expiry), page "Last updated on 28 October 2026", read in full 2026-11-07', date: '2026-10-28', read: 'rendered page text' },
        { url: 'https://www.indusind.bank.in/content/dam/indusind-corporate/credit-cards/MITC_Premium.pdf', kind: 'IndusInd Bank Credit Card MITC, consolidated premium-card file "MITC-Premium Card Consolidated_13.10.2026" (14 pages; fees, interest, forex, DCC, late fee, fuel and other surcharges for CRED IndusInd Bank RuPay)', date: '2026-10-13', read: 'pdftotext' },
        { url: 'https://www.indusind.bank.in/iblogs/press-release/launch-of-cred-indusind-bank-rupay-credit-card/', kind: 'IndusInd Bank launch press release, 15 Sep 2025: zero joining fee, 5% online and 1% offline, every point equivalent to a rupee on main redemption routes, NPCI RuPay quote', date: '2025-09-15', read: 'page text' },
      ],
      unverified: [
        'Annual fee: the IndusInd MITC fee table shows joining NIL and annual ₹499 for this card, with a footnote that the annual fee does not apply to targeted "Lifetime Free" limited-time promotions, and the header says actual fees are conveyed at application. Which cohort a new applicant gets is not stated. The launch press release says only "zero joining fees". annual_fee_inr keeps 499.',
        'Foreign currency mark-up 3.5% + GST is taken from the MITC clause "All other Credit Cards (not specified above) 3.5%": the CRED card is not named in that row, so the general rate applies by exclusion. No CRED-specific forex figure was found; confirm with IndusInd. The DCC fee row (2% + GST from 15 June 2026) does name the card.',
        'Interest rate 3.95% a month (47.40% a year) for revolving credit and cash advances is stated for this card in the MITC; the MITC also says the Bank can change the rate by customer profile.',
        'Fuel: the MITC says a 1% fuel surcharge waiver exists but points to the bank website for per-product waiver details, so fuel_surcharge waiver_percent, minimum and cap are null. The card pays 1% + GST on cumulative fuel above ₹30,000 a statement cycle from 15 June 2026.',
        'EMI processing and foreclosure charges, returned-payment fee and lounge access for this card are not in the MITC rows read; left null / not modelled.',
        'Redemption values (₹1 / ₹0.50), the 70% limit (100% for utility and credit-card bill payments) and the 2-year expiry were re-read on 2026-11-07 from CRED Section Z, which is a CRED programme document, not an IndusInd Bank document; CRED can change them with notice.',
        'Section Z exclusions are now read in full (including FASTag and tolls, CBDC, jewellery, forex and quasi-cash); channel-based exclusions (UPI outside CRED UPI, insurance and utility paid outside the CRED app) are not modelled as MCC rules.',
        'CRED is a facilitator and runs the rewards programme; IndusInd is the issuer.',
        'Rounding: points are rounded per transaction (₹101 at 5% gives 5; ₹195 gives 10), so rounding_mode "round" is an approximation.',
      ],
      notes: ['Minimum ₹100 per transaction to earn.', 'Points earning stops if the CRED membership lapses.'],
    }) },
  },

  // ───────────────────────────────────────────── IOB RuPay Platinum / Select
  'indian-overseas-bank-rupay-platinum': iob('platinum', { annual: 250, tier: 'Platinum' }),
  'indian-overseas-bank-rupay-select': iob('select', { annual: 500, tier: 'Select' }),
};

function iob(v, o) {
  return {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: o.annual, is_upi_linkable: true, data_source_tier: 'issuer_page', source_url: 'https://www.iob.bank.in/en/credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: 0.25, point_value_baseline_basis: 'IOB credit card page (last updated 5 Nov 2026), Features of Rupay Credit Card, and IOB RuPay credit card FAQ Q27 (last updated 7 Oct 2026): each reward point has a value of ₹0.25; redeemable for merchandise, gift card, travel, entertainment, recharge and DTH; minimum ' + (v === 'platinum' ? '750' : '1,000') + ' points to redeem. The page says redeem "before the expiry of reward point" but gives no expiry period.', point_expiry_months: null },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'IOB RuPay FAQ (7 Oct 2026): all IOB customers can apply; NRIs holding an Indian passport are eligible; for a CIBIL score below 650 a limit against a deposit with 10% margin is offered; no third-party guarantee; documents are the application form, income proof (ITR, salary slip or Form 16) and KYC. IOB page credit limits for RuPay ' + o.tier + ': ' + (v === 'platinum' ? 'minimum ₹60,000, maximum under ₹2,00,000 for the public (under ₹1,50,000 for staff).' : 'minimum ₹2,00,000 for the public (₹1,50,000 for staff), maximum ₹5,00,000.'), rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.25, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      R({ id: `iob-rupay-${v}-base-1rp-per-100`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100, minimum_transaction_inr: 100, channels: ['POS', 'e-commerce'] }, reason: 'One reward point for every ₹100 spent on RuPay ' + o.tier + ', each point worth ₹0.25 (0.25% back). Points are given for transactions of ₹100 and above made at POS or e-commerce (IOB RuPay FAQ Q27; IOB credit card page).' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 2.5, annual_interest_rate_percent: 30 },
      forex_markup: { markup_percent: 2.5, gst_applicable: true },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 5000, monthly_waiver_cap_inr: 250 },
      cash_advance: { atm_transaction_fee_percent: 2.25, atm_transaction_fee_min_inr: null, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 40 },
      banking_penalties: { overlimit_charge: { fee_percent: null, min_fee_inr: 100, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
    },
    statement_and_late_fees: { grace_period_days: null, grace_period_void_on_revolving_balance: true, minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['5% of the billed transactions (purchases and cash advances) plus interest and charges applied plus applicable GST, minimum ₹100 (MITC)'] }, late_payment_slabs: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 100 }] },
    redemption_matrix: { direct_options: [{ channel: 'IOB credit card rewards (merchandise, gift card, travel, entertainment, recharge, DTH)', redemption_type: 'partner_catalogue', inr_value_per_point: 0.25, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: v === 'platinum' ? 750 : 1000, cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: null, effective_to: null }], partner_transfers: [] },
    insurance_and_protection: [{ cover_type: 'other', coverage_inr: v === 'platinum' ? 200000 : 1000000, coverage_usd: 'N/A', claim_condition: 'Personal accident cover provided free by NPCI under the RuPay insurance programme (FY 2025-26 documents linked on the IOB page); the amount changes with NPCI terms.', effective_from: null, effective_to: null }],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 100000, period: 'card_anniversary_year', evaluation_condition: 'IOB MITC (PDF created 20 Aug 2026), fee table: RuPay ' + o.tier + ' joining fee NIL, annual fee ₹' + o.annual + ' + GST, minimum spends for annual fee reversal ₹1,00,000. The MITC does not say which period the spend is counted over or which categories are excluded; card_anniversary_year is assumed.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: o.annual },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: 4, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: `iob-rupay-${v}-domestic-lounge`, cat: 'lounge', sponsor: 'Indian Overseas Bank', label: 'Complimentary domestic airport lounge access', cond: { source: 'IOB credit card page', eligible_card: 'RuPay ' + o.tier, spend_criteria: 'not stated', lounge_list: 'not stated' }, qty: v === 'platinum' ? 1 : 2, per: 'quarter' }),
      B({ id: `iob-rupay-${v}-international-lounge`, cat: 'lounge', sponsor: 'Indian Overseas Bank', label: 'Complimentary international airport lounge access (per calendar year)', cond: { source: 'IOB credit card page', eligible_card: 'RuPay ' + o.tier, period: 'calendar year', spend_criteria: 'not stated', lounge_list: 'not stated' }, qty: v === 'platinum' ? 1 : 2, per: 'annual' }),
    ],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.iob.bank.in/documents/d/guest/mitc-iob-credit-cards', kind: 'IOB credit card MITC (2 pages, PDF created 20 Aug 2026, footer 5298_06/26): fee table lists RuPay Platinum and RuPay Select with no "proposed" marker; interest, forex, fuel waiver, late fee, MAD, add-on cards', read: 'pdftotext' },
        { url: 'https://www.iob.bank.in/en/credit-card', kind: 'IOB credit card page, last updated 5 Nov 2026: Features of Rupay Credit Card (earn rate, point value, minimum redemption, lounge, fuel waiver, NPCI personal accident cover)', read: 'rendered page text' },
        { url: 'https://www.iob.bank.in/en/Frequently-Asked-Questions-Rupay-Credit-Cards', kind: 'IOB RuPay credit card FAQ, last updated 7 Oct 2026: "At present the following types of cards are issued by IOB: RuPay Classic, RuPay Platinum, RuPay Select"; reward Q27; eligibility', read: 'rendered page text' },
        { url: 'https://www.iob.bank.in/documents/d/guest/iobCredit_Card_Schedule_of_Charges', kind: 'IOB credit card Schedule of Charges (PDF created 21 Oct 2023; one page): marks the RuPay variants "proposed to be launched", which the 2026 FAQ and MITC supersede', read: 'pdftotext' },
      ],
      unverified: [
        'AVAILABILITY resolved to on sale: the 7 Oct 2026 FAQ says RuPay Classic, Platinum and Select "are issued" at present, the Aug 2026 MITC lists them without the "proposed" asterisk, and the 5 Nov 2026 page describes them. The "proposed to be launched" note is on a 2023-dated Schedule of Charges. The FAQ says "all IOB customers can apply"; whether non-customers can apply is not stated, so application_mode "open" needs a person to confirm.',
        'Reward rate is 1 point per ₹100 at ₹0.25 a point (0.25%), from the FAQ and the page. The page text under the Select column is headed "RuPay Platinum Credit Cards" (copy slip); the Select minimum redemption (1,000 points) and the FAQ ("Platinum, Signature and Select" earn 1 per ₹100) show it is the Select rule. The ₹100 minimum per transaction applies to POS and e-commerce spends; MCC exclusions and the points expiry period are not stated.',
        'Annual fee reversal: ₹1,00,000 minimum spend for both RuPay Platinum and Select in the MITC fee table; the counting period and spend exclusions are not stated.',
        'Lounge access: 1 domestic per quarter and 1 international per calendar year (Platinum), 2 and 2 (Select), from the page; no spend criteria, lounge list or network programme is stated.',
        'Personal accident cover ₹2 lakh (Platinum) and ₹10 lakh (Select) is NPCI-provided and "changing time to time"; the FY 2025-26 NPCI documents linked from the page were not read.',
        'The page lists a "Proposed Terms of EMI Option" (processing fee nil, 3% pre-closure, ₹3,000 minimum) that is marked proposed, so it is not modelled.',
        'The IOB page also lists a "RuPay EKAA Super Premium Credit Card" (separate page), a card that is not in the catalogue or the research lists.',
      ],
      notes: ['Forex 2.5%; cash advance 2.25% (₹22.50 per ₹1,000) plus finance charge from the date of withdrawal, limit 40% of the card limit; interest 2.5% a month (30% a year), interest-free period 20 to 50 days; fuel surcharge 1%, waived for ₹400 to ₹5,000 transactions up to ₹250 per billing cycle; card replacement ₹100 + GST; over-limit fee ₹100; late fee ₹100 after 3 days past due; up to 4 add-on cards, no fee. The earlier ₹22.50 minimum cash fee was a restatement of 2.25% per ₹1,000 and is removed.'],
    }) },
  };
}
