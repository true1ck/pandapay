// ICICI Bank cards. Sources (read 2026-11-07):
//  MITC = ICICI Most Important Terms and Conditions, "Last updated on Nov 6th, 2026", 54 pages
//         https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/mitc_cc.pdf
//  TB   = Additional Terms and Conditions for Times Black ICICI Bank Credit Card, version 3, 2 May 2025 (43 pages)
//  Pages = issuer product pages (verbatim read by the fetch tool; no revision date on either)
import { R, X, C, B, prov, GST } from '../lib.mjs';

const MITC = 'https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/mitc_cc.pdf';
const mitcSrc = { url: MITC, kind: 'MITC, last updated 6 Nov 2026 (fees, forex, reward caps, exclusions, lounge)', read: 'pdftotext' };

const UTILITY_1838 = [4899, 4900, 4901, 3887, 4897, 5416, 5417, 4812, 4813, 4814, 4815, 4821, 4896, 4902, 3886];
const UTILITY_TB = [4899, 4900, 4901, 3887];
const INSURANCE = [5960, 6300, 6381, 6399];
const EDUCATION = [8211, 8220, 8241, 8244, 8249, 8299, 8493, 8494, 7911];
const GOVT = [6760, 9222, 9311, 9313, 9211, 9399, 9402, 9405];

export const cards = {
  // ───────────────────────────────────────────── 1838 Reserve
  'icici-1838-reserve': {
    card_product: { ...GST, card_type: 'credit', network: 'visa', application_mode: 'invite_only', joining_fee_inr: 175000, annual_fee_inr: 175000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/1838-reserve-icici-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated by ICICI for this card. Checked 2026-11-07: the 1838 Reserve issuer page, the ICICI MITC (last updated 6 Nov 2026), the ICICI general credit card T&C (tnc_english.pdf, file dated 28 Sep 2026, linked from the card page) and the ICICI Rewards pages give no rupee value for one reward point; the Times Black terms state ₹0.40 per point for that card only and must not be reused. effective_base_return_percent is left null.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'By invitation only; interest can be registered and ICICI verifies eligibility. Relationship-based product: ICICI can downgrade or withdraw it if the cardholder does not keep the minimum relationship value (MITC).', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] }, { parameter: 'citizenship', operator: 'in', threshold_value: null, allowed_values: ['indian_citizen'] }], required_documents: ['proof of identity', 'proof of address', 'proof of income'] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 3, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: 100000, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('r1838-excl-fuel', 'fuel', [1361, 3851, 5172, 5541, 5542, 5983, 9752, 5555], 'No reward points on fuel (MITC).'),
      X('r1838-excl-rent', 'rent', [7014, 7407, 5271, 6513], 'No reward points on rent payments (MITC).'),
      X('r1838-excl-wallet', 'wallet_load', [6540], 'No reward points on e-wallet loads (MITC).'),
      X('r1838-excl-emi', 'emi', [], 'No reward points on EMI transactions (MITC).'),
      R({ id: 'r1838-domestic-3', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 3, cap: 'r1838-total-cap', cond: { transaction_type: 'domestic', unit_note: 'issuer says "3% on domestic spends"; 3 points per ₹100 is inferred from percent-of-spend wording' }, reason: '3% reward points on domestic spends (issuer page). Unit inferred, see open questions.' }),
      R({ id: 'r1838-international-2', cat: 'international_spend', pri: 25, type: 'accelerator', ppb: 2, mult: 2, cap: 'r1838-total-cap', cond: { transaction_type: 'international' }, reason: '2% reward points on international spends (issuer page). Unit inferred.' }),
    ],
    cap_rules: [
      C({ id: 'r1838-total-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 100000, after: 'zero_accrual' }),
      C({ id: 'r1838-bills-cap', cat: 'utility', metric: 'total_reward_points', period: 'statement_cycle', points: 10000, mccs: [...UTILITY_1838, ...INSURANCE, ...EDUCATION, ...GOVT], after: 'zero_accrual', parent: 'r1838-total-cap' }),
      C({ id: 'r1838-other-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 90000, after: 'zero_accrual', parent: 'r1838-total-cap' }),
    ],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 1.67, annual_interest_rate_percent: 20 },
      forex_markup: { markup_percent: 0, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 0, gst_applicable: true, trigger_condition: 'MITC: no mark-up and no dynamic currency conversion mark-up on 1838 Reserve' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    },
    statement_and_late_fees: { late_payment_slabs: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 0 }] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Annual fee waiver is not applicable (issuer page, MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 0 },
      welcome_and_renewal_gift: { trigger: 'joining_fee_paid', benefit_points: 'N/A', effective_value_inr: 82500, condition: 'Luxury stay at Lohono Platinum Villas (worth ₹50,000), welcome gift on Tata CliQ Luxury or Good Earth (worth ₹25,000) and a Klook museum experience (worth ₹7,500); delivered by e-mail or the 1838 app after the joining fee is paid and the first billing cycle completes.' },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: 0, fee_per_card_inr: 'N/A', separate_priority_pass: 'N/A', lounge_quota_shared: 'N/A', reward_points_pooled: 'N/A', min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: 'r1838-quorum', cat: 'other', sponsor: 'Quorum Club', label: 'Quorum Club full-access membership', value: 300000 }),
      B({ id: 'r1838-crib-life', cat: 'concierge', sponsor: 'Crib Life', label: 'Dedicated concierge, unlimited requests', value: 100000 }),
      B({ id: 'r1838-truefitt', cat: 'other', sponsor: 'Truefitt & Hill', label: 'Four Royal Signature Services, one per quarter', qty: 4, per: 'annual', value: 49600 }),
      B({ id: 'r1838-business-class', cat: 'other', sponsor: 'ICICI Bank', label: 'Business-class ticket with 50% off for a companion, once per quarter (up to ₹50,000 off)', qty: 1, per: 'quarter', value: 50000 }),
      B({ id: 'r1838-airport-transfer', cat: 'other', sponsor: 'ICICI Bank', label: 'International airport transfers, once per quarter', qty: 1, per: 'quarter' }),
      B({ id: 'r1838-harrods', cat: 'other', sponsor: 'Harrods', label: 'Harrods Gold tier', value: 100000 }),
      B({ id: 'r1838-accor', cat: 'other', sponsor: 'Accor', label: 'Accor+ Explorer membership', value: 20000 }),
      B({ id: 'r1838-itc', cat: 'other', sponsor: 'ITC Hotels', label: 'Stay 3 nights, pay for 2', value: 15500 }),
    ],
    insurance_and_protection: [],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/1838-reserve-icici-credit-card', kind: 'issuer page (verbatim read)', read: 'fetch tool' },
        mitcSrc,
      ],
      unverified: [
        'Reward unit: the page says "3% on domestic" and "2% on international" with no points per ₹100; 3 and 2 points per ₹100 are inferred. The value of one reward point is NOT stated in any ICICI document read (card page, MITC of 6 Nov 2026, general credit card T&C dated 28 Sep 2026, Rewards pages), so point_value_inr_baseline stays null and the percent return cannot be turned into rupees. Do not reuse the Times Black ₹0.40.',
        'Reward cap period: the MITC says the 1,00,000-point and 10,000-point caps are per statement cycle; the card page FAQ says "per month". The MITC is used.',
        'No spend trigger is stated for the joining-benefit vouchers beyond paying the joining fee.',
        'Interest (settled 2026-11-07, W6): MITC Section I, 2. Finance Charges (2) states for the 1838 Reserve ICICI Bank Credit Card 1.67% per month i.e. 20% per annum on retail transactions and cash advances, and says the APR is the same for retail purchases, balance transfer, cash advances, non-payment of minimum due and late payment. The card page also says 1.67% a month.',
        'Network: the page says issued with Times Internet and Visa; the MITC fee table does not name a network.',
        'GST: assumed 18% as for other ICICI fees; the page says "+ GST" only.',
      ],
      notes: [
        'Lounge: the MITC states domestic and international lounge access is not available on the 1838 Reserve card.',
        'Add-on cards are not issued. Late bill payment and ATM withdrawal fees are Nil (issuer page).',
        'Caps (MITC): 1,00,000 points per statement cycle overall; 10,000 across utilities, insurance, education and government/tax; 90,000 for everything else.',
        'The 1838 Reserve fee table in the MITC lists joining ₹1,75,000, first-year annual fee Nil, annual fee from the second year ₹1,75,000. joining_fee_inr and annual_fee_inr use those.',
      ],
    }) },
  },

  // ───────────────────────────────────────────── Times Black
  'icici-times-black': {
    card_product: { ...GST, card_type: 'credit', network: 'visa', application_mode: 'open', joining_fee_inr: 20000, annual_fee_inr: 20000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/times-black-icici-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: 0.4, point_value_baseline_basis: 'Times Black terms: redemption against statement is ₹0.40 per ICICI reward point; the value is up to ₹1 per point on other redemption options.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Issuer page: Indian citizen over 21 with a salaried monthly income of ₹2,00,000 or a self-employed annual income of ₹24,00,000.', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] }, { parameter: 'net_monthly_salary_inr', operator: '>=', threshold_value: 200000, allowed_values: [] }, { parameter: 'annual_income_self_employed_inr', operator: '>=', threshold_value: 2400000, allowed_values: [] }], required_documents: ['proof of identity', 'proof of address', 'proof of income'] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: 0.8, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('tb-excl-fuel', 'fuel', [], 'No reward points on fuel (Times Black terms).'),
      X('tb-excl-rent', 'rent', [], 'No reward points on rent (Times Black terms).'),
      X('tb-excl-emi', 'emi', [], 'Points on transactions converted into EMIs are reversed (Times Black terms).'),
      R({ id: 'tb-domestic-2', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 2, cap: 'tb-bills-cap', cond: { transaction_type: 'domestic', unit_note: '"2% reward points" read as 2 points per ₹100' }, reason: '2% ICICI reward points on eligible domestic transactions. At ₹0.40 per point for statement credit that is 0.8% in value; up to ₹1 per point gives 2% on other redemptions.' }),
      R({ id: 'tb-international-2-5', cat: 'international_spend', pri: 25, type: 'accelerator', ppb: 2.5, mult: 2.5, cap: 'tb-bills-cap', cond: { transaction_type: 'international' }, reason: '2.5% ICICI reward points on eligible international transactions.' }),
    ],
    cap_rules: [C({ id: 'tb-bills-cap', cat: 'utility', metric: 'total_reward_points', period: 'statement_cycle', points: 5000, mccs: [...UTILITY_TB, ...INSURANCE, ...EDUCATION, ...GOVT], after: 'zero_accrual' })],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 1.49, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 1.49, gst_applicable: true, trigger_condition: 'MITC: 1.49% dynamic currency conversion mark-up on Times Black' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    },
    statement_and_late_fees: { late_payment_slabs: [] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 2500000, period: 'card_anniversary_year', evaluation_condition: 'MITC: minimum spends of ₹25,00,000 for annual fee reversal; the page says spending over ₹25 lakh waives the fee for the next year.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 20000 },
      welcome_and_renewal_gift: { trigger: 'joining', benefit_points: 'N/A', effective_value_inr: null, condition: 'Luxury stay gift card (EaseMyTrip ₹10,000 or Lohono ₹12,000), travel visa benefits worth ₹10,000 (Atlys, OneVasco), lifestyle gift cards (Toni and Guy ₹3,000, Interflora ₹1,000) and a Zomato Gold annual membership. No spend trigger is stated for these.' },
      spend_milestones: [
        { id: 'tb-klook-2l', label: 'Klook experiences worth ₹10,000', threshold_spend_inr: 200000, reward_value_inr: 10000, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'tb-wework-5l', label: 'WeWork day passes or airport transfers worth ₹10,000', threshold_spend_inr: 500000, reward_value_inr: 10000, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'tb-tata-cliq-10l', label: 'Tata CLiQ Luxury gift card worth ₹10,000', threshold_spend_inr: 1000000, reward_value_inr: 10000, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'tb-stay-20l', label: 'One-night luxury stay at Ayatana or Lohono worth ₹20,000', threshold_spend_inr: 2000000, reward_value_inr: 20000, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null },
      ],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 3500, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: 'tb-intl-lounge', cat: 'lounge', program: 'priority_pass', sponsor: 'ICICI Bank / Priority Pass', label: 'Unlimited international lounge access via Priority Pass membership (primary and Plus cardholders)', qty: null, per: 'N/A' }),
      B({ id: 'tb-domestic-lounge', cat: 'lounge', sponsor: 'ICICI Bank', label: 'Unlimited complimentary domestic lounge access (primary and add-on cardholders)', qty: null, per: 'N/A' }),
      B({ id: 'tb-concierge', cat: 'concierge', sponsor: 'ICICI Bank', label: '24x7 concierge services' }),
    ],
    insurance_and_protection: [],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/times-black-icici-credit-card', kind: 'issuer page (verbatim read of fees, rewards, benefits, eligibility)', read: 'fetch tool' },
        mitcSrc,
        { url: 'https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/times-black-icici-credit-card-terms-conditions.pdf', kind: 'Times Black additional T&C, v3, 2 May 2025 (reward points, value, lounge)', read: 'pdftotext' },
      ],
      unverified: [
        'Reward unit: the terms say "2% / 2.5% ICICI Bank reward points"; 2 and 2.5 points per ₹100 is inferred, matching ICICI convention.',
        'Spend-milestone period: the page lists ₹2 lakh, ₹5 lakh, ₹10 lakh and ₹20 lakh triggers without saying per year, so period "annual" is an assumption.',
        'The Times Black terms are version 3 dated 2 May 2025; the MITC is dated 6 Nov 2026. Where they differ, the MITC wins. No difference was found on the points read.',
        'Network: the terms refer to Visa concierge and lounge services; the MITC fee table does not name a network.',
        'Interest (settled 2026-11-07, W6): MITC Section I, 2. Finance Charges (1) states 3.75% per month i.e. 45% per annum for revolving credit on retail transactions and cash advances, with the same APR for retail purchases, balance transfer, cash advances, non-payment of minimum due and late payment. Item (2) carves out only the 1838 Reserve card (1.67% a month), so Times Black takes the general rate by exclusion; the MITC does not name Times Black in the finance-charge clause, so confirm with ICICI. The MITC Section II also says ICICI can change the rate (as low as 1.25% a month for some customers) at its discretion.',
      ],
      notes: [
        'Fee row in the MITC: joining ₹20,000, first-year annual fee Nil, annual fee from year two ₹20,000, Plus/add-on card fee ₹3,500, spends for annual fee reversal ₹25,00,000.',
        'Reward caps (MITC): 5,000 points per statement cycle cumulatively on utilities, insurance, education and government/tax payments, domestic and international together.',
      ],
    }) },
  },
};
