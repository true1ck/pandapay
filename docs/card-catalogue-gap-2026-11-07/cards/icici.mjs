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
    card_product: { ...GST, card_type: 'credit', network: 'visa', application_mode: 'invite_only', joining_fee_inr: 175000, annual_fee_inr: 175000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/1838-reserve-icici-credit-card', status: 'draft', verified_at: null, point_expiry_months: 36, point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated by ICICI for this card. Checked 2026-11-07: the 1838 Reserve issuer page, the ICICI MITC (last updated 6 Nov 2026), the ICICI general credit card T&C (tnc_english.pdf, file dated 28 Sep 2026, linked from the card page) and the ICICI Rewards pages give no rupee value for one reward point; the Times Black terms state ₹0.40 per point for that card only and must not be reused. effective_base_return_percent is left null. Re-checked 2026-11-07 (W9): also the 1838 Reserve page FAQ, the ICICI Rewards FAQ page, the Rewards page and the ICICI benefits page; the redemption handling fee table in the MITC names 1838 Reserve (a Nil row shared with Emeralde Private Metal and Times Black, against ₹99 for catalogue redemptions on other cards, and ₹25 for online and in-store partner brand redemptions) but gives no rupee value per point.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'By invitation only; interest can be registered and ICICI verifies eligibility. Relationship-based product: ICICI can downgrade or withdraw it if the cardholder does not keep the minimum relationship value (MITC).', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] }, { parameter: 'citizenship', operator: 'in', threshold_value: null, allowed_values: ['indian_citizen'] }], required_documents: ['proof of identity', 'proof of address', 'proof of income'] },
    accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: null, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: 100000, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('r1838-excl-fuel', 'fuel', [1361, 3851, 5172, 5541, 5542, 5983, 9752, 5555], 'No reward points on fuel (MITC).'),
      X('r1838-excl-rent', 'rent', [7014, 7407, 5271, 6513], 'No reward points on rent payments (MITC).'),
      X('r1838-excl-wallet', 'wallet_load', [6540], 'No reward points on e-wallet loads (MITC).'),
      X('r1838-excl-emi', 'emi', [], 'No reward points on EMI transactions (MITC).'),
      R({ id: 'r1838-domestic-3', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: null, mult: 3, cap: 'r1838-total-cap', cond: { transaction_type: 'domestic', stated_wording: '"Rewards points earned on every transaction: 3% On Domestic Spends" (issuer page)', unit_basis: 'NOT STATED: ICICI gives a percent, not points per ₹100 or a rupee value per point for this card; points_per_block is left empty on purpose' }, reason: '3% reward points on domestic spends, as ICICI words it. Points per ₹100 not stated (see open questions), so no points_per_block is recorded; mult carries the stated 3% only.' }),
      R({ id: 'r1838-international-2', cat: 'international_spend', pri: 25, type: 'accelerator', ppb: null, mult: 2, cap: 'r1838-total-cap', cond: { transaction_type: 'international', stated_wording: '"2% On International Spends" (issuer page)', unit_basis: 'NOT STATED: percent only, no points per ₹100' }, reason: '2% reward points on international spends, as ICICI words it. Points per ₹100 not stated, so no points_per_block is recorded.' }),
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
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/1838-reserve-icici-credit-card', kind: 'issuer page read 2026-11-07 in a browser (Network Benefits tile "Access to Visa Services", rewards tile "3% On Domestic Spends 2% On International Spends", fees, FAQ including reward capping)', read: 'rendered page text and FAQ answers' },
        mitcSrc,
        { url: 'https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/tnc_english.pdf', kind: 'ICICI general credit card terms and conditions linked from the card page ("Click here for applicable Terms & Conditions"); reward schemes described without rates or point values; 1838 not named', date: 'PDF created 2026-09-28', read: 'pdftotext' },
        { url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/credit-card-services/rewards', kind: 'ICICI Bank Credit Card Rewards page and its FAQ page: "To understand the exact earn rate on your Card, please refer to your Card page"; no card-level unit or point value', read: 'rendered page text' },
      ],
      unverified: [
        'Reward unit (re-checked 2026-11-07, W9, NOT FOUND): ICICI words the earn only as "3% On Domestic Spends" and "2% On International Spends" on the card page; no ICICI document says how many reward points per ₹100 that is. Looked at: the card page and its FAQ, the MITC of 6 Nov 2026 (the reward-caps table and "Terms and Conditions pertinent to ICICI Bank Rewards"), the general credit card terms (28 Sep 2026), the Rewards page and Rewards FAQ page (which defers to the card page); the Times Black co-brand site does not cover this card. The earlier inference of 3 and 2 points per ₹100 was therefore removed: points_per_block and base_points_per_block are empty and the rules carry only the stated percent. If ICICI confirms 3 and 2 points per ₹100, set points_per_block 3 and 2, base_block_inr 100 and base_points_per_block 3.',
        'Value of one reward point: NOT stated by ICICI for this card (card page, FAQ, MITC, general terms, Rewards pages), so point_value_inr_baseline stays null and the percent return cannot be turned into rupees. Do not reuse the Times Black ₹0.40.',
        'Reward cap period: the MITC says the 1,00,000-point and 10,000-point caps are per statement cycle; the card page FAQ says "per month". The MITC is used (newer, dated 6 Nov 2026).',
        'No spend trigger is stated for the joining-benefit vouchers beyond paying the joining fee.',
        'Late payment fee (found 2026-11-07, W9, NOT settled): the card page says "Late Bill Payment: Nil" and the draft carries a Nil slab; the MITC late-payment table (w.e.f. 15 Nov 2024; ₹100 to ₹1,300 by outstanding amount) says "excluding ICICI Bank Emeralde Private Metal Credit Card" and does not name 1838 Reserve, so on the MITC alone 1838 Reserve would pay late fees. The page is undated, the MITC is dated 6 Nov 2026; the page was kept. A person must confirm with ICICI.',
        'Interest (settled 2026-11-07, W6): MITC Section I, 2. Finance Charges (2) states for the 1838 Reserve ICICI Bank Credit Card 1.67% per month i.e. 20% per annum on retail transactions and cash advances, and says the APR is the same for retail purchases, balance transfer, cash advances, non-payment of minimum due and late payment. The card page also says 1.67% a month.',
        'Network (settled 2026-11-07, W9): Visa. The issuer card page FAQ says the card is "issued by ICICI Bank in association with Times Internet Ltd. and Visa" and its Network Benefits tile lists "Access to Visa Services for Primary Cardholders". The MITC fee table does not name a network, which does not conflict.',
        'GST: the page says "+ GST" on the joining and annual fee; ICICI documents state "18% GST" only for EMI and loan items, not for these fees, so 18% is the statutory rate and not an ICICI statement for this card.',
      ],
      notes: [
        'Lounge: the MITC states domestic and international lounge access is not available on the 1838 Reserve card.',
        'Reward points expire 36 months from issuance and lapse on card cancellation (MITC, "Terms and Conditions pertinent to ICICI Bank Rewards" items 2 and 3; ICICI Rewards page says valid for 3 years); credited within 5 working days of the statement date (MITC) or 7 (Rewards page).',
        'Add-on cards are not issued. Late bill payment and ATM withdrawal fees are Nil (issuer page).',
        'Caps (MITC): 1,00,000 points per statement cycle overall; 10,000 across utilities, insurance, education and government/tax; 90,000 for everything else.',
        'The 1838 Reserve fee table in the MITC lists joining ₹1,75,000, first-year annual fee Nil, annual fee from the second year ₹1,75,000. joining_fee_inr and annual_fee_inr use those.',
      ],
    }) },
  },

  // ───────────────────────────────────────────── Times Black
  'icici-times-black': {
    card_product: { ...GST, card_type: 'credit', network: 'visa', application_mode: 'open', joining_fee_inr: 20000, annual_fee_inr: 20000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.icici.bank.in/personal-banking/cards/credit-card/times-black-icici-credit-card', status: 'draft', verified_at: null, point_expiry_months: 36, point_value_inr_baseline: 0.4, point_value_baseline_basis: 'ICICI Times Black page FAQ (read 2026-11-07): "The value of 1 ICICI Bank reward point can be up to ₹ 1. However, when redeeming ICICI Bank reward points against your statement, the redemption rate is 1 Reward Point (RP) = ₹0.40." Times Black additional T&C v3 (2 May 2025): "Value of 1 ICICI Bank reward point is up to ₹ 1" and "Redemption against statement of ICICI Bank reward points: 1 Rupee = ₹ 0.4" (the T&C wording is garbled; the page states it as 1 RP = ₹0.40). The baseline uses the statement-credit rate, the only fixed one.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Issuer page: Indian citizen over 21 with a salaried monthly income of ₹2,00,000 or a self-employed annual income of ₹24,00,000.', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] }, { parameter: 'net_monthly_salary_inr', operator: '>=', threshold_value: 200000, allowed_values: [] }, { parameter: 'annual_income_self_employed_inr', operator: '>=', threshold_value: 2400000, allowed_values: [] }], required_documents: ['proof of identity', 'proof of address', 'proof of income'] },
    accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: null, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('tb-excl-fuel', 'fuel', [], 'No reward points on fuel (Times Black terms).'),
      X('tb-excl-rent', 'rent', [], 'No reward points on rent (Times Black terms).'),
      X('tb-excl-emi', 'emi', [], 'Points on transactions converted into EMIs are reversed (Times Black terms).'),
      R({ id: 'tb-domestic-2', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: null, mult: 2, cap: 'tb-bills-cap', cond: { transaction_type: 'domestic', stated_wording: '"Get <2>% ICICI Bank reward points on all eligible domestic transactions" (Times Black T&C v3; page FAQ "You can earn 2% ICICI Bank reward points")', unit_basis: 'NOT STATED: ICICI gives a percent, not points per ₹100; points_per_block is left empty on purpose' }, reason: '2% ICICI Bank reward points on eligible domestic transactions, as ICICI words it. Points per ₹100 not stated (see open questions), so no points_per_block or percent return is recorded; mult carries the stated 2% only.' }),
      R({ id: 'tb-international-2-5', cat: 'international_spend', pri: 25, type: 'accelerator', ppb: null, mult: 2.5, cap: 'tb-bills-cap', cond: { transaction_type: 'international', stated_wording: '"Get <2.5>% ICICI Bank reward points on all eligible international transactions" (Times Black T&C v3)', unit_basis: 'NOT STATED: percent only, no points per ₹100' }, reason: '2.5% ICICI Bank reward points on eligible international transactions, as ICICI words it. Points per ₹100 not stated, so no points_per_block is recorded.' }),
    ],
    cap_rules: [C({ id: 'tb-bills-cap', cat: 'utility', metric: 'total_reward_points', period: 'statement_cycle', points: 5000, mccs: [...UTILITY_TB, ...INSURANCE, ...EDUCATION, ...GOVT], after: 'zero_accrual' })],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 1.49, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 1.49, gst_applicable: true, trigger_condition: 'MITC: 1.49% dynamic currency conversion mark-up on Times Black' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    },
    statement_and_late_fees: { late_payment_slabs: [
      { min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 },
      { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 },
      { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 500 },
      { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 600 },
      { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 },
      { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 900 },
      { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 },
      { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
    ] },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 2500000, period: 'card_anniversary_year', evaluation_condition: 'MITC: minimum spends of ₹25,00,000 for annual fee reversal; the page says spending over ₹25 lakh waives the fee for the next year.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 20000 },
      welcome_and_renewal_gift: { trigger: 'joining', benefit_points: 'N/A', effective_value_inr: null, condition: 'Luxury stay gift card (EaseMyTrip ₹10,000 or Lohono ₹12,000), travel visa benefits worth ₹10,000 (Atlys, OneVasco), lifestyle gift cards (Toni and Guy ₹3,000, Interflora ₹1,000) and a Zomato Gold annual membership. No spend trigger is stated for these.' },
      spend_milestones: [
        { id: 'tb-klook-2l', label: 'Klook experiences worth ₹10,000', threshold_spend_inr: 200000, reward_value_inr: 10000, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'tb-wework-5l', label: 'WeWork day passes or airport transfers worth ₹10,000', threshold_spend_inr: 500000, reward_value_inr: 10000, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'tb-tata-cliq-10l', label: 'Tata CLiQ Luxury gift card worth ₹10,000', threshold_spend_inr: 1000000, reward_value_inr: 10000, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'tb-stay-20l', label: 'One-night luxury stay at Ayatana or Lohono worth ₹20,000', threshold_spend_inr: 2000000, reward_value_inr: 20000, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
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
        { url: 'https://www.icici.bank.in/content/dam/icicibank/india/managed-assets/revamp-page-images/docs/pdf/times-black-icici-credit-card-terms-conditions.pdf', kind: 'Times Black additional T&C, v3, 2 May 2025 (reward points, value, milestone definition, lounge)', date: 'PDF created 2026-01-19; document says "Updated as on: May 02, 2025", Version 3', read: 'pdftotext' },
        { url: 'https://www.timesblack.com/faqs', kind: 'Times Black co-brand site FAQ (Times Internet, not ICICI): "2% Reward points" and "monthly cap of 5k reward points"; not used for any value (ICICI documents say per statement cycle)', read: 'rendered page text' },
      ],
      unverified: [
        'Reward unit (re-checked 2026-11-07, W9, NOT FOUND): every ICICI statement words the earn as a percent: Times Black T&C v3 "Get <2>% ICICI Bank reward points on all eligible domestic transactions" and "<2.5>%" on international, and the card page FAQ "You can earn 2% ICICI Bank reward points on all eligible domestic transactions". None says how many reward points per ₹100, and the MITC, the general credit card terms and the Rewards pages are silent on a per-card unit (the Rewards FAQ defers to the card page). The co-brand site (Times Internet) repeats "2% Reward points" only. The earlier inference of 2 and 2.5 points per ₹100 was removed: points_per_block, base_points_per_block and effective_base_return_percent are empty, and the rules carry only the stated percent. If ICICI confirms 2 and 2.5 points per ₹100, set points_per_block 2 and 2.5, base_block_inr 100, base_points_per_block 2 and effective_base_return_percent 0.8 (2 x ₹0.40 per ₹100).',
        'Spend-milestone period (settled 2026-11-07, W9): the Times Black T&C v3 defines "Anniversary Year" as 12 months from the date of issue and each 12-month period after, and says "Milestone Benefits: Benefits are offered to the Cardholder ... on achieving the threshold spends in an Anniversary Year"; the four milestones now carry period card_anniversary_year (the page and the co-brand site only say "annual spending levels"). Each Milestone Benefit is then available in the Times Black app for six months from the notification (page FAQ and T&C). Whether a milestone repeats every anniversary year is not stated beyond "until the next periodic cycle" for an Eligible Cardholder who has used a benefit, so is_repeatable stays false.',
        'The Times Black terms are version 3 dated 2 May 2025 (PDF file created 19 Jan 2026); the MITC is dated 6 Nov 2026. Where they differ, the MITC wins. No difference was found on the points read. The statement-credit value wording is garbled in the T&C ("1 Rupee = ₹ 0.4") and clear on the undated page FAQ ("1 Reward Point (RP) = ₹0.40"); the page is used for the reading and the T&C for "up to ₹1".',
        'Reward cap period (settled): MITC and Times Black T&C say the 5,000-point cap is per statement cycle; the co-brand site says "monthly". The ICICI documents are used.',
        'Network (settled 2026-11-07, W9): Visa. The issuer card page FAQ says the card is "issued by ICICI Bank in association with Times Internet Ltd. and Visa" (the only network named for this card on any ICICI page or document; it is worded as an association rather than "Visa network", and the card art on the page, the Times Black banner image, carries no network mark). The earlier note about "Visa concierge and lounge services" in the T&C was a misreading: "Visa" in the T&C v3 means travel visa applications (OneVasco, Atlys, "Times Black Visa Wallet"), not the card network. The MITC names no network for the card and its lounge clauses are generic ("VISA, MASTERCARD or RUPAY"), which does not conflict. A person holding an issued card can confirm.',
        'Late payment fee: the card page says "Ranging from ₹100 to ₹1300"; the slabs come from the MITC late payment table (w.e.f. 15 Nov 2024, applied to the outstanding after payments received before the due date, which applies to every card except Emeralde Private Metal).',
        'Interest (settled 2026-11-07, W6): MITC Section I, 2. Finance Charges (1) states 3.75% per month i.e. 45% per annum for revolving credit on retail transactions and cash advances, with the same APR for retail purchases, balance transfer, cash advances, non-payment of minimum due and late payment. Item (2) carves out only the 1838 Reserve card (1.67% a month), so Times Black takes the general rate by exclusion; the MITC does not name Times Black in the finance-charge clause, so confirm with ICICI. The MITC Section II also says ICICI can change the rate (as low as 1.25% a month for some customers) at its discretion.',
      ],
      notes: [
        'Reward points expire 36 months from issuance and lapse on card cancellation (MITC, "Terms and Conditions pertinent to ICICI Bank Rewards" items 2 and 3; ICICI Rewards page says valid for 3 years).',
        'Fee row in the MITC: joining ₹20,000, first-year annual fee Nil, annual fee from year two ₹20,000, Plus/add-on card fee ₹3,500, spends for annual fee reversal ₹25,00,000.',
        'Reward caps (MITC): 5,000 points per statement cycle cumulatively on utilities, insurance, education and government/tax payments, domestic and international together.',
      ],
    }) },
  },
};
