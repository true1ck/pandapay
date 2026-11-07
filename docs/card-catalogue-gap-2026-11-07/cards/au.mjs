// AU Small Finance Bank cards. Sources (all read 2026-11-07):
//  KFS   = AU Key Fact Statement v1.9, 2 Nov 2026  https://www.au.bank.in/pdf/credit-card/Schedule-of-Charges-CC.pdf
//  PAGE  = issuer product page rendered in a real browser session
//  Doc names below are AU PDFs under https://www.au.bank.in/pdf/ (dated 1 Mar 2026 unless stated)
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const KFS = 'https://www.au.bank.in/pdf/credit-card/Schedule-of-Charges-CC.pdf';
const KFS_DATE = 'Key Fact Statement v1.9, 2 Nov 2026';

// Fees shared by every AU retail card in the KFS (per-card values passed in).
const auFees = ({ fuelCap, forex = 3.49, cashLimit = 20, atmFee = 2.5, fuelMin = 400, emiPost = 99 }) => ({
  apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
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

const auEligibility = (extra = []) => ({
  evaluation_mode: 'guideline_only',
  notes: 'AU states these criteria are only indicative and reserves the right to approve or decline.',
  rules: [
    { parameter: 'age_years_salaried', operator: '>=', threshold_value: 21, allowed_values: [] },
    { parameter: 'age_years_salaried', operator: '<=', threshold_value: 60, allowed_values: [] },
    { parameter: 'age_years_self_employed', operator: '>=', threshold_value: 25, allowed_values: [] },
    { parameter: 'age_years_self_employed', operator: '<=', threshold_value: 65, allowed_values: [] },
    { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] },
    ...extra,
  ],
});

const lateFee = { key: 'late_payment_fee_rule', value: { rule: '15% of Total Amount Due, minimum ₹10, maximum ₹1,300', source: `${KFS_DATE}, section 5`, note: 'Percentage fee cannot be expressed as fixed slabs, so late_payment_slabs is empty.' } };
const returnFee = { key: 'payment_return_charge', value: { rule: '2% of Total Amount Due or ₹500, whichever is higher, on return/failure of card payment (cheque, ECS/NACH, autopay)', source: `${KFS_DATE}, section 10` } };
const nonEarn = (extra = {}) => ({ ...extra });

const addon = { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: 18 };

const common = (slug, pageUrl, fuelCap, extra = {}) => ({
  card_product: { ...GST, card_type: 'credit', data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: pageUrl, status: 'draft', verified_at: null, ...extra.card_product },
  fees_and_surcharges: auFees({ fuelCap, ...(extra.fees || {}) }),
  statement_and_late_fees: auStatement,
  addon_card_rules: addon,
});

export const cards = {
  // ───────────────────────────────────────────────────────────── Ananta
  'au-ananta': (() => {
    const o = common('au-ananta', 'https://www.au.bank.in/personal-banking/credit-cards/ananta-credit-card', 200);
    return {
      ...o,
      card_product: { ...o.card_product, joining_fee_inr: 2000, annual_fee_inr: 2000, application_mode: 'open', point_value_inr_baseline: 0.25, point_value_baseline_basis: 'Ananta page FAQ milestone table: 5,000 bonus Reward Points = ₹1,250 and 50,000 = ₹12,500, i.e. ₹0.25 per point. AU Rewardz FAQ says a point\'s value depends on card variant and redemption category, so this is the page\'s stated value, not a guaranteed redemption rate.', point_expiry_months: 24 },
      eligibility_engine: auEligibility(),
      accrual_engine: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: 25000, capping_period_basis: 'statement_cycle' },
      reward_rules: [
        R({ id: 'ananta-dining-5rp', cat: 'dining', type: 'accelerator', ppb: 5, mult: 5, cap: 'ananta-accelerated-cycle-cap', reason: 'Up to 5 Reward Points per ₹100 on shopping, dining and travel (page + FAQ).' }),
        R({ id: 'ananta-travel-5rp', cat: 'travel', type: 'accelerator', ppb: 5, mult: 5, cap: 'ananta-accelerated-cycle-cap', reason: 'Up to 5 Reward Points per ₹100 on shopping, dining and travel (page + FAQ).' }),
        R({ id: 'ananta-shopping-5rp', cat: 'all_retail', pri: 30, type: 'accelerator', ppb: 5, mult: 5, cap: 'ananta-accelerated-cycle-cap', cond: { category_label: 'shopping', note: 'AU does not define Shopping by MCC on the product page' }, reason: 'Shopping is named without an MCC list on the page, FAQ, MITC v2.23 or CMA. Treat as unrestricted until reviewed.' }),
        R({ id: 'ananta-base-2rp', cat: 'all_retail', pri: 35, type: 'standard_accrual', ppb: 2, mult: 2, cap: 'ananta-total-cycle-cap', reason: 'Page FAQ: 2 Reward Points per ₹100 on all other retail spends (about 0.5% at the page\'s ₹0.25 per point).' }),
        R({ id: 'ananta-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 1, cap: 'ananta-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page FAQ: 1 Reward Point per ₹100 on insurance, utility and telecom; at most 100 points per utility/telecom transaction.' }),
        R({ id: 'ananta-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 1, cap: 'ananta-total-cycle-cap', reason: 'Page FAQ: 1 Reward Point per ₹100 on insurance.' }),
        ...[['rent', 'rent', 'Rent'], ['cash', 'cash_withdrawal', 'Cash and quasi-cash'], ['education', 'education', 'Education'], ['govt', 'government', 'Government'], ['fuel', 'fuel', 'Fuel'], ['emi', 'excluded_spend', 'EMI'], ['bbps', 'excluded_spend', 'BBPS'], ['transport', 'excluded_spend', 'Transportation']].map(([k, cat, label]) => X(`ananta-excl-${k}`, cat, [], `${label} earns no Reward Points (page FAQ: Cash, Rent, Education & Govt, EMI, Fuel, BBPS, Transportation, Quasi Cash). MCC lists not published for this card.`)),
      ],
      cap_rules: [
        C({ id: 'ananta-accelerated-cycle-cap', cat: 'all_retail', metric: 'bonus_reward_points', period: 'statement_cycle', points: 5000 }),
        C({ id: 'ananta-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' }),
      ],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 300000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹3,00,000 retail spends in the previous card anniversary year. No joining fee waiver.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 2000 },
        welcome_and_renewal_gift: { trigger: 'activation_and_first_transaction_within_30_days_of_issue', benefit_points: 8000, effective_value_inr: null, condition: '8,000 bonus Reward Points on activation and first successful transaction within 30 days of issuance; primary cardholder who has paid the joining fee; credited within 3 working days (Welcome Benefit T&C, 1 Mar 2026).' },
        spend_milestones: [
          { id: 'ananta-m1', label: '5,000 bonus Reward Points (page FAQ table: ₹1,250)', threshold_spend_inr: 250000, reward_value_inr: 1250, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
          { id: 'ananta-m2', label: '10,000 bonus Reward Points (incremental; page FAQ table: ₹2,500)', threshold_spend_inr: 500000, reward_value_inr: 2500, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
          { id: 'ananta-m3', label: '15,000 bonus Reward Points (incremental; page FAQ table: ₹3,750)', threshold_spend_inr: 750000, reward_value_inr: 3750, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
          { id: 'ananta-m4', label: '20,000 bonus Reward Points (incremental; page FAQ table: ₹5,000)', threshold_spend_inr: 1000000, reward_value_inr: 5000, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'ananta-domestic-lounge', cat: 'lounge', program: 'priority_pass', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge via flight booking on AU Rewardz', cond: { min_flight_booking_inr: 5000, booking_channel: 'AU Rewardz', primary_cardholder_only: true, qr_per_one_way_ticket: 1, qr_per_return_ticket: 2 }, qty: 4, per: 'quarter', from: '2026-03-01' }),
      ],
      dynamic_promotions_registry: [
        P({ id: 'ananta-partner-discount', cat: 'other', sponsor: 'AU partner merchants (Amazon Fashion, District by Zomato listed)', platform: 'partner merchants', type: 'instant_discount', pct: 15 }),
      ],
      additional_data: { items: [
        { key: 'verified_network_research', value: { finding_status: 'partial', product_status: 'active', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/ananta-credit-card', evidence: 'Page (hidden popup, read from the DOM): a "Visa Cardholders" popup lists MakeMyTrip, Times Prime and Alaya Stays offers through Visa-branded partner links, and the page says partner offers are "basis your selected network variant" (so more than one network exists). Checked and NOT confirmed elsewhere: the card art shows no network logo; the Ananta lounge T&C names no network; the same "Visa Cardholders" popup also sits on the Paytm AU page, whose card art is RuPay Platinum, so the popup is a shared block, not proof for Ananta.', candidates: [
          { network: 'visa', network_tier: 'N/A', label: 'AU Ananta Credit Card (Visa offers popup)', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/ananta-credit-card', evidence: 'Popup heading "Visa Cardholders"; the MakeMyTrip link in it is a Visa Signature offer page (URL path visa-signature-credit-cards-offer). Not stated as the issued network.' },
        ] } },
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/personal-banking/credit-cards/ananta-credit-card', kind: 'issuer_page + FAQ + popups', read: 'rendered page text including hidden accordions and popups, re-read 2026-11-07 (base rates, exclusions and the rupee value of milestone points are in the FAQ)' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: 'https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf', kind: 'MITC: points terms are by reference to the Cardmember Agreement', date: 'MITC v2.23, 2 Nov 2026', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf', kind: 'Cardmember Agreement 23.5 (25,000 point cap, 5,000 shopping/dining/travel cap), 23.6, 23.8, 23.22', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/TnC_Ananta_Lounge.pdf', kind: 'lounge T&C (names no network)', date: '2026-03-01' },
            { url: 'https://www.au.bank.in/pdf/Ananta_Milestone-Benefit.pdf', kind: 'milestone T&C', date: '2026-03-01' },
            { url: 'https://www.au.bank.in/pdf/TnC-ANANTA_Welcome-Benefit.pdf', kind: 'welcome T&C', date: '2026-03-01' },
          ],
          unverified: [
            'Network: UNRESOLVED after a second sweep on 2026-11-07 (wave 3, W7). Only a "Visa Cardholders" popup on the page points to Visa; the page also says offers follow "your selected network variant" (same wording in AU\'s credit card comparison blog), so more than one network variant exists and the others are not named. Checked and found silent: the Ananta card art (listing tile and product-page art, no network mark on the front), the Ananta lounge, welcome and milestone T&Cs, the Amazon Fashion and District partner T&Cs, the Ananta blogs, AU\'s 6 May 2026 portfolio press release and the Q1 FY27 results note, KFS v1.9 and MITC v2.23 (they name a network only for the CheQ Visa), and the Cardmember Agreement of 16 May 2026 (clauses 3.14 to 3.16 allow a network change at renewal, "network selection, if applicable", and use "VISA/RuPay" for every card). Visa India\'s PSU offers page lists AU Small Finance Bank as a participating issuer but names no card, and visa.co.in, mastercard.co.in, npci.org.in and rupay.co.in carry no AU card list. Needs a physical card, the AU 0101 app card view, or a written answer from AU (1800 1200 1500; creditcard.priority@aubank.in is the KFS contact for Ananta). card_product.network left null.',
            'Point value: the Ananta page states ₹0.25 per point only through its milestone table. AU Rewardz FAQ and Cardmember Agreement clause 22.11 (16 May 2026 copy; 23.11 in the undated copy) say the conversion rate differs by card variant and point to the variant page; no other Ananta document states one. Redemption options by category are not listed on the page.',
            'Exclusion MCC lists are not published for Ananta (categories only).',
            'Cap after the 5,000-point cycle limit on shopping/dining/travel: the page and CMA give only the maximum, not what later spend earns. Modelled as dropping to base rate. Whether the cap counts all points in those categories (as the page words it) or only the bonus above base is not stated; modelled as bonus_reward_points.',
            'The 25,000-point per-cycle cap on all MCCs is from the CMA 23.5 table, which lists Ananta.',
            'Welcome benefit value in rupees is not stated; 8,000 points at ₹0.25 would be ₹2,000 (derived, not written into effective_value_inr).',
          ],
          notes: ['Milestone bonuses carry the rupee values printed in the page FAQ table (5,000 = ₹1,250; 10,000 = ₹2,500; 15,000 = ₹3,750; 20,000 = ₹5,000; total ₹12,500).', 'Cash and fuel spends do not count toward milestone spend (Milestone T&C).', 'Reward Points are earned in multiples of ₹100 (CMA 23.22), modelled as floor; points expire after 2 years (CMA 23.8).'],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Laksya
  'au-laksya': (() => {
    const o = common('au-laksya', 'https://www.au.bank.in/personal-banking/credit-cards/laksya-credit-card', 150, { fees: { emiPost: 0 } });
    return {
      ...o,
      card_product: { ...o.card_product, joining_fee_inr: 1000, annual_fee_inr: 1000, application_mode: 'open', point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated on the Laksya page, its FAQ or the welcome T&C (the welcome choice of 4,000 points or a ₹1,000 voucher is a choice, not a stated conversion). AU Rewardz FAQ: value depends on card variant and redemption category.', point_expiry_months: 24 },
      eligibility_engine: auEligibility(),
      accrual_engine: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000, capping_period_basis: 'statement_cycle' },
      reward_rules: [
        R({ id: 'laksya-grocery-5rp', cat: 'grocery', ppb: 5, mult: 5, cap: 'laksya-grocery-dept-cycle-cap', reason: 'FAQ: 5 Reward Points per ₹100 on grocery purchases; shared 1,000-point statement-cycle cap with departmental stores.' }),
        R({ id: 'laksya-departmental-5rp', cat: 'departmental_stores', ppb: 5, mult: 5, cap: 'laksya-grocery-dept-cycle-cap', reason: 'FAQ: 5 Reward Points per ₹100 on department stores; shared cap with grocery.' }),
        R({ id: 'laksya-contactless-5rp', cat: 'all_retail', rail: 'contactless', ppb: 5, mult: 5, reason: 'FAQ: 5 Reward Points per ₹100 on contactless (Tap & Pay); no maximum cap on contactless.' }),
        R({ id: 'laksya-base-2rp', cat: 'all_retail', pri: 35, type: 'standard_accrual', ppb: 2, mult: 2, cap: 'laksya-total-cycle-cap', reason: 'Page FAQ: 2 Reward Points per ₹100 on all other retail spends.' }),
        R({ id: 'laksya-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 1, cap: 'laksya-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page FAQ: 1 Reward Point per ₹100 on insurance, utility and telecom; at most 100 points per utility/telecom transaction.' }),
        R({ id: 'laksya-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 1, cap: 'laksya-total-cycle-cap', reason: 'Page FAQ: 1 Reward Point per ₹100 on insurance.' }),
        ...[['rent', 'rent', 'Rent'], ['cash', 'cash_withdrawal', 'Cash and quasi-cash'], ['education', 'education', 'Education'], ['govt', 'government', 'Government'], ['fuel', 'fuel', 'Fuel'], ['emi', 'excluded_spend', 'EMI'], ['bbps', 'excluded_spend', 'BBPS'], ['transport', 'excluded_spend', 'Transportation']].map(([k, cat, label]) => X(`laksya-excl-${k}`, cat, [], `${label} earns no Reward Points (page FAQ: Cash, Rent, Education & Govt, EMI, Fuel, BBPS, Transportation, Quasi Cash). MCC lists not published for this card.`)),
      ],
      cap_rules: [
        C({ id: 'laksya-grocery-dept-cycle-cap', cat: 'grocery', metric: 'bonus_reward_points', period: 'statement_cycle', points: 1000 }),
        C({ id: 'laksya-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' }),
      ],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 200000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹2,00,000 retail spends in the previous card anniversary year. No joining fee waiver.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 1000 },
        welcome_and_renewal_gift: { trigger: 'activation_and_first_transaction_within_30_days_of_issue', benefit_points: 4000, effective_value_inr: 1000, condition: 'Choose 4,000 bonus Reward Points OR brand vouchers worth ₹1,000; claim within 2 months of activation; choice cannot be changed; primary cardholder who paid the joining fee (Welcome Benefit T&C, 1 Mar 2026).' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'laksya-domestic-lounge', cat: 'lounge', program: 'N/A', sponsor: 'AU Small Finance Bank', label: 'Domestic airport lounge access (spend-based)', cond: { rule: 'Spend at least ₹50,000 in a calendar quarter to unlock access in the next calendar quarter', primary_cardholder_only: true, validation_swipe_inr: 2, max_per_quarter: 2, source: 'Page FAQ: 8 visits per calendar year, max 2 per quarter, on spending ₹50,000 in the previous quarter' }, calc: { page_headline_total: 8 }, qty: 8, per: 'annual', from: '2025-11-28' }),
        B({ id: 'laksya-bogo-movie', cat: 'movie', sponsor: 'AU Small Finance Bank', label: 'Buy-one-get-one movie tickets every month', qty: null, per: 'calendar_month', cond: 'N/A' }),
      ],
      dynamic_promotions_registry: [
        P({ id: 'laksya-partner-15pct', cat: 'other', sponsor: 'AU partner merchants (Amazon FreshNow, Zomato, District by Zomato listed)', platform: 'partner merchants', type: 'instant_discount', pct: 15 }),
      ],
      additional_data: { items: [
        { key: 'verified_network_research', value: { finding_status: 'partial', product_status: 'active', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/laksya-credit-card', evidence: 'Page (hidden popup, read from the DOM): a "Visa Cardholders" popup lists MakeMyTrip, Times Prime and Alaya Stays offers. Checked and NOT confirmed elsewhere: the Laksya lounge T&C (28 Nov 2025) says only "Visa/RuPay Network" for all eligible AU cards; the card art shows no network logo; the same popup also sits on the Paytm AU page, whose card art is RuPay Platinum, so the popup is a shared block, not proof for Laksya.', candidates: [
          { network: 'visa', network_tier: 'N/A', label: 'AU Laksya Credit Card (Visa offers popup)', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/laksya-credit-card', evidence: 'Popup heading "Visa Cardholders" on the product page. Not stated as the issued network.' },
        ] } },
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/personal-banking/credit-cards/laksya-credit-card', kind: 'issuer_page + FAQ + popups', read: 'rendered page text including hidden accordions and popups, re-read 2026-11-07 (base rates, exclusions, lounge split are in the FAQ)' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: 'https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf', kind: 'MITC: points terms are by reference to the Cardmember Agreement', date: 'MITC v2.23, 2 Nov 2026', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf', kind: 'Cardmember Agreement 23.5 (25,000 point cap; 1,000 grocery and departmental cap), 23.6, 23.8, 23.22', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/TnC_Laksya_Lounge.pdf', kind: 'lounge T&C ("Visa/RuPay Network")', date: '2025-11-28', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/TnC-Laksya_Welcome-Benefit.pdf', kind: 'welcome T&C', date: '2026-03-01' },
          ],
          unverified: [
            'Network: UNRESOLVED after a second sweep on 2026-11-07 (wave 3, W7). The Laksya lounge T&C defines an eligible card as one "issued by AU Bank on Visa/RuPay Network", which covers every AU card and does not pick one; a "Visa Cardholders" popup on the page is the only Laksya-specific hint and is a block shared with other AU cards. Checked and found silent: the Laksya card art (listing tile and product-page art, no network mark on the front), the Laksya welcome T&C and the Amazon FreshNow, Zomato and District partner T&Cs, AU\'s 6 May 2026 portfolio press release and the Q1 FY27 results note, KFS v1.9 and MITC v2.23 (they name a network only for the CheQ Visa), and the Cardmember Agreement of 16 May 2026 (clauses 3.14 to 3.16 allow a network change at renewal and use "VISA/RuPay" for every card). visa.co.in, mastercard.co.in, npci.org.in and rupay.co.in carry no AU card list. Needs a physical card, the AU 0101 app card view, or a written answer from AU (1800 1200 1500; creditcard.support@aubank.in). card_product.network left null.',
            'Reward Point value in rupees: not stated for Laksya. AU Rewardz FAQ and Cardmember Agreement clause 22.11 (16 May 2026 copy; 23.11 in the undated copy) say the conversion rate differs by card variant and point to the variant page, and the Laksya page, FAQ and welcome T&C state none. effective_base_return_percent left null.',
            'Exclusion MCC lists are not published for Laksya (categories only).',
            'The 25,000-point per-cycle cap on all MCCs is from the CMA 23.5 table, which lists Laksya.',
          ],
          notes: [
            'Xpress EMI processing fee is zero on Laksya per KFS section 12.',
            'Lounge quota resolved from the page FAQ: 8 domestic visits per calendar year, at most 2 per quarter, after ₹50,000 spent in the previous quarter (the lounge T&C states the ₹50,000 rule).',
            'Reward Points are earned in multiples of ₹100 (CMA 23.22), modelled as floor; points expire after 2 years (CMA 23.8).',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Tejas
  'au-tejas': (() => {
    const o = common('au-tejas', 'https://www.au.bank.in/personal-banking/credit-cards/tejas-credit-card', 100);
    const partner = (id, cat, sponsor, platform) => P({ id, cat, sponsor, platform, type: 'cashback', pct: 10, max: 50, quota: true });
    return {
      ...o,
      card_product: { ...o.card_product, joining_fee_inr: 500, annual_fee_inr: 500, application_mode: 'open', point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated on the Tejas page, its FAQ or the welcome T&C (the welcome choice of 2,000 points or a ₹500 voucher is a choice, not a stated conversion). AU Rewardz FAQ: value depends on card variant and redemption category.', point_expiry_months: 24 },
      eligibility_engine: auEligibility(),
      accrual_engine: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000, capping_period_basis: 'statement_cycle' },
      reward_rules: [
        R({ id: 'tejas-rewardz-5rp', cat: 'all_retail', rail: 'smartbuy_or_equivalent_portal', ppb: 5, mult: 5, cap: 'tejas-total-cycle-cap', cond: { platform: 'AU Rewardz portal (rewardz.au.bank.in)', applies_to: 'flights, hotels, voucher shopping, bill payments and other purchases made through the AU Rewardz portal' }, reason: 'Page FAQ (re-read 2026-11-07): "5 Reward Points per ₹100 spent on any transactions made through the AU Rewardz portal" - flights, hotels, voucher shopping, bill payments etc. via AU Rewardz.' }),
        R({ id: 'tejas-base-1rp', cat: 'all_retail', pri: 35, type: 'standard_accrual', ppb: 1, mult: 1, cap: 'tejas-total-cycle-cap', reason: 'Page FAQ: 1 Reward Point per ₹100 on all other spends.' }),
        R({ id: 'tejas-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 1, cap: 'tejas-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page footnote: at most 100 Reward Points per transaction on utility and telecom spends; the rate is the 1 point per ₹100 base.' }),
        ...[['rent', 'rent', 'Rent'], ['cash', 'cash_withdrawal', 'Cash and quasi-cash'], ['education', 'education', 'Education'], ['govt', 'government', 'Government'], ['fuel', 'fuel', 'Fuel'], ['emi', 'excluded_spend', 'EMI'], ['bbps', 'excluded_spend', 'BBPS'], ['transport', 'excluded_spend', 'Transportation']].map(([k, cat, label]) => X(`tejas-excl-${k}`, cat, [], `${label} earns no Reward Points (page FAQ: Cash, Rent, Education & Govt, EMI, Fuel, BBPS, Transportation, Quasi Cash). MCC lists not published for this card.`)),
      ],
      cap_rules: [C({ id: 'tejas-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 150000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹1,50,000 retail spends in the previous card anniversary year. No joining fee waiver.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 500 },
        welcome_and_renewal_gift: { trigger: 'activation_and_first_transaction_within_30_days_of_issue', benefit_points: 2000, effective_value_inr: 500, condition: 'Choose 2,000 bonus Reward Points OR brand vouchers worth ₹500; claim within 6 months of activation; choice cannot be changed (Welcome Benefit T&C, 1 Mar 2026).' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [],
      dynamic_promotions_registry: [
        partner('tejas-district-movies', 'movie', 'District by Zomato', 'District'),
        partner('tejas-amazon-fresh', 'grocery', 'Amazon Fresh', 'Amazon Fresh'),
        partner('tejas-zomato', 'dining', 'Zomato', 'Zomato food delivery'),
        partner('tejas-cabs', 'travel', 'Uber / Ola / Rapido', 'Cab services'),
        partner('tejas-bill-pay', 'utility', 'AU 0101', 'AU 0101 bill payments'),
      ].map((p) => ({ ...p, valid_from: null })),
      additional_data: { items: [
        { key: 'verified_network_research', value: { finding_status: 'partial', product_status: 'active', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/tejas-credit-card', evidence: 'Page (hidden popup, read from the DOM): a "Visa Cardholders" popup lists MakeMyTrip, Times Prime and Alaya Stays offers. Checked and NOT confirmed elsewhere: the Tejas page lists no lounge benefit so there is no lounge T&C to read, the card art shows no network logo, and the same popup also sits on the Paytm AU page, whose card art is RuPay Platinum, so the popup is a shared block, not proof for Tejas.', candidates: [
          { network: 'visa', network_tier: 'N/A', label: 'AU Tejas Credit Card (Visa offers popup)', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/tejas-credit-card', evidence: 'Popup heading "Visa Cardholders" on the product page. Not stated as the issued network.' },
        ] } },
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/personal-banking/credit-cards/tejas-credit-card', kind: 'issuer_page + FAQ + popups', read: 'rendered page text including hidden accordions and popups, re-read 2026-11-07 (portal definition of the 5-point rate, base rate, exclusions and the 500-point bonus condition are in the FAQ)' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: 'https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf', kind: 'MITC: points terms are by reference to the Cardmember Agreement', date: 'MITC v2.23, 2 Nov 2026', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf', kind: 'Cardmember Agreement 23.5 (25,000 point cap lists Tejas), 23.6, 23.8, 23.22', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/TnC-TEJAS_Welcome-Benefit.pdf', kind: 'welcome T&C', date: '2026-03-01' },
            { url: 'https://www.au.bank.in/pdf/Zomato-AU-Tejas-Credit-Card.pdf', kind: 'partner offer T&C' },
          ],
          unverified: [
            'Network: UNRESOLVED after a second sweep on 2026-11-07 (wave 3, W7). Only a "Visa Cardholders" popup on the page points to Visa, and that block is shared with other AU cards. Checked and found silent: the Tejas card art (listing tile and product-page art, no network mark on the front), the Tejas welcome T&C and the District, Amazon FreshNow, Zomato, cab and bill-payment partner T&Cs, AU\'s 6 May 2026 portfolio press release and the Q1 FY27 results note, KFS v1.9 and MITC v2.23 (they name a network only for the CheQ Visa), and the Cardmember Agreement of 16 May 2026 (clauses 3.14 to 3.16 allow a network change at renewal and use "VISA/RuPay" for every card). Tejas has no lounge benefit, so no lounge T&C exists to read. visa.co.in, mastercard.co.in, npci.org.in and rupay.co.in carry no AU card list. Needs a physical card, the AU 0101 app card view, or a written answer from AU (1800 1200 1500; creditcard.support@aubank.in). card_product.network left null.',
            'Reward Point value in rupees: not stated for Tejas. AU Rewardz FAQ and Cardmember Agreement clause 22.11 (16 May 2026 copy; 23.11 in the undated copy) say the conversion rate differs by card variant and point to the variant page, and the Tejas page, FAQ and welcome T&C state none (the welcome choice of 2,000 points or a ₹500 voucher is a choice, not a conversion). effective_base_return_percent left null.',
            'Exclusion MCC lists are not published for Tejas (categories only).',
            'The 25,000-point per-cycle cap on all MCCs is from the CMA 23.5 table, which lists Tejas. No separate cap is stated for the 5-point portal rate.',
          ],
          notes: [
            'Resolved from the page FAQ: the 5-point rate is earned only on purchases made through the AU Rewardz portal (flights, hotels, voucher shopping, bill payments); all other spends earn 1 point per ₹100; at most 100 points per utility or telecom transaction.',
            'Bonus 500 Reward Points: need at least 5 transactions of ₹500 or more within one statement cycle (page FAQ). Not modelled because the milestone schema is spend-based, not transaction-count-based.',
            'Reward Points are earned in multiples of ₹100 (CMA 23.22), modelled as floor; points expire after 2 years (CMA 23.8).',
            'Partner offers: each is 10% (max ₹50, minimum transaction ₹150, once per month) at District, Amazon Fresh, Zomato, Uber/Ola/Rapido and AU 0101 bill payments (FAQ table). Recorded as partner offers, not reward rates.',
            'Also listed on the page: Card Liability Cover, Credit Shield, Device Protection Plan (no cover amounts given).',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Prathama
  'au-prathama': (() => {
    const o = common('au-prathama', 'https://www.au.bank.in/personal-banking/credit-cards/prathama-credit-card', 100);
    return {
      ...o,
      card_product: { ...o.card_product, joining_fee_inr: 100, annual_fee_inr: 100, application_mode: 'open', point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated for Prathama: the page and FAQ (hidden accordions included, re-read 2026-11-07) say only "Redeem your Reward Points for a range of amazing benefits", there is no Prathama welcome, lounge or milestone T&C, and AU Rewardz FAQ and Cardmember Agreement clause 22.11 say the rate depends on the card variant and redemption category and defer to the variant page. Left null on purpose.', point_expiry_months: 24 },
      eligibility_engine: auEligibility(),
      accrual_engine: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000, capping_period_basis: 'statement_cycle' },
      reward_rules: [
        R({ id: 'prathama-contactless-2rp', cat: 'all_retail', rail: 'contactless', ppb: 2, mult: 2, cap: 'prathama-total-cycle-cap', reason: 'FAQ: 2 Reward Points per ₹100 on contactless (Tap & Pay) transactions.' }),
        R({ id: 'prathama-cycle-over-5000-2rp', cat: 'all_retail', pri: 30, ppb: 2, mult: 2, cap: 'prathama-incremental-cycle-cap', cond: { cycle_spend_gt_inr: 5000, applies_to: 'incremental spend beyond ₹5,000 in a statement cycle' }, reason: 'Page: 2 Reward Points per ₹100 on incremental spends once the cycle crosses ₹5,000; CMA 23.5.2 caps this at 1,000 points per statement cycle. Threshold-gated; the engine cannot know whether it was crossed, so review before projecting.' }),
        R({ id: 'prathama-base-1rp', cat: 'all_retail', pri: 35, type: 'standard_accrual', ppb: 1, mult: 1, cap: 'prathama-total-cycle-cap', reason: 'Page FAQ: 1 Reward Point per ₹100 on all other eligible transactions.' }),
        R({ id: 'prathama-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 1, cap: 'prathama-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page footnote: at most 100 Reward Points per transaction on utility and telecom spends; the rate is the 1 point per ₹100 base.' }),
        ...[['rent', 'rent', 'Rent'], ['cash', 'cash_withdrawal', 'Cash and cash-like transactions'], ['education', 'education', 'Education fees'], ['govt', 'government', 'Government payments'], ['fuel', 'fuel', 'Fuel'], ['emi', 'excluded_spend', 'EMI transactions and conversions'], ['bbps', 'excluded_spend', 'BBPS'], ['transport', 'excluded_spend', 'Transportation']].map(([k, cat, label]) => X(`prathama-excl-${k}`, cat, [], `${label} earns no Reward Points (page FAQ and footnote). MCC lists not published for this card.`)),
      ],
      cap_rules: [
        C({ id: 'prathama-incremental-cycle-cap', cat: 'all_retail', metric: 'bonus_reward_points', period: 'statement_cycle', points: 1000 }),
        C({ id: 'prathama-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' }),
      ],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 75000, period: 'card_anniversary_year', evaluation_condition: 'From the 2nd year: ₹75,000 spends in the previous card anniversary year. No joining fee waiver.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 100 },
        welcome_and_renewal_gift: { trigger: 'N/A', benefit_points: 'N/A', effective_value_inr: 'N/A', condition: 'FAQ: no welcome benefit on Prathama.' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [],
      dynamic_promotions_registry: [],
      additional_data: { items: [
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/personal-banking/credit-cards/prathama-credit-card', kind: 'issuer_page + FAQ', read: 'rendered page text including hidden accordions and popups, re-read 2026-11-07 (base rate and exclusions are in the FAQ)' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: 'https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf', kind: 'MITC: points terms are by reference to the Cardmember Agreement', date: 'MITC v2.23, 2 Nov 2026', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf', kind: 'Cardmember Agreement 23.5 (25,000 point cap lists Prathama), 23.5.2 (Prathama 2 points above ₹5,000, max 1,000 per cycle), 23.8, 23.22', date: 'undated', read: 'pdftotext' },
          ],
          unverified: [
            'Network: UNRESOLVED after a second sweep on 2026-11-07 (wave 3, W7). The Prathama page carries no network text at all (not even the shared Visa popup), the Prathama card art (listing tile and product-page art) shows no network mark on the front, and AU publishes no Prathama-specific PDF. Also silent: AU\'s 6 May 2026 portfolio press release and the Q1 FY27 results note, KFS v1.9 and MITC v2.23 (they name a network only for the CheQ Visa), and the Cardmember Agreement of 16 May 2026 (clauses 3.14 to 3.16 allow a network change at renewal and use "VISA/RuPay" for every card). visa.co.in, mastercard.co.in, npci.org.in and rupay.co.in carry no AU card list. Needs a physical card, the AU 0101 app card view, or a written answer from AU (1800 1200 1500; creditcard.support@aubank.in). card_product.network left null.',
            'Reward Point value in rupees: not stated for Prathama (see point_value_baseline_basis). Ask AU, or read the value from a Prathama redemption screen in AU Rewardz, before filling it. effective_base_return_percent left null.',
            'CMA 23.5.2 says Prathama holders can earn "a maximum of 1000 Reward Points per statement cycle" after the ₹5,000 threshold: modelled as a cap on the incremental 2-point rate only; whether it caps all points is not stated.',
            'Exclusion MCC lists are not published for Prathama (categories only).',
          ],
          notes: ['500 bonus Reward Points on each successful recurring-payment (standing instruction) setup, once per merchant for life (page FAQ); event bonus, not a spend rate, so not modelled.', 'Resolved from the page FAQ: 1 Reward Point per ₹100 on all other eligible transactions; at most 100 points per utility or telecom transaction.', 'Reward Points are earned in multiples of ₹100 (CMA 23.22), modelled as floor; points expire after 2 years (CMA 23.8).'],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Paytm AU
  'paytm-au-credit-card': (() => {
    const o = common('paytm-au-credit-card', 'https://www.au.bank.in/personal-banking/credit-cards/paytm-au-credit-card', 100);
    const PAYTM_EXCL = [
      ['paytm-excl-wallet', 'wallet_load', [6540], 'Wallet reloads earn nothing.'],
      ['paytm-excl-rent', 'rent', [6513], 'Rental payments / real estate earn nothing.'],
      ['paytm-excl-education', 'education', [8211, 8220, 8241, 8244, 8249, 8299], 'Education earns nothing.'],
      ['paytm-excl-govt', 'government', [9211, 9222, 9223, 9311, 9399, 9400, 9402, 9405], 'Government services earn nothing.'],
      ['paytm-excl-fuel', 'fuel', [5983, 5172, 5541, 5542], 'Fuel earns nothing.'],
      ['paytm-excl-utilities', 'utility', [4812, 4814, 4899, 4900], 'Utilities earn nothing.'],
      ['paytm-excl-transport', 'excluded_spend', [4011, 4111, 4112, 4121, 4131, 4411, 4582, 4784, 4789, 5561, 7523], 'Transportation earns nothing.'],
      ['paytm-excl-insurance', 'insurance', [5960, 6300], 'Insurance earns nothing.'],
    ].map(([id, cat, mccs, why]) => X(id, cat, mccs, `${why} (Reward Point Usage T&C, exclusion list 1.)`));
    return {
      ...o,
      card_product: { ...o.card_product, network: 'rupay', network_tier: 'rupay_platinum', is_upi_linkable: true, joining_fee_inr: 0, annual_fee_inr: 0, application_mode: 'open', point_value_inr_baseline: 0.5, point_value_baseline_basis: 'FAQ: 1 Reward Point = ₹1 when redeemed on Paytm Gold, ₹0.50 across other categories. Baseline uses ₹0.50; Paytm Gold redemption doubles it.' },
      eligibility_engine: auEligibility(),
      accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: 3000, capping_period_basis: 'statement_cycle' },
      reward_rules: [
        ...PAYTM_EXCL,
        R({ id: 'paytm-upi-2rp', cat: 'upi', rail: 'upi_qr', pri: 10, ppb: 2, mult: 2, channel: 'paytm_upi', cond: { platform: 'Paytm UPI', transaction_amount_min_inr: 100, transaction_amount_max_inr: 2000 }, cap: 'paytm-au-cycle-cap', reason: '2 Reward Points per ₹100 on Paytm UPI for transactions of ₹100 to ₹2,000.' }),
        R({ id: 'paytm-upi-1rp-above-2000', cat: 'upi', rail: 'upi_qr', pri: 11, ppb: 1, mult: 1, channel: 'paytm_upi', cond: { platform: 'Paytm UPI', transaction_amount_gt_inr: 2000 }, cap: 'paytm-au-cycle-cap', reason: '1 Reward Point per ₹100 on Paytm UPI for transactions above ₹2,000.' }),
        R({ id: 'paytm-online-travel-5rp', cat: 'all_retail', rail: 'online', pri: 5, ppb: 5, mult: 5, channel: 'paytm_app', cond: { platform: 'Paytm app', merchant_scope: 'MIDs agreed between Paytm and the bank', nature: 'online' }, cap: 'paytm-au-cycle-cap', reason: '5 Reward Points per ₹100 on Paytm online and travel spends made through the Paytm app, identified by agreed merchant IDs.' }),
        R({ id: 'paytm-other-upi-1rp-per-400', cat: 'upi', rail: 'upi_qr', pri: 12, ppb: 1, mult: 1, cond: { transaction_amount_gt_inr: 400, other_upi_apps: true, per_inr_block: 400 }, cap: 'paytm-au-cycle-cap', reason: '1 Reward Point per ₹400 on UPI done through any other UPI app (non-excluded categories). Block is ₹400, not ₹100.' }),
        R({ id: 'paytm-online-1rp', cat: 'all_retail', rail: 'online', pri: 20, type: 'standard_accrual', ppb: 1, mult: 1, cond: { nature: 'online', minimum_transaction_inr: 100 }, cap: 'paytm-au-cycle-cap', reason: '1 Reward Point per ₹100 on online retail spends (minimum ₹100).' }),
        R({ id: 'paytm-offline-1rp', cat: 'all_retail', rail: 'pos_terminal', pri: 20, type: 'standard_accrual', ppb: 1, mult: 1, cond: { nature: 'offline', minimum_transaction_inr: 100 }, cap: 'paytm-au-cycle-cap', reason: '1 Reward Point per ₹100 on offline retail spends (minimum ₹100).' }),
      ],
      cap_rules: [C({ id: 'paytm-au-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 3000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: no joining or annual fee (page and KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'paytm-au-lounge', cat: 'lounge', sponsor: 'Paytm Travel', label: 'Complimentary domestic airport lounge access via Paytm Travel (for the cardholder and companions)', cond: { rule: 'Book a return flight through Paytm Travel on the Paytm app; minimum round-trip booking value ₹5,000 to generate 1 Lounge QR; max 4 lounge accesses per booking; QR once generated cannot be cancelled or reversed', booking_channel: 'Paytm Travel', min_round_trip_booking_inr: 5000, max_per_booking: 4, source: 'Paytm AU product page, re-read 2026-11-07' }, qty: 12, per: 'N/A' }),
      ],
      dynamic_promotions_registry: [],
      redemption_matrix: {
        direct_options: [
          { channel: 'Paytm Gold on the Paytm app', redemption_type: 'other', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 'N/A', effective_from: null, effective_to: null },
          { channel: 'Other categories (Paytm app and AU rewards portal)', redemption_type: 'other', inr_value_per_point: 0.5, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 99, effective_from: null, effective_to: null },
        ],
        partner_transfers: [],
      },
      additional_data: { items: [
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/personal-banking/credit-cards/paytm-au-credit-card', kind: 'issuer_page + FAQ', read: 'rendered page text' },
            { url: 'https://www.au.bank.in/pdf/Paytm-AU-Credit-Card-Rewards-TCs.pdf', kind: 'Reward Point Usage T&C (earn rules, cap, exclusions)', read: 'pdftotext' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
          ],
          unverified: [
            'Network: RuPay Platinum is printed on the card image shown on the AU product page ("Paytm RuPay Platinum" art with the RuPay Platinum logo); the UPI-linked earn rules fit RuPay. The page also carries a shared "Visa Cardholders" offers popup (MakeMyTrip, Times Prime, Alaya Stays) which looks like a shared block rather than a statement about this card; whether a Visa variant also exists is not stated, so only RuPay is set.',
            'The 5-point merchant ID list is agreed between Paytm and AU and is not published.',
            'Lounge: 12 complimentary domestic lounge accesses are stated, but the period they run over (year, card year or total) is not.',
            'Reward Point Usage T&C carries no revision date.',
            'Conflict: the product page lists "1 Reward Point per ₹100 spent on Paytm Utility Bill payments via Paytm app", while the Reward Point Usage T&C excludes utilities (MCCs 4812, 4814, 4899, 4900). The T&C exclusion is kept; the page line may refer to a different MCC.',
          ],
          notes: [
            'Page (re-read 2026-11-07) states the point value as 1 Reward Point = ₹1 on Paytm Gold and ₹0.50 on AU Rewardz; base earn is 1 Reward Point per ₹100 on online and offline spends. Both were already in the draft; no change.',
            'Lounge (page): 12 complimentary domestic airport lounge accesses on booking return flights via Paytm Travel on the Paytm app; minimum round-trip booking ₹5,000 for 1 Lounge QR; max 4 per booking. Recorded in the lounge benefit.',
            'Headline "up to 2% on Paytm UPI" and "5% on Paytm spends" assume ₹1 per point (Paytm Gold). At the ₹0.50 other-category value they are 1% and 2.5%.',
            'Minimum transaction ₹100 per transaction (₹400 for UPI on other apps).',
            'Redemption fee ₹99 + GST per successful redemption applies (KFS).',
          ],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── Traverse (NRI)
  'au-traverse-nri': (() => {
    const o = common('au-traverse-nri', 'https://www.au.bank.in/premium-banking/credit-cards/traverse-credit-card', 250, { fees: { forex: 0.99, cashLimit: 50, atmFee: 0 } });
    return {
      ...o,
      card_product: { ...o.card_product, joining_fee_inr: 4999, annual_fee_inr: 4999, application_mode: 'open', point_value_inr_baseline: null, point_value_baseline_basis: 'Value of one AU Reward Point is not stated for Traverse: the page (hidden accordions included, re-read 2026-11-07) has no redemption or point-value text, the welcome gift (MakeMyTrip voucher) and milestone benefit (Taj voucher) T&Cs are voucher terms with no point conversion, and AU Rewardz FAQ and Cardmember Agreement clause 22.11 say the rate depends on the card variant and redemption category and defer to the variant page. Left null on purpose.', point_expiry_months: 24 },
      eligibility_engine: {
        evaluation_mode: 'all_pass',
        notes: 'Apply at a branch. Needs both an NRE account and an NRE FD with AU.',
        rules: [
          { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['non_resident_indian'] },
          { parameter: 'au_nre_account', operator: '==', threshold_value: 1, allowed_values: [] },
          { parameter: 'au_nre_fd', operator: '==', threshold_value: 1, allowed_values: [] },
          { parameter: 'age_years', operator: '>=', threshold_value: 18, allowed_values: [] },
          { parameter: 'age_years', operator: '<=', threshold_value: 75, allowed_values: [] },
        ],
      },
      accrual_engine: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: 25000, capping_period_basis: 'statement_cycle' },
      reward_rules: [
        ...[['fuel', 'fuel', 'Fuel'], ['emi', 'excluded_spend', 'EMI'], ['cash', 'cash_withdrawal', 'Cash'], ['rent', 'rent', 'Rent'], ['education', 'education', 'Education'], ['govt', 'government', 'Government']].map(([k, cat, label]) => X(`traverse-excl-${k}`, cat, [], `${label} MCC transactions are not eligible for Reward Points (Traverse page note, re-read 2026-11-07). MCC lists not published for this card.`)),
        R({ id: 'traverse-international-4rp', cat: 'international_spend', pri: 10, ppb: 4, mult: 2, cap: 'traverse-total-cycle-cap', cond: { transaction_type: 'international' }, reason: 'Page (re-read 2026-11-07): 4 Reward Points per ₹100 on international spends.' }),
        R({ id: 'traverse-bills-1rp', cat: 'bills', pri: 25, ppb: 1, mult: 0.5, cap: 'traverse-total-cycle-cap', cond: { includes: ['utility', 'telecom'], max_points_per_transaction: 100 }, reason: 'Page: 1 Reward Point per ₹100 on insurance, utility and telecom payments; at most 100 points per utility and telecom transaction.' }),
        R({ id: 'traverse-insurance-1rp', cat: 'insurance', pri: 25, ppb: 1, mult: 0.5, cap: 'traverse-total-cycle-cap', reason: 'Page: 1 Reward Point per ₹100 on insurance.' }),
        R({ id: 'traverse-domestic-2rp', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cap: 'traverse-total-cycle-cap', cond: { transaction_type: 'domestic' }, reason: 'Page: 2 Reward Points per ₹100 on domestic spends.' }),
      ],
      cap_rules: [C({ id: 'traverse-total-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 25000, after: 'zero_accrual' })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 600000, period: 'card_anniversary_year', evaluation_condition: 'Waiver on completing ₹6 lakh spends in a card anniversary year (page).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 4999 },
        welcome_and_renewal_gift: { trigger: 'card_activation_within_30_days_of_card_setup', benefit_points: 'N/A', effective_value_inr: 5000, condition: 'MakeMyTrip gift card/voucher worth ₹5,000 (GyFTR); claim within 180 days of the first eligibility message (Welcome Benefit T&C).' },
        spend_milestones: [
          { id: 'traverse-taj-10l', label: 'Taj voucher worth ₹10,000', threshold_spend_inr: 1000000, reward_value_inr: 10000, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'traverse-spa', cat: 'other', sponsor: 'AU Small Finance Bank', label: 'Complimentary airport spa access', qty: 4, per: 'annual', cond: { max_per_quarter: 1 } }),
        B({ id: 'traverse-lounge', cat: 'lounge', program: 'priority_pass', sponsor: 'AU Small Finance Bank', label: 'Domestic and international airport lounge access', cond: { page: '2 complimentary domestic and international airport lounge accesses per quarter', priority_pass_doc: 'Priority Pass terms list Traverse at 2 international lounge accesses per calendar quarter; Priority Pass use within India is chargeable at USD 35 per visit', primary_cardholder_only: true }, qty: 2, per: 'quarter' }),
        B({ id: 'traverse-meet-assist', cat: 'concierge', sponsor: 'AU Small Finance Bank', label: 'Complimentary airport meet and assist (end-to-end VIP check-in; page: 4 services a year, 1 per quarter; book via concierge 1800 210 0298)', cond: { max_per_quarter: 1 }, qty: 4, per: 'annual' }),
      ],
      dynamic_promotions_registry: [
        P({ id: 'traverse-duty-free', cat: 'other', sponsor: 'AU Small Finance Bank', platform: 'duty-free shopping', type: 'flat_cashback_₹500_on_min_spend_₹10000', max: 500 }),
      ],
      additional_data: { items: [
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/premium-banking/credit-cards/traverse-credit-card', kind: 'issuer_page', read: 'rendered page text' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: 'https://www.au.bank.in/pdf/traverse-credit-card/welcome-benefit.pdf', kind: 'welcome T&C', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/traverse-milestone-benefit.pdf', kind: 'milestone T&C', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/credit-cards/mitc(with-schedule-of-charges).pdf', kind: 'MITC: points terms are by reference to the Cardmember Agreement', date: 'MITC v2.23, 2 Nov 2026', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/credit-cards/credit-card-member-agreement.pdf', kind: 'Cardmember Agreement 23.5 (25,000 point cap lists Traverse NRI), 23.8, 23.22', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/zenith-plus-credit-card/Priority%20Pass%20Lounges.pdf', kind: 'Priority Pass usage T&C (Traverse: 2 international accesses per calendar quarter, USD 35 per paid visit)', date: 'undated', read: 'pdftotext' },
            { url: 'https://www.au.bank.in/pdf/zenith-plus-credit-card/au-small-finance-bank-cc-airport-lounge-terms-conditions.pdf', kind: 'airport lounge program T&C (spend-based domestic lounge excludes Zenith+ and Traverse; names "Visa/RuPay" generically)', date: 'undated; revision w.e.f. 10 Apr 2026', read: 'pdftotext' },
          ],
          unverified: [
            'RESOLVED on re-check 2026-11-07: the page now states the earn rates (4 Reward Points per ₹100 international, 2 domestic, 1 on insurance, utility and telecom, max 100 points per utility/telecom transaction). The card is no longer held for lack of a rate.',
            'Network: UNRESOLVED after a second sweep on 2026-11-07 (wave 3, W7). The Traverse page, its NRI and premium listing pages, the Traverse welcome, milestone and Meet & Assist T&Cs and the Priority Pass usage T&C name no network. The Traverse card art (listing tile and product-page art: navy card, chip, no contactless mark, no network mark on the front) shows none. The AU lounge programme T&C names "Visa/RuPay" for every eligible AU card and excludes Traverse from the domestic programme. Also silent: KFS v1.9 and MITC v2.23 (they name a network only for the CheQ Visa, and list Traverse (NRI) only for fees, the 0.99% markup and the Priority Pass charge), and the Cardmember Agreement of 16 May 2026 (clauses 3.14 to 3.16 allow a network change at renewal and use "VISA/RuPay" for every card). visa.co.in, mastercard.co.in, npci.org.in and rupay.co.in carry no AU card list. Needs a physical card or the AU 0101 app card view, or a written answer from AU (1800 1200 1500; creditcard.support@aubank.in; Traverse concierge 1800 210 0298). card_product.network left null.',
            'Reward Point value in rupees: not stated for Traverse (see point_value_baseline_basis). Ask AU, or read the value from a Traverse redemption screen in AU Rewardz, before filling it. effective_base_return_percent left null.',
            'Lounge: the page says 2 complimentary domestic and international accesses per quarter; the Priority Pass T&C gives Traverse 2 international per quarter and says Priority Pass use in India is chargeable, and the spend-based domestic programme excludes Traverse. Whether the 2 per quarter are domestic or international or either is unclear. Recorded as 2 per quarter, Priority Pass.',
            'Exclusion MCC lists are not published for Traverse (categories only). Cash and fuel are also excluded from milestone spend.',
            'Whether international spend is defined by merchant location or currency is not stated.',
          ],
          notes: [
            'Reward Points are earned in multiples of ₹100 (CMA 23.22), modelled as floor; points expire after 2 years (CMA 23.8); 25,000-point per-cycle cap on all MCCs is from the CMA 23.5 table.','KFS lists ₹4,999 for both Zenith+ and Traverse in one row; joining fee set equal to annual per the KFS header "Joining fee ... / Annual membership fees".', 'Zero cash-withdrawal fee and 0.99% forex markup per KFS.', 'Fuel surcharge waiver up to ₹250 per statement month.'],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),

  // ───────────────────────────────────────────────────────────── CheQ AU
  'cheq-au-credit-card': (() => {
    const o = common('cheq-au-credit-card', 'https://www.au.bank.in/personal-banking/credit-cards/cheq-au-credit-card', 150, { fuelMin: 500 });
    const MIN = { minimum_transaction_inr: 200 };
    const CHEQ_EXCL = [
      ['cheq-excl-wallet', 'wallet_load', [6540], 'Wallet reloads'], ['cheq-excl-jewellery', 'jewellery', [5944, 5094], 'Jewellery and gold'],
      ['cheq-excl-rent', 'rent', [6513], 'Rent / real estate'], ['cheq-excl-insurance', 'insurance', [6300, 6381, 5960, 6012, 6051, 6399], 'Insurance'],
      ['cheq-excl-education', 'education', [8211, 8220, 8241, 8244, 8249, 8299], 'Education'], ['cheq-excl-govt', 'government', [9211, 9222, 9223, 9311, 9399, 9400, 9402, 9405], 'Government services'],
      ['cheq-excl-fuel', 'fuel', [5983, 5172, 5541, 5542], 'Fuel'], ['cheq-excl-gaming', 'gaming', [5816], 'Digital gaming'], ['cheq-excl-cash', 'cash_withdrawal', [6010, 6011], 'Cash'],
    ].map(([id, cat, mccs, label]) => X(id, cat, mccs, `${label} earns nothing (CheQ AU Reward Points Usage T&C, Exclusion Categories).`));
    return {
      ...o,
      card_product: { ...o.card_product, network: null, joining_fee_inr: 0, annual_fee_inr: 0, application_mode: 'open', is_upi_linkable: true, form_factors: ['virtual_card', 'physical_plastic'], point_value_inr_baseline: 0.5, point_value_baseline_basis: 'CheQ T&C: 2 CheQ Points = ₹1 on flights, hotels and gift cards; 4 points = ₹1 on bill payments. Baseline uses 2 points = ₹1.' },
      eligibility_engine: auEligibility([{ parameter: 'cheq_app_registered_user', operator: '==', threshold_value: 1, allowed_values: [] }]),
      accrual_engine: { base_block_inr: 200, rounding_mode: 'floor', base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: null, capping_period_basis: 'calendar_month' },
      reward_rules: [
        ...CHEQ_EXCL,
        R({ id: 'cheq-12pct-partners', cat: 'all_retail', pri: 5, ppb: 24, mult: 12, channel: 'partner_brands', cond: { ...MIN, partner_brands: ['Amazon', 'Flipkart', 'Zomato', 'BigBasket', 'Apple Products (Unicorn)', 'CheQ Travel (flights and hotels)'], also: 'utility bills paid via the CheQ app', applies_to: 'Visa variant; RuPay variant only via CheQ app UPI or CheQ Travel/utility', identified_by: 'merchant ID' }, cap: 'cheq-accelerated-monthly-cap', reason: '12% CheQ points = 24 points per ₹200 on partner brands and CheQ-app utility bills. At 2 points = ₹1 that is about 6% in value (3% when redeemed on bills at 4 points = ₹1).' }),
        R({ id: 'cheq-5pct-categories', cat: 'all_retail', pri: 10, ppb: 10, mult: 5, cond: { ...MIN, mcc_list: [5814, 5812, 5262, 5611, 5621, 5651, 5691, 5699, 5732, 5942, 5311, 5631, 5641, 5999, 7296, 5310, 5331, 5399, 5655, 5661, 5681, 5698, 5941, 5945, 5411, 5499, 4112, 4511, 4131, 4722, 4723, 4011, 4121, 7011], applies_to: 'Visa variant; RuPay variant only via CheQ app UPI' }, cap: 'cheq-accelerated-monthly-cap', reason: '5% CheQ points = 10 points per ₹200 on listed dining, shopping, grocery and travel MCCs. About 2.5% in value at 2 points = ₹1.' }),
        R({ id: 'cheq-upi-2-5pct', cat: 'upi', rail: 'upi_qr', pri: 12, ppb: 5, mult: 2.5, channel: 'cheq_upi', cond: { ...MIN, app: 'CheQ UPI', variant: 'RuPay' }, reason: '2.5% CheQ points = 5 points per ₹200 on UPI through the CheQ app on the RuPay variant; UPI via other apps earns zero. Outside the accelerated cap.' }),
        R({ id: 'cheq-base-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: MIN, reason: '1% CheQ points = 2 points per ₹200 on all other eligible spends; no monthly or annual cap on base rewards. About 0.5% in value.' }),
      ],
      cap_rules: [C({ id: 'cheq-accelerated-monthly-cap', cat: 'all_retail', metric: 'bonus_reward_points', period: 'calendar_month', points: 12000, after: 'downgrade_to_base_rate', afterPpb: 2 })],
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free per KFS and product page. The LED card variant has a one-time ₹999 + GST fee.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: 'pay_at_least_minimum_due_on_first_statement', benefit_points: 'N/A', effective_value_inr: 695, condition: 'Complimentary EazyDiner Prime membership valued at ₹695, issued after paying at least the minimum due on the first statement; no cash value (CheQ partner T&C).' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [],
      dynamic_promotions_registry: [],
      redemption_matrix: {
        direct_options: [
          { channel: 'CheQ Travel flights and hotels', redemption_type: 'flight_hotel_booking', inr_value_per_point: 0.5, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 'N/A', effective_from: null, effective_to: null },
          { channel: 'Top brand gift cards on CheQ', redemption_type: 'partner_catalogue', inr_value_per_point: 0.5, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 'N/A', effective_from: null, effective_to: null },
          { channel: 'Bill payments on CheQ', redemption_type: 'statement_credit', inr_value_per_point: 0.25, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 'N/A', effective_from: null, effective_to: null },
        ],
        partner_transfers: [],
      },
      additional_data: { items: [
        dualNetwork({
          sourceUrl: 'https://www.au.bank.in/personal-banking/credit-cards/cheq-au-credit-card',
          evidence: 'AU product page FAQ: apply from the CheQ app and you receive 2 cards, 1 Visa and 1 RuPay, on one credit account. The Visa card is the LED card.',
          variants: [
            { network: 'visa', network_tier: 'N/A', label: 'CheQ AU Credit Card (Visa, LED)', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/cheq-au-credit-card', evidence: 'Page: "Your Visa card illuminates automatically with every POS transaction".' },
            { network: 'rupay', network_tier: 'N/A', label: 'CheQ AU Credit Card (RuPay)', source_url: 'https://www.au.bank.in/personal-banking/credit-cards/cheq-au-credit-card', evidence: 'Page: link your RuPay card to CheQ UPI and earn 5 CheQ points per ₹200.' },
          ],
        }),
        ...prov({
          sources: [
            { url: 'https://www.au.bank.in/personal-banking/credit-cards/cheq-au-credit-card', kind: 'issuer_page + FAQ', read: 'rendered page text' },
            { url: 'https://www.au.bank.in/pdf/credit-card/CheQ-Rewards-TnC.pdf', kind: 'AU CheQ Reward Points Usage T&C (earn rules, MCCs, exclusions)', read: 'pdftotext' },
            { url: KFS, kind: 'KFS', date: KFS_DATE },
            { url: 'https://cheq.one/legal/credit-card-terms-and-conditions', kind: 'partner T&C, published 6 Nov 2026 (redemption values, expiry, welcome gift); partner document, not the bank\'s', read: 'page text via fetch tool' },
          ],
          unverified: [
            'Fee conflict is resolved: the bank KFS v1.9 (2 Nov 2026) says lifetime free with ₹999 + GST one-time for the LED card only, matching the partner. The older "₹499 / ₹1,499" figures in an earlier fee schedule are superseded.',
            'The cap is "12,000 points per month" in the AU FAQ and "per statement cycle" in the CheQ partner T&C; modelled as calendar_month per the bank document.',
            'Partner-brand merchant ID list is not published in the documents read.',
            'Redemption values (2/2/4 points per ₹1) come from the partner T&C, not an AU document.',
            'Points expire 24 months after credit (AU FAQ and partner T&C agree).',
          ],
          notes: ['Rewards credited 2-3 working days after settlement (AU FAQ).', 'Fuel surcharge waiver 1% for ₹500-5,000, up to ₹150 per statement month (KFS).', 'LED variant one-time fee ₹999 + GST is not in joining_fee_inr (set 0) because the schema has one joining fee.'],
        }),
        lateFee, returnFee,
      ] },
    };
  })(),
};
