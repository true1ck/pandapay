// RBL Bank credit cards, batch A: Nova, iGlobe, World Safari Lite, World Safari Plus, SalarySe UP, IndianOil XTRA.
// (Lumiere is NOT drafted: RBL's current card list labels it "By invite only"; see wave2/W4a.json.)
// Sources read 2026-11-07. Every PDF was fetched with curl and read with pdftotext; pages were fetched as HTML and converted to text.
// Document dates: RBL documents print no revision date except the codes below, so the PDF creation date and the
// server Last-Modified header are quoted as the best available date.
//  SOC   = Schedule of Charges, code "RBL-CC-SOC-V2-04-06-2026" (4 Jun 2026; PDF created 4 Jun 2026; Last-Modified 29 Aug 2026)
//          https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf
//  MITC  = Most Important Terms and Conditions cum KFS, code "RBL-CC-MITC-V2-29-10-2026" (29 Oct 2026; Last-Modified 30 Oct 2026)
//          https://webassets.rbl.bank.in/document/Credit%20Cards/RBL-MITC-final.pdf
//  CMA   = Cardmember Agreement, code "RBL-CC-CMA-27-10-2026" (27 Oct 2026), the source of the per-card T&C links
//  RWD   = RBL Bank Credit Cards Rewards Programme T&C, https://rblrewards.rbl.bank.in/tnc (no date printed; read 2026-11-07)
//  MILES = RBL Miles Transfer Programme T&C (PDF created 18 Aug 2026)
//  LIST  = https://www.rbl.bank.in/personal-banking/cards/credit-cards/category ("Showing 64 Cards", read 2026-11-07)
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const SOC = 'https://webassets.rbl.bank.in/document/Credit%20Cards/CardsScheduleCharges.pdf';
const MITC = 'https://webassets.rbl.bank.in/document/Credit%20Cards/RBL-MITC-final.pdf';
const CMA = 'https://webassets.rbl.bank.in/document/credit-cards/rbl-cc-cardmember-agreement.pdf';
const RWD = 'https://rblrewards.rbl.bank.in/tnc';
const MILES = 'https://webassets.rbl.bank.in/document/credit-cards/rbl-miles-transfer-programme.pdf';
const LIST = 'https://www.rbl.bank.in/personal-banking/cards/credit-cards/category';
const LOUNGES = 'https://webassets.rbl.bank.in/document/credit-cards/mastercard-visa-india-lounge-program-lounge-list.pdf';
const page = (s) => `https://www.rbl.bank.in/personal-banking/cards/credit-cards/${s}`;

const srcSOC = { url: SOC, kind: 'Schedule of Charges: annual fee row, finance charge, cash advance, late fee, forex, fuel/rent/utility/education/FASTag fees', date: 'code RBL-CC-SOC-V2-04-06-2026 (4 Jun 2026); PDF created 2026-06-04; Last-Modified 2026-08-29', read: 'pdftotext + page image' };
const srcMITC = { url: MITC, kind: 'MITC cum KFS: joining fee, annual fee table, add-on fees, interest bands, grace period, MAD, late fee, forex, EMI rule', date: 'code RBL-CC-MITC-V2-29-10-2026 (29 Oct 2026); Last-Modified 2026-10-30', read: 'pdftotext' };
const srcCMA = { url: CMA, kind: 'Cardmember Agreement: table that links each card to its product T&C', date: 'code RBL-CC-CMA-27-10-2026 (27 Oct 2026)', read: 'pdftotext + embedded links' };
const srcRWD = { url: RWD, kind: 'Credit Cards Rewards Programme T&C: redemption fee, 24-month expiry, minimum redemption, reversal rule', date: 'no date printed; read 2026-11-07', read: 'page text' };
const srcMILES = { url: MILES, kind: 'Miles Transfer Programme T&C: product-wise conversion ratios, 12 partners, limits', date: 'PDF created 2026-08-18', read: 'pdftotext' };
const srcLIST = { url: LIST, kind: 'Current credit card list (64 cards): sold-status check', date: 'read 2026-11-07', read: 'page text' };

// ---------- shared exclusion MCC tables (identical wording in each T&C that lists them) ----------
const MCC = {
  fuel: [32, 2541, 4001, 5542, 5541, 5172],
  utilities: [4900],
  insurance: [6300, 6310],
  quasi: [6050, 6051, 4829],
  rent: [6513],
  wallet: [6540],
  education: [8220, 8244, 8249, 8211, 8241, 8299],
  govt: [9400, 1490, 2490, 2995, 7800, 9406, 9222, 9405, 9399, 9211, 9402, 9401, 9311, 9223],
  contracted: [1711, 1740, 763, 1520, 742, 1761, 1799, 1750, 1731, 1771, 780],
  cash: [6011, 6010],
  railways: [66, 4011, 4112],
  misc: [5960],
};
// [key, app category token, mcc list, label]
const EXCL_ROW = {
  fuel: ['fuel', 'fuel', MCC.fuel, 'Fuel and auto'],
  utilities: ['utilities', 'utility', MCC.utilities, 'Utilities'],
  insurance: ['insurance', 'insurance', MCC.insurance, 'Insurance'],
  quasi: ['quasi-cash', 'cash_withdrawal', MCC.quasi, 'Quasi-cash'],
  rent: ['rent', 'rent', MCC.rent, 'Real estate and rental'],
  wallet: ['wallets', 'wallet_load', MCC.wallet, 'Wallets and service providers'],
  education: ['education', 'education', MCC.education, 'Education'],
  govt: ['government', 'government', MCC.govt, 'Government services'],
  contracted: ['contracted', 'excluded_spend', MCC.contracted, 'Contracted services'],
  cash: ['cash', 'cash_withdrawal', MCC.cash, 'Cash'],
  railways: ['railways', 'excluded_spend', MCC.railways, 'Railways'],
  misc: ['miscellaneous', 'excluded_spend', MCC.misc, 'Miscellaneous'],
};
const exclusions = (prefix, keys, src, extra = []) => [
  ...keys.map((k) => { const [id, cat, mccs, label] = EXCL_ROW[k]; return X(`${prefix}-excl-${id}`, cat, mccs, `${label} earns no reward points (${src}).`); }),
  ...extra,
];
const mccUnion = (keys) => [...new Set(keys.flatMap((k) => EXCL_ROW[k][2]))];
const catList = (keys) => [...new Set(keys.map((k) => EXCL_ROW[k][1]))];
const emiExcl = (prefix, src) => X(`${prefix}-excl-emi`, 'emi', [], `EMI conversion of retail transactions (Split-N-Pay and EMI requested at POS/web/app) earns no points (${src}; MITC: base points are not accrued on EMI conversion for any RBL card).`);
const feeExcl = (prefix, src) => X(`${prefix}-excl-fees`, 'excluded_spend', [], `Fees, charges and GST are not part of the qualifying purchase value (${src}).`);
const upiSmall = (prefix, src) => X(`${prefix}-excl-upi-small`, 'upi', [], `Offline UPI transactions under ₹2,000 at small merchants (turnover of not more than ₹20 lakh in the previous financial year) on the RuPay card earn no points, vouchers, milestones or other benefits (${src}).`, { transaction_amount_lt_inr: 2000, mode: 'offline_upi', merchant_annual_turnover_lte_inr: 2000000, network: 'rupay' });

// ---------- fees that apply to every RBL card (SOC + MITC) ----------
const SURCH = [
  { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on the transaction amount for all rental transactions (SOC; MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
  { category_id: 'fuel', mcc_list: MCC.fuel, fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on each fuel and auto transaction above ₹10,000, at most ₹3,000 per transaction; the amount includes surcharge and purchase (SOC; MITC)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
  { category_id: 'utility', mcc_list: [4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee when utility spends on the card exceed ₹50,000 in a month (SOC: "per month per card"; MITC: "aggregate utility spends")', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
  { category_id: 'education', mcc_list: MCC.education, fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on education payments made through third-party apps (Cred, PhonePe, Cheqedu, Paytm, Mobikwik, Nobroker, Housing.com and others, "not limited to" the list); no fee when paid on the school or college website or its POS (SOC; MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
  { category_id: 'toll', mcc_list: [4784, 4111, 4131], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on FASTag loading and toll payments above ₹10,000 per transaction per card (SOC; MITC)', threshold_spend_inr: 10000, effective_from: '2026-01-07', effective_to: null },
];
const emiRule = { key: 'merchant_emi_processing_fee_rule', value: { rule: '1.5% of the amount or ₹150, whichever is higher, on every EMI conversion made at the merchant at the time of the transaction (SOC; MITC). GST at 18% applies.', note: 'The universal field holds a flat rupee amount only, so merchant_instant_emi_processing_fee_inr is left null.' } };
const lateRule = { key: 'late_payment_fee_rule', value: { rule: '12.5% of the outstanding amount (statement total amount due less net payments), minimum ₹5, maximum ₹1,300; GST at 18% on top', source: 'SOC; MITC section v, applicable from 17 Oct 2025', grace: 'The fee is levied only when the account stays past due for more than three days after the payment due date (MITC section v-d).', note: 'A percentage fee cannot be written as fixed slabs, so late_payment_slabs is empty.' } };
const baseFees = (o) => ({
  apr: o.apr ?? { monthly_interest_rate_percent: 3.99, annual_interest_rate_percent: 47.88 },
  forex_markup: { markup_percent: o.forex, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: o.forex, gst_applicable: true, trigger_condition: 'SOC and MITC list one markup for "Foreign Currency Transaction / Dynamic & Static Conversion Transactions"; it also applies to INR transactions at an overseas location and at overseas-registered merchants located in India' },
  fuel_surcharge: { category_id: 'fuel', surcharge_percent: o.fuel?.surcharge ?? null, waiver_percent: o.fuel?.waiver ?? null, min_txn_inr: o.fuel?.min ?? null, max_txn_inr: o.fuel?.max ?? null, monthly_waiver_cap_inr: o.fuel?.cap ?? null },
  cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
  category_surcharges: SURCH,
  emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: null, foreclosure_charge_percent: null, gst_applicable: true },
  banking_penalties: { overlimit_charge: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, auto_debit_bounce_charge_inr: 500, cheque_bounce_charge_inr: 500 },
  reward_redemption_fee: o.redemption ?? { fee_inr: 99, gst_applicable: true, exempted_channels: [], notes: 'INR 99 + GST per redemption day (SOC; MITC; RWD 4.3).' },
});
const baseStatement = {
  grace_period_days: 50,
  grace_period_void_on_revolving_balance: true,
  minimum_amount_due_mad: { calculation_mode: 'max', components: [
    'Total GST + current-month EMI debits + [the higher of (100% of fees and charges + 5% of retail spends, cash advance and interest) or ₹200] + any unpaid earlier minimum due + over-limit utilisation (MITC section D-b)',
    'If that amount exceeds the total amount due, the minimum due equals the total amount due',
  ] },
  late_payment_slabs: [],
};
const aprNote = 'Finance charge: MITC says "up to 3.99% per month (47.88% a year)" for these cards and then lists bureau-score bands (above 775: 3.35% a month; 725-775: 3.85%; below 725: 3.99%). The draft stores the 3.99% maximum.';

// ---------- miles transfer partners (MILES section 3) ----------
const PARTNERS = [
  ['air-india-maharaja-club', 'Air India Maharaja Club', 'airline', 10],
  ['indigo-bluchip', 'IndiGo BluChip', 'airline', 1],
  ['airasia-rewards', 'AirAsia Rewards', 'airline', 10],
  ['ethiopian-shebamiles', 'Ethiopian Airlines ShebaMiles', 'airline', 1],
  ['spicejet-spiceclub', 'SpiceJet SpiceClub', 'airline', 1],
  ['air-arabia-air-rewards', 'Air Arabia Air Rewards', 'airline', 1],
  ['itc-club-itc', 'ITC Hotels Club ITC', 'hotel', 10],
  ['orchid-rewards', 'Orchid Hotels Orchid Rewards', 'hotel', 1],
  ['radisson-rewards', 'Radisson Hotel Group Radisson Rewards', 'hotel', 1],
  ['vietnam-lotusmiles', 'Vietnam Airlines Lotusmiles', 'airline', 1],
  ['philippine-mabuhay-miles', 'Philippine Airlines Mabuhay Miles', 'airline', 10],
  ['qatar-privilege-club', 'Qatar Airways Privilege Club', 'airline', 1],
];
const transfers = (ratio) => PARTNERS.map(([code, name, type, tat]) => ({
  partner_code: code, program_name: name, network_program: null, type,
  conversion_ratio: { card_points: ratio, partner_miles: 1 },
  min_transfer_points: 0, transfer_multiple: ratio, yearly_cap_points: null, turnaround_days: tat,
  effective_from: null, effective_to: null,
}));
const milesNote = { key: 'miles_transfer_limits', value: { source: 'Miles Transfer Programme T&C (PDF created 2026-08-18)', rule: 'No minimum, points must be a multiple of the ratio; up to 50,000 points per request and at most 2 requests per cardholder per month; primary cardholder only; transfers are final; credited usually in 3 business days and up to 10; turnaround_days holds the per-partner maximum (1 or 10 working days).', not_modelled: 'The universal partner_transfers row has no cap per month, so the 2 x 50,000 monthly limit is kept here.' } };

const addonDefault = { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null };
const redemptionOf = (opts) => ({ direct_options: opts, partner_transfers: [] });
const opt = (channel, type, value, fee, extra = {}) => ({ channel, redemption_type: type, inr_value_per_point: value, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: fee, effective_from: null, effective_to: null, ...extra });

export const cards = {
  // ═════════════════════════════════════════════════════════════ Nova
  'rbl-bank-nova': (() => {
    const E = ['fuel', 'utilities', 'insurance', 'quasi', 'rent', 'wallet', 'education', 'govt', 'contracted', 'cash', 'railways', 'misc'];
    return {
      card_product: { ...GST, name: 'RBL Bank Nova Credit Card', issuer_slug: 'rbl', card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 12500, is_upi_linkable: null, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('nova-credit-card'), status: 'draft', verified_at: null, point_value_inr_baseline: 1, point_value_baseline_basis: 'Nova T&C (Rewards Program): 1 Reward Point = ₹1, redeemable at nova.rbl.bank.in on flights, hotels, e-gift cards, miles transfer, experiences, events, gifting, merchandise and philanthropy. Only one value is stated, no lower fallback.', point_expiry_months: 36, confirmed_flat_base_outside_smartbuy_or_equivalent_portal: true },
      eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
      accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 4, base_cashback_percent: 'N/A', effective_base_return_percent: 2, cycle_accrual_ceiling_points: null, capping_period_basis: 'calendar_month', reversal_policy: { mode: null, negative_balance_allowed: null, negative_balance_settlement: null } },
      reward_rules: [
        ...exclusions('rbl-nova', E, 'Nova T&C Table 1', [
          X('rbl-nova-excl-bills2pay', 'excluded_spend', [], 'Bills2Pay payments (RBL MyBank bill payment facility) earn no points (Nova T&C Table 1).', { channel: 'bills2pay' }),
          emiExcl('rbl-nova', 'Nova T&C Table 1'),
          feeExcl('rbl-nova', 'Nova T&C Table 1: charges and GST'),
        ]),
        R({ id: 'rbl-nova-portal-travel-12', cat: 'travel', pri: 10, rail: 'smartbuy_or_equivalent_portal', channel: 'nova.rbl.bank.in', ppb: 12, mult: 3, cap: 'rbl-nova-portal-cap', cond: { platform: 'nova.rbl.bank.in', per_inr_block: 200, purchases: ['flight bookings', 'hotel bookings'] }, reason: '3X accelerated points, i.e. 12 per ₹200, on flight and hotel bookings made through nova.rbl.bank.in (Nova T&C, Rewards Program).' }),
        R({ id: 'rbl-nova-portal-egift-12', cat: 'other', pri: 11, rail: 'smartbuy_or_equivalent_portal', channel: 'nova.rbl.bank.in', ppb: 12, mult: 3, cap: 'rbl-nova-portal-cap', cond: { platform: 'nova.rbl.bank.in', per_inr_block: 200, purchases: ['e-gift card purchases'] }, reason: '3X accelerated points, i.e. 12 per ₹200, on e-gift card purchases made through nova.rbl.bank.in (Nova T&C, Rewards Program).' }),
        R({ id: 'rbl-nova-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 4, mult: 1, cond: { per_inr_block: 200 }, reason: '4 reward points per ₹200 spent on the card, outside the excluded categories (Nova T&C, Rewards Program; page: "anywhere").' }),
      ],
      cap_rules: [
        C({ id: 'rbl-nova-portal-cap', cat: 'travel', metric: 'total_reward_points', period: 'calendar_month', points: 30000, after: 'downgrade_to_base_rate', afterPpb: 4 }),
      ],
      brand_specific_voucher_caps: [],
      fees_and_surcharges: baseFees({ apr: { monthly_interest_rate_percent: 3.4, annual_interest_rate_percent: 40.8 }, forex: 2, fuel: { surcharge: null, waiver: 1, min: 500, max: 10000, cap: 1000 }, redemption: { fee_inr: 0, gst_applicable: null, exempted_channels: ['all redemptions'], notes: 'SOC and MITC: the INR 99 + GST redemption fee does not apply to the Nova card; RWD 4.3.1(b)(iv) lists it as exempt.' } }),
      statement_and_late_fees: baseStatement,
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 1000000, period: 'card_anniversary_year', evaluation_condition: 'The next anniversary year\'s fee (₹12,500 + GST) is not levied when spends reach ₹10 lakh in the card anniversary year (Nova T&C; SOC; MITC). Spends in the excluded categories of Table 1 do not count.', excluded_category_ids: catList(E), excluded_mcc_list: mccUnion(E), waives_fee_inr: 12500 },
        welcome_and_renewal_gift: { trigger: 'first_retail_transaction_within_37_days_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 12500, condition: 'E-gift card worth ₹12,500, a choice of Taj Experiences or Luxe, on a retail transaction within 37 calendar days of issue and payment of the annual fee shown in the first statement; reflected within 60 days of issue. A renewal benefit of the same ₹12,500 e-gift card applies on a retail transaction within 30 days of each anniversary and payment of that year\'s fee (Nova T&C). The redemption link is valid 120 days.' },
        spend_milestones: [
          { id: 'rbl-nova-quarterly-gift', label: 'E-gift card worth ₹10,000 (Taj Experiences, Tata CLiQ Luxury, MakeMyTrip or Marriott Bonvoy) on spends of ₹3 lakh or more in a calendar quarter', threshold_spend_inr: 300000, reward_value_inr: 10000, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'rbl-nova-lounge-india', cat: 'lounge', sponsor: 'RBL Bank', label: 'Complimentary domestic airport lounge visits: 12 per calendar year in total across primary, add-on cardholders and their guests', cond: { shared_with: ['add_on_cardholders', 'guests'], authorisation_up_to_inr: 25 }, qty: 12, per: 'annual' }),
        B({ id: 'rbl-nova-lounge-intl', cat: 'lounge', program: 'priority_pass', sponsor: 'RBL Bank', label: 'Complimentary international airport lounge visits for the primary cardholder: 12 per calendar year; guests (including add-on cardholders) 4 per calendar year', cond: { primary_visits_per_calendar_year: 12, guest_visits_per_calendar_year: 4, extra_visit_charge_usd_up_to: 35, international_transactions_must_be_enabled: true }, qty: 12, per: 'annual' }),
        B({ id: 'rbl-nova-golf', cat: 'golf', sponsor: 'RBL Bank', label: '4 complimentary golf rounds and 12 golf lessons a year for the primary cardholder (green fee only; caddy, cart, insurance and equipment are paid at the club)', cond: { rounds_per_year: 4, lessons_per_year: 12 }, qty: 4, per: 'annual' }),
      ],
      insurance_and_protection: [],
      addon_card_rules: { ...addonDefault, lounge_quota_shared: true, reward_points_pooled: true },
      redemption_matrix: { direct_options: [
        opt('nova.rbl.bank.in: flight and hotel bookings', 'flight_hotel_booking', 1, 0),
        opt('nova.rbl.bank.in: e-gift cards, experiences, events, gifting, physical merchandise, philanthropy', 'other', 1, 0),
      ], partner_transfers: transfers(2) },
      dynamic_promotions_registry: [
        P({ id: 'rbl-nova-dining-district', cat: 'dining', sponsor: 'District / Zomato', platform: 'District or Zomato app, select fine-dine restaurants', type: 'instant_discount', pct: 10, max: 3000, quota: false }),
      ],
      additional_data: { items: [
        emiRule, lateRule, milesNote,
        { key: 'addon_card_fee_rule', value: { rule: 'Two add-on cards are free; ₹3,000 one-time fee per card beyond two (MITC section iii).', source: 'MITC' } },
        ...prov({
          sources: [
            { url: 'https://drws17a9qx558.cloudfront.net/document/credit-cards/tnc-nova-credit-card.pdf', kind: 'Nova T&C (fee waiver, welcome and renewal gift, rewards, cap, milestone, lounge, golf, fuel, forex, Table 1 exclusions); link taken from the Cardmember Agreement table', date: 'PDF created 2026-07-07; Last-Modified 2026-08-05', read: 'pdftotext' },
            { url: page('nova-credit-card'), kind: 'issuer product page', read: 'page text and DOM; no card network stated' },
            srcSOC, srcMITC, srcCMA, srcMILES, srcLIST,
            { url: 'https://www.rbl.bank.in/nova-form', kind: 'the "Express your interest" page the product page links to (viewed only, nothing entered)', read: 'page text' },
          ],
          unverified: [
            'Network: no issuer document or card art read states Visa, Mastercard or RuPay (the T&C only says "MasterCard/RuPay/VISA" generically). Left null.',
            'Application route: the product page and the current card list offer only an "Express your interest" form, not "Apply Now". Unlike Lumiere, the list does not label Nova "By invite only". Whether a customer can apply directly is not stated; application_mode "open" is an assumption.',
            'Cap period and fallback: the 30,000-point cap is on accelerated points "in a calendar month"; what the 12-per-₹200 spend earns after the cap is not stated. Modelled as falling back to 4 per ₹200.',
            'Nova T&C refers to "the above-mentioned program partners" for miles transfer but prints no partner list, and the product page shows a KrisFlyer logo that the Miles Transfer T&C (12 partners) does not list. All 12 partners from the Miles Transfer T&C are used; confirm which apply to Nova.',
            'Lounge visits: the T&C says "a calendar year" for both the 12 domestic and 12 international visits; the product page does not give a period. Modelled as annual.',
            'Milestone repeat: the T&C says the e-gift card is earned on ₹3 lakh "in a calendar quarter"; is_repeatable true assumes it repeats each quarter.',
            'The T&C general terms item 11 names the "Insignia Preferred Banking Credit Card" (copy-paste in the issuer document); read as Nova.',
            'Finance charge: the MITC states Nova (with Lumiere and Insignia) separately at 3.4% a month (40.8% a year); that rate is stored. All other cards are "up to 3.99% a month" with bureau-score bands.',
          ],
          notes: [
            'The card-list headline "6% value back on gift cards, hotel and flight bookings" is 12 points per ₹200 at ₹1 per point through the Nova portal; the base rate is 2%.',
            'Fee: SOC and MITC show ₹12,500 for the first and later years; the MITC "Joining Fee: NIL" applies, so joining_fee_inr is 0 and the first-year fee is stored as the annual fee (the three Shoppers Stop drafts store the first-year fee as the joining fee).',
            'Forex markup 2% (SOC; MITC; T&C). Fuel surcharge waiver 1% on ₹500-₹10,000 transactions, capped at ₹1,000 a month (calendar month).',
            'Reward points expire after 36 months if not redeemed (Nova T&C).',
          ],
        }),
      ] },
    };
  })(),

  // ═════════════════════════════════════════════════════════════ iGlobe
  'rbl-bank-iglobe': (() => ({
    card_product: { ...GST, name: 'RBL Bank iGlobe Credit Card', issuer_slug: 'rbl', card_type: 'credit', network: 'mastercard', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 3000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('iglobe-credit-card'), status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'No document read states what one iGlobe reward point is worth in rupees. The product page, the T&C and the Rewards Programme T&C give no per-point value; only the miles ratio (4 reward points = 1 partner mile) is published.', point_expiry_months: 24, confirmed_flat_base_outside_smartbuy_or_equivalent_portal: 'N/A' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Page: "exclusively designed for NRI customers"; card bill payment is accepted only through a standing instruction (auto-debit) from an RBL Bank NRE savings account (page; T&C 3.8). The application route is a branch or Relationship Manager.', rules: [
      { parameter: 'customer_type', operator: 'in', threshold_value: null, allowed_values: ['nri'] },
      { parameter: 'bill_payment_source', operator: 'in', threshold_value: null, allowed_values: ['rbl_nre_savings_account_standing_instruction'] },
    ], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 5, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null, reversal_policy: { mode: 'proportional_deduction', negative_balance_allowed: null, negative_balance_settlement: null } },
    reward_rules: [
      X('rbl-iglobe-excl-emi', 'emi', [], 'EMI transactions do not count for reward points (iGlobe T&C 3.3; MITC).'),
      X('rbl-iglobe-excl-cash', 'cash_withdrawal', [], 'Cash withdrawals do not count for reward points (iGlobe T&C 3.3).'),
      X('rbl-iglobe-excl-fees', 'excluded_spend', [], 'Fees, charges and GST are not part of the qualifying purchase value (iGlobe T&C 3.3).'),
      R({ id: 'rbl-iglobe-intl-10', cat: 'international_spend', pri: 10, ppb: 10, mult: 2, cond: { transaction_type: 'international', per_inr_block: 100, definition: 'merchant located outside India or merchant bank outside India, excluding Nepal and Bhutan (T&C 2.12)' }, reason: '10 reward points per ₹100 on international purchases (iGlobe T&C 3.3; page).' }),
      R({ id: 'rbl-iglobe-domestic-5', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 5, mult: 1, cond: { transaction_type: 'domestic', per_inr_block: 100 }, reason: '5 reward points per ₹100 on eligible domestic retail purchases (iGlobe T&C 3.3; page).' }),
    ],
    cap_rules: [],
    brand_specific_voucher_caps: [],
    fees_and_surcharges: baseFees({ forex: 1.5, fuel: { surcharge: 1, waiver: 1, min: 500, max: 4000, cap: 250 }, redemption: { fee_inr: 0, gst_applicable: null, exempted_channels: ['all redemptions'], notes: 'The iGlobe page and T&C do not mention the redemption fee; SOC, MITC and RWD 4.3.1(b)(ii) list iGlobe as exempt from the INR 99 + GST fee.' } }),
    statement_and_late_fees: baseStatement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'SOC and MITC show ₹3,000 for the first and later years with no spend-linked waiver. The fee is NIL for an Insignia Preferred Banking customer.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'first_retail_transaction_within_30_days_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 3000, condition: 'MakeMyTrip voucher worth ₹3,000 on an eligible retail transaction within 30 days of issue and payment of the annual fee shown in the first statement by its due date; credited within 60 days of issue (T&C 3.1; page).' },
      spend_milestones: [
        { id: 'rbl-iglobe-annual-5l', label: '10,000 reward points on spends of ₹5 lakh in a year (billed spends of primary and add-on cards; EMI, cash, fees, charges and GST excluded)', threshold_spend_inr: 500000, reward_value_inr: null, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null },
        { id: 'rbl-iglobe-annual-8l', label: 'A further 10,000 reward points on spends of ₹8 lakh in a year', threshold_spend_inr: 800000, reward_value_inr: null, period: 'annual', is_repeatable: false, effective_from: null, effective_to: null },
      ],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'rbl-iglobe-lounge-india', cat: 'lounge', sponsor: 'Mastercard', label: '2 complimentary domestic airport lounge visits per calendar quarter at select lounges in India; only one entry per cardmember per visit', cond: { authorisation_inr: 25, first_come_first_served: true }, qty: 2, per: 'quarter' }),
      B({ id: 'rbl-iglobe-lounge-intl', cat: 'lounge', program: 'priority_pass', sponsor: 'RBL Bank', label: '6 complimentary international airport lounge visits per year through a complimentary Priority Pass; non-cardmember guests are charged, and the T&C states visit charges of up to USD 27 for international lounge visits', cond: { visits_per_year: 6, visit_charge_usd_up_to: 27 }, qty: 6, per: 'annual' }),
      B({ id: 'rbl-iglobe-golf', cat: 'golf', program: 'mastercard_golf', sponsor: 'Mastercard', label: '4 complimentary golf green-fee rounds a year, one golf lesson each month, and 50% off the green fee beyond 4 rounds; 7 days\' advance notice', cond: { rounds_per_year: 4, lessons_per_month: 1, discount_beyond_percent: 50 }, qty: 4, per: 'annual' }),
      B({ id: 'rbl-iglobe-concierge', cat: 'concierge', sponsor: 'Aspire Lifestyles India Pvt. Ltd.', label: '24x7 concierge desk (golf, car rental and limousine, hotel, dining, spa and fitness, business services, events, flowers and gifts); +91 22 6232 7777' }),
    ],
    insurance_and_protection: [],
    addon_card_rules: { ...addonDefault, fee_per_card_inr: 0, reward_points_pooled: true },
    redemption_matrix: { direct_options: [
      opt('RBL Rewards Portal (rblrewards.rbl.bank.in)', 'other', null, 0),
    ], partner_transfers: transfers(4) },
    dynamic_promotions_registry: [],
    additional_data: { items: [
      emiRule, lateRule, milesNote,
      { key: 'insignia_preferred_fee_note', value: { rule: 'Annual fee NIL for an Insignia Preferred Banking customer, ₹3,000 otherwise (SOC; MITC).', source: 'SOC row iGlobe; MITC section i' } },
      ...prov({
        sources: [
          { url: 'https://webassets.rbl.bank.in/document/credit-cards/terms-conditions-iglobe-credit-card.pdf', kind: 'iGlobe T&C (welcome, forex, rewards, milestones, fuel waiver, concierge, golf, lounges, payment method)', date: 'PDF created 2026-07-23; Last-Modified 2026-08-05', read: 'pdftotext' },
          { url: page('iglobe-credit-card'), kind: 'issuer product page', read: 'page text' },
          srcSOC, srcMITC, srcCMA, srcRWD, srcMILES, srcLIST,
          { url: LOUNGES, kind: 'RBL Bank India Lounge Program list (not itemised here)', date: 'PDF created 2026-10-15', read: 'pdftotext (first page)' },
        ],
        unverified: [
          'Value of a reward point is not published in any document read, so effective_base_return_percent and the milestone rupee values are null. Only the miles ratio (4 points = 1 mile) is stated.',
          'Network: the card art shows no network logo. "Mastercard" rests on T&C 3.7 and 3.8 (the golf programme is "offered by Mastercard", lounges are "via MasterCard service providers"), while the product page says the lounge programme is "offered by MasterCard/Visa". Confirm against the card itself.',
          'Reward point expiry: the iGlobe T&C is silent. 24 months is the Rewards Programme T&C rule (RWD 5.1), which exempts only the Insignia Preferred card.',
          'Lounge count: the T&C says Priority Pass access to "1700+" lounges, the product page says "1,400+".',
          'Milestone credit time: the T&C says within 30 days of crossing the threshold in one clause and "within days" in another; the page says 45 days.',
          'The additional 10,000 points at ₹8 lakh reads as in addition to the 10,000 at ₹5 lakh; the T&C wording ("additional") does not say whether the two tiers are cumulative.',
          'Application route is "visit your nearest branch or reach out to your Relationship Manager" and the card list shows only "Know more", not "Apply Now"; modelled as open.',
          'Insignia Preferred Banking customers pay NIL; the draft stores the standard ₹3,000.',
          aprNote,
        ],
        notes: [
          'Rewards: 5 points per ₹100 on domestic and 10 per ₹100 on international purchases. Points earned in a month are credited within 45 days of settlement (T&C 3.3).',
          'Forex markup 1.5% (SOC; MITC; T&C 3.2). Fuel surcharge waiver 1% on ₹500-₹4,000 fuel purchases, up to ₹250 a calendar month; the surcharge is 1% of the transaction (T&C 3.5).',
          'Joining fee is NIL (MITC); the first-year fee is stored as the annual fee.',
          'Add-on cards are NIL (MITC "Insignia Credit Card & iGlobe Credit Card: Nil").',
        ],
      }),
    ] },
  }))(),

  // ═════════════════════════════════════════════════════════════ World Safari Lite
  'rbl-bank-world-safari-lite': (() => {
    const E = ['fuel', 'utilities', 'wallet', 'insurance', 'railways', 'rent', 'misc'];
    return {
      card_product: { ...GST, name: 'RBL Bank World Safari Lite Credit Card', issuer_slug: 'rbl', card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 1000, is_upi_linkable: null, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('world-safari-lite-credit-card'), status: 'draft', verified_at: null, point_value_inr_baseline: 0.05, point_value_baseline_basis: 'Product page: on the RBL Bank Rewards Portal one point is worth ₹0.25 on flight and hotel bookings and ₹0.05 on all other redemptions; points are redeemable only on that portal. The baseline is the ₹0.05 value that applies to every redemption; ₹0.25 applies to flights and hotels only. A ₹99 + GST fee applies per redemption day.', point_expiry_months: 24, confirmed_flat_base_outside_smartbuy_or_equivalent_portal: null },
      eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
      accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: null, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null, reversal_policy: { mode: 'proportional_deduction', negative_balance_allowed: null, negative_balance_settlement: null } },
      reward_rules: [
        ...exclusions('rbl-wsl', E, 'World Safari Lite T&C 3.4(d)', [emiExcl('rbl-wsl', 'MITC')]),
        R({ id: 'rbl-wsl-portal-travel-5', cat: 'travel', pri: 10, rail: 'smartbuy_or_equivalent_portal', channel: 'rbl_rewards_portal', ppb: 5, mult: 5, cond: { platform: 'RBL Rewards Portal', purchases: ['flight bookings', 'hotel bookings'], per_inr_block: 100 }, reason: '5 reward points per ₹100 on flight and hotel bookings made on the RBL rewards portal (T&C 3.4(b); page "5X").' }),
        R({ id: 'rbl-wsl-domestic-travel-1', cat: 'travel', pri: 20, ppb: 1, mult: 1, cond: { transaction_type: 'domestic', per_inr_block: 100, travel_mccs: 'Airlines 3000-3350, Hotels and Motels 3501-3999 and 7011, Transportation 4111, 4119, 4121, 4131, 4214, 4215, 4225, 4411, 4457, 4468, 4511, 4582, 4722, 4723, 4784, 4789' }, reason: '1 reward point per ₹100 on eligible domestic travel purchases in the Airlines, Hotels & Motels and Transportation merchant categories (T&C 3.4(a),(e); World Safari Lite and Plus travel MCC list).' }),
      ],
      cap_rules: [],
      brand_specific_voucher_caps: [],
      fees_and_surcharges: baseFees({ forex: 0 }),
      statement_and_late_fees: baseStatement,
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'SOC and MITC show ₹1,000 for the first and later years with no spend-linked waiver.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: 'first_eligible_transaction_within_30_days_and_fee_paid', benefit_points: 'N/A', effective_value_inr: 1000, condition: 'Vouchers worth ₹1,000+ (page: Ixigo voucher of ₹599 off flights and hotels, plus a Swiggy One membership) on an eligible transaction within 30 days of issue; the page says the annual fee must be paid by its due date, while T&C 3.2(c) says the "first month membership fees"; mailed within 90 days of issue (T&C) or within 30 days of meeting eligibility (page).' },
        spend_milestones: [
          { id: 'rbl-wsl-annual-2-5l', label: '5,000 reward points on eligible spends of ₹2.5 lakh in a membership year', threshold_spend_inr: 250000, reward_value_inr: 250, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
          { id: 'rbl-wsl-annual-5l', label: '10,000 reward points on eligible spends of ₹5 lakh in a membership year', threshold_spend_inr: 500000, reward_value_inr: 500, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'rbl-wsl-lounge-india', cat: 'lounge', sponsor: 'RBL Bank', label: '1 complimentary domestic airport lounge visit per calendar quarter, earned by eligible spends of ₹50,000 or more in the previous calendar quarter; primary cardholder only, lapses if unused', cond: { previous_quarter_spend_gte_inr: 50000, primary_cardholder_only: true, authorisation_up_to_inr: 25 }, qty: 1, per: 'quarter' }),
        B({ id: 'rbl-wsl-lounge-intl', cat: 'lounge', program: 'lounge_key', sponsor: 'RBL Bank', label: '1 complimentary international airport lounge visit per calendar quarter through a Lounge Key voucher, earned by spends of ₹50,000 or more in that quarter and claimed in the MyCard app; voucher valid 180 days', cond: { quarter_spend_gte_inr: 50000, claim_channel: 'RBL MyCard app', voucher_validity_days: 180 }, qty: 1, per: 'quarter' }),
      ],
      insurance_and_protection: [],
      addon_card_rules: { ...addonDefault, fee_per_card_inr: 200, lounge_quota_shared: false },
      redemption_matrix: { direct_options: [
        opt('RBL Bank Rewards Portal: flight and hotel bookings', 'flight_hotel_booking', 0.25, 99),
        opt('RBL Bank Rewards Portal: all other redemptions', 'other', 0.05, 99),
      ], partner_transfers: [] },
      dynamic_promotions_registry: [],
      additional_data: { items: [
        emiRule, lateRule,
        { key: 'addon_card_fee_rule', value: { rule: 'MITC: ₹200 annual fee per add-on cardholder. The lounge benefit does not apply to add-on cards (T&C 3.3.2(b)).', source: 'MITC section iii' } },
        ...prov({
          sources: [
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/tnc-world-safari-lite.pdf', kind: 'World Safari Lite T&C (forex, welcome, lounges, rewards, exclusion table, milestones)', date: 'PDF created 2026-03-30; Last-Modified 2026-05-19', read: 'pdftotext + page images for the exclusion table' },
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/world-safari-lite-and-plus-travel-mcc-list.pdf', kind: 'Travel category MCC list (Airlines, Hotels and Motels, Transportation)', date: 'PDF created 2025-12-10; Last-Modified 2026-01-01', read: 'pdftotext' },
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/welcome-benefit-world-safari-lite-credit-card.pdf', kind: 'Welcome benefit T&C (Ixigo voucher, Swiggy One)', date: 'PDF created 2026-09-02', read: 'pdftotext' },
            { url: page('world-safari-lite-credit-card'), kind: 'issuer product page (point values, lounge, milestones)', read: 'page text' },
            srcSOC, srcMITC, srcCMA, srcRWD, srcLIST,
            { url: LOUNGES, kind: 'RBL Bank India Lounge Program list (not itemised here)', date: 'PDF created 2026-10-15', read: 'pdftotext (first page)' },
          ],
          unverified: [
            'Base rate: the T&C and page state earn rates only for domestic travel (1 point per ₹100) and portal flights and hotels (5 per ₹100). No rate is stated for any other eligible spend, although the exclusion table implies other categories may earn. base_points_per_block and the return percent are left null; a person must confirm whether non-travel spend earns anything.',
            'Network: no issuer document or card art read names Visa, Mastercard or RuPay (T&C: "MasterCard/RuPay/VISA"). Left null.',
            'International travel: only "domestic travel" earns 1 point per ₹100; whether international airline, hotel or transport spend earns anything is not stated.',
            'Welcome benefit: T&C 3.2(c) conditions the voucher on paying the "first month membership fees", while the page says the annual fee; the card carries an annual fee. Ixigo offer valid to 31 Dec 2026 per the welcome T&C.',
            'Milestone tiers: T&C 3.5(b) says "additional 10,000" points at ₹5 lakh; it is not stated whether this adds to the 5,000 at ₹2.5 lakh. Rupee values use the ₹0.05 baseline (₹0.25 would be 5x).',
            'Lounge: T&C 3.3.1 requires ₹50,000 spend in the same calendar quarter for the international voucher; 3.3.2 and the page tie the domestic visit to the previous quarter. The page says one visit per quarter "within and outside India".',
            'Points value for flights and hotels is ₹0.25, so the 5X earn is a 1.25% return only if redeemed on flights or hotels; at ₹0.05 it is 0.25%.',
            'Reward point expiry is the Rewards Programme T&C rule (24 months, RWD 5.1); the product T&C is silent.',
            aprNote,
          ],
          notes: [
            'Zero forex markup: 0% on World Safari Lite (SOC; MITC; T&C 3.1).',
            'Excluded from earning: Fuel & Auto, Utilities, Wallet, Insurance, Railways, Rental and Miscellaneous (5960) (T&C 3.4(d) and its MCC table; the table is an image in the PDF and was read from the page image). Travel merchant categories are Airlines, Hotels & Motels and Transportation as defined by the network.',
            'No fuel surcharge waiver is stated for this card.',
            'Joining fee is NIL (MITC); the first-year fee is stored as the annual fee.',
          ],
        }),
      ] },
    };
  })(),

  // ═════════════════════════════════════════════════════════════ World Safari Plus
  'rbl-bank-world-safari-plus': (() => {
    const E = ['fuel', 'utilities', 'wallet', 'insurance', 'railways', 'rent', 'misc'];
    return {
      card_product: { ...GST, name: 'RBL Bank World Safari Plus Credit Card', issuer_slug: 'rbl', card_type: 'credit', network: 'mastercard', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 6000, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('world-safari-plus-credit-card'), status: 'draft', verified_at: null, point_value_inr_baseline: 0.1, point_value_baseline_basis: 'Product page: 1 Reward Point = ₹1 on flight and hotel bookings and ₹0.10 on all other redemptions, on the RBL Bank Rewards Portal. The baseline is the ₹0.10 value that applies to every redemption; ₹1 applies to flights and hotels only. A ₹99 + GST fee applies per redemption day.', point_expiry_months: 24, confirmed_flat_base_outside_smartbuy_or_equivalent_portal: null },
      eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
      accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.1, cycle_accrual_ceiling_points: null, capping_period_basis: null, reversal_policy: { mode: 'proportional_deduction', negative_balance_allowed: null, negative_balance_settlement: null } },
      reward_rules: [
        ...exclusions('rbl-wsp', E, 'World Safari Plus T&C 3.4', [emiExcl('rbl-wsp', 'MITC')]),
        R({ id: 'rbl-wsp-portal-travel-5', cat: 'travel', pri: 10, rail: 'smartbuy_or_equivalent_portal', channel: 'rbl_rewards_portal', ppb: 5, mult: 5, cond: { platform: 'rblrewards.rbl.bank.in', purchases: ['airlines', 'hotels and motels', 'transportation'], per_inr_block: 100 }, reason: '5 reward points per ₹100 on Airlines, Hotels & Motels and Transportation purchases made on the RBL rewards portal (T&C 3.4; page: up to 5% at ₹1 per point).' }),
        R({ id: 'rbl-wsp-domestic-travel-2', cat: 'travel', pri: 20, ppb: 2, mult: 2, cond: { transaction_type: 'domestic', per_inr_block: 100, travel_mccs: 'Airlines 3000-3350, Hotels and Motels 3501-3999 and 7011, Transportation 4111, 4119, 4121, 4131, 4214, 4215, 4225, 4411, 4457, 4468, 4511, 4582, 4722, 4723, 4784, 4789' }, reason: '2 reward points per ₹100 on every other eligible domestic travel transaction (T&C 3.4; page).' }),
        R({ id: 'rbl-wsp-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100, not_eligible_for_base: 'Airlines, Hotels and Motels and Transportation (these earn the travel rates above instead)' }, reason: '1 reward point per ₹100 on all other eligible spends (T&C 3.4; page: "domestic spends"). Airline, hotel and transport merchant categories are excluded from this base rate.' }),
      ],
      cap_rules: [],
      brand_specific_voucher_caps: [],
      fees_and_surcharges: baseFees({ forex: 0 }),
      statement_and_late_fees: baseStatement,
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'SOC and MITC show ₹6,000 for the first and later years with no spend-linked waiver.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
        welcome_and_renewal_gift: { trigger: 'first_eligible_transaction_within_30_days_and_fee_paid', benefit_points: 6000, effective_value_inr: null, condition: '6,000 reward points on an eligible retail transaction within 30 days of issue and payment of the annual fee shown in the first statement by its due date; credited within 60 days of issue (T&C 3.2). The page says the points are "worth INR 6,000", which holds only at ₹1 per point on flights and hotels; at the general ₹0.10 value they are worth ₹600, so no rupee value is stored.' },
        spend_milestones: [
          { id: 'rbl-wsp-annual-7-5l', label: 'Club Marriott membership on eligible spends of ₹7.5 lakh in a membership year', threshold_spend_inr: 750000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
          { id: 'rbl-wsp-annual-15l', label: 'Marriott or Taj Experiences voucher worth ₹20,000 on eligible spends of ₹15 lakh in a membership year', threshold_spend_inr: 1500000, reward_value_inr: 20000, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'rbl-wsp-lounge-india', cat: 'lounge', sponsor: 'RBL Bank', label: '2 complimentary domestic airport lounge visits per calendar quarter; primary cardholder only, not on add-on cards', cond: { primary_cardholder_only: true, authorisation_up_to_inr: 25 }, qty: 2, per: 'quarter' }),
        B({ id: 'rbl-wsp-lounge-intl', cat: 'lounge', program: 'priority_pass', sponsor: 'RBL Bank', label: '4 complimentary international airport lounge visits a year through Priority Pass; later visits are charged up to USD 35', cond: { visits_per_year: 4, extra_visit_charge_usd_up_to: 35, international_transactions_must_be_enabled: true }, qty: 4, per: 'annual' }),
        B({ id: 'rbl-wsp-golf', cat: 'golf', program: 'mastercard_golf', sponsor: 'Mastercard', label: '4 complimentary golf green-fee rounds a year and one golf lesson each month, with preferential green-fee rates beyond that; Mastercard network only; 7 days\' advance notice', cond: { rounds_per_year: 4, lessons_per_month: 1, mastercard_network_only: true }, qty: 4, per: 'annual' }),
        B({ id: 'rbl-wsp-concierge', cat: 'concierge', sponsor: 'Aspire Lifestyles India Pvt. Ltd.', label: '24x7 concierge (dining, hotels, wellness, car rental and cruises, gifts, sports and events, overseas education assistance); +91 22 6115 6300' }),
      ],
      insurance_and_protection: [
        { cover_type: 'other', coverage_inr: 'N/A', coverage_usd: 100000, claim_condition: 'Complimentary multi-trip travel insurance, sum insured USD 100,000, worldwide including USA and Canada, 3 trips a year of up to 10 days each, ages 18-60; policy link emailed within 30 days of issue, valid one year, void if the card is cancelled (T&C 3.8; travel insurance policy schedule by Care Health Insurance).', effective_from: null, effective_to: null },
        { cover_type: 'medical_emergency_overseas', coverage_inr: 'N/A', coverage_usd: 50000, claim_condition: 'Emergency medical expenses, in-patient only, USD 100 deductible; medical evacuation included in the medical expense cover.', effective_from: null, effective_to: null },
        { cover_type: 'other', coverage_inr: 'N/A', coverage_usd: 7500, claim_condition: 'Repatriation of mortal remains, part of the medical expense cover, no deductible.', effective_from: null, effective_to: null },
        { cover_type: 'baggage_loss_delay', coverage_inr: 'N/A', coverage_usd: 200, claim_condition: 'Loss of checked-in baggage, USD 25 deductible.', effective_from: null, effective_to: null },
        { cover_type: 'baggage_loss_delay', coverage_inr: 'N/A', coverage_usd: 250, claim_condition: 'Trip delay, after a 12-hour delay.', effective_from: null, effective_to: null },
        { cover_type: 'other', coverage_inr: 'N/A', coverage_usd: 300, claim_condition: 'Loss of passport, USD 30 deductible.', effective_from: null, effective_to: null },
        { cover_type: 'other', coverage_inr: 'N/A', coverage_usd: 10000, claim_condition: 'Personal liability, no deductible.', effective_from: null, effective_to: null },
        { cover_type: 'other', coverage_inr: 'N/A', coverage_usd: 250, claim_condition: 'Dental treatment, USD 100 deductible.', effective_from: null, effective_to: null },
      ],
      addon_card_rules: { ...addonDefault, fee_per_card_inr: 200, lounge_quota_shared: false },
      redemption_matrix: { direct_options: [
        opt('RBL Bank Rewards Portal: flight and hotel bookings', 'flight_hotel_booking', 1, 99),
        opt('RBL Bank Rewards Portal: all other redemptions', 'other', 0.1, 99),
      ], partner_transfers: transfers(3) },
      dynamic_promotions_registry: [
        P({ id: 'rbl-wsp-mmt-intl-hotels', cat: 'travel', sponsor: 'MakeMyTrip', platform: 'MakeMyTrip website and apps, code MMTRBLWS', type: 'instant_discount', pct: 15, max: 10000, quota: true, permanent: false }),
        P({ id: 'rbl-wsp-mmt-intl-flights', cat: 'travel', sponsor: 'MakeMyTrip', platform: 'MakeMyTrip website and apps, code MMTRBLWS', type: 'instant_discount', pct: 10, max: 7500, quota: true, permanent: false }),
        P({ id: 'rbl-wsp-postcard-hotels', cat: 'travel', sponsor: 'The Postcard Hotel', platform: 'postcardresorts.com, code RBL5000', type: 'instant_discount', pct: 10, max: 5000, quota: true, permanent: false, from: '2026-08-13', to: '2027-08-13' }),
        P({ id: 'rbl-wsp-avis-airport-transfer', cat: 'travel', sponsor: 'Avis India', platform: 'avis.co.in/partner/rbl, code AVISRBLSAFARI', type: 'instant_discount', pct: 35, max: 'N/A', quota: false, permanent: false, to: '2028-10-15' }),
        P({ id: 'rbl-wsp-avis-intl-self-drive', cat: 'travel', sponsor: 'Avis India', platform: 'email globalselfdrive@avis.co.in, code AVISRBLSD', type: 'instant_discount', pct: 5, max: 5000, quota: false, permanent: false, to: '2028-10-15' }),
      ],
      additional_data: { items: [
        emiRule, lateRule, milesNote,
        { key: 'addon_card_fee_rule', value: { rule: 'MITC: ₹200 annual fee per add-on cardholder. The lounge benefit does not apply to add-on cards (T&C 3.3).', source: 'MITC section iii' } },
        { key: 'miles_transfer_fee', value: { rule: 'A redemption fee of ₹99 + tax is levied on a World Safari Plus miles transfer request; the Miles Transfer T&C says this is the only card it applies to there.', source: 'Miles Transfer Programme T&C section 4' } },
        ...prov({
          sources: [
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/tnc-world-safari-plus.pdf', kind: 'World Safari Plus T&C (forex, welcome, lounges, rewards, milestones, concierge, golf, insurance, Avis, MakeMyTrip and Postcard offers)', date: 'PDF created 2026-09-16; Last-Modified 2026-09-16', read: 'pdftotext' },
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/travel-insurance-world-safari-plus.pdf', kind: 'Travel insurance policy schedule (covers and limits)', date: 'PDF created 2026-09-16', read: 'pdftotext' },
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/world-safari-lite-and-plus-travel-mcc-list.pdf', kind: 'Travel category MCC list', date: 'PDF created 2025-12-10; Last-Modified 2026-01-01', read: 'pdftotext' },
            { url: page('world-safari-plus-credit-card'), kind: 'issuer product page (point values, offers, milestones)', read: 'page text' },
            srcSOC, srcMITC, srcCMA, srcRWD, srcMILES, srcLIST,
            { url: LOUNGES, kind: 'RBL Bank India Lounge Program list (not itemised here)', date: 'PDF created 2026-10-15', read: 'pdftotext (first page)' },
          ],
          unverified: [
            'Network: the card art shows no logo. "Mastercard" rests on the product page ("your World Safari Plus Mastercard Credit Card") and T&C 3.7 (golf "complimentary to cardmembers on Mastercard network only"); a non-Mastercard variant is not excluded by the wording.',
            'The ₹0.10 baseline makes the 1-point base rate a 0.1% return; the ₹1 flights-and-hotels value makes the portal 5X a 5% return only if points are redeemed on flights or hotels.',
            'International travel: Airlines, Hotels and Transportation are excluded from the base rate and only "domestic travel" earns 2 points; whether international travel spend earns anything outside the portal is not stated.',
            'MakeMyTrip offers: the T&C prints the offer period as "1 March 2028 to 31 March 2028" (and says "once per customer in a year"), which looks like a typo; the product page states no window. valid_from and valid_to are left null for those two offers. Other windows are as printed: Postcard Hotel 13 Aug 2026 to 13 Aug 2027, Avis to 15 Oct 2028.',
            'The T&C and the page list "Priority Pass & Lounge Key" in the lounge heading but describe only Priority Pass for the 4 international visits.',
            'Reward point expiry is the Rewards Programme T&C rule (24 months, RWD 5.1); the product T&C is silent.',
            'The miles ratio is 3 points : 1 mile per the Miles Transfer T&C; the product page says only "exchange your reward points for airline miles and hotel loyalty points".',
            'Milestones are "annual spends in one membership year"; the Club Marriott membership has no stated rupee value.',
            aprNote,
          ],
          notes: [
            'Zero forex markup: 0% on World Safari Plus (SOC; MITC; T&C 3.1).',
            'Excluded from earning: Fuel & Auto, Utilities, Wallet, Insurance, Railways, Rental and Miscellaneous (5960); Airlines, Hotels and Transportation are excluded only from the base rate (T&C 3.4).',
            'Travel insurance cover figures are from the policy schedule (USD 100,000 sum insured; sub-limits as listed); the full policy exclusions were not read.',
            'No fuel surcharge waiver is stated for this card.',
            'Joining fee is NIL (MITC); the first-year fee is stored as the annual fee.',
          ],
        }),
      ] },
    };
  })(),

  // ═════════════════════════════════════════════════════════════ SalarySe UP
  'rbl-bank-salaryse-up': (() => {
    const E = ['fuel', 'utilities', 'insurance', 'quasi', 'railways', 'rent', 'education', 'wallet', 'govt', 'contracted', 'cash', 'misc'];
    return {
      card_product: { ...GST, name: 'RBL Bank SalarySe UP Credit Card', issuer_slug: 'rbl', card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 499, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('salaryse-up-credit-card'), status: 'draft', verified_at: null, point_value_inr_baseline: 0.1, point_value_baseline_basis: 'SalarySe UP T&C 3.2(e),(f): 1 point = ₹0.20 when redeemed in the SalarySe app (no redemption fee) and ₹0.10 on the RBL Rewards Portal (₹99 + GST fee). The baseline is the ₹0.10 portal value, which is available to everyone; ₹0.20 applies in the SalarySe app only.', point_expiry_months: 24, confirmed_flat_base_outside_smartbuy_or_equivalent_portal: 'N/A' },
      eligibility_engine: { evaluation_mode: 'guideline_only', notes: '100% virtual card issued with Critical Path Technologies Pvt Ltd (SalarySe); no physical card is delivered and it is used through the RBL MyBank app and UPI.', rules: [], required_documents: [] },
      accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.1, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle', reversal_policy: { mode: 'proportional_deduction', negative_balance_allowed: null, negative_balance_settlement: null } },
      reward_rules: [
        ...exclusions('rbl-salaryse', E, 'SalarySe UP T&C 3.4', [
          X('rbl-salaryse-excl-bills2pay', 'excluded_spend', [], 'Bills2Pay payments earn no points (SalarySe UP T&C 3.4).', { channel: 'bills2pay' }),
          emiExcl('rbl-salaryse', 'SalarySe UP T&C 3.2(d)'),
          upiSmall('rbl-salaryse', 'SalarySe UP T&C 3.4'),
        ]),
        R({ id: 'rbl-salaryse-upi-5x', cat: 'upi', rail: 'upi_qr', pri: 10, ppb: 5, mult: 5, channel: 'salaryse_platform', cap: 'rbl-salaryse-5x-cap', cond: { platform: 'SalarySe app', per_inr_block: 100, monthly_salaryse_upi_spend_lte_inr: 20000 }, reason: '5 reward points per ₹100 on eligible UPI transactions made on the SalarySe platform, up to 1,000 points a month (T&C 3.2(b)).' }),
        R({ id: 'rbl-salaryse-upi-10x', cat: 'upi', rail: 'upi_qr', pri: 9, ppb: 10, mult: 10, channel: 'salaryse_platform', cap: 'rbl-salaryse-10x-cap', cond: { platform: 'SalarySe app', per_inr_block: 100, applies_to: 'incremental SalarySe UPI spend above ₹20,000 in the billing month' }, reason: '10 reward points per ₹100 on the part of monthly SalarySe UPI spend above ₹20,000, up to 8,000 points a month (T&C 3.2(c) and illustration 1).' }),
        R({ id: 'rbl-salaryse-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 reward point per ₹100 on eligible online and offline spends (T&C 3.2(a); page).' }),
      ],
      cap_rules: [
        C({ id: 'rbl-salaryse-5x-cap', cat: 'upi', metric: 'total_reward_points', period: 'statement_cycle', points: 1000, after: 'downgrade_to_base_rate', afterPpb: 1 }),
        C({ id: 'rbl-salaryse-10x-cap', cat: 'upi', metric: 'total_reward_points', period: 'statement_cycle', points: 8000, after: 'downgrade_to_base_rate', afterPpb: 1 }),
      ],
      brand_specific_voucher_caps: [],
      fees_and_surcharges: baseFees({ forex: 3.5, redemption: { fee_inr: 99, gst_applicable: true, exempted_channels: ['redemption in the SalarySe app'], notes: 'INR 99 + GST per redemption day on the RBL Rewards Portal; none when redeeming in the SalarySe app (page; T&C 3.2(f); RWD 4.3.1(d)(ii)).' } }),
      statement_and_late_fees: baseStatement,
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 200000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee of ₹499 + GST is waived on spends of ₹2 lakh in the preceding anniversary year (T&C 3.3; SOC; MITC). Spends in the excluded categories do not count.', excluded_category_ids: catList(E), excluded_mcc_list: mccUnion(E), waives_fee_inr: 499 },
        welcome_and_renewal_gift: { trigger: 'first_transaction_of_inr_500_within_30_days', benefit_points: 2500, effective_value_inr: null, condition: '2,500 reward points on a first transaction of at least ₹500 within 30 days of issue, credited within 60 days. Also 1,500 points on spends of ₹30,000 in the first 3 months, and 2,000 points on 15 successful UPI transactions of at least ₹500 each within 30 days (T&C 3.1). One time only. Rupee value depends on the redemption route (₹0.10 or ₹0.20 per point), so none is stored.' },
        spend_milestones: [],
      },
      lifestyle_and_network_benefits: [],
      insurance_and_protection: [],
      addon_card_rules: { ...addonDefault, fee_per_card_inr: 200 },
      redemption_matrix: { direct_options: [
        opt('SalarySe app', 'other', 0.2, 0),
        opt('RBL Bank Rewards Portal', 'other', 0.1, 99),
      ], partner_transfers: [] },
      dynamic_promotions_registry: [],
      additional_data: { items: [
        emiRule, lateRule,
        { key: 'addon_card_fee_rule', value: { rule: 'MITC lists ₹200 annual fee per add-on cardholder for SalarySe UP; the card is virtual only.', source: 'MITC section i and iii' } },
        ...prov({
          sources: [
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/tnc-salary-se-up-credit-card.pdf', kind: 'SalarySe UP T&C (welcome, rewards, caps, illustration, fee waiver, MCC exclusions, UPI)', date: 'PDF created 2026-05-11; Last-Modified 2026-05-19', read: 'pdftotext' },
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/salaryse-up-credit-card-role-responsibilities.pdf', kind: 'Co-brand partner roles and responsibilities', date: 'PDF created 2024-08-29', read: 'pdftotext' },
            { url: page('salaryse-up-credit-card'), kind: 'issuer product page (RuPay statement, point values)', read: 'page text' },
            srcSOC, srcMITC, srcCMA, srcRWD, srcLIST,
          ],
          unverified: [
            'Cap period: the T&C says "per month"; its illustration uses a "billing month" and "single billing cycle". Modelled as statement_cycle.',
            'What spend earns above the caps is not stated: after the 1,000-point 5X cap the illustration shows the 10X rate taking over above ₹20,000, and after the 8,000-point 10X cap nothing is stated. Both caps are modelled as falling back to 1 point per ₹100.',
            'The 5X and 10X rates apply to "eligible UPI transactions on the SalarySe platform" only; UPI on other apps earns the base rate (illustration 1 marks "UPI on XYZ" as not eligible).',
            'Value of a reward point: ₹0.20 in the SalarySe app, ₹0.10 on the RBL portal. The baseline is the lower value. At ₹0.20 the headline "up to 10X" is 2% on incremental UPI spend; at ₹0.10 it is 1%.',
            'Reward point expiry is the Rewards Programme T&C rule (24 months, RWD 5.1); the product T&C is silent.',
            'The product page lists "Welcome benefits: 2,500 + 2,000 + 1,500 points" as three offers; modelled as one welcome block with the three conditions in the text.',
            'No fuel surcharge waiver is stated; Fuel & Auto is an excluded category.',
            'The card is virtual only, yet the MITC lists a ₹200 add-on fee for SalarySe UP; whether add-on cards exist is not stated.',
            'The product page and the current card list show no "Apply Now" link for this card (it is sold through the SalarySe partner app); modelled as open.',
            aprNote,
          ],
          notes: [
            'RuPay only (page: "available only on RuPay Network"); linkable on UPI apps (T&C 3.5). NCMC is not available (T&C 3.2(k)).',
            'Forex markup is the general 3.5% (SOC "up to 3.5%"; MITC "3.5% on all cards").',
            'Joining fee is NIL (MITC); the first-year fee is stored as the annual fee.',
          ],
        }),
      ] },
    };
  })(),

  // ═════════════════════════════════════════════════════════════ IndianOil XTRA
  'rbl-bank-indianoil-xtra': (() => {
    const E = ['utilities', 'insurance', 'quasi', 'railways', 'rent', 'education', 'wallet', 'govt', 'contracted', 'cash', 'misc'];
    const XTRA_PDF = 'https://webassets.rbl.bank.in/document/credit-cards/tnc-indianoil-rbl-bank-extra-credit-card.pdf';
    const FAQ = 'https://webassets.rbl.bank.in/document/credit-cards/indianoil-rbl-bank-credit-card-faqs.pdf';
    return {
      card_product: { ...GST, name: 'RBL Bank IndianOil XTRA Credit Card', issuer_slug: 'rbl', card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 1500, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page('indianoil-rbl-bank-xtra-credit-card'), status: 'draft', verified_at: null, point_value_inr_baseline: 0.1, point_value_baseline_basis: 'XTRA T&C 4.2 and FAQ 11, 26: 1 Fuel Point = ₹0.50 when converted to IndianOil XTRA Reward points (3 Fuel Points = 5 XRP, 1 XRP = ₹0.30) for fuel at IndianOil stations, and ₹0.10 on the RBL Rewards Portal. The baseline is the ₹0.10 value available everywhere; ₹0.50 applies only to conversion for fuel at IndianOil stations, which is what the page headlines ("8.5% valueback").', point_expiry_months: 24, confirmed_flat_base_outside_smartbuy_or_equivalent_portal: 'N/A' },
      eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'XTRA FAQ 6: individuals aged 21 to 70, subject to the Bank\'s internal policy.', rules: [
        { parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] },
        { parameter: 'age_years', operator: '<=', threshold_value: 70, allowed_values: [] },
      ], required_documents: [] },
      accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: 0.2, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle', reversal_policy: { mode: 'proportional_deduction', negative_balance_allowed: null, negative_balance_settlement: null } },
      reward_rules: [
        ...exclusions('rbl-xtra', E, 'XTRA T&C 3.8', [
          X('rbl-xtra-excl-bills2pay', 'excluded_spend', [], 'Bills2Pay payments earn no fuel points (XTRA T&C 3.2).', { channel: 'bills2pay' }),
          emiExcl('rbl-xtra', 'XTRA T&C 3.2'),
          feeExcl('rbl-xtra', 'XTRA T&C 3.2: fees, charges and GST'),
          upiSmall('rbl-xtra', 'XTRA T&C 3.6'),
        ]),
        R({ id: 'rbl-xtra-iocl-15', cat: 'fuel', pri: 10, ppb: 15, mult: 7.5, channel: 'indianoil_select_stations', cap: 'rbl-xtra-iocl-cap', cond: { merchant: 'IndianOil fuel stations on IOCL\'s select MID/TID list', per_inr_block: 100 }, reason: '15 fuel points per ₹100 at select IndianOil fuel stations, up to 2,000 points a month; applies only to the MID/TID list supplied by IOCL (XTRA T&C 3.2).' }),
        R({ id: 'rbl-xtra-base-2', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 fuel points per ₹100 on all purchases other than the excluded categories (XTRA T&C 3.2; FAQ 2: "no capping"). Fuel at other pumps is not excluded.' }),
      ],
      cap_rules: [
        C({ id: 'rbl-xtra-iocl-cap', cat: 'fuel', metric: 'total_reward_points', period: 'statement_cycle', points: 2000, after: 'downgrade_to_base_rate', afterPpb: 2 }),
      ],
      brand_specific_voucher_caps: [],
      fees_and_surcharges: baseFees({ forex: 3.5, fuel: { surcharge: null, waiver: 1, min: 500, max: 4000, cap: 200 }, redemption: { fee_inr: 99, gst_applicable: true, exempted_channels: ['RBL Rewards conversion to IndianOil XTRA Reward points above 5,000 (fee waived)'], notes: 'INR 99 + GST per redemption day (SOC; MITC; RWD 4.3). MITC and RWD 4.3.1(d)(iii) waive it for "IOCL Credit Card - RBL Rewards Conversion >5000"; what the 5,000 counts (points) is not stated.' } }),
      statement_and_late_fees: baseStatement,
      fee_waiver_and_milestones: {
        annual_fee_waiver: { threshold_spend_inr: 275000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee of ₹1,500 + GST is waived on valid spends of ₹2.75 lakh a year (XTRA T&C 3.3; SOC; MITC); the waiver applies only if the annual fee has been paid (page). Excluded categories do not count; Fuel & Auto is not excluded.', excluded_category_ids: catList(E), excluded_mcc_list: mccUnion(E), waives_fee_inr: 1500 },
        welcome_and_renewal_gift: { trigger: 'first_transaction_above_inr_500_within_30_days_and_fee_paid', benefit_points: 3000, effective_value_inr: null, condition: '3,000 fuel points on an eligible retail transaction above ₹500 within 30 days of issue and payment of the annual fee shown in the first statement by its due date; credited within 60 days of the fee payment; once per cardholder (T&C 3.1). At ₹0.50 (XRP conversion) that is ₹1,500; at ₹0.10 it is ₹300, so no rupee value is stored.' },
        spend_milestones: [
          { id: 'rbl-xtra-quarterly-1000fp', label: '1,000 fuel points per calendar quarter on spends of ₹75,000 or more (excluded categories do not count)', threshold_spend_inr: 75000, reward_value_inr: 100, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null },
        ],
      },
      lifestyle_and_network_benefits: [
        B({ id: 'rbl-xtra-ncmc', cat: 'other', program: 'rupay', sponsor: 'NPCI', label: 'National Common Mobility Card functionality and RuPay credit card on UPI, on the RuPay variant only', cond: { network: 'rupay' } }),
      ],
      insurance_and_protection: [],
      addon_card_rules: { ...addonDefault, fee_per_card_inr: 200 },
      redemption_matrix: { direct_options: [
        opt('RBL Rewards Portal: convert Fuel Points to IndianOil XTRA Reward points (redeem at IndianOil fuel stations)', 'other', 0.5, null),
        opt('RBL Rewards Portal: all other redemptions', 'other', 0.1, 99),
      ], partner_transfers: [] },
      dynamic_promotions_registry: [],
      additional_data: { items: [
        dualNetwork({
          sourceUrl: page('indianoil-rbl-bank-xtra-credit-card'),
          evidence: 'Issuer page: "IndianOil RBL Bank XTRA Credit Card is available on MasterCard & RuPay network." T&C 3.6 and 3.7: UPI scan and pay and NCMC are available on the RuPay variant only.',
          variants: [
            { network: 'mastercard', network_tier: 'N/A', label: 'IndianOil RBL Bank XTRA Credit Card (Mastercard)', source_url: page('indianoil-rbl-bank-xtra-credit-card'), evidence: 'Issuer page: available on MasterCard & RuPay network.' },
            { network: 'rupay', network_tier: 'N/A', label: 'IndianOil RBL Bank XTRA Credit Card (RuPay)', source_url: XTRA_PDF, evidence: 'T&C 3.6, 3.7: UPI and NCMC features are RuPay only; offline UPI under ₹2,000 at small merchants earns no fuel points.' },
          ],
        }),
        emiRule, lateRule,
        { key: 'addon_card_fee_rule', value: { rule: 'MITC: ₹200 annual fee per add-on cardholder.', source: 'MITC section iii' } },
        ...prov({
          sources: [
            { url: XTRA_PDF, kind: 'IndianOil RBL Bank XTRA T&C (welcome, rewards, fee waiver, fuel waiver, milestone, RuPay features, exclusions, XRP value)', date: 'PDF created 2026-05-07; Last-Modified 2026-05-19', read: 'pdftotext' },
            { url: FAQ, kind: 'IndianOil credit card FAQs (benefits, validity, eligibility, point values)', date: 'PDF created 2026-05-18', read: 'pdftotext' },
            { url: 'https://webassets.rbl.bank.in/document/credit-cards/indianoil-rbl-bank-credit-card-role-responsibilities.pdf', kind: 'Co-brand partner roles (IndianOil)', date: 'PDF created 2024-08-27', read: 'pdftotext' },
            { url: page('indianoil-rbl-bank-xtra-credit-card'), kind: 'issuer product page (networks, headline claims)', read: 'page text' },
            srcSOC, srcMITC, srcCMA, srcRWD, srcLIST,
          ],
          unverified: [
            'Network: the page says Mastercard and RuPay; which a given customer gets is not stated. Stored as a dual-network card with network left null. is_upi_linkable is true for the RuPay variant only (T&C 3.6); the Mastercard variant cannot be linked to UPI (MITC section C).',
            'Cap period: the T&C and FAQ say "2,000 fuel points in a month" without defining the month; points are credited "once bill has been generated". Modelled as statement_cycle.',
            'What earns above the 2,000-point cap at IndianOil stations is not stated: T&C 3.2 gives the 2-point base rate for purchases "other than excluded categories and IndianOil fuel stations", while FAQ 2 says 2 points on "all spends except the exclusion categories (no capping)". Modelled as falling back to 2 points per ₹100.',
            'Value of a Fuel Point: ₹0.50 through XTRA Reward conversion (3 Fuel Points = 5 XRP at ₹0.30 each) and ₹0.10 elsewhere. The baseline is ₹0.10, so the stored base return is 0.2% and the IndianOil rate 1.5%; at ₹0.50 they are 1% and 7.5% (the page headlines 8.5% including the 1% surcharge waiver).',
            'The "250 litres free petrol a year on monthly spends of ₹45,000" headline was not reconciled with the earn rate and is not modelled.',
            'Redemption fee for XRP conversion: MITC and RWD say "IOCL Credit Card - RBL Rewards Conversion >5000 (Fee Waived)"; what the 5,000 refers to is not stated, so redemption_fee_inr is null for that route.',
            'IndianOil station list: accelerated points apply only at the MID/TID list IOCL supplies (cc-iocl-fuel-station-list.pdf), which was not read.',
            'Fuel surcharge waiver is processed on the 23rd of each month; whether the ₹200 cap is per calendar month or per statement is not stated beyond "every month".',
            'Welcome and annual-fee-waiver conditions require the annual fee to be paid; the "valid spends" for the ₹2.75 lakh waiver exclude the same categories as the earn rate.',
            aprNote,
          ],
          notes: [
            'Rewards are "Fuel Points"; they are valid for 2 years from earning (FAQ 12) and cannot be adjusted against the card outstanding (FAQ 19).',
            'Fuel Points convert to IndianOil XTRA Reward points only on the RBL Rewards Portal (FAQ 26).',
            'Fuel & Auto is not an excluded earn category on this card; the SOC and MITC 1% fee on fuel transactions above ₹10,000 (max ₹3,000) still applies.',
            'Joining fee is NIL (MITC); the first-year fee is stored as the annual fee.',
          ],
        }),
      ] },
    };
  })(),
};
