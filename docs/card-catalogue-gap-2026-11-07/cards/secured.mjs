// FD-backed secured cards from small finance banks. Sources read 2026-11-07 (pdftotext).
import { R, X, C, B, prov, GST } from '../lib.mjs';

const SBM_KFS = 'https://www.sbm.bank.in/pdf/kfs/PB_paisaplus_KFS.pdf';
const SBM_SOP = 'https://www.sbm.bank.in/pdf/notice-board/PB_paisaplus_Reward-Structure.pdf';
const SSFB_KFS = 'https://suryoday.bank.in/assets/pdf/KFS_SSFB_RuPay_Platinum_Credit_MBK.pdf';

const sbmExcl = [
  ['sbm-excl-rent', 'rent', [6513, 7349], 'Rentals and property management'],
  ['sbm-excl-cash', 'cash_withdrawal', [6010, 6011, 6051, 4829], 'Cash, quasi-cash and wire transfers'],
  ['sbm-excl-finance', 'excluded_spend', [6012, 7322, 6211], 'Financial institutions, debt collection and securities'],
  ['sbm-excl-wallet', 'wallet_load', [6540], 'Debit card to wallet credit'],
  ['sbm-excl-education', 'education', [8211, 8241, 8244, 8249, 8220, 8299], 'Education'],
  ['sbm-excl-insurance', 'insurance', [5960, 6300, 6381], 'Insurance'],
  ['sbm-excl-govt', 'government', [7800, 7802, 7995, 9211, 9222, 9311, 9399, 9402, 9405], 'Government, tax, lottery and gambling'],
  ['sbm-excl-agri', 'excluded_spend', [763, 780, 820, 821, 822, 823, 824, 825, 5261], 'Agriculture, horticulture and lawn and garden supply'],
  ['sbm-excl-utilities', 'utility', [4900], 'Utilities'],
  ['sbm-excl-contractors', 'excluded_spend', [1520, 1711, 1731, 1740, 1750, 1761, 1771, 1799], 'Contractor services'],
  ['sbm-excl-transport', 'excluded_spend', [4784, 4789], 'Toll, bridge fees and transportation'],
  ['sbm-excl-fuel', 'fuel', [5541, 5542], 'Fuel spends (the SOP names "Fuel Spends" without MCC codes; MCC 5541 and 5542 assumed)'],
].map(([id, cat, mccs, label]) => X(id, cat, mccs, `${label} earn no cash points (SBM Paisa Plus rewards SOP excluded-category MCC list).`));

export const cards = {
  // ───────────────────────────────────────────── SBM Paisabazaar Paisa Plus
  'sbm-paisabazaar-paisa-plus': {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 499, is_upi_linkable: true, form_factors: ['virtual_card', 'physical_plastic'], data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.sbm.bank.in/personal-banking/cards/secured-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: 1, point_value_baseline_basis: 'SOP: 1 Cash Point = ₹1, no redemption fee; adjusted against the card outstanding via the Paisabazaar app. Points expire 1 year after earning.', point_expiry_months: 12 },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'FD-backed: credit limit is 90% of the fixed deposit; FD tenure 390 days with auto-renewal (KFS).', rules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 5000, allowed_values: [] }], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: 3000, capping_period_basis: 'calendar_month' },
    reward_rules: [
      ...sbmExcl,
      X('sbm-excl-upi-small', 'upi', [], 'No cash points on UPI spends below ₹2,000 (SOP).', { transaction_amount_lt_inr: 2000, rail: 'upi' }),
      R({ id: 'sbm-online-1-5pct-fd-10k', cat: 'all_retail', rail: 'online', pri: 10, cb: 1.5, mult: 1, cap: 'sbm-monthly-cap', cond: { cumulative_fd_size_gte_inr: 10000 }, reason: 'Online spends: effective cashback 1.5% (₹1.5 on a ₹100 transaction) when the cumulative FD is ₹10,000 or more (SOP).' }),
      R({ id: 'sbm-online-1pct-fd-5k', cat: 'all_retail', rail: 'online', pri: 11, cb: 1, mult: 1, cap: 'sbm-monthly-cap', cond: { cumulative_fd_size_gte_inr: 5000, cumulative_fd_size_lt_inr: 10000 }, reason: 'Online spends: effective cashback 1.0% when the cumulative FD is ₹5,000 to under ₹10,000 (SOP).' }),
      R({ id: 'sbm-other-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, ppb: 2, cap: 'sbm-monthly-cap', cond: { per_inr_block: 200, upi_minimum_inr: 2000 }, reason: 'All other spends: 2 cash points per ₹200, effective 1.0%, with a ₹2,000 minimum for UPI spends (SOP).' }),
    ],
    cap_rules: [
      C({ id: 'sbm-daily-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'day', points: 500, after: 'zero_accrual' }),
      C({ id: 'sbm-monthly-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'calendar_month', points: 3000, after: 'zero_accrual' }),
    ],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.5, annual_interest_rate_percent: 42 },
      forex_markup: { markup_percent: 0, gst_applicable: true },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
      category_surcharges: [],
    },
    statement_and_late_fees: {
      grace_period_days: 45,
      grace_period_void_on_revolving_balance: null,
      minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['5% for ECOM transactions', '100% of interest', '100% of fees'] },
      late_payment_slabs: [
        { min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }, { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 500 },
        { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 600 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 750 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 950 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1000 },
      ],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 50000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee ₹499 + GST, waived when spend in the preceding year is ₹50,000 or more. Stated by the KFS (SBM file 12 Oct 2026) and by MITC Table 01 (29 Oct 2026); both are later than the rewards SOP (30 Apr 2026), whose FD tier table shows "Joining / Annual Fee 0" and is superseded on this point. Renewal fee ₹499 (MITC Table 06).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 499 },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: 0, fee_per_card_inr: 'N/A', separate_priority_pass: 'N/A', lounge_quota_shared: 'N/A', reward_points_pooled: 'N/A', min_age_years: null },
    lifestyle_and_network_benefits: [],
    redemption_matrix: { direct_options: [{ channel: 'Paisabazaar app, adjusted against card outstanding', redemption_type: 'statement_credit', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 500, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null }], partner_transfers: [] },
    additional_data: { items: prov({
      sources: [
        { url: SBM_KFS, kind: 'SBM Bank Paisa Bazaar Credit Card Key Fact Statement (SBM file dated 12 Oct 2026; fees, interest, late fee, MAD)', read: 'pdftotext' },
        { url: SBM_SOP, kind: 'Paisabazaar Paisa Plus Rewards SOP (PDF created 30 Apr 2026, SBM file dated 4 May 2026; earn, caps, value, exclusions)', read: 'pdftotext' },
        { url: 'https://www.sbm.bank.in/pdf/terms-conditions/SBM-Secured-Credit-Card-T&C.pdf', kind: 'SBM Secured Credit Card MITC and Cardholder Member Agreement, 52 pages (SBM file dated 29 Oct 2026): Table 01 annual fee and waiver, Table 06 renewal and cancellation, Table 07 forex 0% and surcharge 1%', read: 'pdftotext' },
        { url: 'https://www.sbm.bank.in/images/cards/PB_paisaplus_Rupay_CC.webp', kind: 'Card image for Paisa Plus on the SBM secured credit card page (file name PB_paisaplus_Rupay_CC): shows the RuPay credit logo', read: 'image viewed' },
        { url: 'https://www.sbm.bank.in/pdf/terms-conditions/PB_paisaplus-MITC.pdf', kind: 'Paisa Plus MITC (PDF created 26 Feb 2026, modified 29 Apr 2026, SBM file dated 12 May 2026): clause 4.2 says the virtual card is "RuPay / Visa powered (as per the issued network)"; superseded by the 29 Oct 2026 combined document', read: 'pdftotext' },
      ],
      unverified: [
        'Annual fee, resolved to 499: the KFS (12 Oct 2026) and the combined MITC (29 Oct 2026) both say ₹499 + GST, waived at ₹50,000 spend in the preceding year. The rewards SOP (30 Apr 2026) is older and shows joining/annual fee 0 in its FD tier table; it is superseded on fees. A person may still want to ask Paisabazaar whether earlier cohorts keep a zero fee.',
        'Network, resolved to RuPay from the issuer page card image only (file PB_paisaplus_Rupay_CC shows the RuPay credit logo). No KFS, SOP or MITC names the network; the MITC clause 4.2 is generic ("RuPay / Visa powered, as per the issued network"). The SOP rule on UPI spends fits a RuPay card.',
        'Forex: the KFS says N/A, MITC Table 07 (29 Oct 2026) says 0%. 0 is used; the card is RuPay, so confirm international acceptance.',
        'The SOP and KFS carry no revision date; dates above are PDF creation dates and SBM server file dates.',
        'The SOP says fuel, EMI, jewellery, games and lottery earn nothing but gives MCC codes only for the table below it. Fuel is modelled as MCC 5541 and 5542; jewellery and games are not modelled.',
        'Cap period: the SOP says "monthly cap of 3000" without defining calendar month versus statement cycle; calendar_month is assumed.',
        'Fuel surcharge is 1% (MITC Table 07, "Surcharge Fee"); no waiver is stated.',
      ],
      notes: [
        'Credit limit is 90% of the FD; FD tenure 390 days with auto-renewal; closing the card closes the FD (KFS).',
        'Card cancellation within six months costs ₹499 + GST; surcharge fee 1% (KFS).',
        'Cost of cash points: 60% borne by Paisabazaar, 40% by SBM (SOP).',
        'Rewards depend on the cumulative FD size (₹5,000 to under ₹10,000 versus ₹10,000 and above), a per-user attribute the ranking engine cannot see.',
      ],
    }) },
  },

  // ───────────────────────────────────────────── Suryoday MobiKwik First RuPay Platinum
  'suryoday-mobikwik-first-rupay-platinum': {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://suryoday.bank.in/personal/cards/credit-cards/secured-credit-card/', status: 'draft', verified_at: null },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'KFS: individuals, Indian citizens and residents. FD-backed secured card; service provider 42 Card Solutions Pvt. Ltd.', rules: [{ parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] }], required_documents: [] },
    accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 2.95, annual_interest_rate_percent: 35.4 },
      forex_markup: { markup_percent: 2.5, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: null },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 8000, monthly_waiver_cap_inr: 40000 },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: null, daily_interest_percent: null, max_limit_percent: 20 },
      category_surcharges: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% surcharge on rental payments under MCC 6513', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    },
    statement_and_late_fees: {
      grace_period_days: null,
      grace_period_void_on_revolving_balance: null,
      minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['10% of billed amount', 'plus any overdue and over-limit amounts'] },
      late_payment_slabs: [],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Annual and joining fees are NIL (KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    additional_data: { items: [
      ...prov({
        sources: [
          { url: SSFB_KFS, kind: 'Suryoday SSFB RuPay Platinum (MobiKwik) Key Fact Statement', read: 'pdftotext' },
          { url: 'https://suryoday.bank.in/personal/cards/credit-cards/secured-credit-card/', kind: 'issuer listing page (MobiKwik First tile: "1% Cashback*"; page footnote "#With the capping of ₹3,000"), re-read 2026-11-07 in the built-in browser', read: 'rendered page text' },
          { url: 'https://www.mobikwik.com/products/first-fd-credit-card', kind: 'MobiKwik (co-brand partner, not issuer) product page: "Flat 1% Cashback* on UPI and Online spends"; FAQ "1% Cashback on all Ecommerce transactions" and "1% Cashback on UPI payments made via MobiKwik UPI"; no terms link for the cashback', read: 'rendered page text, 2026-11-07' },
          { url: 'https://suryoday.bank.in/assets/pdf/MITC_SSFB_RuPay_Platinum_Credit_Card.pdf', kind: 'Generic Suryoday RuPay Platinum MITC (file dated 17 Jun 2026, 30 pages), clause "l) CASH BACK PROGRAM": states no rate, cap, period or merchant list; used only to confirm the cashback rules are not in it', read: 'pdftotext' },
        ],
        unverified: [
          'Cashback (checked 2026-11-07, W6): no document that states the cap, period, exclusions or minimum transaction for the 1% cashback was found, so no reward rule is written. The issuer listing page links a cashback PDF only for the Stable Money cards (0.5%; stablemoney-suryoday-sfb-credit-card-cashback.pdf); the MobiKwik tile has no "Know More" link. The page links a MobiKwik MITC (https://suryoday.bank.in/assets/pdf/MITC_SSFB_RuPay_Platinum_Credit_MBK.pdf) but that URL returns a 404 page. The MobiKwik KFS (https://suryoday.bank.in/assets/pdf/KFS_SSFB_RuPay_Platinum_Credit_MBK.pdf, file dated 24 Jun 2026) has fees only and no reward terms; the generic Suryoday MITC cashback clause gives no rate or cap. The issuer page footnote "#With the capping of ₹3,000" is attached to the product line as a whole and does not say per month or per statement cycle or that it covers this variant. The MobiKwik page says 1% on e-commerce and 1% on UPI payments made via MobiKwik UPI, which is a partner statement, not an issuer term. effective_base_return_percent 1 is the advertised figure only. Hold this card until Suryoday or MobiKwik publishes the cashback terms.',
          'KFS carries no revision date in its text; the PDF metadata shows 24 Jun 2026.',
          'Do not reuse the Stable Money card\'s zero forex: this card charges 2.5% + GST (KFS).',
          'Late payment fee: 2.5% of the outstanding or ₹250 + GST, whichever is higher (KFS); cannot be shown as fixed slabs.',
        ],
        notes: ['Cash advances are restricted to 20% of the credit limit; cash advance fee 2.5% of the amount, minimum ₹500 + GST (KFS).', 'Fuel surcharge waiver is limited to ₹40,000 in a calendar month with no single transaction above ₹8,000 (KFS).'],
      }),
      { key: 'late_payment_fee_rule', value: { rule: '2.5% of the outstanding, or ₹250 + GST, whichever is higher', source: 'KFS' } },
    ] },
  },
};
