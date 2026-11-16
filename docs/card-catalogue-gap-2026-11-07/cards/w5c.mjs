// Wave 5, agent W5C (15 Nov 2026): Union Bank of India (12 cards drafted), Indian Bank (4 drafted), IDBI Bank (7 drafted).
// Every value below comes from an issuer page or issuer document read on 2026-11-15; nothing from comparison sites.
//
// UNION BANK OF INDIA
//  KFS  = https://www.unionbankofindia.bank.in/pdf/Key-Fact-Statement.pdf  (Credit Cards KFS, Version 1.4, 13 pages, PDF created 22 Apr 2026): fees, waivers, rewards for Unicorn and Nexteria, interest, forex, late fee
//  MITC = https://www.unionbankofindia.bank.in/pdf/mitc-credit-cards.pdf    (24 pages, PDF created 22 Apr 2026): same fee tables as the KFS
//  Card pages = https://www.unionbankofindia.bank.in/en/Details/<slug> (plain fetch, tab content read from the page source)
// INDIAN BANK
//  MITC = https://indianbank.bank.in/documents/d/guest/mitc-final-with-effective-apr (10 pages, PDF created 27 Sep 2026)
//  FEATURES = https://indianbank.bank.in/documents/d/guest/CREDIT-CARD-FEATURES-AND-BENEFITS-6 (2 pages, PDF created 29 Dec 2023: older)
//  POSTER = https://indianbank.bank.in/documents/d/guest/Get-Rewards-for-Every-Spent-with-IB-Credit-Card-3 (A4 poster, PDF created 24 Jan 2025, image only: read by looking at it)
//  YOUTH_MITC = https://indianbank.bank.in/documents/d/guest/mitc-youth-credit-card (PDF created 30 Oct 2026)
//  LIST = https://indianbank.bank.in/en/credit-cards (page last modified 30 Oct 2026)
// IDBI BANK
//  Product pages = https://www.idbi.bank.in/<name>-credit-card.aspx (undated)
//  MITC = https://www.idbi.bank.in/pdf/MITC-CC.PDF (24 pages, PDF created 23 Oct 2026; fee schedule inside says "Effective from April 13, 2023")
//  FAQ  = https://www.idbi.bank.in/credit-card-faq.aspx (names the network for five of the seven cards)
//  Card art = https://www.idbi.bank.in/images/Lumine-Credit-Card.png and Eclat-Credit-Card.png (RuPay mark on both)
import { R, X, C, B, P, prov, GST } from '../lib.mjs';

const FETCHED = { fetched_on: '2026-11-15' };
const src = (kind, url, date, read = 'issuer page text or pdftotext') => ({ url, kind, ...(date ? { date } : {}), read });

// ---------------------------------------------------------------------------------------------
// Generic maker. o carries every per-card value; unknown stays null.
// ---------------------------------------------------------------------------------------------
const make = (p, o) => ({
  card_product: {
    ...GST, name: o.name, issuer_slug: o.issuer, card_type: 'credit', network: o.network, network_tier: o.tier || 'N/A', application_mode: o.mode || 'open',
    joining_fee_inr: o.joining, annual_fee_inr: o.annual, is_upi_linkable: o.upi ?? null,
    data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: o.page, status: 'draft', verified_at: null,
    point_value_inr_baseline: o.pv ?? null, point_value_baseline_basis: o.pvBasis, point_expiry_months: o.expiry ?? null,
  },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.eligibility || null, rules: [], required_documents: [] },
  accrual_engine: {
    base_block_inr: o.block, rounding_mode: null, base_points_per_block: o.basePts ?? 'N/A', base_cashback_percent: o.baseCb ?? 'N/A',
    effective_base_return_percent: o.baseReturn ?? null, cycle_accrual_ceiling_points: o.cycleCeil ?? null, capping_period_basis: o.cycleCeil ? 'calendar_month' : null,
  },
  reward_rules: o.rules,
  cap_rules: o.caps || [],
  fees_and_surcharges: {
    apr: { monthly_interest_rate_percent: o.aprM, annual_interest_rate_percent: o.aprM * 12 },
    forex_markup: { markup_percent: o.forex, gst_applicable: true },
    dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: 'No separate DCC markup is stated in the issuer documents read' },
    fuel_surcharge: { category_id: 'fuel', surcharge_percent: o.fuel.surcharge ?? null, waiver_percent: o.fuel.waiver ?? null, min_txn_inr: o.fuel.min ?? null, max_txn_inr: o.fuel.max ?? null, monthly_waiver_cap_inr: o.fuel.cap ?? null },
    cash_advance: { atm_transaction_fee_percent: o.cash.pct ?? null, atm_transaction_fee_min_inr: o.cash.min ?? null, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: o.cash.limit ?? null },
    category_surcharges: [],
    emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: o.emi.proc ?? null, foreclosure_charge_percent: o.emi.fore ?? null, gst_applicable: true },
    banking_penalties: { overlimit_charge: o.over, auto_debit_bounce_charge_inr: o.bounce ?? null, cheque_bounce_charge_inr: o.bounce ?? null },
    reward_redemption_fee: { fee_inr: o.redeemFee ?? null, gst_applicable: null },
  },
  statement_and_late_fees: { late_payment_slabs: o.late },
  fee_waiver_and_milestones: {
    annual_fee_waiver: o.waiver
      ? { threshold_spend_inr: o.waiver.spend, period: o.waiver.period || 'card_anniversary_year', evaluation_condition: o.waiver.text, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: o.annual }
      : { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: o.noWaiverText || 'No annual fee applies, so there is nothing to waive.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
    welcome_and_renewal_gift: o.welcome || { trigger: 'N/A', benefit_points: 'N/A', effective_value_inr: 'N/A', condition: 'No welcome benefit is stated in the issuer documents read.' },
    spend_milestones: o.milestones || [],
  },
  addon_card_rules: { max_addon_cards: o.addon ?? null, fee_per_card_inr: o.addonFee ?? null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: o.pooled ?? null, min_age_years: null },
  lifestyle_and_network_benefits: o.benefits || [],
  dynamic_promotions_registry: o.promos || [],
  additional_data: { items: [
    ...(o.dual ? [o.dual] : []),
    ...prov({
      sources: o.sources,
      unverified: o.unverified,
      notes: o.notes || [],
      extra: { ...FETCHED, ...(o.provExtra || {}) },
    }),
  ] },
});

// =============================================================================================
// UNION BANK OF INDIA
// =============================================================================================
const UB = 'union-bank-of-india';
const KFS = 'https://www.unionbankofindia.bank.in/pdf/Key-Fact-Statement.pdf';
const MITC_UB = 'https://www.unionbankofindia.bank.in/pdf/mitc-credit-cards.pdf';
const UBP = (s) => `https://www.unionbankofindia.bank.in/en/Details/${s}`;
const ubSources = (page, kind) => [
  src('Key Fact Statement, Credit Cards, Version 1.4 (PDF created 22 Apr 2026): joining and annual fees, fee waivers, interest, late fee, forex, fuel waiver, cash limits, reward notes for Unicorn and Nexteria', KFS, 'PDF created 2026-04-22', 'pdftotext'),
  src('MITC, Credit Cards (PDF created 22 Apr 2026): same fee tables as the KFS', MITC_UB, 'PDF created 2026-04-22', 'pdftotext'),
  src(kind, page, null, 'plain page fetch; tab content read from the page source'),
];
const ubLate = [{ min_balance_inr: 0, max_balance_inr: 25000, fee_inr: 200 }, { min_balance_inr: 25001, max_balance_inr: null, fee_inr: 500 }];
const ubFees = (cashLimit, fuel) => ({
  issuer: UB, aprM: 3, forex: 3, late: ubLate,
  fuel: fuel || { waiver: 1, cap: 100 },
  cash: { pct: 3, min: 500, limit: cashLimit },
  emi: { proc: null, fore: 2 },
  over: { fee_percent: 2.5, min_fee_inr: 250, gst_applicable: true },
  bounce: 250,
});
const ubCommonUnverified = (extra = []) => [
  'Reward points exclusions: the KFS lists excluded MCCs (jewellery, fuel, cash withdrawal, bitcoin, wallet loading, alcohol and wine shops, insurance) only for Unicorn and Nexteria. For the other cards the page says only "no reward points on cash withdrawals" (FAQ); the full list of MCCs that earn nothing is not published ("eligible MCCs prescribed by Bank time to time").',
  'Fuel surcharge waiver wording differs: the card pages say "per billing cycle"; the KFS and MITC say "per month". The page wording is used. The surcharge the acquirer charges at the pump (the amount being waived) is not stated, and no minimum transaction value is stated except for UNI CARBON (Rs 200 and above).',
  'KFS and MITC say all fees are exclusive of GST; the 18% rate is taken from the worked examples in the same documents (GST of Rs 36 on a Rs 200 fee).',
  'Reward-point value: the card page states 1 Reward Point = Rs 0.25. The KFS and MITC do not repeat it.',
  'Both PDFs are Version 1.4 with no printed effective date; the file creation date (22 Apr 2026) is the only date available.',
  ...extra,
];
const PV25 = 0.25;
const PV25_BASIS = 'Card page features table: "1 Reward Point = Rs. 0.25" (Union Bank of India card page read 2026-11-15). Not repeated in the KFS or MITC.';
const ubMilestone = (id, label, spend, pts, pv) => ({ id, label, threshold_spend_inr: spend, reward_value_inr: pv ? pts * pv : null, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null });

const ubStd = (slug, name, page, pageKind, o) => make(slug, {
  ...ubFees(o.cashLimit, o.fuel), name, page, network: o.network, tier: o.tier, upi: o.upi,
  joining: o.joining ?? 0, annual: o.annual, waiver: { spend: o.waiverSpend, text: `KFS fee table: annual fee Rs ${o.annual} + GST, collected at the start of the 2nd year, waived if card spend in the last 12 months (from card issuance date) is Rs ${o.waiverSpend.toLocaleString('en-IN')} (KFS and MITC).` },
  pv: o.pv ?? PV25, pvBasis: o.pvBasis ?? PV25_BASIS, expiry: null,
  block: 100, basePts: o.pts, baseReturn: o.pts * (o.pv ?? PV25) / 100 * 100,
  rules: o.rules || [R({ id: `${slug}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: o.pts, mult: 1, cond: { per_inr_block: 100 }, reason: `${o.pts} reward point(s) per Rs 100 spent (card page); 1 point = Rs 0.25.` })],
  caps: [], addon: o.addon ?? 3, addonFee: o.addonFee ?? null, pooled: null,
  eligibility: o.eligibility || null,
  milestones: o.milestones || [], welcome: o.welcome, benefits: o.benefits, promos: o.promos || [],
  sources: [...ubSources(page, pageKind), ...(o.extraSources || [])],
  unverified: ubCommonUnverified(o.unverified || []),
  notes: o.notes || [],
});

// ---- Union Bank: Visa Gold / Platinum / Signature, RuPay Platinum / Select -------------------
const UB_ACC = (s) => s;
const mcxNote = 'Reward points on cash withdrawals: none (card page FAQ).';

// =============================================================================================
// INDIAN BANK
// =============================================================================================
const IB = 'indian-bank';
const IB_MITC = 'https://indianbank.bank.in/documents/d/guest/mitc-final-with-effective-apr';
const IB_FEAT = 'https://indianbank.bank.in/documents/d/guest/CREDIT-CARD-FEATURES-AND-BENEFITS-6';
const IB_POSTER = 'https://indianbank.bank.in/documents/d/guest/Get-Rewards-for-Every-Spent-with-IB-Credit-Card-3';
const IB_LIST = 'https://indianbank.bank.in/en/credit-cards';
const ibSources = () => [
  src('Most Important Terms and Conditions (PDF created 27 Sep 2026): AMC, interest, late fee, forex, fuel surcharge, limits, insurance', IB_MITC, 'PDF created 2026-09-27', 'pdftotext and page image'),
  src('Credit Card Features and Benefits sheet (PDF created 29 Dec 2023, older): card variants, credit limits, reward points, lounge line', IB_FEAT, 'PDF created 2023-12-29', 'pdftotext'),
  src('"Get rewards for every spent with IB credit card" poster (PDF created 24 Jan 2025, image only): Rs 1 cashback per Rs 100, Rs 0.50 on listed categories, exclusions; shows a RuPay Platinum and a Visa Platinum card', IB_POSTER, 'PDF created 2025-01-24', 'page image read visually'),
  src('Credit Cards page (last modified 30 Oct 2026): list of variants, AMC waiver footnote, daily limits', IB_LIST, 'last modified 2026-10-30', 'plain page fetch'),
];
const ibLate = [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 250 }];
const ibBase = {
  issuer: IB, joining: 0, forex: 3, late: ibLate, page: IB_LIST,
  fuel: { surcharge: 2.5, waiver: null }, cash: { pct: null, min: 50, limit: 40 },
  emi: { proc: null, fore: 3 }, over: { fee_percent: null, min_fee_inr: 50, gst_applicable: null }, bounce: 250, upi: null,
  expiry: null,
};
const ibUnverified = (extra = []) => [
  'Reward documents are older than the 2026 MITC and disagree in form: the Dec 2023 features sheet says "1 point valued at Re.1 for every Rs.100 spent" (Platinum, Select, Visa Gold) while the Jan 2025 poster says "cashback of Rs 1 for every Rs 100 spent, credited to the card statement in the same billing month" and Rs 0.50 per Rs 100 on rent, utilities, fuel, insurance, jewellery and government spends. Both give Rs 1 per Rs 100. The poster does not say which variants it covers (it shows Platinum cards). The 2026 MITC does not mention rewards. A person should confirm which variants earn the cashback and whether it is still current.',
  'Poster note: no cashback on wallet load, EMI transactions, ATM withdrawals and UPI transactions below Rs 2,000. Whether there is a monthly cap is not stated.',
  'Fuel: the MITC states a surcharge of Rs 10 or 2.5% of the transaction amount, whichever is higher, on petrol and pump purchases, and no surcharge waiver for these cards. Surcharge is recorded as 2.5% with the Rs 10 minimum noted here.',
  'Cash advance: MITC states a fee of Rs 50 per cash advance and interest of 2.25% a month from the transaction date; the percentage-based fee is not applicable (flat Rs 50). Late fee Rs 250 flat (MITC).',
  'Over limit fee Rs 50 flat (MITC schedule). EMI processing fee 2% of the converted amount, minimum Rs 199, maximum Rs 1,000; EMI interest 18% a year; foreclosure 3% of pending principal (MITC).',
  'MITC states "All the charges and interest mentioned are excluding GST" only in the Youth MITC; the main MITC does not say it, so the GST flag follows the Youth MITC wording.',
  ...extra,
];

// =============================================================================================
// IDBI BANK
// =============================================================================================
const ID = 'idbi-bank';
const ID_MITC = 'https://www.idbi.bank.in/pdf/MITC-CC.PDF';
const ID_FAQ = 'https://www.idbi.bank.in/credit-card-faq.aspx';
const IDP = (s) => `https://www.idbi.bank.in/${s}`;
const idSources = (page, kind, extra = []) => [
  src(kind, page, null, 'plain page fetch'),
  src('MITC, IDBI Bank Credit Card (PDF created 23 Oct 2026; the fee schedule inside says "Effective from April 13, 2023"): fee schedule by variant, interest, late fee, forex, fuel waiver, Delight Points exclusions and expiry, cashback table', ID_MITC, 'PDF created 2026-10-23', 'pdftotext'),
  src('Credit card FAQ: lists the Aspire, Royale, Euphoria, Imperium and Winnings variants with their networks', ID_FAQ, null, 'plain page fetch'),
  ...extra,
];
const idLate = [{ min_balance_inr: 0, max_balance_inr: 500, fee_inr: 0 }, { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 400 }, { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 500 }, { min_balance_inr: 10001, max_balance_inr: 20000, fee_inr: 750 }, { min_balance_inr: 20001, max_balance_inr: null, fee_inr: 950 }];
const ID_EXCL_MCC = [6010, 6011, 6211, 6300, 6381, 9211, 9222, 9311, 9399, 9405, 4112, 5960, 5541, 5542, 5172, 5983];
const idExcl = (p) => X(`${p}-excluded-mccs`, 'excluded_spend', ID_EXCL_MCC, 'No Delight Points on cash disbursements, securities, insurance, government and court payments, passenger railways, direct-marketing insurance and fuel MCCs (MITC section 12).');
const ID_PV_BASIS = 'IDBI Bank states no rupee value for one Delight Point on the card page, the MITC or the FAQ read on 2026-11-15 (the IDBI Delight site redirects to idbidelight.idbi.bank.in and was not read). Left null.';
const idBase = {
  issuer: ID, pv: null, pvBasis: ID_PV_BASIS, expiry: 36,
  forex: 3.5, late: idLate, cash: { pct: 2.5, min: 500, limit: null }, emi: { proc: 0, fore: 0 },
  over: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: null }, bounce: 500, redeemFee: 20,
};
const idUnverified = (extra = []) => [
  'Value of one Delight Point in rupees: NOT STATED by IDBI in the card page, MITC or FAQ read. Point value, effective return and every rupee value of a bonus or milestone stay null. Question for IDBI: what is one Delight Point worth in rupees for this card, and on what redemption (the MITC mentions only a Rs 20 fee for cash-back redemption between 1,000 and 4,000 points)?',
  'Delight Points expiry: the MITC says points expire after 3 years (campaign points after 1 year). Taken as 36 months.',
  'Late fee and interest come from the MITC fee schedule "effective from April 13, 2023" inside a file created 23 Oct 2026; the card page values match it.',
  'Cash advance fee is 2.5% of the amount or Rs 500, whichever is higher; the page wording says "transaction fee" and is read as the transaction amount (MITC section 1b says "transaction amount").',
  'The milestone benefits on the page are bonus points on net annual spend; the page does not say whether the year is the card year or a calendar year, so the period is a guess flagged here: card_anniversary_year is used.',
  'The page says Delight Points accrue on all transactions except the MCC list in MITC section 12; the exemptions on the page are linked ("refer exempted categories here"), and the MITC list was used.',
  ...extra,
];
const idMilestone = (id, label, spend, pts) => ({ id, label: `${pts.toLocaleString('en-IN')} bonus Delight Points on net annual spend of Rs ${spend.toLocaleString('en-IN')} (card page; rupee value unknown)`, threshold_spend_inr: spend, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: false, effective_from: null, effective_to: null });
const idWelcome = (act, first, firstSpend, days = 30) => ({ trigger: 'card_activation', benefit_points: act, effective_value_inr: null, condition: `${act} bonus Delight Points on card activation, and ${first} bonus Delight Points on a first transaction of Rs ${firstSpend.toLocaleString('en-IN')} or more within ${days} days of activation (card page). Rupee value unknown.` });

export const cards = {};

// ===================================== UNION BANK OF INDIA =====================================
cards['union-bank-of-india-visa-gold'] = ubStd('union-bank-of-india-visa-gold', 'Union Bank of India VISA Gold Credit Card', UBP('visa-gold-credit-card'), 'VISA Gold card page: reward points, fuel waiver, accidental insurance, add-on cards', {
  network: 'visa', tier: 'visa_gold', annual: 350, waiverSpend: 30000, addonFee: 250, cashLimit: 20, pts: 1,
  benefits: [B({ id: 'union-bank-of-india-visa-gold-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance cover Rs 5 lakh (premium borne by cardholder)' })],
  unverified: [mcxNote, 'Add-on cards: page says a maximum of 3; KFS add-on annual fee Rs 250, add-on joining nil.'],
});
cards['union-bank-of-india-visa-platinum'] = ubStd('union-bank-of-india-visa-platinum', 'Union Bank of India VISA Platinum Credit Card', UBP('visa-platinum-credit-card'), 'VISA Platinum card page', {
  network: 'visa', tier: 'visa_platinum', annual: 450, waiverSpend: 50000, addonFee: 350, cashLimit: 30, pts: 2,
  benefits: [B({ id: 'union-bank-of-india-visa-platinum-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance cover Rs 10 lakh (premium borne by cardholder)' })],
  unverified: [mcxNote, 'Add-on cards: page says a maximum of 3; KFS add-on annual fee Rs 350, add-on joining nil.'],
});
cards['union-bank-of-india-visa-signature'] = ubStd('union-bank-of-india-visa-signature', 'Union Bank of India VISA Signature Credit Card', UBP('visa-signature-credit-card'), 'VISA Signature card page', {
  network: 'visa', tier: 'visa_signature', annual: 1999, waiverSpend: 270000, addonFee: 999, cashLimit: 40, pts: 4,
  benefits: [B({ id: 'union-bank-of-india-visa-signature-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance cover Rs 30 lakh (premium borne by cardholder)' })],
  unverified: [mcxNote, 'Add-on cards: page says a maximum of 3; KFS add-on annual fee Rs 999, add-on joining nil. No lounge benefit is listed on the page, although a Visa Signature card normally has one: not stated, so not added.'],
});
cards['union-bank-of-india-rupay-platinum'] = ubStd('union-bank-of-india-rupay-platinum', 'Union Bank of India RuPay Platinum Credit Card', UBP('rupay-platinum-credit-card'), 'RuPay Platinum card page', {
  network: 'rupay', tier: 'rupay_platinum', upi: true, annual: 350, waiverSpend: 30000, addonFee: 250, cashLimit: 30, pts: 2,
  benefits: [B({ id: 'union-bank-of-india-rupay-platinum-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 2 lakh (premium borne by NPCI) plus an additional Rs 10 lakh (premium borne by cardholder)' })],
  unverified: [mcxNote, 'The page introduction says the card "comes with complimentary lounge access" but states no quota, so no lounge benefit with a count is recorded. Add-on annual fee Rs 250 (KFS).'],
});
cards['union-bank-of-india-rupay-select'] = ubStd('union-bank-of-india-rupay-select', 'Union Bank of India RuPay Select Credit Card', UBP('rupay-select-credit-card'), 'RuPay Select card page', {
  network: 'rupay', tier: 'rupay_select', upi: true, annual: 550, waiverSpend: 50000, addonFee: 450, cashLimit: 40, pts: 4,
  benefits: [
    B({ id: 'union-bank-of-india-rupay-select-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / RuPay', label: 'Complimentary domestic and international airport lounge access', cond: { domestic_per_year: 8, domestic_per_quarter: 2, international_per_year: 2 }, qty: 10, per: 'annual' }),
    B({ id: 'union-bank-of-india-rupay-select-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 10 lakh (premium borne by NPCI) plus an additional Rs 30 lakh (premium borne by cardholder)' }),
  ],
  unverified: [mcxNote, 'Add-on annual fee Rs 450 (KFS).'],
});
cards['union-bank-of-india-sparsh'] = ubStd('union-bank-of-india-sparsh', 'Union Bank of India Sparsh Credit Card', UBP('union-sparsh-credit-card'), 'Sparsh card page: charges and features table, eligibility (visually impaired customers only), key points', {
  network: 'rupay', tier: 'N/A', upi: null, annual: 550, waiverSpend: 50000, cashLimit: null, pts: 4, mode: 'restricted',
  eligibility: 'Only visually impaired individuals are eligible (page: identified from bank records). Age 21-65; card against a lien on a term deposit from age 18. CIBIL 700 and above, not applicable to a card against a term deposit. Base limit Rs 50,000 (page).',
  benefits: [
    B({ id: 'union-bank-of-india-sparsh-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / RuPay', label: 'Complimentary domestic and international airport lounge access', cond: { domestic_per_year: 8, domestic_per_quarter: 2, international_per_year: 2 }, qty: 10, per: 'annual' }),
    B({ id: 'union-bank-of-india-sparsh-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 10 lakh (premium borne by NPCI) plus an additional Rs 30 lakh (premium borne by cardholder)' }),
  ],
  welcome: { trigger: 'N/A', benefit_points: 'N/A', effective_value_inr: 'N/A', condition: 'Annual fee waived in the 1st year (page).' },
  unverified: [
    'The Sparsh card is not in the KFS fee table; its fees come from the card page "Charges and features" table only (joining nil, annual Rs 550 + GST, waived in the 1st year and not levied if previous-year spend is Rs 50,000). The page says all other charges, insurance, fees and fuel surcharge waiver are the same as the RuPay Select variant, so the KFS RuPay Select values (cash limit 40%, add-on fee Rs 450) apply by that reference but are not restated for Sparsh. Cash limit is left null.',
    'Fuel waiver for Sparsh is written "1% up to Rs 100 p.m." on its page.',
    mcxNote,
  ],
  addonFee: null,
});
cards['union-bank-of-india-divaa-icon'] = make('union-bank-of-india-divaa-icon', {
  ...ubFees(30), name: 'Union Bank of India DIVAA ICON Credit Card (Women, RuPay Platinum)', page: UBP('divaa-icon-credit-card'), network: 'rupay', tier: 'rupay_platinum', upi: null,
  joining: 0, annual: 1499, waiver: { spend: 100000, text: 'Annual fee Rs 1,499 + GST waived on spend of Rs 1,00,000 within 12 months of activation (card page); the KFS says spend in the last 12 months from card issuance date.' },
  pv: PV25, pvBasis: 'Card page Eligibility and Reward Structure: "1 Reward Point = Rs 0.25 value".', expiry: null,
  block: 100, basePts: 2, baseReturn: 0.5,
  rules: [R({ id: 'union-bank-of-india-divaa-icon-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 Reward Points for every Rs 100 spent; exclusions "as per standard MCC guidelines" (card page).' })],
  caps: [], addon: null, addonFee: 1499, pooled: null,
  eligibility: 'Women customers only. Age 21-65; card against a lien on a term deposit from age 18. CIBIL score 700 and above, not applicable to a card against a term deposit (card page).',
  benefits: [
    B({ id: 'union-bank-of-india-divaa-icon-lounge', cat: 'lounge', sponsor: 'Union Bank of India', label: 'Airport lounge access: domestic 2 per quarter, international 2 per year', cond: { domestic_per_quarter: 2, international_per_year: 2 }, qty: 4, per: 'quarter' }),
    B({ id: 'union-bank-of-india-divaa-icon-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 2 lakh (premium borne by NPCI) plus an additional Rs 10 lakh (premium borne by cardholder), once annually; cyber insurance Rs 2 lakh or cancer insurance for women' }),
  ],
  promos: [
    P({ id: 'union-bank-of-india-divaa-icon-bms', cat: 'entertainment', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', max: 250, quota: true }),
    P({ id: 'union-bank-of-india-divaa-icon-mmt', cat: 'travel', sponsor: 'MakeMyTrip', platform: 'MakeMyTrip', type: 'instant_discount', max: 1500, quota: true }),
  ],
  sources: [...ubSources(UBP('divaa-icon-credit-card'), 'DIVAA ICON card page: features and benefits table, fees and charges, eligibility and reward structure')],
  unverified: ubCommonUnverified([
    'Add-on annual fee: the KFS shows Rs 1,499 for add-on as well as primary; joining nil for both.',
    'Partner offers (Lakme Rs 1,500 e-gift card per quarter, Flipkart Rs 250, Nykaa Rs 500, Myntra Rs 250 twice a quarter, Jockey Rs 250, Big Basket Rs 250, Healthians Rs 1,000, Cult Fit, Swiggy One 3 months) are listed on the page as coupons by frequency; only BookMyShow and MakeMyTrip are modelled as discounts here. Quantity per cycle is on the page.',
    'The KFS names the card "Divaa Icon Credit Card (Female Only - RuPay Platinum)" and the page says it upgrades the bank\'s earlier women-centric card; no separate earlier card is in this assignment.',
  ]),
  notes: ['Card network: KFS and cash-limit table name the card as RuPay Platinum.'],
});
cards['union-bank-of-india-jcb-wellness'] = make('union-bank-of-india-jcb-wellness', {
  ...ubFees(40), name: 'Union Bank of India Union JCB Wellness Credit Card', page: UBP('union-jcb-wellness-credit-card'), network: 'rupay', tier: 'rupay_select', upi: true,
  joining: 999, annual: 999, waiver: { spend: 100000, text: 'Annual fee Rs 999 + GST waived if card spend in the last 12 months is Rs 1,00,000 (KFS). Joining fee Rs 999; no add-on card (KFS "NA").' },
  pv: PV25, pvBasis: PV25_BASIS, expiry: null, block: 100, basePts: 2, baseReturn: 0.5,
  rules: [
    X('union-bank-of-india-jcb-wellness-fuel-excluded', 'fuel', [], 'Page states 2 points on "all other non-fuel spends", so fuel is read as earning no points.'),
    R({ id: 'union-bank-of-india-jcb-wellness-accel-4', cat: 'dining', pri: 10, ppb: 4, mult: 2, cond: { categories: ['dining', 'shopping', 'groceries', 'departmental_stores', 'apparel'], per_inr_block: 100 }, reason: '4 reward points per Rs 100 on dining, shopping, groceries, departmental stores and apparel (card page).' }),
    R({ id: 'union-bank-of-india-jcb-wellness-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 points per Rs 100 on all other non-fuel spends (card page); 1 point = Rs 0.25.' }),
  ],
  caps: [], addon: 0, addonFee: null, pooled: null,
  milestones: [ubMilestone('union-bank-of-india-jcb-wellness-m1', '1,000 bonus points at Rs 1,50,000 annual spend (page)', 150000, 1000, PV25), ubMilestone('union-bank-of-india-jcb-wellness-m2', '1,500 bonus points at Rs 2,00,000 annual spend (page)', 200000, 1500, PV25), ubMilestone('union-bank-of-india-jcb-wellness-m3', '2,000 bonus points at Rs 2,50,000 annual spend (page)', 250000, 2000, PV25)],
  benefits: [
    B({ id: 'union-bank-of-india-jcb-wellness-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / RuPay', label: 'Complimentary airport lounge access', cond: { domestic_per_year: 8, domestic_per_quarter: 2, international_per_year: 2 }, qty: 10, per: 'annual' }),
    B({ id: 'union-bank-of-india-jcb-wellness-golf', cat: 'golf', sponsor: 'Union Bank of India', label: 'Complimentary golf round, once a year', qty: 1, per: 'annual' }),
    B({ id: 'union-bank-of-india-jcb-wellness-health', cat: 'health', sponsor: 'Union Bank of India', label: 'Complimentary health check-up (diagnostic test) once a year; spa massage sessions; gym 15/30-day trial once a year', qty: 1, per: 'annual' }),
    B({ id: 'union-bank-of-india-jcb-wellness-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 10 lakh (premium borne by NPCI) plus an additional Rs 30 lakh (premium borne by cardholder)' }),
  ],
  sources: ubSources(UBP('union-jcb-wellness-credit-card'), 'Union JCB Wellness card page: benefits table, features, milestone rewards'),
  unverified: ubCommonUnverified([
    'Network: the page names RuPay (RuPay credit card can be linked on UPI; RuPay Select booking steps; RuPay Airport Lounge details). "JCB" in the card name is not described as a network anywhere on the page or in the KFS. Network recorded as RuPay on that page wording; a person should confirm the issued network.',
    'The page says the annual benefits are "worth around Rs 22,000" but gives no per-benefit rupee value, so none is recorded.',
    'Milestone period: "in a year"; card anniversary year is assumed.',
  ]),
  notes: ['Whether the 4-point categories include online shopping or are in-store only is not stated; "shopping" is as written on the page.'],
});
cards['union-bank-of-india-jcb-health'] = make('union-bank-of-india-jcb-health', {
  ...ubFees(30), name: 'Union Bank of India Union JCB Health Credit Card', page: UBP('union-jcb-health-credit-card'), network: 'rupay', tier: 'rupay_select', upi: true,
  joining: 499, annual: 499, waiver: { spend: 50000, text: 'Annual fee Rs 499 + GST waived if card spend in the last 12 months is Rs 50,000 (KFS). Joining fee Rs 499; no add-on card (KFS "NA").' },
  pv: PV25, pvBasis: PV25_BASIS, expiry: null, block: 100, basePts: 2, baseReturn: 0.5,
  rules: [R({ id: 'union-bank-of-india-jcb-health-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 points per Rs 100 (card page); 1 point = Rs 0.25.' })],
  caps: [], addon: 0, addonFee: null, pooled: null,
  milestones: [{ id: 'union-bank-of-india-jcb-health-m1', label: '2,000 bonus points for every Rs 50,000 spent beyond Rs 2,00,000 in a year (page)', threshold_spend_inr: 250000, reward_value_inr: 500, period: 'card_anniversary_year', is_repeatable: true, effective_from: null, effective_to: null }],
  benefits: [
    B({ id: 'union-bank-of-india-jcb-health-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / RuPay', label: 'Complimentary airport lounge access', cond: { domestic_per_year: 8, domestic_per_quarter: 2, international_per_year: 2 }, qty: 10, per: 'annual' }),
    B({ id: 'union-bank-of-india-jcb-health-wellness', cat: 'health', sponsor: 'Union Bank of India', label: 'Wellness package through eahomecare.in: 2 teleconsultations with e-prescription, 2 psychologist teleconsultations, 1 diagnostic package, 1 dietician consultation, 1 fitness session, car and home services, device protection (frequencies on the page)' }),
    B({ id: 'union-bank-of-india-jcb-health-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 10 lakh (premium borne by NPCI) plus an additional Rs 10 lakh (premium borne by cardholder)' }),
  ],
  sources: ubSources(UBP('union-jcb-health-credit-card'), 'Union JCB Health card page: benefits table, features, milestone rewards'),
  unverified: ubCommonUnverified([
    'Network: the page names RuPay (UPI linking and RuPay lounge and offers links); "JCB" in the name is not described as a network. Recorded as RuPay on that wording; a person should confirm.',
    'The page says annual benefits are "worth Rs 31,750" with no per-benefit rupee value; none recorded. Milestone reward_value_inr is 2,000 points x Rs 0.25 = Rs 500; the page says "for every Rs 50,000 beyond Rs 2.00 lakh in a year", modelled as a repeating step from Rs 2,50,000 (period assumed card anniversary year).',
  ]),
});
cards['union-bank-of-india-uni-carbon'] = make('union-bank-of-india-uni-carbon', {
  ...ubFees(40, { waiver: 1, min: 200, cap: 100, surcharge: null }), name: 'Union Bank of India Union UNI-CARBON Credit Card (HPCL co-brand)', page: UBP('union-uni-carbon-credit-card'), network: 'rupay', tier: 'N/A', upi: true,
  joining: 499, annual: 550, waiver: { spend: 100000, text: 'Annual fee Rs 550 + GST waived if card spend in the last 12 months is Rs 1,00,000 (KFS). Joining fee Rs 499 for the primary card.' },
  pv: PV25, pvBasis: PV25_BASIS, expiry: null, block: 100, basePts: 2, baseReturn: 0.5,
  rules: [
    R({ id: 'union-bank-of-india-uni-carbon-hpcl-fuel', cat: 'fuel', pri: 5, ppb: 16, cb: 4, mult: 8, cap: 'union-bank-of-india-uni-carbon-hpcl-cap', cond: { merchant: 'HPCL authorised outlets', min_txn_inr: 500, per_inr_block: 100 }, reason: '16 reward points (equal to Rs 4 cashback, 4%) per Rs 100 on fuel at HPCL authorised outlets on transactions of Rs 500 and above, up to Rs 150 per billing cycle per card (card page).' }),
    R({ id: 'union-bank-of-india-uni-carbon-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 points per Rs 100 on non-fuel spend (card page); 1 point = Rs 0.25.' }),
  ],
  caps: [C({ id: 'union-bank-of-india-uni-carbon-hpcl-cap', cat: 'fuel', metric: 'eligible_spend_amount', period: 'billing_cycle', inr: 150, after: 'downgrade_to_base_rate', afterPpb: 0 })],
  addon: 3, addonFee: 250, pooled: null,
  welcome: { trigger: 'fuel_purchase_within_60_days_of_activation', benefit_points: 'N/A', effective_value_inr: 300, condition: 'Up to Rs 300 credited to the bill if the customer purchases fuel worth Rs 300 or more at an HPCL authorised outlet within 60 days of activation (card page).' },
  milestones: [ubMilestone('union-bank-of-india-uni-carbon-m1', '500 bonus points at Rs 1,25,000 annual spend (page; cumulative 500)', 125000, 500, PV25), ubMilestone('union-bank-of-india-uni-carbon-m2', '600 bonus points at Rs 1,50,000 (cumulative 1,100)', 150000, 600, PV25), ubMilestone('union-bank-of-india-uni-carbon-m3', '700 bonus points at Rs 1,75,000 (cumulative 1,800)', 175000, 700, PV25), ubMilestone('union-bank-of-india-uni-carbon-m4', '800 bonus points at Rs 2,00,000 (cumulative 2,600)', 200000, 800, PV25)],
  benefits: [B({ id: 'union-bank-of-india-uni-carbon-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Accidental insurance Rs 10 lakh (premium borne by NPCI) plus an additional Rs 10 lakh (premium borne by cardholder)' })],
  promos: [P({ id: 'union-bank-of-india-uni-carbon-hp-pay', cat: 'fuel', sponsor: 'HPCL', platform: 'HP Pay app', type: 'cashback', pct: 1.5, quota: false })],
  sources: ubSources(UBP('union-uni-carbon-credit-card'), 'UNI-CARBON card page: welcome and cashback benefits, rewards, fuel waiver, milestones'),
  unverified: ubCommonUnverified([
    'Billing-cycle cap: the page says the 4% HPCL cashback is "up to a maximum of Rs 150 per billing cycle per card"; modelled as a Rs 150 cap on the cashback amount per billing cycle (the cap metric used is the rupee value of the cashback, not spend).',
    'On HP Pay app payments the page adds 1.5% cash back as 6 HP loyalty points credited to the HP Pay app (HPCL points); modelled as a partner offer without a rupee cap. Total savings stated: 6.5%.',
    'Beyond Rs 2,00,000 annual spend the page says 1,000 additional points for every Rs 50,000 in a billing year; not modelled as a step.',
    'Fuel excluded from the 2-point rate ("non-fuel transactions"); HPCL fuel earns the 16-point cashback rate only at HPCL outlets on Rs 500 and above; fuel elsewhere earns nothing. Fuel surcharge waiver: 1% on Rs 200 and above at HPCL outlets, Rs 100 per billing cycle.',
  ]),
});

cards['union-bank-of-india-unicorn'] = make('union-bank-of-india-unicorn', {
  ...ubFees(40), name: 'Union Bank of India Union Unicorn RuPay Credit Card', page: UBP('union-unicorn-credit-card'), network: 'rupay', tier: 'N/A', upi: null,
  joining: 2400, annual: 2400, waiver: { spend: 300000, text: 'Annual fee Rs 2,400 + GST waived on card spend of Rs 3,00,000 in the last 12 months; joining fee waived if Rs 1,00,000 is spent within 90 days of activation (KFS).' },
  pv: null, pvBasis: 'The Unicorn page and the KFS state no rupee value for one reward point (the Rs 0.25 value on the other Union cards is stated on those cards\' pages only). Left null.', expiry: null,
  block: 100, basePts: 4, baseReturn: null, cycleCeil: 10000,
  rules: [
    X('union-bank-of-india-unicorn-excluded', 'excluded_spend', [], 'No reward points on jewellery, fuel, cash withdrawal, bitcoin, wallet loading, alcohol and wine shops, insurance payments; "eligible MCCs prescribed by Bank time to time" (KFS).', { categories: ['jewellery', 'fuel', 'cash_withdrawal', 'bitcoin', 'wallet_load', 'alcohol', 'insurance'] }),
    R({ id: 'union-bank-of-india-unicorn-birthday', cat: 'other', pri: 10, ppb: null, mult: 5, cond: { wording: 'Birthday month: Earn 5X Rewards', period: 'birthday_month', multiplier_basis: 'NOT STATED: 5X of the base rate of 4 points per Rs 100 is the natural reading but the KFS does not define "5X"', per_inr_block: 100 }, reason: '5X rewards in the birthday month (KFS and card page); cap and basis not stated beyond the 10,000 points a month cap.' }),
    R({ id: 'union-bank-of-india-unicorn-monthly-milestone', cat: 'other', pri: 11, ppb: null, mult: 5, cond: { wording: 'Monthly Milestone: Earn 5X rewards on spend of Rs 20k and above', min_monthly_spend_inr: 20000, multiplier_basis: 'NOT STATED: whether 5X applies to the whole month\'s spend or only the part above Rs 20,000', per_inr_block: 100 }, reason: '5X rewards on monthly spend of Rs 20,000 and above (KFS).' }),
    R({ id: 'union-bank-of-india-unicorn-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 4, mult: 1, cond: { per_inr_block: 100 }, reason: '4 reward points on each Rs 100 spent, subject to eligible MCCs (KFS note).' }),
  ],
  caps: [C({ id: 'union-bank-of-india-unicorn-monthly-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'calendar_month', points: 10000, after: 'no_further_accrual' })],
  addon: null, addonFee: 2400, pooled: null,
  welcome: { trigger: 'spend_within_30_days_of_activation', benefit_points: 4000, effective_value_inr: null, condition: 'Spend at least Rs 10,000 within 30 days of activation and earn an additional 4,000 reward points (KFS and page).' },
  milestones: [1, 2, 3, 4, 5].map((n) => ubMilestone(`union-bank-of-india-unicorn-m${n}`, `2,000 additional reward points on annual spend of Rs ${n} lakh (KFS; milestone points capped at 10,000)`, n * 100000, 2000, null)),
  benefits: [
    B({ id: 'union-bank-of-india-unicorn-lounge', cat: 'lounge', program: 'priority_pass', sponsor: 'NPCI / Union Bank of India', label: 'Domestic and international airport lounge access via Priority Pass, plus RuPay exclusive domestic lounge access', cond: { domestic_per_year: 8, international_per_year: 2 }, qty: 10, per: 'annual' }),
    B({ id: 'union-bank-of-india-unicorn-accident', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Personal accident insurance and permanent disability cover Rs 10 lakh' }),
  ],
  promos: [
    P({ id: 'union-bank-of-india-unicorn-bms', cat: 'entertainment', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', max: 250, quota: true }),
    P({ id: 'union-bank-of-india-unicorn-mmt', cat: 'travel', sponsor: 'MakeMyTrip', platform: 'MakeMyTrip', type: 'instant_discount', pct: 10, max: 1500, quota: true }),
  ],
  sources: ubSources(UBP('union-unicorn-credit-card'), 'Unicorn card page: NPCI offering table, rewards structure ("proposed as follows")'),
  unverified: ubCommonUnverified([
    'QUESTION: what is one Unicorn reward point worth in rupees? Neither the Unicorn page nor the KFS states it, so point value and effective return are null.',
    'The card page labels the reward structure "proposed as follows"; the KFS (April 2026) states the same structure without that wording. The KFS is followed.',
    'Birthday-month 5X and monthly-milestone 5X: the base the multiplier applies to (all spend, or only spend above Rs 20,000) is not stated; modelled with a multiplier but no points per block.',
    'Lounge: the page says "8 Domestic and 2 International lounge access per annum via Priority Pass" next to "RuPay exclusive domestic lounge airport access"; whether the RuPay lounges are on top of the 8 is not stated. Counts recorded as printed.',
    'Partner benefits on the page (3 months Swiggy One, MakeMyTrip 10% up to Rs 1,500 annually, Aromas spa per quarter, Myntra Rs 250, Big Basket Rs 250, Nykaa Rs 500 per quarter, BookMyShow Rs 250 per month, 12 months OTT subscription) have no period/quota detail beyond what is on the page.',
    'Monthly cap: 10,000 points per customer ID per month excluding milestone points (KFS); the cap behaviour after the limit is not stated, no further accrual assumed.',
  ]),
});

cards['union-bank-of-india-nexteria'] = make('union-bank-of-india-nexteria', {
  ...ubFees(40), name: 'Union Bank of India NEXTERIA Credit Card (RuPay Ekaa, metal)', page: UBP('nexteria-credit-card'), network: 'rupay', tier: 'N/A', upi: null,
  joining: 12499, annual: 12499, waiver: { spend: 800000, text: 'Annual fee Rs 12,499 + GST waived on spend of Rs 8,00,000 in the previous year; joining fee waived if Rs 3,00,000 is spent within 90 days of activation (KFS and page).' },
  pv: null, pvBasis: 'No Union Bank page or document read states a rupee value for one NEXTERIA reward point. Left null.', expiry: null,
  block: 125, basePts: 5, baseReturn: null, cycleCeil: 10000,
  eligibility: 'Minimum gross income Rs 25 lakh a year; also available against a term deposit of at least Rs 10 lakh. Base limit Rs 2 lakh. Age 21-65 (term-deposit card from 18); CIBIL 700 and above, not applicable to a deposit-backed card (card page).',
  rules: [
    X('union-bank-of-india-nexteria-excluded', 'excluded_spend', [], 'No reward points on jewellery, fuel, cash withdrawal, bitcoin, wallet loading, alcohol and wine shops, insurance payments; "eligible MCCs prescribed by Bank time to time" (KFS).', { categories: ['jewellery', 'fuel', 'cash_withdrawal', 'bitcoin', 'wallet_load', 'alcohol', 'insurance'] }),
    R({ id: 'union-bank-of-india-nexteria-birthday', cat: 'online', pri: 10, ppb: null, mult: 10, cap: 'union-bank-of-india-nexteria-birthday-cap', cond: { wording: 'Birthday Month: Earn 10X Reward points on online shopping/electronics spends', period: 'birthday_month', multiplier_basis: 'NOT STATED: 10X of the base rate (5 points per Rs 125) is the natural reading but is not defined', per_inr_block: 125 }, reason: '10X reward points on online shopping and electronics in the birthday month, up to 10,000 points (KFS and page).' }),
    R({ id: 'union-bank-of-india-nexteria-monthly-milestone', cat: 'other', pri: 11, ppb: null, mult: 5, cond: { wording: 'Monthly Milestone: Earn 5X rewards on spend of Rs 2,00,000 and above', min_monthly_spend_inr: 200000, multiplier_basis: 'NOT STATED: whether 5X applies to the whole month or only the part above Rs 2,00,000', per_inr_block: 125 }, reason: '5X rewards on monthly spend of Rs 2,00,000 and above, up to 10,000 points (KFS).' }),
    R({ id: 'union-bank-of-india-nexteria-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 5, mult: 1, cond: { per_inr_block: 125 }, reason: '5 reward points on each Rs 125 spent, subject to eligible MCCs (KFS note).' }),
  ],
  caps: [
    C({ id: 'union-bank-of-india-nexteria-monthly-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'calendar_month', points: 10000, after: 'no_further_accrual' }),
    C({ id: 'union-bank-of-india-nexteria-birthday-cap', cat: 'online', metric: 'bonus_reward_points', period: 'calendar_month', points: 10000, after: 'downgrade_to_base_rate', afterPpb: 5 }),
  ],
  addon: null, addonFee: 12499, pooled: null,
  milestones: [
    ubMilestone('union-bank-of-india-nexteria-m1', '10,000 additional reward points on annual spend of Rs 10 lakh (KFS)', 1000000, 10000, null),
    ubMilestone('union-bank-of-india-nexteria-m2', '15,000 additional reward points on annual spend of Rs 12 lakh and above (KFS; milestone points capped at 15,000 a year)', 1200000, 15000, null),
  ],
  benefits: [
    B({ id: 'union-bank-of-india-nexteria-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / Union Bank of India', label: 'Unlimited domestic and international lounge visits for the cardholder; two family visits per quarter (1+3)', cond: { cardholder_visits: 'unlimited', family_visits_per_quarter: 2 }, qty: null, per: 'quarter' }),
    B({ id: 'union-bank-of-india-nexteria-hotel', cat: 'other', sponsor: 'ITC / Hotel Luxe', label: '2+1 complimentary nights at ITC premium hotels, 1+1 set-menu dining, 1+1 spa; Hotel Luxe Elite Plus membership', cond: {} }),
    B({ id: 'union-bank-of-india-nexteria-golf', cat: 'golf', sponsor: 'NPCI', label: '4 domestic complimentary golf lessons or rounds a year', qty: 4, per: 'annual' }),
    B({ id: 'union-bank-of-india-nexteria-insurance', cat: 'insurance_related_perk', sponsor: 'Union Bank of India', label: 'Personal accident Rs 50 lakh, air accident Rs 1 crore, purchase protection Rs 2 lakh, baggage loss Rs 20,000, cyber insurance Rs 2 lakh' }),
  ],
  promos: [P({ id: 'union-bank-of-india-nexteria-bms', cat: 'entertainment', sponsor: 'Union Bank of India', platform: 'movie tickets', type: 'instant_discount', max: 500, quota: true })],
  sources: ubSources(UBP('nexteria-credit-card'), 'NEXTERIA card page: benefits, rewards structure, eligibility'),
  unverified: ubCommonUnverified([
    'QUESTION: what is one NEXTERIA reward point worth in rupees? Not stated, so point value is null.',
    'Network: the page says the card is built on the "Ekaa" variant of the RuPay network; RuPay recorded, RuPay tier left N/A.',
    'Birthday-month and monthly-milestone 5X/10X: multiplier basis and the period for the 10,000-point birthday-month cap are not stated (calendar month assumed for the cap period).',
    'Lounge: "unlimited visit for individuals" and "two family visits per quarter, 1+3" as printed; quota count is null because the family quantity is not stated as a single number.',
    'Page items marked "Proposed RuPay Exclusive Benefits (may change from time to time)" (movie screening, concerts, dining with District, RuPay lounge) are not modelled.',
    'Movie ticket: buy 1 get 1 up to Rs 500 once a month (page); platform not named.',
  ]),
});

// ===================================== INDIAN BANK =====================================
const ibPlatinum = (slug, name, network, tier, evidence, lounge) => make(slug, {
  ...ibBase, aprM: 1.66, name, network, tier, annual: 250,
  waiver: { spend: 50000, text: 'AMC Rs 250 from the 2nd year (1st year free); waived if the previous year\'s transaction usage exceeds Rs 50,000 (MITC and listing page footnote).' },
  pv: 1, pvBasis: 'Dec 2023 features sheet: "1 point valued at Re.1 for every Rs.100 spent"; Jan 2025 poster states the same Rs 1 per Rs 100 as cashback credited in the same billing month. Treated as 1% value; see open question.', expiry: null,
  block: 100, basePts: 'N/A', baseCb: 1, baseReturn: 1,
  rules: [
    X(`${slug}-no-reward`, 'excluded_spend', [], 'No cashback on wallet load, EMI transactions, ATM withdrawals and UPI transactions below Rs 2,000 (poster, Jan 2025).', { categories: ['wallet_load', 'emi', 'cash_withdrawal', 'upi_below_2000'] }),
    R({ id: `${slug}-low-rate`, cat: 'bills', pri: 10, cb: 0.5, mult: 0.5, cond: { categories: ['rent', 'utilities', 'fuel', 'insurance', 'jewellery', 'government'], per_inr_block: 100 }, reason: 'Rs 0.50 cashback per Rs 100 (0.5%) on rent, utilities, fuel, insurance, jewellery and government spends (poster, Jan 2025).' }),
    R({ id: `${slug}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: 'Rs 1 cashback (1 point of Re 1) per Rs 100 spent, credited in the same billing month (poster, Jan 2025; features sheet Dec 2023).' }),
  ],
  caps: [], addon: 4, addonFee: 0, pooled: null,
  benefits: [...(lounge ? [B({ id: `${slug}-lounge`, cat: 'lounge', sponsor: 'Indian Bank', label: 'Airport lounge access (features sheet: "Yes"; no quota stated)' })] : []), B({ id: `${slug}-accident`, cat: 'insurance_related_perk', sponsor: 'Indian Bank', label: network === 'visa' ? 'Free insurance cover for Visa Platinum: death by air accident Rs 5 lakh, other accident Rs 2 lakh, hospitalisation, baggage and purchase protection per MITC table' : 'Personal accident and permanent disability cover up to Rs 2 lakh (MITC table, RuPay Platinum)' })],
  sources: [...ibSources(), ...(evidence ? [evidence] : [])],
  unverified: ibUnverified([lounge ? 'Lounge: the features sheet says "Airport Lounge Access: Yes" with no number of visits or lounge list; no quota recorded.' : 'No lounge line for this variant in the features sheet.']),
});
cards['indian-bank-visa-platinum'] = ibPlatinum('indian-bank-visa-platinum', 'Indian Bank IB-VISA-Platinum Credit Card', 'visa', 'visa_platinum', src('MITC names "VISA Platinum" with its own purchase interest rate, insurance column and daily limits; the poster shows a Visa Platinum card face', IB_MITC, 'PDF created 2026-09-27', 'pdftotext and image'), false);
cards['indian-bank-rupay-platinum'] = ibPlatinum('indian-bank-rupay-platinum', 'Indian Bank IB-RuPay-Platinum Credit Card', 'rupay', 'rupay_platinum', src('Poster shows an Indian Bank RuPay Platinum card face with the RuPay mark; MITC names "RuPay Platinum"', IB_POSTER, 'PDF created 2025-01-24', 'image'), true);
cards['indian-bank-rupay-select'] = make('indian-bank-rupay-select', {
  ...ibBase, aprM: 1.66, name: 'Indian Bank IB-RuPay-Select Credit Card', network: 'rupay', tier: 'rupay_select', annual: 250,
  waiver: { spend: 50000, text: 'AMC Rs 250 from the 2nd year (1st year free); waived if the previous year\'s transaction usage exceeds Rs 50,000 (MITC and listing page footnote).' },
  pv: 1, pvBasis: 'Dec 2023 features sheet: "1 point valued at Re.1 for every Rs.100 spent" for RuPay Select; the Jan 2025 poster states Rs 1 cashback per Rs 100 for the IB credit card generally. Treated as 1% value; see open question.', expiry: null,
  block: 100, basePts: 'N/A', baseCb: 1, baseReturn: 1,
  rules: [
    X('indian-bank-rupay-select-no-reward', 'excluded_spend', [], 'No cashback on wallet load, EMI transactions, ATM withdrawals and UPI transactions below Rs 2,000 (poster, Jan 2025).', { categories: ['wallet_load', 'emi', 'cash_withdrawal', 'upi_below_2000'] }),
    R({ id: 'indian-bank-rupay-select-low-rate', cat: 'bills', pri: 10, cb: 0.5, mult: 0.5, cond: { categories: ['rent', 'utilities', 'fuel', 'insurance', 'jewellery', 'government'], per_inr_block: 100 }, reason: 'Rs 0.50 cashback per Rs 100 on rent, utilities, fuel, insurance, jewellery and government spends (poster, Jan 2025).' }),
    R({ id: 'indian-bank-rupay-select-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: 'Rs 1 per Rs 100 spent (features sheet Dec 2023; poster Jan 2025).' }),
  ],
  caps: [], addon: 4, addonFee: 0, pooled: null,
  benefits: [B({ id: 'indian-bank-rupay-select-lounge', cat: 'lounge', sponsor: 'Indian Bank', label: 'Airport lounge access (features sheet: "Yes"; no quota stated)' }), B({ id: 'indian-bank-rupay-select-accident', cat: 'insurance_related_perk', sponsor: 'Indian Bank', label: 'Personal accident and permanent disability cover up to Rs 10 lakh (MITC table, RuPay Select)' })],
  sources: [...ibSources()],
  unverified: ibUnverified(['Lounge: the features sheet says "Airport Lounge Access: Yes" with no number of visits; no quota recorded.', 'Network: MITC names "RuPay Select"; the poster does not show a Select card face.']),
});
cards['indian-bank-visa-business'] = make('indian-bank-visa-business', {
  ...ibBase, aprM: 1.99, name: 'Indian Bank IB-VISA-Business Credit Card', network: 'visa', tier: 'N/A', annual: 500, mode: 'restricted',
  waiver: { spend: 200000, text: 'AMC Rs 500 from the 2nd year (1st year free); waived if previous-year usage exceeds Rs 2,00,000 (MITC and listing page footnote).' },
  pv: 1, pvBasis: 'Dec 2023 features sheet: "1 point valued at Re.1 for every Rs.200 spent" for Visa Business. No newer document restates it.', expiry: null,
  block: 200, basePts: 1, baseReturn: 0.5,
  rules: [R({ id: 'indian-bank-visa-business-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 200 }, reason: '1 point (valued at Re 1) for every Rs 200 spent (features sheet, Dec 2023).' })],
  caps: [], addon: null, addonFee: null, pooled: null,
  benefits: [],
  sources: [...ibSources()],
  unverified: ibUnverified(['Business card: reward rate comes only from the Dec 2023 features sheet; the Jan 2025 poster does not say whether it covers Business. Purchase interest 1.99% a month is from the same sheet; the 2026 MITC lists purchase rates for Gold, Classic, Bharat, Platinum and Select but not for Business. Eligibility for business or corporate entities only; no EMI facility on this card (features sheet).', 'MITC schedule columns list VISA Business with 2.25% a month cash advance interest.']),
});

// ===================================== IDBI BANK =====================================
cards['idbi-bank-royale-signature'] = make('idbi-bank-royale-signature', {
  ...idBase, aprM: 2.5, name: 'IDBI Bank Royale Signature Credit Card', page: IDP('royal-credit-card.aspx'), network: 'visa', tier: 'visa_signature', joining: 0, annual: 0,
  block: 100, basePts: 3, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 5000, cap: 500 },
  rules: [idExcl('idbi-royale'), R({ id: 'idbi-royale-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 1, cond: { per_inr_block: 100 }, reason: '3 Delight Points for every Rs 100 spent (card page); transactions in the MITC exemption list earn nothing.' })],
  caps: [], addon: 2, addonFee: 0, pooled: true,
  welcome: idWelcome(500, 750, 1500),
  milestones: [idMilestone('idbi-royale-m1', '', 200000, 1500), idMilestone('idbi-royale-m2', '', 400000, 2000)],
  benefits: [
    B({ id: 'idbi-royale-lounge', cat: 'lounge', program: 'visa', sponsor: 'Visa', label: '1 complimentary lounge visit per calendar quarter at participating airport lounges in India (provided by Visa; subject to change at Visa\'s discretion)', qty: 1, per: 'quarter' }),
    B({ id: 'idbi-royale-air-accident', cat: 'insurance_related_perk', sponsor: 'IDBI Bank', label: 'Air travel accident insurance cover Rs 25 lakh' }),
  ],
  sources: idSources(IDP('royal-credit-card.aspx'), 'Royale Signature card page: features, fees and charges, lounge, eligibility'),
  unverified: idUnverified(['Lounge: Visa lounge access and its list are on the issuer\'s PDF https://www.idbi.bank.in/pdf/VISA-Airport-Lounge-Access.pdf (not read). The page says 1 visit a quarter, the calendar basis of "per quarter" for Royale is calendar quarter per the page; the Winnings page uses 15th-of-month quarters.', 'The page fee table prints the late-fee slabs garbled ("Rs.500 to Rs.5000 to Rs.10000 to Rs.20000 - Rs.950"); the MITC slabs are used.', 'Page says "currently being offered with no joining fees"; the MITC schedule shows joining and annual nil. If the nil joining fee is a limited-time offer is not stated.']),
});
cards['idbi-bank-euphoria-world'] = make('idbi-bank-euphoria-world', {
  ...idBase, aprM: 2.9, name: 'IDBI Bank Euphoria World Credit Card', page: IDP('Euphoria-credit-card.aspx'), network: 'mastercard', tier: 'mastercard_world', joining: 0, annual: 1499,
  waiver: { spend: 150000, text: 'Annual fee Rs 1,499 from the 2nd year onwards, waived on spends of more than Rs 1,50,000 in a year (card page); MITC: waived on minimum spends of Rs 1,50,000 in the preceding year.' },
  block: 100, basePts: 3, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 5000, cap: 500 },
  rules: [
    idExcl('idbi-euphoria'),
    R({ id: 'idbi-euphoria-travel', cat: 'travel', pri: 10, ppb: 6, mult: 2, cond: { categories: ['hotels', 'airlines', 'irctc', 'bus_bookings'], per_inr_block: 100 }, reason: '6 Delight Points per Rs 100 on travel (hotels, airlines, IRCTC, bus bookings etc.) (card page).' }),
    R({ id: 'idbi-euphoria-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 1, cond: { per_inr_block: 100 }, reason: '3 Delight Points per Rs 100 on every other spend (card page).' }),
  ],
  caps: [], addon: 2, addonFee: 0, pooled: true,
  welcome: idWelcome(500, 750, 5000),
  milestones: [idMilestone('idbi-euphoria-m1', '', 200000, 1500), idMilestone('idbi-euphoria-m2', '', 400000, 2000)],
  benefits: [
    B({ id: 'idbi-euphoria-lounge', cat: 'lounge', program: 'mastercard', sponsor: 'Mastercard', label: '12 complimentary lounge visits per calendar year at participating airport lounges in India (provided by Mastercard)', qty: 12, per: 'annual' }),
    B({ id: 'idbi-euphoria-air-accident', cat: 'insurance_related_perk', sponsor: 'IDBI Bank', label: 'Air travel accident insurance cover Rs 25 lakh' }),
  ],
  sources: idSources(IDP('Euphoria-credit-card.aspx'), 'Euphoria World card page: features, fees and charges, lounge, eligibility'),
  unverified: idUnverified(['"2X Delight points on travel" in the banner versus 6 versus 3 points per Rs 100 in the body: the body values are used (6 is exactly twice 3).', 'Travel accelerator: the page names hotels, airlines, IRCTC and bus bookings "etc."; the MCC list that qualifies is not stated. No cap on the 6-point rate is stated.']),
});
cards['idbi-bank-aspire-platinum'] = make('idbi-bank-aspire-platinum', {
  ...idBase, aprM: 2.9, name: 'IDBI Bank Aspire Platinum Credit Card', page: IDP('aspire-credit-card.aspx'), network: 'visa', tier: 'visa_platinum', joining: 0, annual: 0,
  block: 150, basePts: 2, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 4000, cap: 300 },
  rules: [idExcl('idbi-aspire'), R({ id: 'idbi-aspire-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 150 }, reason: '2 Delight Points for every Rs 150 spent (card page).' })],
  caps: [], addon: null, addonFee: null, pooled: true,
  welcome: idWelcome(500, 500, 1500),
  milestones: [idMilestone('idbi-aspire-m1', '', 100000, 1000), idMilestone('idbi-aspire-m2', '', 200000, 1500)],
  benefits: [],
  sources: idSources(IDP('aspire-credit-card.aspx'), 'Aspire Platinum card page: features, fees and charges'),
  unverified: idUnverified(['No lounge access is listed on the page. Number of add-on cards is not stated on the page for this card.']),
});
cards['idbi-bank-imperium-platinum'] = make('idbi-bank-imperium-platinum', {
  ...idBase, aprM: 2.9, name: 'IDBI Bank Imperium Platinum Credit Card (secured against FD)', page: IDP('Imperium-credit-card.aspx'), network: 'visa', tier: 'visa_platinum', mode: 'secured', joining: 0, annual: 499,
  waiver: { spend: 75000, text: 'Annual fee Rs 499, waived on spends of more than Rs 75,000 in a year (card page and MITC schedule).' },
  eligibility: 'Secured card against the cardholder\'s own fixed deposit(s): credit limit up to 85% of the FD, cash withdrawal limit up to 70% of the credit limit (card page).',
  block: 150, basePts: 2, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 4000, cap: 400 },
  rules: [idExcl('idbi-imperium'), R({ id: 'idbi-imperium-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 150 }, reason: '2 Delight Points for every Rs 150 spent (card page).' })],
  caps: [], addon: null, addonFee: null, pooled: true,
  welcome: idWelcome(500, 500, 1500),
  milestones: [idMilestone('idbi-imperium-m1', '', 100000, 1000), idMilestone('idbi-imperium-m2', '', 200000, 1500)],
  benefits: [],
  sources: idSources(IDP('Imperium-credit-card.aspx'), 'Imperium Platinum card page: secured card against FD, features, fees and charges'),
  unverified: idUnverified(['Joining fee conflict: the card page says joining fee Rs 499 and annual Rs 499; the MITC schedule says joining nil, annual Rs 499 (waived on Rs 75,000 spend) and closure charge Rs 999 within one year. The MITC (newer file) is used: joining 0.', 'Fuel waiver: the page text names the "Aspire Platinum Card" and says up to Rs 300 a month (copied wording); the MITC schedule says Rs 400 a month for Imperium. The MITC value is used.', 'Assignment note said "Visa" from the FAQ: the FAQ lists "Imperium Platinum Card (Visa)" and the page says "issued on the VISA platform".']),
});
cards['idbi-bank-winnings-select'] = make('idbi-bank-winnings-select', {
  ...idBase, aprM: 3.4, name: 'IDBI Bank Winnings Select Credit Card (RuPay)', page: IDP('Winnings-credit-card.aspx'), network: 'rupay', tier: 'rupay_select', joining: 0, annual: 899,
  waiver: { spend: 90000, text: 'Annual fee Rs 899 from the 2nd year, waived on spends of more than Rs 90,000 in a year (card page); MITC: minimum Rs 90,000 in the preceding year.' },
  block: 100, basePts: 2, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 4000, cap: 400 },
  rules: [
    idExcl('idbi-winnings'),
    R({ id: 'idbi-winnings-utility-cashback', cat: 'bills', pri: 8, cb: 10, mult: 1, cap: 'idbi-winnings-utility-cap', cond: { mcc_list: [4814, 4816, 4899, 4900], per_inr_block: 100 }, reason: '10% cashback on utility bill payments (MCC 4814, 4816, 4899, 4900), up to Rs 100 a month (MITC section 13, Winnings row).' }),
    R({ id: 'idbi-winnings-dining-cashback', cat: 'dining', pri: 9, cb: 5, mult: 1, cap: 'idbi-winnings-dining-cap', cond: { mcc_list: [5814, 5812], per_inr_block: 100 }, reason: '5% cashback on dining (MCC 5814, 5812), up to Rs 50 a month (MITC section 13, Winnings row).' }),
    R({ id: 'idbi-winnings-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 Delight Points for every Rs 100 spent (card page).' }),
  ],
  caps: [
    C({ id: 'idbi-winnings-utility-cap', cat: 'bills', metric: 'eligible_spend_amount', period: 'calendar_month', inr: 100, after: 'downgrade_to_base_rate', afterPpb: 2 }),
    C({ id: 'idbi-winnings-dining-cap', cat: 'dining', metric: 'eligible_spend_amount', period: 'calendar_month', inr: 50, after: 'downgrade_to_base_rate', afterPpb: 2 }),
  ],
  addon: 2, addonFee: 0, pooled: true,
  welcome: idWelcome(500, 500, 1000),
  milestones: [idMilestone('idbi-winnings-m1', '', 100000, 1000), idMilestone('idbi-winnings-m2', '', 200000, 1500)],
  benefits: [
    B({ id: 'idbi-winnings-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / RuPay', label: '2 complimentary lounge visits per quarter in India and 2 per half year outside India (RuPay; quarters run from the 15th: Jan 15-Apr 15, Apr 15-Jul 15, Jul 15-Oct 15, Oct 15-Jan 15)', cond: { domestic_per_quarter: 2, international_per_half_year: 2 }, qty: 2, per: 'quarter' }),
    B({ id: 'idbi-winnings-accident', cat: 'insurance_related_perk', sponsor: 'IDBI Bank', label: 'Personal accident cover: accidental death Rs 10 lakh and permanent disability Rs 10 lakh (age 18-70; one successful transaction in the last 90 days)' }),
  ],
  sources: idSources(IDP('Winnings-credit-card.aspx'), 'Winnings card page: features, lounge, fees and charges'),
  unverified: idUnverified(['Cashback conflict: the MITC (Oct 2026) section 13 lists 10% utility cashback (Rs 100 a month) and 5% dining cashback (Rs 50 a month) for "Winnings"; the Winnings card page (undated) does not mention any cashback. The MITC is followed; a person should confirm the cashback is live for the Winnings Select card.', 'Whether the cashback replaces or adds to the 2 Delight Points on those transactions is not stated. The MITC also lists an Apex variant with higher caps; not part of this assignment.', 'The MITC says "Opulence, Apex & SmartPay variants will be launched shortly"; none is in this assignment.']),
});
cards['idbi-bank-lic-csl-lumine-platinum'] = make('idbi-bank-lic-csl-lumine-platinum', {
  ...idBase, aprM: 3.4, name: 'IDBI Bank LIC CSL Lumine Platinum Credit Card', page: IDP('Lumine-credit-card.aspx'), network: 'rupay', tier: 'rupay_platinum', joining: 0, annual: 0,
  block: 100, basePts: 3, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 4000, cap: 300 }, redeemFee: 99,
  rules: [idExcl('idbi-lumine'), R({ id: 'idbi-lumine-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 3, mult: 1, cond: { per_inr_block: 100 }, reason: '3 Delight Points for every Rs 100 spent (card page; the page sentence says "your Eclat Credit Card", a copy error read as this card).' })],
  caps: [], addon: 1, addonFee: 0, pooled: true,
  welcome: idWelcome(500, 500, 2000),
  milestones: [idMilestone('idbi-lumine-m1', '', 100000, 1000), idMilestone('idbi-lumine-m2', '', 200000, 1500)],
  benefits: [B({ id: 'idbi-lumine-accident', cat: 'insurance_related_perk', sponsor: 'IDBI Bank', label: 'Personal accidental death insurance cover Rs 2 lakh and credit shield cover' })],
  sources: idSources(IDP('Lumine-credit-card.aspx'), 'Lumine Platinum card page', [src('Card art image on the issuer\'s LIC co-brand page, read visually: shows the RuPay mark and "PLATINUM"', IDP('images/Lumine-Credit-Card.png'), null, 'image read visually'), src('LIC co-branded credit cards page: apply via phone banking or an LIC branch', IDP('lic-co-branded-credit-cards.aspx'), null, 'plain page fetch')]),
  unverified: idUnverified(['Network: no IDBI text states the network for Lumine (the FAQ variant list omits the LIC cards). Card art on idbi.bank.in shows the RuPay mark with "PLATINUM"; recorded as RuPay on that evidence.', 'Redemption fee conflict: the page says Rs 99 per redemption; the MITC says Rs 20 per occasion for cash-back redemption of 1,000-4,000 points. The page value is recorded here, MITC value on the other IDBI cards.', 'Page wording copies "Eclat" in several places (rewards sentence, fuel line, merchant counts); read as this card.', 'Add-on cards: page says up to 1.']),
});
cards['idbi-bank-lic-csl-eclat-select'] = make('idbi-bank-lic-csl-eclat-select', {
  ...idBase, aprM: 3.4, name: 'IDBI Bank LIC CSL Eclat Select Credit Card', page: IDP('Eclat-credit-card.aspx'), network: 'rupay', tier: 'rupay_select', joining: 0, annual: 0,
  block: 100, basePts: 4, baseReturn: null, fuel: { surcharge: 1, waiver: 1, min: 400, max: 5000, cap: 500 },
  rules: [idExcl('idbi-eclat'), R({ id: 'idbi-eclat-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 4, mult: 1, cond: { per_inr_block: 100 }, reason: '4 Delight Points for every Rs 100 spent (card page).' })],
  caps: [], addon: 2, addonFee: 0, pooled: true,
  welcome: idWelcome(500, 1000, 5000),
  milestones: [idMilestone('idbi-eclat-m1', '', 200000, 1500), idMilestone('idbi-eclat-m2', '', 400000, 2000)],
  benefits: [
    B({ id: 'idbi-eclat-lounge', cat: 'lounge', program: 'rupay', sponsor: 'NPCI / RuPay', label: 'Airport lounge access provided by RuPay (number of visits not stated; quarters run from the 15th of the month)' }),
    B({ id: 'idbi-eclat-insurance', cat: 'insurance_related_perk', sponsor: 'IDBI Bank', label: 'Air travel accident cover Rs 25 lakh, personal accidental death cover Rs 5 lakh, credit shield (outstanding dues on death); accidental death and permanent disability Rs 10 lakh (age 18-70)' }),
  ],
  sources: idSources(IDP('Eclat-credit-card.aspx'), 'Eclat Select card page', [src('Card art image on the issuer\'s LIC co-brand page, read visually: shows the RuPay mark and "SELECT"', IDP('images/Eclat-Credit-Card.png'), null, 'image read visually')]),
  unverified: idUnverified(['Network: no IDBI text states the network for Eclat; the lounge paragraph says it is provided by RuPay and the card art shows the RuPay mark with "SELECT". Recorded as RuPay.', 'Lounge: the page names RuPay as provider and gives a quarter note but no number of visits; no quota recorded.', 'The IDBI navigation spells the card "Elat"; the page and the MITC schedule say "Eclat".', 'Insurance wording conflicts within the page (Rs 5 lakh personal accidental death versus Rs 10 lakh accidental death and permanent disability); both recorded as printed.']),
});
