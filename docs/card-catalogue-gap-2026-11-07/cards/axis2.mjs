// Axis Bank wave 2: the two IndiGo co-branded cards. Sources (all read 2026-11-07):
//  MITC       = Axis Bank credit cards MITC (62 pages, PDF created 8 Oct 2026) https://www.axis.bank.in/docs/default-source/default-document-library/mitc-credit-cards.pdf
//  BASE_TNC   = "Terms and Conditions - IndiGo Axis Bank Credit Card" (14 pages, PDF created 28 Sep 2026)
//  PREM_TNC   = IndiGo Axis Bank Premium Credit Card T&C (16 pages, PDF created 23 Oct 2026)
//  LOUNGE     = Axis Bank Credit Cards Domestic Airport Lounge Access Program (6 pages, PDF created 16 Apr 2026)
//  NOTICE_*   = "Revision of ... Terms and Conditions" notices linked from the product pages, effective 28 Aug 2026 (PDF created 27 Jul 2026)
//  Product pages read in a real browser session (the site did not answer plain fetches); card art read from the page banners.
//  IndiGo BluChip programme pages on goindigo.in (loyalty home, FAQ, terms, Axis partner page) were read for the BluChip value question.
import { R, X, C, B, P, prov, GST } from '../lib.mjs';

const MITC = 'https://www.axis.bank.in/docs/default-source/default-document-library/mitc-credit-cards.pdf';
const BASE_PAGE = 'https://www.axis.bank.in/cards/credit-card/indigo-axis-bank-credit-card';
const PREM_PAGE = 'https://www.axis.bank.in/cards/credit-card/indigo-axis-bank-premium-credit-card';
const BASE_TNC = 'https://www.axis.bank.in/docs/default-source/default-document-library/final_indigo-base_customer-tnc.pdf';
const PREM_TNC = 'https://www.axis.bank.in/docs/default-source/default-document-library/final_indigo-premium_customer-tnc.pdf';
const LOUNGE = 'https://www.axis.bank.in/docs/default-source/default-document-library/axis-bank-airport-lounge-access-program.pdf';
const NOTICE_BASE = 'https://campaign.axis.bank.in/generic/terms-and-conditions-generic-all.pdf';
const NOTICE_PREM = 'https://campaign.axis.bank.in/generic/terms-and-conditions-indigopremium.pdf';
const IBC_FAQ = 'https://www.goindigo.in/loyalty/faq.html';
const IBC_TNC = 'https://www.goindigo.in/loyalty/terms-and-conditions.html';
const IBC_PARTNER = 'https://www.goindigo.in/loyalty/partners/axis-credit-card.html';

const mitcSrc = { url: MITC, kind: 'MITC (fees, interest, forex, late fee, surcharges; both IndiGo cards named in the fee table)', date: 'PDF created 2026-10-08', read: 'pdftotext' };
const ibcSrcs = [
  { url: IBC_FAQ, kind: 'IndiGo BluChip FAQ: "IndiGo BluChips do not have any monetary value and cannot be exchanged for cash"; usable only to book IndiGo flights', read: 'rendered page text' },
  { url: IBC_TNC, kind: 'IndiGo BluChip membership terms: no fixed rupee rate; "conversion rate for Cash + IndiGo BluChips may vary based on the origin, destination, flight schedule, flight number, date, season, fare, cabin, tier, sales channel"', read: 'rendered page text' },
  { url: IBC_PARTNER, kind: 'IndiGo partner page for the two Axis cards (earn summary, "up to 19 / 23" headline breakdown)', read: 'rendered page text' },
];

// Fees and charges the MITC applies to both IndiGo cards (forex and DCC differ).
const fees = ({ forex }) => ({
  apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 55.55 },
  forex_markup: { markup_percent: forex, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: forex, gst_applicable: true, trigger_condition: 'MITC: same markup on international transactions in Indian currency and on INR transactions with foreign-registered merchants. Notice effective 28 Aug 2026 revised the DCC markup from 1.5% to ' + forex + '%.' },
  // The MITC fuel row (1% of the transaction amount) names the cards whose surcharge is refunded; neither IndiGo card is in the refunded or the not-refunded list.
  fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
  cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
  category_surcharges: [
    { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on each rental transaction, uncapped', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'wallet_load', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once cumulative wallet loads reach ₹10,000 in a statement cycle (from 20 Dec 2024)', threshold_spend_inr: 10000, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'fuel', mcc_list: [5983, 5541, 5542, 5172], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once cumulative fuel spend reaches ₹50,000 in a statement cycle (from 20 Dec 2024)', threshold_spend_inr: 50000, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'utility', mcc_list: [4814, 4899, 4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once cumulative utility payments reach ₹25,000 in a statement cycle (from 20 Dec 2024)', threshold_spend_inr: 25000, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'education_third_party', mcc_list: [8211, 8220, 8241, 8244, 8249, 8299], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on each education payment made through third-party apps such as CRED, Paytm, Cheq and Mobikwik; direct school or college website or POS is exempt; DCC and international markup also apply to education transactions (from 20 Dec 2024)', threshold_spend_inr: null, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'gaming', mcc_list: [5816], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once online skill-gaming spend reaches ₹10,000 in a statement cycle (MITC, all cards; not repeated on the IndiGo product pages)', threshold_spend_inr: 10000, effective_from: '2024-12-20', effective_to: null },
  ],
  banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
});

const statement = {
  grace_period_days: null,
  grace_period_void_on_revolving_balance: null,
  minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['MITC: sum of all instalments, all fees, interest or finance charges, taxes, any amount over the credit limit, and 2% of the remaining balance outstanding, subject to a minimum of ₹100; if the total amount due is below ₹100 the MAD equals it'] },
  late_payment_slabs: [
    { min_balance_inr: 0, max_balance_inr: 500, fee_inr: 0 },
    { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 500 },
    { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 },
    { min_balance_inr: 10001, max_balance_inr: 50000, fee_inr: 1200 },
    { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
  ],
};

// Earn exclusions common to both cards (T&C "Excluded Categories"; the T&C names categories, not MCC numbers).
const exclusions = (p) => [
  X(`${p}-excl-government`, 'government', [], 'Government services earn no BluChips (T&C excluded categories).'),
  X(`${p}-excl-insurance`, 'insurance', [], 'Insurance services earn no BluChips.'),
  X(`${p}-excl-utility`, 'bills', [], 'Utility services including telecom earn no BluChips.'),
  X(`${p}-excl-rent`, 'rent', [], 'Rental payments earn no BluChips.'),
  X(`${p}-excl-wallet`, 'wallet', [], 'Wallet loads earn no BluChips.'),
  X(`${p}-excl-fuel`, 'fuel', [], 'Fuel earns no BluChips.'),
  X(`${p}-excl-jewellery`, 'other', [], 'Jewellery earns no BluChips.'),
  X(`${p}-excl-tolls`, 'other', [], 'Bridge fees, road fees and tolls earn no BluChips (T&C; the 28 Aug 2026 notice repeats this).'),
  X(`${p}-excl-gift-cards`, 'other', [], 'Gift cards earn no BluChips (the 28 Aug 2026 notice moves gift cards from the "Wallet" spend category to a separate "Gift Card" category, still excluded).'),
  X(`${p}-excl-emi`, 'emi', [], 'All EMI transaction types (loan on credit card, Dial an EMI, balance conversion and transfer, merchant EMI, balance on EMI) earn no BluChips; BluChips already earned are reversed on conversion, and credited back on EMI cancellation but not on foreclosure (T&C).'),
  X(`${p}-excl-cash`, 'other', [], 'ATM cash withdrawals earn no BluChips.'),
  X(`${p}-excl-fees`, 'other', [], 'Fees, charges and GST, and temporary credits or their reversals, earn no BluChips.'),
];

const GROCERY_MCCS = [5399, 5422, 5441, 5411, 5451, 5462, 5499, 5999];
const INDIGO_COND = { mcc_list: [4511], merchant_name_keywords: ['Indigo', 'Interglobe'], description: 'Airline MCC 4511 where the merchant name carries "Indigo" or "Interglobe" (IndiGo channels)' };

const bluchipBasis = 'IndiGo BluChips have no stated rupee value. Axis T&C (IndiGo BluChip Program Specific Terms 1): "loyalty points and do not hold any monetary value", not legal tender, cannot be exchanged for cash. IndiGo FAQ: no monetary value, usable only to book IndiGo flights; redemption value per BluChip is not published and the Cash + BluChips conversion varies by route, date, fare and cabin. BluChips stay valid while the member is programme-active in the last 24 months (IndiGo FAQ); BluChip Vouchers last 6 months from issue.';

const redemption = {
  direct_options: [{
    channel: 'IndiGo website and app (IndiGo flights only; a BluChip Voucher applies to the base fare on economy and Stretch, one journey, no return or multi-segment, no change or cancellation)',
    redemption_type: 'flight_hotel_booking', inr_value_per_point: null, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: null, cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: null, effective_to: null,
  }],
  partner_transfers: [],
};

const upiOpen = 'Whether the card can be linked to UPI is unclear: the base T&C caps earns from "CC on UPI" at 750 BluChips per statement month, but the page caption and card art show Visa, and the MITC "Credit Card on UPI" section lists only RuPay cards.';

export const cards = {
  // ───────────────────────────────────────────── IndiGo Axis Bank Credit Card (base)
  'axis-bank-indigo': {
    card_product: {
      ...GST, name: 'IndiGo Axis Bank Credit Card', issuer_slug: 'axis', card_type: 'credit', network: 'visa', network_tier: null, application_mode: 'open',
      joining_fee_inr: 799, annual_fee_inr: 799, is_upi_linkable: null,
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: BASE_PAGE, status: 'draft', verified_at: null,
      point_value_inr_baseline: null, point_value_baseline_basis: bluchipBasis, point_expiry_months: null,
    },
    eligibility_engine: {
      evaluation_mode: 'guideline_only', notes: 'Axis page: primary cardholder 18 to 70, resident of India. Documents: PAN copy, proof of income (latest payslip, Form 16 or IT return), residence proof (driving licence, electricity bill or landline bill). The applicant must be, or be enrolled as, an IndiGo BluChip member using the same email and mobile number (T&C).',
      rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 18, allowed_values: [] }, { parameter: 'age_years', operator: '<=', threshold_value: 70, allowed_values: [] }, { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] }],
      required_documents: [],
    },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      ...exclusions('indigo'),
      R({ id: 'indigo-channel-3', cat: 'travel', pri: 5, ppb: 3, mult: 3, cond: { ...INDIGO_COND, per_inr_block: 100 }, reason: '3 IndiGo BluChips per ₹100 on IndiGo channels (T&C Base and Accelerated earn); uncapped even on UPI.' }),
      R({ id: 'indigo-upi-grocery-2', cat: 'groceries', rail: 'upi_qr', pri: 9, ppb: 2, mult: 2, cap: 'indigo-upi-monthly-cap', cond: { mcc_list: GROCERY_MCCS, per_inr_block: 100, rail_note: 'credit card on UPI' }, reason: 'Same 2 BluChips per ₹100 on grocery MCCs when paid through credit card on UPI, but earns from UPI are capped at 750 BluChips per statement month across base, grocery and dining; above the cap nothing is earned and the spend does not count toward milestones (T&C UPI Capping).' }),
      R({ id: 'indigo-upi-dining-2', cat: 'dining', rail: 'upi_qr', pri: 9, ppb: 2, mult: 2, cap: 'indigo-upi-monthly-cap', cond: { mcc_list: [5812, 5814, 5813], per_inr_block: 100, rail_note: 'credit card on UPI' }, reason: 'Same 2 BluChips per ₹100 on dining MCCs when paid through credit card on UPI, inside the shared 750 BluChip monthly UPI cap (T&C UPI Capping).' }),
      R({ id: 'indigo-upi-base-1', cat: 'all_retail', rail: 'upi_qr', pri: 29, type: 'standard_accrual', ppb: 1, mult: 1, cap: 'indigo-upi-monthly-cap', cond: { per_inr_block: 100, rail_note: 'credit card on UPI' }, reason: '1 BluChip per ₹100 on other eligible spends when paid through credit card on UPI, inside the shared 750 BluChip monthly UPI cap; IndiGo channel spends are exempt from the cap (T&C UPI Capping).' }),
      R({ id: 'indigo-grocery-2', cat: 'groceries', pri: 10, ppb: 2, mult: 2, cond: { mcc_list: GROCERY_MCCS, per_inr_block: 100 }, reason: '2 IndiGo BluChips per ₹100 on grocery MCCs (T&C Base and Accelerated earn).' }),
      R({ id: 'indigo-dining-2', cat: 'dining', pri: 10, ppb: 2, mult: 2, cond: { mcc_list: [5812, 5814, 5813], per_inr_block: 100 }, reason: '2 IndiGo BluChips per ₹100 on dining MCCs (T&C Base and Accelerated earn).' }),
      R({ id: 'indigo-base-1', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 IndiGo BluChip per ₹100 on all eligible non-accelerated spends (T&C and Axis page).' }),
    ],
    cap_rules: [C({ id: 'indigo-upi-monthly-cap', cat: 'upi', metric: 'total_reward_points', period: 'statement_cycle', points: 750, after: 'zero_accrual' })],
    fees_and_surcharges: fees({ forex: 3.5 }),
    statement_and_late_fees: statement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No spend-based waiver: the MITC fee table lists ₹799 joining and ₹799 annual with no waiver condition, and the T&C bills the annual fee on the first statement after each anniversary year. Lifetime-free and first-year-free promotional cardholders get no welcome or renewal voucher.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'joining_or_annual_fee_payment', benefit_points: 1200, effective_value_inr: null, condition: 'Voucher worth 1,200 IndiGo BluChips on payment of the joining fee, and again each year on payment of the annual fee; issued to the BluChip account within 30 days, only if the fee is paid within 120 days of being charged; valid 6 months; not for add-on, lifetime-free or first-year-free cardholders (T&C 4). The rupee value is not stated.' },
      spend_milestones: [
        { id: 'indigo-m1', label: 'Voucher worth 1,200 IndiGo BluChips', threshold_spend_inr: 150000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        { id: 'indigo-m2', label: 'Voucher worth 1,200 IndiGo BluChips', threshold_spend_inr: 300000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
      ],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'indigo-domestic-lounge', cat: 'lounge', program: 'N/A', sponsor: 'Axis Bank', label: 'Domestic airport lounge access (Axis lounge programme, Set A lounges)', cond: { min_eligible_spend_inr_previous_3_calendar_months: 50000, waived_for_new_card: 'month of issuance and the following 3 calendar months', entry: 'cardholder only, validated by a nominal swipe (₹2 Visa, ₹25 Mastercard, ₹2 RuPay); guests paid' }, qty: 1, per: 'quarter' }),
    ],
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    redemption_matrix: redemption,
    dynamic_promotions_registry: [],
    additional_data: { items: [
      { key: 'late_payment_fee_rule', value: { rule: 'Slabs by total payment due: nil up to ₹500; ₹500 for ₹501 to ₹5,000; ₹750 for ₹5,001 to ₹10,000; ₹1,200 for ₹10,001 to ₹50,000; ₹1,300 above ₹50,000. An extra ₹100 applies when the Minimum Amount Due is missed in two consecutive cycles, until it is cleared. Charged on the outstanding balance (total due less payments).', source: 'MITC and Axis product page; 28 Aug 2026 notice repeats the slabs' } },
      ...prov({
        sources: [
          { url: BASE_PAGE, kind: 'issuer product page (Features, Fees & Charges, Eligibility expanded); page caption "IndiGo VISA Axis Bank Credit Card"', read: 'rendered page text and card art' },
          { url: BASE_TNC, kind: 'IndiGo Axis Bank Credit Card T&C: earn rates, MCCs, exclusions, UPI cap, welcome and milestone vouchers, lounge, redemption terms', date: 'PDF created 2026-09-28', read: 'pdftotext' },
          mitcSrc,
          { url: LOUNGE, kind: 'Domestic airport lounge access programme: IndiGo Axis Bank Credit Card in Set A at 1 per quarter, ₹50,000 spend rule', date: 'PDF created 2026-04-16', read: 'pdftotext' },
          { url: NOTICE_BASE, kind: 'Axis revision notice effective 28 Aug 2026 (DCC markup 3.5% from 1.5%, late fee above ₹50,000, payment allocation order, gift card category); the base page banner links the generic version', date: 'PDF created 2026-07-27', read: 'pdftotext' },
          ...ibcSrcs,
        ],
        unverified: [
          'Value of one IndiGo BluChip in rupees: not stated by Axis or IndiGo (both say BluChips have no monetary value; the Cash + BluChips rate varies). point_value_inr_baseline and effective_base_return_percent are null.',
          'Network: Visa, read from the page caption "IndiGo VISA Axis Bank Credit Card" and the card art. The art carries the disclaimer "This is AI generated visual and for representation purposes only" and appears to show "Visa Signature", so network_tier is left null. A human should confirm the network and tier against an issued card.',
          upiOpen + ' is_upi_linkable is left null.',
          'Fuel surcharge waiver: not stated. The MITC fuel row is 1% of the transaction amount; neither IndiGo card is named in the refunded list (₹400 to ₹4,000 and similar) or in the "refund not applicable" list, and the product page and T&C are silent.',
          'MCC numbers behind the excluded categories (government, insurance, utility including telecom, rent, wallet, fuel, jewellery, tolls, gift cards) are not published; exclusions are category-level. Rounding mode and minimum transaction amount are not stated.',
          'The 3 / 2 / 1 BluChips per ₹100 are card spend only. The headline "up to 19 IndiGo BluChips per ₹100" on the page banner is not a card rate: IndiGo\'s partner page splits the equivalent premium "up to 23" as 7 on card spends, 12 on IndiGo flights booked on IndiGo channels and 4 as a Blu 1 tier bonus, and the last two come from the BluChip programme, not from the card.',
          'Maximum number of add-on cards is not stated (MITC add-on fee is nil; add-on holders get no separate welcome or annual voucher).',
          'Promotional offers in the T&C (lifetime-free card with an activation voucher for applications 1 Sep to 31 Oct 2026; double welcome benefit for applications 1 Jun to 31 Aug 2026) have ended and are not modelled.',
          'Both product pages show a banner that T&C "will be updated w.e.f. 28th August\'26" (the base page names the Premium card by mistake); the revision notice was read and only changes DCC, the late fee above ₹50,000, payment allocation and gift card classification.',
          'Interest-free period: the MITC gives a general 20 to 50 days for Axis cards, not a card-specific figure, so grace_period_days is null.',
        ],
        notes: [
          'IndiGo BluChips earned are credited by IndiGo within 30 working days of the statement date, computed on spends net of returns (T&C). Transactions converted to EMI are reversed.',
          'Earn from credit-card-on-UPI spends is capped at 750 BluChips per statement month across base, grocery and dining earn (IndiGo channel spends are uncapped); the cap rule is written as zero accrual above 750 because the T&C says capped earns above 750 "shall not" earn and do not count toward milestones.',
          'Milestone spends count net spends in the card anniversary year on eligible categories; vouchers are issued within 30 days after the next statement and only when that anniversary year\'s fee is paid; each is valid 6 months, redeemable against the base fare of an IndiGo flight (economy or Stretch).',
          'Fees plus GST: joining ₹799 and annual ₹799 (T&C 3). Forex 3.5%, DCC 3.5%, rent 1%, cash advance 2.5% (minimum ₹500), cash payment at branch ₹175, over-limit 2.5% (minimum ₹500), returned payment 2% (minimum ₹500).',
          'EMI conversion offered for transactions above ₹1,500 on request (page).',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── IndiGo Axis Bank Premium Credit Card
  'axis-bank-indigo-premium': {
    card_product: {
      ...GST, name: 'IndiGo Axis Bank Premium Credit Card', issuer_slug: 'axis', card_type: 'credit', network: 'visa', network_tier: 'visa_signature', application_mode: 'open',
      joining_fee_inr: 5000, annual_fee_inr: 5000, is_upi_linkable: null,
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: PREM_PAGE, status: 'draft', verified_at: null,
      point_value_inr_baseline: null, point_value_baseline_basis: bluchipBasis, point_expiry_months: null,
    },
    eligibility_engine: {
      evaluation_mode: 'guideline_only', notes: 'Axis page: primary cardholder 18 to 70, net income at least ₹6 lakh a year, resident of India. Documents: PAN copy, proof of income (latest payslip, Form 16 or IT return), residence proof. The applicant must be, or be enrolled as, an IndiGo BluChip member using the same email and mobile number (T&C).',
      rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 18, allowed_values: [] }, { parameter: 'age_years', operator: '<=', threshold_value: 70, allowed_values: [] }, { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] }, { parameter: 'annual_net_income_inr', operator: '>=', threshold_value: 600000, allowed_values: [] }],
      required_documents: [],
    },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      ...exclusions('indigop'),
      R({ id: 'indigop-channel-7', cat: 'travel', pri: 5, ppb: 7, mult: 3.5, cond: { ...INDIGO_COND, per_inr_block: 100 }, reason: '7 IndiGo BluChips per ₹100 on IndiGo channels (T&C Base and Accelerated earn).' }),
      R({ id: 'indigop-grocery-3', cat: 'groceries', pri: 10, ppb: 3, mult: 1.5, cond: { mcc_list: GROCERY_MCCS, per_inr_block: 100 }, reason: '3 IndiGo BluChips per ₹100 on grocery MCCs (T&C).' }),
      R({ id: 'indigop-hotel-3', cat: 'travel', pri: 10, ppb: 3, mult: 1.5, cond: { mcc_list: [7011], mcc_ranges: [[3501, 3838]], per_inr_block: 100, label: 'hotels' }, reason: '3 IndiGo BluChips per ₹100 on hotel MCCs 3501 to 3838 and 7011 (T&C table "Grocery and Hotel"; the Axis page says "groceries and hotel"). The T&C sentence and the IndiGo partner page say "Grocery and Dining" instead; see open questions.' }),
      R({ id: 'indigop-base-2', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 IndiGo BluChips per ₹100 on all eligible non-accelerated spends (T&C and Axis page).' }),
    ],
    cap_rules: [],
    fees_and_surcharges: fees({ forex: 2.5 }),
    statement_and_late_fees: statement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No spend-based waiver: the MITC fee table lists ₹5,000 joining and ₹5,000 annual with no waiver condition, and the T&C bills the annual fee on the first statement after each anniversary year. Lifetime-free and first-year-free promotional cardholders get no welcome or annual voucher.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'joining_or_annual_fee_payment', benefit_points: 5000, effective_value_inr: null, condition: 'Voucher worth 5,000 IndiGo BluChips plus one complimentary 6E Eats voucher on payment of the joining fee, and again each year on payment of the annual fee; issued within 30 days, only if the fee is paid within 120 days of being charged; valid 6 months; not for add-on, lifetime-free or first-year-free cardholders (T&C 4). The rupee value is not stated.' },
      spend_milestones: [
        { id: 'indigop-m1', label: 'Voucher worth 5,000 IndiGo BluChips', threshold_spend_inr: 200000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        { id: 'indigop-m2', label: 'Voucher worth 5,000 IndiGo BluChips', threshold_spend_inr: 500000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        { id: 'indigop-m3', label: 'Voucher worth 5,000 IndiGo BluChips', threshold_spend_inr: 800000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        { id: 'indigop-m4', label: 'Voucher worth 5,000 IndiGo BluChips', threshold_spend_inr: 1200000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
      ],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'indigop-domestic-lounge', cat: 'lounge', program: 'N/A', sponsor: 'Axis Bank', label: 'Domestic airport lounge access (Axis lounge programme, Set B lounges)', cond: { min_eligible_spend_inr_previous_3_calendar_months: 50000, waived_for_new_card: 'month of issuance and the following 3 calendar months', entry: 'cardholder only, validated by a nominal swipe (₹2 Visa, ₹25 Mastercard, ₹2 RuPay); guests paid' }, qty: 2, per: 'quarter' }),
      B({ id: 'indigop-international-lounge', cat: 'lounge', program: 'priority_pass', sponsor: 'Axis Bank / Priority Pass', label: 'International airport lounge access with a complimentary Priority Pass membership (2 visits per calendar year)', cond: { period: 'calendar year', verification: 'a USD 1 transaction on the card is made to access the lounge and reversed on successful authorisation', exclusion: 'lounges at international terminals within India are not eligible for complimentary Priority Pass access' }, qty: 2, per: 'annual' }),
    ],
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    redemption_matrix: redemption,
    dynamic_promotions_registry: [
      P({ id: 'indigop-bookmyshow-bogo', cat: 'movie', sponsor: 'BookMyShow (Bigtree)', platform: 'bookmyshow.com website and BookMyShow app', type: 'buy_one_get_one_ticket', pct: 'N/A', max: 250, quota: true, permanent: true }),
      P({ id: 'indigop-dining-delights', cat: 'dining', sponsor: 'EazyDiner (Axis Bank Dining Delights programme)', platform: 'EazyDiner website and app', type: 'restaurant_discount_up_to_1000', pct: 'N/A', max: 1000, quota: false, permanent: false, to: '2027-01-31' }),
    ],
    additional_data: { items: [
      { key: 'late_payment_fee_rule', value: { rule: 'Slabs by total payment due: nil up to ₹500; ₹500 for ₹501 to ₹5,000; ₹750 for ₹5,001 to ₹10,000; ₹1,200 for ₹10,001 to ₹50,000; ₹1,300 above ₹50,000. An extra ₹100 applies when the Minimum Amount Due is missed in two consecutive cycles, until it is cleared.', source: 'MITC and Axis product page; 28 Aug 2026 notice repeats the slabs' } },
      ...prov({
        sources: [
          { url: PREM_PAGE, kind: 'issuer product page (Features, Fees & Charges, Eligibility expanded); card art', read: 'rendered page text and card art' },
          { url: PREM_TNC, kind: 'IndiGo Axis Bank Premium Credit Card T&C: earn rates, MCCs, exclusions, welcome and milestone vouchers, lounge, BookMyShow offer', date: 'PDF created 2026-10-23', read: 'pdftotext' },
          mitcSrc,
          { url: LOUNGE, kind: 'Domestic airport lounge access programme: IndiGo Axis Bank Premium Credit Card in Set B at 2 per quarter, ₹50,000 spend rule', date: 'PDF created 2026-04-16', read: 'pdftotext' },
          { url: NOTICE_PREM, kind: 'Axis revision notice effective 28 Aug 2026 (DCC markup 2.5% from 1.5%, late fee above ₹50,000, payment allocation order, gift card category) and effective 1 Nov 2026 (BookMyShow offer needs ₹25,000 spend in the previous 3 months)', date: 'PDF created 2026-07-27', read: 'pdftotext' },
          { url: 'https://www.axis.bank.in/offers/dining-delights/up-to-inr-1000-off-on-the-axis-bank-dining-program', kind: 'Axis Dining Delights with EazyDiner offer page linked from the Premium page (valid till 31 Jan 2027)', read: 'rendered page text' },
          ...ibcSrcs,
        ],
        unverified: [
          'Value of one IndiGo BluChip in rupees: not stated by Axis or IndiGo (both say BluChips have no monetary value; the Cash + BluChips rate varies). point_value_inr_baseline and effective_base_return_percent are null.',
          'Network: Visa Signature, read from the card art on the page banner (VISA Signature logo beside the Axis Bank and IndiGo marks). The page text and T&C never name the network, so a human should confirm it against an issued card.',
          'Accelerated category conflict: the T&C earn table and MCC list say "Grocery and Hotel" (hotel MCCs 3501 to 3838 and 7011), the Axis page says "groceries and hotel", but T&C item v and IndiGo\'s partner page say "grocery and dining". The rule is written for hotels, as the MCC table and the page agree; dining is not given the 3x rate. A person must confirm.',
          'Fuel surcharge waiver: not stated. Neither IndiGo card is named in the MITC refunded list or in the "refund not applicable" list, and the product page and T&C are silent.',
          'MCC numbers behind the excluded categories are not published; exclusions are category-level. Rounding mode and minimum transaction amount are not stated. Unlike the base card, the Premium T&C has no UPI earn cap.',
          'Whether the card can be linked to UPI is not stated: the Premium T&C has no UPI cap, the card art shows Visa, and the MITC "Credit Card on UPI" section lists only RuPay cards. is_upi_linkable is left null.',
          'BookMyShow offer: buy one get one on tickets, once a month, maximum discount ₹250 per month, only after ₹25,000 spend in the previous 3 months (₹25,000 criterion effective 1 Nov 2026; waived for the issuance month and following 3 months). The Axis page says "once every month".',
          'Dining Delights is an Axis programme with EazyDiner ("₹1,000* off & more"); the asterisked terms were not read, so ₹1,000 is only the headline maximum and the card-specific amount is unknown.',
          'The page headline "Earn up to 8 FREE domestic flights annually" is marketing arithmetic on vouchers, not a rate; vouchers have no stated rupee value.',
          'Maximum number of add-on cards is not stated (MITC add-on fee is nil; add-on holders get no separate welcome or renewal voucher).',
          'Promotional offers (double welcome benefit for applications 1 Jun to 31 Oct 2026) have ended and are not modelled.',
        ],
        notes: [
          'IndiGo\'s partner page states 2 domestic lounge visits per quarter and 2 international per year, forex 2.5% and 1 movie ticket a month, consistent with Axis.',
          'IndiGo BluChips earned are credited by IndiGo within 30 working days of the statement date, computed on spends net of returns. Milestone vouchers (5,000 BluChips each at ₹2 lakh, ₹5 lakh, ₹8 lakh and ₹12 lakh of annual spend) are issued within 30 days after the next statement and only when that anniversary year\'s fee is paid; each is valid 6 months.',
          'Fees plus GST: joining ₹5,000 and annual ₹5,000 (T&C 3). Forex 2.5% and DCC 2.5% (MITC), rent 1%, cash advance 2.5% (minimum ₹500), cash payment at branch ₹175, over-limit 2.5% (minimum ₹500), returned payment 2% (minimum ₹500).',
          'Interest 3.75% a month (55.55% a year); the MITC gives a general 20 to 50 day interest-free period for Axis cards, so grace_period_days is null.',
        ],
      }),
    ] },
  },
};
