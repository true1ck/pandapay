// SBM Bank India FD-backed (secured) co-branded cards. Sources read 2026-11-07.
//  PAGE = SBM secured credit card page: lists every variant with its KFS, MITC and reward links; card images show the network.
//  TNC  = SBM Secured Credit Card MITC and Cardholder Member Agreement (52 pages, SBM file dated 29 Oct 2026, pdftotext).
//         Its Tables 01-11 give joining/annual fee, ATM fee, interest, late fee, forex, surcharge, rent and education fees,
//         cash limits and minimum due for each of the eight variants. The per-card MITC links on the page all redirect to it.
//  Each card's own KFS (file dates 12 Oct 2026 unless noted) and reward document are listed in its provenance.
// Not drafted here: OneCard SBM (edited in oct.mjs) and Paisabazaar Paisa Plus (edited in secured.mjs).
import { R, X, C, prov, dualNetwork, GST } from '../lib.mjs';

const PAGE = 'https://www.sbm.bank.in/personal-banking/cards/secured-credit-card';
const TNC = 'https://www.sbm.bank.in/pdf/terms-conditions/SBM-Secured-Credit-Card-T&C.pdf';
const KFS = (f) => `https://www.sbm.bank.in/pdf/kfs/${f}`;
const NB = (f) => `https://www.sbm.bank.in/pdf/notice-board/${f}`;
const ART = (f) => `https://www.sbm.bank.in/images/cards/${f}`;

const tncSource = { url: TNC, kind: 'SBM Secured Credit Card MITC and Cardholder Member Agreement, 52 pages (SBM file dated 29 Oct 2026): Tables 01-11 give fees, interest, late fee, forex, surcharge, rent and education fees, cash limits and minimum due for every variant', read: 'pdftotext' };
const pageSource = (art) => ({ url: PAGE, kind: `SBM secured credit card page (read 7 Nov 2026): lists the card with its KFS, MITC and reward links; card image ${ART(art)} shows the network`, read: 'page text; card image viewed' });

// Category-level exclusions follow the importer's tokens. Rows whose MCCs are only a slice of a PandaPay category use
// excluded_spend, which the importer keeps for review instead of zeroing a whole category.
const exclRows = (prefix, label, rows) => rows.map(([k, cat, mccs, what, extra]) => X(`${prefix}-excl-${k}`, cat, mccs, `${what} earn nothing (${label}).`, extra || {}));

// novio (RuPay variant) and Niyo reward T&Cs carry the same excluded-MCC table.
const credilioRows = [
  ['cash', 'cash_withdrawal', [6010, 6011, 6012], 'Financial institutions and manual cash disbursements'],
  ['quasi-cash', 'excluded_spend', [6051], 'Foreign currency, money orders and travellers cheques'],
  ['rent', 'rent', [6513, 7349], 'Real estate agents and managers, rentals and property management'],
  ['wallet', 'wallet_load', [6540, 6541], 'Stored-value card purchase and load, wallets'],
  ['gambling', 'excluded_spend', [7800, 7801, 7995], 'Government lotteries, online casinos and betting'],
  ['political', 'excluded_spend', [8651], 'Political organisations'],
  ['securities', 'excluded_spend', [6211], 'Security brokers and dealers'],
  ['fuel-dealers', 'excluded_spend', [5172, 5983], 'Fuel dealers and distributors (petrol pumps, MCC 5541 and 5542, are not in this list)'],
  ['education', 'education', [8220, 8241, 8244, 8249, 8299, 8351], 'Educational institutions'],
  ['legal-accounting', 'excluded_spend', [8111, 8931], 'Legal and accounting services'],
  ['utility', 'utility', [4900, 4812, 4814, 4816, 4899], 'Utilities and telecom'],
  ['insurance', 'insurance', [5960, 6300, 6381], 'Insurance'],
  ['novelty', 'excluded_spend', [5947], 'Card, gift, novelty and souvenir shops'],
  ['railways', 'excluded_spend', [4011, 4112], 'Railways'],
  ['agri', 'excluded_spend', [763, 820, 821, 822, 823, 824, 825, 742, 743, 744, 780], 'Agricultural services, cooperatives, horticulture, landscaping and veterinary services'],
  ['government', 'government', [9211, 9222, 9223, 9311, 9399, 9400, 9402, 9405], 'Tax payments, court costs, postal services, fines and government services'],
];

// Kredit.Pe reward construct uses the same excluded-MCC table as the Paisabazaar Paisa Plus SOP, with a few differences.
const kreditRows = [
  ['rent', 'rent', [6513, 7349], 'Rentals and property management'],
  ['cash', 'cash_withdrawal', [6010, 6011, 6051], 'Cash withdrawal at merchants and ATMs and quasi-cash'],
  ['wire', 'excluded_spend', [4829], 'Wire transfers and money orders'],
  ['finance', 'excluded_spend', [6012, 7322, 6211], 'Financial institutions, debt collection and securities brokers'],
  ['wallet', 'wallet_load', [6540], 'Debit card to wallet credit'],
  ['education', 'education', [8211, 8220, 8241, 8244, 8249, 8299], 'Education'],
  ['insurance', 'insurance', [5960, 6300, 6381], 'Insurance'],
  ['govt', 'government', [9211, 9222, 9311, 9399, 9402, 9405], 'Government services, court costs, fines, tax and postal services'],
  ['gambling', 'excluded_spend', [7800, 7802, 7995], 'Government lotteries, racing and gambling'],
  ['agri', 'excluded_spend', [763, 780, 820, 821, 822, 823, 824, 825, 5261], 'Agriculture, horticulture and lawn and garden supply'],
  ['utilities', 'utility', [4900], 'Utilities'],
  ['contractors', 'excluded_spend', [1520, 1711, 1731, 1740, 1750, 1761, 1771, 1799], 'Contractor services'],
  ['toll', 'excluded_spend', [4784], 'Toll and bridge fees'],
  ['advertising', 'excluded_spend', [7311], 'Advertising services'],
  ['commuter-rail', 'excluded_spend', [4111], 'Local commuter rail, ferries and local water transport above ₹2,000', { transaction_amount_gt_inr: 2000 }],
  ['passenger-rail', 'excluded_spend', [4112], 'Passenger railways above ₹10,000', { transaction_amount_gt_inr: 10000 }],
];

const rentEdu = (rent, edu, rentFrom = '2026-07-15') => [
  ...(rent ? [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% processing fee on rental payments (MCC 6513), over and above any merchant convenience fee (MITC Table 07; page FAQ 8)', threshold_spend_inr: null, effective_from: rentFrom, effective_to: null }] : []),
  ...(edu ? [{ category_id: 'education', mcc_list: [8211, 8220, 8241, 8244, 8249, 8299], fee_percent: 1, gst_applicable: true, trigger_condition: '1% processing fee on education payments (MCCs 8211, 8220, 8241, 8244, 8249, 8299), over and above any merchant convenience fee (MITC Table 07; page FAQ 8)', threshold_spend_inr: null, effective_from: '2026-07-15', effective_to: null }] : []),
];

const make = (o) => ({
  card_product: {
    ...GST, name: o.name, issuer_slug: 'sbm-bank-india', network: o.network ?? null, network_tier: o.tier ?? 'N/A', card_tier: 'N/A', card_type: 'credit',
    joining_fee_inr: o.joining ?? 0, annual_fee_inr: o.annual ?? 0, is_upi_linkable: o.upi ?? null, application_mode: 'open', form_factors: o.forms ?? [],
    data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: PAGE, status: 'draft', verified_at: null,
    point_value_inr_baseline: o.pv !== undefined ? o.pv : 'N/A', point_value_baseline_basis: o.pvBasis !== undefined ? o.pvBasis : 'N/A', point_expiry_months: o.expiry !== undefined ? o.expiry : 'N/A',
  },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.elig ?? 'FD-backed secured card: the credit limit is 90% of the fixed deposit (KFS). The minimum deposit is not stated in the SBM documents read.', rules: o.eligRules ?? [], required_documents: [] },
  accrual_engine: o.accrual,
  reward_rules: o.rules ?? [],
  cap_rules: o.caps ?? [],
  fees_and_surcharges: {
    apr: { monthly_interest_rate_percent: o.apr[0], annual_interest_rate_percent: o.apr[1] },
    forex_markup: { markup_percent: o.forex, gst_applicable: true },
    fuel_surcharge: { category_id: 'fuel', surcharge_percent: o.fuel, waiver_percent: o.fuel === 0 ? 'N/A' : null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    cash_advance: { atm_transaction_fee_percent: o.cash[0], atm_transaction_fee_min_inr: o.cash[1], interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: o.cash[2] },
    category_surcharges: o.surcharges ?? [],
    ...(o.emi ? { emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 99, foreclosure_charge_percent: 3, gst_applicable: true } } : {}),
    ...(o.over !== undefined ? { banking_penalties: { overlimit_charge: o.over, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null } } : {}),
    ...(o.redeemFee !== undefined ? { reward_redemption_fee: { fee_inr: o.redeemFee, gst_applicable: null } } : {}),
  },
  statement_and_late_fees: {
    grace_period_days: 45, grace_period_void_on_revolving_balance: true,
    minimum_amount_due_mad: { calculation_mode: o.madMode ?? 'fixed_percent', components: o.mad },
    late_payment_slabs: o.lateSlabs,
  },
  fee_waiver_and_milestones: {
    annual_fee_waiver: o.waiver,
    welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
    spend_milestones: [],
  },
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 'N/A', separate_priority_pass: 'N/A', lounge_quota_shared: 'N/A', reward_points_pooled: 'N/A', min_age_years: null },
  lifestyle_and_network_benefits: [],
  ...(o.redemption ? { redemption_matrix: o.redemption } : {}),
  additional_data: { items: [
    ...(o.network2 ? [o.network2] : []),
    ...prov({ sources: o.sources, unverified: o.unverified, notes: o.notes }),
    { key: 'late_payment_fee_rule', value: { rule: o.lateRule, source: o.lateSource } },
  ] },
});

const noFee = (text) => ({ threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: text, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' });
const nilSlab = (fee) => [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: fee }];

export const cards = {
  // ───────────────────────────────────────────── SBM MobiKwik First (issuer SBM Bank India; a different product from the Suryoday MobiKwik First card)
  'sbm-mobikwik-first': make({
    name: 'SBM MobiKwik First Credit Card', network: 'rupay', upi: true,
    pv: 'N/A', pvBasis: 'Cashback card: cashback is credited to the MobiKwik Wallet in rupees and "can be encashed or transferred to the bank account" (rewards T&C).', expiry: 'N/A',
    accrual: { base_block_inr: 'N/A', rounding_mode: 'round', base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [
      X('sbm-mbk-excl-dating-gambling', 'excluded_spend', [7273, 7995], 'Dating and escort services and gambling earn no cashback (rewards T&C excluded-MCC table).'),
      X('sbm-mbk-excl-govt-tax', 'government', [9399, 9311], 'Government services and tax payments earn no cashback (rewards T&C).'),
      X('sbm-mbk-excl-funding-5406', 'excluded_spend', [5406], '"Funding transaction" (MCC 5406 in the cashback list) earns no cashback.'),
      X('sbm-mbk-excl-funding-6540', 'wallet_load', [6540], '"Funding transaction" (MCC 6540 in the shared excluded table, section 4) earns no cashback.'),
      X('sbm-mbk-excl-financial', 'excluded_spend', [6012], 'Financial institutions (merchandise and services) earn no cashback.'),
      X('sbm-mbk-excl-rent', 'rent', [6513], 'Real estate agents and rentals earn no cashback.'),
      X('sbm-mbk-excl-emi', 'emi', [], 'Transactions converted to EMI earn no cashback, even if the EMI is later foreclosed or cancelled (rewards T&C).'),
      X('sbm-mbk-excl-other-upi-apps', 'upi', [], 'UPI transactions with the card registered on any app other than MobiKwik (Paytm, Google Pay, PhonePe and others) earn nothing (rewards T&C: "NIL").', { rail: 'credit_card_on_upi', platform: 'any UPI app other than MobiKwik' }),
      R({ id: 'sbm-mbk-upi-mobikwik-1pct', cat: 'upi', rail: 'credit_card_on_upi', channel: 'mobikwik_app', pri: 10, cb: 1, mult: 1, cond: { platform: 'MobiKwik app (@ikwik handle)', minimum_transaction_inr: 2000 }, from: '2026-02-01', reason: '1% cashback on UPI transactions made through the MobiKwik app with the card, minimum transaction value ₹2,000 (rewards T&C, programme effective 1 Feb 2026).' }),
      R({ id: 'sbm-mbk-online-pos-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { includes: ['online e-commerce merchants', 'offline POS merchants'], minimum_transaction_inr: 0 }, from: '2026-02-01', reason: '1% cashback on online e-commerce and offline POS merchants, no minimum transaction value; rounded to the nearest rupee per transaction (rewards T&C, effective 1 Feb 2026).' }),
    ],
    caps: [],
    apr: [3.5, 42], forex: 3, fuel: 1, cash: [2.5, 250, 30],
    madMode: 'max',
    mad: ['5% of the outstanding amount or ₹100, whichever is greater (POS/ECOM)', '10% of cash transactions', '100% of interest', '100% of fees', 'plus overdue minimum payments, any amount over the credit limit and EMI instalments due'],
    lateSlabs: [],
    lateRule: '2.5% of the total outstanding or ₹200, whichever is higher, + GST', lateSource: 'MobiKwik First KFS (12 Oct 2026) and MITC Table 08',
    waiver: noFee('Membership and annual maintenance fees are nil (KFS; MITC Table 01). Physical card fee ₹200; card cancellation within six months of activation ₹200 (KFS; MITC Table 06).'),
    redemption: { direct_options: [{ channel: 'MobiKwik Wallet: cashback credited within 7 working days of statement generation, can be encashed or transferred to the bank account', redemption_type: 'cashback', inr_value_per_point: 'N/A', max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: '2026-02-01', effective_to: null }], partner_transfers: [] },
    sources: [
      { url: KFS('MobiKwik-First-Card-KFS.pdf'), kind: 'SBM MobiKwik First Credit Card KFS (SBM file dated 12 Oct 2026): fees, interest, late fee, forex, cash limit', read: 'pdftotext' },
      { url: NB('Mobikwik-RP.pdf'), kind: 'SBM MobiKwik First Card Rewards Program T&C: cashback programme effective 1 Feb 2026 (PDF created 10 Feb 2026, SBM file dated 12 May 2026); also keeps the superseded SuperCash programme valid till 31 Jan 2026', read: 'pdftotext' },
      tncSource, pageSource('mobikwik-card.webp'),
    ],
    unverified: [
      'Network: no SBM document names it. RuPay is read from the card image on the SBM page (the RuPay logo is on the MobiKwik First card); the rewards T&C also treats the card as UPI-linked, which fits a RuPay credit card.',
      'No cap, period limit or maximum is stated in the cashback T&C. App and wallet terms on mobikwik.com were not read.',
      'The "funding transaction" exclusion has two MCCs: the cashback table says 5406, the shared excluded table (headed SuperCash and Cashback) says 6540. Both are excluded here.',
      'The rewards T&C carries no revision date beyond "effective 1 Feb 2026" and also lists the older SuperCash rates (10% online and POS, 5% and 1% UPI) that ended 31 Jan 2026. Only the cashback programme is modelled.',
      'The page FAQ (items 7-10) says a 1% processing fee on rent and education applies from 15 Jul 2026 without naming variants. MITC Table 07 shows 0% for this card, so no surcharge is modelled.',
      'The minimum FD and eligibility rules are not stated in any SBM document read for this card.',
      'Fuel surcharge: the KFS says "Surcharge Fee 1% of the transaction amount"; MITC clause 8.7 ties it to fuel. No waiver is stated.',
    ],
    notes: [
      'Different product from suryoday-mobikwik-first-rupay-platinum: issuer is SBM Bank (India) Ltd, not Suryoday Small Finance Bank, with its own KFS (forex 3%, interest 3.5% a month, late fee 2.5% or ₹200, cash fee 2.5% or ₹250). The Suryoday card has forex 2.5% and interest 2.95% a month.',
      'Cashback is credited to the MobiKwik Wallet within 7 working days of statement generation and is forfeited if no wallet is opened within 30 days of bill generation.',
      'Cash interest 3.5% a month from day one; cash limit 30% of the credit limit.',
    ],
  }),

  // ───────────────────────────────────────────── SBM ZET (held: no published reward rate)
  'sbm-zet': make({
    name: 'SBM ZET Credit Card', network: 'rupay', upi: true, forms: ['virtual_card', 'physical_plastic'],
    accrual: { base_block_inr: 'N/A', rounding_mode: 'N/A', base_points_per_block: 'N/A', base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [], caps: [],
    apr: [3.5, 42], forex: 2.49, fuel: 1, cash: [3.5, 300, 50], emi: true,
    surcharges: rentEdu(true, true),
    madMode: 'max',
    mad: ['5% of the outstanding amount or ₹100, whichever is greater (POS/ECOM)', '10% of cash transactions', '100% of interest', '100% of fees', 'plus overdue minimum payments, any amount over the credit limit and EMI instalments due'],
    lateSlabs: [],
    lateRule: '5% of the total outstanding, minimum ₹50 and maximum ₹1,000, + GST (with effect from 23 Oct 2026)', lateSource: 'ZET KFS (12 Oct 2026) and MITC Table 08',
    waiver: noFee('Membership and annual fees are nil (KFS; MITC Table 01). Card replacement ₹249 + GST; card cancellation ₹499 + GST within two years of activation (with effect from 23 Oct 2026, KFS).'),
    sources: [
      { url: KFS('SBM-Bank-ZET-Credit-Card-KFS.pdf'), kind: 'SBM ZET Credit Card KFS (SBM file dated 12 Oct 2026; late fee and cancellation fee marked with effect from 23 Oct 2026)', read: 'pdftotext' },
      tncSource, pageSource('sbm-zet-card.webp'),
    ],
    unverified: [
      'HELD, no published reward rate: the SBM page links only a KFS and an MITC for ZET and describes UPI payments plus FD interest; there is no SBM reward document. Partner pages on zetapp.in advertise cashback tied to a paid ZET Plus subscription and gift-voucher discounts; those are partner marketing, not an SBM document, and are not used as facts.',
      'Network: the page text calls it "an FD-backed RuPay credit card" and the card image shows the RuPay logo. The KFS does not name the network.',
      'The minimum deposit is not stated by SBM; MITC Table 06 only shows virtual cards for FDs below ₹5,000 and physical cards at ₹5,000 or more.',
      'Fuel surcharge: the KFS says "Surcharge Fee 1%"; MITC clause 8.7 ties it to fuel. No waiver is stated.',
    ],
    notes: [
      'Cash interest 3.5% a month from day one; cash limit 50% of the credit limit; ATM fee 3.5% or ₹300, whichever is higher.',
      'EMI: processing fee ₹99 or 1% (whichever is higher) per conversion, 1.5% a month, foreclosure ₹99 or 3% of the remaining principal (MITC Table, EMI charges).',
      'The 1% rent and education fees took effect on 15 Jul 2026 (MITC note to Table 07).',
    ],
  }),

  // ───────────────────────────────────────────── SBM Kredit.Pe
  'sbm-kredit-pe': make({
    name: 'SBM Kredit.Pe Credit Card', network: 'rupay', upi: true, annual: 199,
    pv: 'N/A', pvBasis: 'Cashback card, but the reward document says cashback is redeemed "for additional discounts on popular brands" and does not say it can be withdrawn as cash or what a rupee of cashback is worth when redeemed. Face value is assumed.', expiry: 'N/A',
    accrual: { base_block_inr: 100, rounding_mode: 'N/A', base_points_per_block: 'N/A', base_cashback_percent: 3, effective_base_return_percent: 3, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [
      ...exclRows('sbm-kredit', 'Kredit.Pe rewards construct, excluded-MCC table', kreditRows),
      X('sbm-kredit-excl-other-upi-apps', 'upi', [], 'UPI payments with the card on any other UPI app earn no cashback (rewards construct: "Users will not earn any cashback when they use any other UPI App").', { rail: 'credit_card_on_upi', platform: 'any UPI app other than Kredit.Pe' }),
      R({ id: 'sbm-kredit-pos-3pct', cat: 'all_retail', rail: 'pos_terminal', pri: 10, cb: 3, mult: 3, cond: { per_inr_block: 100 }, reason: '3% cashback on every ₹100 spent on offline (PoS) merchant card payments (rewards construct).' }),
      R({ id: 'sbm-kredit-online-3pct', cat: 'online', rail: 'online', pri: 10, cb: 3, mult: 3, cond: { per_inr_block: 100 }, reason: '3% cashback on every ₹100 spent on online (e-commerce) merchant card payments (rewards construct).' }),
      R({ id: 'sbm-kredit-upi-app-3pct', cat: 'upi', rail: 'credit_card_on_upi', channel: 'kredit_pe_app', pri: 10, cb: 3, mult: 3, cond: { platform: 'Kredit.Pe app', per_inr_block: 100 }, reason: '3% cashback on every ₹100 spent on the card via UPI on Kredit.Pe (rewards construct).' }),
    ],
    caps: [],
    apr: [3.5, 42], forex: 3.5, fuel: 1, cash: [2.5, 100, 50],
    surcharges: [
      { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% processing fee on rental payments (KFS: Rental Payment Fee 1%; MITC Table 07)', threshold_spend_inr: null, effective_from: null, effective_to: null },
      ...rentEdu(false, true),
    ],
    mad: ['5% of the outstanding amount for POS/ECOM', '10% of cash transactions (MITC Table 11; the KFS says 5%)', '100% of interest', '100% of fees'],
    lateSlabs: [],
    lateRule: '5% of the outstanding, minimum ₹50 and maximum ₹1,000, + GST', lateSource: 'Kredit.Pe KFS (12 Oct 2026) and MITC Table 08',
    waiver: { threshold_spend_inr: null, period: null, evaluation_condition: 'Annual fee ₹199 + GST (KFS: "applicable for credit limit under ₹4,500"). MITC Table 01 waives it when the minimum FD balance maintained is ₹5,000 or more. The waiver is deposit-based, not spend-based. Joining fee nil. Card cancellation ₹499 + GST in the first six months.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 199 },
    redemption: { direct_options: [{ channel: 'Kredit.Pe app: additional discounts on popular brands (5% or 10% on certain brands)', redemption_type: 'partner_catalogue', inr_value_per_point: 'N/A', max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: null, effective_to: null }], partner_transfers: [] },
    sources: [
      { url: KFS('Kredit-Pe-KFS.pdf'), kind: 'SBM Kredit.Pe Credit Card KFS (SBM file dated 12 Oct 2026): fees, interest, late fee, forex, cash limit', read: 'pdftotext' },
      { url: NB('kredit-pe-RP.pdf'), kind: 'SBM Bank Kredit.Pe Rewards Construct, 2 pages (PDF created 15 Oct 2026; no revision date on the document): 3% cashback, excluded MCCs', read: 'pdftotext' },
      tncSource, pageSource('kredit-pe-card.webp'),
    ],
    unverified: [
      'No cap, period limit or minimum transaction is stated for the 3% cashback.',
      'Redemption: the construct says cashback can be redeemed "for additional discounts on popular brands" (5% on certain brands, 10% on certain brands). It does not say that cashback can be withdrawn as cash or what a rupee of cashback is worth when redeemed. 3% is modelled at face value, which may overstate the real return.',
      'The wording is "3% cashback on every ₹100 spent". Whether cashback is paid only on whole ₹100 blocks or pro rata is not stated; per_inr_block 100 is recorded in the rule conditions.',
      'Network: no SBM document names it. RuPay is read from the card image on the SBM page (kredit-pe-card.webp); the construct also pays cashback for UPI on the Kredit.Pe app.',
      'The excluded list shows MCC 4111 "for transactions above INR 2,000 only" and 4112 "for transactions above INR 10000 only"; modelled as transaction_amount_gt_inr conditions.',
      'Minimum due on cash: the KFS says 5%, MITC Table 11 (later) says 10%; the table is used.',
      'Fuel surcharge: the KFS says "Surcharge Fee 1%"; MITC clause 8.7 ties it to fuel. No waiver is stated.',
    ],
    notes: [
      'Annual fee ₹199 + GST applies only below the ₹5,000 FD level; the KFS expresses the same condition as a credit limit under ₹4,500 (90% of ₹5,000).',
      'Cash interest 3.5% a month from day one; cash limit 50% of the credit limit.',
      'Rent 1% (KFS and Table 07); education 1% from 15 Jul 2026 (MITC note to Table 07).',
    ],
  }),

  // ───────────────────────────────────────────── SBM novio (Credilio). Visa and RuPay variants; rewards published for RuPay only.
  'sbm-novio': make({
    name: 'SBM novio Credit Card', network: null, upi: true, annual: 299, forms: ['virtual_card', 'physical_plastic'],
    pv: null, pvBasis: 'Value of a novio coin is not stated: the rewards T&C says coins redeem for vouchers "at discounted rates, which may vary for each brand" and have "no monetary value, except in respect of the value assigned by the Bank". Left null.', expiry: 0,
    accrual: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 5, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [
      ...exclRows('sbm-novio', 'novio RuPay rewards T&C, excluded-MCC table', credilioRows),
      X('sbm-novio-excl-atm', 'cash_withdrawal', [], 'ATM cash withdrawals earn 0 novio coins (rewards T&C table).', { rail: 'atm' }),
      X('sbm-novio-excl-emi', 'emi', [], 'EMI transactions earn no reward points, even if later reversed or written off (KFS, billing section).'),
      R({ id: 'sbm-novio-fuel-upi-10', cat: 'fuel', rail: 'credit_card_on_upi', pri: 10, ppb: 10, mult: 2, cap: 'sbm-novio-fuel-upi-cap', cond: { variant: 'RuPay', mcc_list: [5541, 5542], minimum_transaction_inr: 400, maximum_transaction_inr: 4000, per_inr_block: 100 }, reason: 'RuPay variant: 10 novio coins per ₹100 on fuel paid by UPI at MCC 5541 and 5542, minimum ₹400 and maximum ₹4,000 per transaction, up to 400 coins a month (rewards T&C).' }),
      R({ id: 'sbm-novio-fuel-pos-1', cat: 'fuel', rail: 'pos_terminal', pri: 11, ppb: 1, mult: 0.2, cap: 'sbm-novio-fuel-pos-cap', cond: { variant: 'RuPay', mcc_list: [5541, 5542], minimum_transaction_inr: 400, maximum_transaction_inr: 4000, per_inr_block: 100 }, reason: 'RuPay variant: 1 novio coin per ₹100 on fuel paid by POS at MCC 5541 and 5542, minimum ₹400 and maximum ₹4,000 per transaction, up to 40 coins a month (rewards T&C).' }),
      R({ id: 'sbm-novio-other-5', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 5, mult: 1, cond: { variant: 'RuPay', includes: ['UPI', 'POS', 'online'], minimum_transaction_inr: 100, per_inr_block: 100 }, reason: 'RuPay variant: 5 novio coins per ₹100 on UPI, POS and online spends outside fuel, minimum ₹100 per transaction, no monthly limit (rewards T&C). Only whole ₹100 multiples count.' }),
    ],
    caps: [
      C({ id: 'sbm-novio-fuel-upi-cap', cat: 'fuel', metric: 'total_reward_points', period: 'calendar_month', points: 400, mccs: [5541, 5542], after: 'zero_accrual' }),
      C({ id: 'sbm-novio-fuel-pos-cap', cat: 'fuel', metric: 'total_reward_points', period: 'calendar_month', points: 40, mccs: [5541, 5542], after: 'zero_accrual' }),
    ],
    apr: [3.5, 42], forex: 2.49, fuel: 1, cash: [2.5, 299, 50], emi: true, over: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, redeemFee: 0,
    surcharges: rentEdu(true, true),
    mad: ['5% of the total amount due (POS/ECOM)', '10% of cash transactions (MITC Table 11)', '100% of interest', '100% of fees', 'plus unpaid earlier minimum dues, any amount over the credit limit and EMI instalments due'],
    lateSlabs: nilSlab(499),
    lateRule: 'flat ₹499 + GST on non-payment of the minimum amount due', lateSource: 'novio KFS (29 Oct 2026) and MITC Table 08',
    waiver: { threshold_spend_inr: 50000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee ₹299 + GST from the second year (joining fee nil). Waived when the minimum FD balance maintained is ₹10,000 or more OR annual spends in the preceding year are ₹50,000 or more (KFS; MITC Table 01). Card cancellation ₹599 within two years of issuance.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 299 },
    redemption: { direct_options: [{ channel: 'novio app Rewards section: vouchers at brand-specific discounted rates', redemption_type: 'partner_catalogue', inr_value_per_point: null, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null }], partner_transfers: [] },
    network2: dualNetwork({
      sourceUrl: KFS('SBM-Credilio-Key-Fact-Statement.pdf'),
      evidence: 'novio KFS: the fee schedule "is applicable for both VISA and Rupay". SBM publishes a rewards T&C only for the "Rupay Variant"; the page card image shows a RuPay Select card.',
      variants: [
        { network: 'visa', network_tier: 'N/A', label: 'SBM novio Credit Card (Visa variant)', source_url: KFS('SBM-Credilio-Key-Fact-Statement.pdf'), evidence: 'KFS: fees apply to both Visa and RuPay variants. No Visa variant rewards document is published on the SBM page.' },
        { network: 'rupay', network_tier: 'rupay_select', label: 'SBM novio Credit Card (RuPay variant)', source_url: NB('RP-SBM-Credilio-Rupay.pdf'), evidence: 'Rewards T&C titled "SBM novio Credit Card - Rupay Variant: Rewards Program"; card image credilio-credit-card.webp shows RuPay Select.' },
      ],
    }),
    sources: [
      { url: KFS('SBM-Credilio-Key-Fact-Statement.pdf'), kind: 'SBM novio Secured Credit Card KFS (SBM file dated 29 Oct 2026): fees, interest (3.5% a month with effect from 6 Jan 2026), late fee, forex', read: 'pdftotext' },
      { url: NB('RP-SBM-Credilio-Rupay.pdf'), kind: 'SBM novio Credit Card - Rupay Variant: Rewards Program T&C, 4 pages (PDF created 24 Jun 2026, SBM file dated 25 Jun 2026): novio coins, fuel limits, excluded MCCs', read: 'pdftotext' },
      tncSource, pageSource('credilio-credit-card.webp'),
    ],
    unverified: [
      'Visa variant: the KFS covers both Visa and RuPay but SBM publishes a rewards T&C only for the RuPay variant, so the Visa variant earn rate is unknown. The reward rules are tagged variant RuPay.',
      'Value of a novio coin is unknown (vouchers at brand-specific discounted rates), so effective return cannot be computed. point_value_inr_baseline is null.',
      'Fuel limits: the table gives a minimum of ₹400 and a maximum of ₹4,000 per transaction. It is not stated whether a fuel transaction above ₹4,000 earns nothing or earns on ₹4,000. The "Max RPs earned/month" of 400 (UPI) and 40 (POS) is assumed to be a calendar month; the T&C does not define the month.',
      'The rewards T&C carries no revision date (PDF created 24 Jun 2026).',
      'Tier: the card image shows RuPay Select for the RuPay variant; the Visa tier is not shown.',
    ],
    notes: [
      'Interest on POS/ECOM 3.5% a month (42% a year) with effect from 6 Jan 2026; cash 2.99% a month (35.88% a year). Cash limit 50% of the credit limit; ATM fee 2.5% or ₹299, whichever is higher.',
      'Card replacement ₹249; FD pre-closure fee 1%; over limit fee nil; rewards redemption fee nil.',
      'EMI: processing fee ₹99 or 1% (whichever is higher), 1.5% a month, foreclosure ₹99 or 3% of the remaining principal.',
      'Rent and education fees of 1% took effect on 15 Jul 2026 (MITC note to Table 07).',
      'Partner is Credilio Financial Technologies; novio coins do not expire (the Bank may change that on 30 days notice).',
    ],
  }),

  // ───────────────────────────────────────────── SBM Magnet (held: no published reward rate)
  'sbm-magnet': make({
    name: 'SBM Magnet Credit Card', network: 'visa', tier: 'visa_platinum',
    accrual: { base_block_inr: 'N/A', rounding_mode: 'N/A', base_points_per_block: 'N/A', base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [], caps: [],
    apr: [2.5, 30], forex: 2.49, fuel: 1, cash: [2.5, 300, 50], over: { fee_percent: 0, min_fee_inr: 0, gst_applicable: null }, redeemFee: 0,
    surcharges: rentEdu(true, true),
    mad: ['5% of the outstanding amount for POS/ECOM', '10% of the outstanding amount for cash transactions', '100% of the outstanding amount for interest and fees'],
    lateSlabs: nilSlab(299),
    lateRule: 'flat ₹299 + GST on non-payment of the minimum amount due', lateSource: 'Magnet KFS (9 Jun 2026) and MITC Table 08',
    waiver: noFee('Joining and annual fees are nil and no waiver applies (KFS; MITC Table 01). Card replacement ₹249; cancellation ₹499 + GST in the first year of activation; FD closure fee 1%.'),
    sources: [
      { url: KFS('SBM-Magnet-CC-Key-Fact-Statement.pdf'), kind: 'SBM Magnet Secured Credit Card KFS (PDF created 9 Jun 2026, SBM file dated 9 Jun 2026; the page links no newer one)', read: 'pdftotext' },
      tncSource, pageSource('SBM-Magnet-Gild-Card.webp'),
    ],
    unverified: [
      'HELD, no published reward rate: the SBM page says the card earns "unlimited magnet coins as rewards" and links only a KFS and an MITC. No rate, cap, exclusion list or coin value is published by SBM.',
      'Naming: the card image on the SBM page for Magnet is labelled "Gild" (Visa Platinum, file SBM-Magnet-Gild-Card.webp), and a partner-hosted copy of the KFS is titled "SBM MAGNET GILD". The KFS and MITC call the product "SBM Magnet". A person should confirm Magnet and Gild are one live product.',
      'Network: Visa Platinum is read from that card image only; no SBM document names the network. A third-party aggregator lists a Magnet RuPay variant; no SBM document confirms it.',
      'The KFS says payments are made through the "Rupicard Mobile app", which looks like stale wording; the MITC lists the partner as Vistas Technolabs (ZET).',
      'Fuel surcharge: the KFS says "Surcharge Fee 1%"; MITC clause 8.7 ties it to fuel. No waiver is stated.',
    ],
    notes: [
      'Interest on POS/ECOM 2.5% a month (30% a year); cash 3.3% a month (40% a year). Cash limit 50% of the credit limit; ATM fee 2.5% or ₹300, whichever is higher.',
      'Page text: "earn FD interest up to 7% p.a." on the deposit.',
      'Rent and education fees of 1% took effect on 15 Jul 2026 (MITC note to Table 07).',
    ],
  }),

  // ───────────────────────────────────────────── SBM Niyo Global
  'sbm-niyo-global': make({
    name: 'SBM Niyo Global Credit Card', network: 'visa', tier: 'visa_platinum',
    pv: 0.1, pvBasis: 'SBM Niyo rewards T&C: "Value of Niyo Coins: 1 Coin = ₹0.10". Coins expire 12 months after issue. Redeemable on Niyo products and services at offers that Niyo can change.', expiry: 12,
    elig: 'FD-backed Global Credit Card; minimum fixed deposit ₹5,000 for issuance (KFS item 3). Credit limit is 90% of the FD (MITC Table 09). Niyo app registration is required to earn coins (rewards T&C).',
    eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 5000, allowed_values: [] }],
    accrual: { base_block_inr: 100, rounding_mode: 'N/A', base_points_per_block: 0, base_cashback_percent: 'N/A', effective_base_return_percent: 0, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [
      X('sbm-niyo-excl-pos-tap', 'all_retail', [], 'POS and tap-and-pay transactions earn no coins (rewards T&C: "no rewards for ATM, POS & Tap and pay").', { rail: 'pos_terminal' }),
      X('sbm-niyo-excl-atm', 'cash_withdrawal', [], 'ATM withdrawals earn no coins (rewards T&C).', { rail: 'atm' }),
      ...exclRows('sbm-niyo', 'Niyo rewards T&C, excluded-MCC table', credilioRows),
      R({ id: 'sbm-niyo-travel-30pct', cat: 'travel', rail: 'online', channel: 'niyo_app', pri: 5, ppb: 30, mult: 30, cap: 'sbm-niyo-annual-cap', cond: { platform: 'Niyo app travel VAS booking', minimum_transaction_inr: 100, per_inr_block: 100 }, reason: '30% coins on travel VAS bookings made through the Niyo app: 30 coins per ₹100, worth 3% at ₹0.10 a coin (rewards T&C).' }),
      R({ id: 'sbm-niyo-domestic-ecom-20pct', cat: 'online', rail: 'online', pri: 10, ppb: 20, mult: 20, cap: 'sbm-niyo-annual-cap', cond: { geography: 'domestic', minimum_transaction_inr: 100, per_inr_block: 100 }, reason: '20% coins on domestic e-commerce: 20 coins per ₹100, worth 2% at ₹0.10 a coin (rewards T&C).' }),
      R({ id: 'sbm-niyo-intl-ecom-10pct', cat: 'online', rail: 'online', pri: 11, ppb: 10, mult: 10, cap: 'sbm-niyo-annual-cap', cond: { geography: 'international', minimum_transaction_inr: 100, per_inr_block: 100 }, reason: '10% coins on international e-commerce: 10 coins per ₹100, worth 1% at ₹0.10 a coin (rewards T&C).' }),
    ],
    caps: [C({ id: 'sbm-niyo-annual-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'annual', points: 500000, after: 'zero_accrual' })],
    apr: [3, 36], forex: 0, fuel: 0, cash: [2.5, 423, 100], over: { fee_percent: null, min_fee_inr: 150, gst_applicable: true },
    madMode: 'max',
    mad: ['5% of the total amount due or ₹100, whichever is greater', '5% of cash withdrawals (MITC Table 11)', '100% of interest', '100% of fees', 'plus unpaid earlier minimum dues and any amount over the credit limit'],
    lateSlabs: nilSlab(150),
    lateRule: 'flat ₹150 + GST if the minimum amount due is not paid by the due date plus 3 days', lateSource: 'Niyo KFS (12 Oct 2026) and MITC Table 08',
    waiver: noFee('KFS: joining fee ₹500 "waived off" and annual membership fee ₹500 "waived off" for primary and add-on cards; MITC Table 01 shows both as 0. Modelled as 0. Card re-issuance ₹249.'),
    redemption: { direct_options: [{ channel: 'Niyo products and services at offers and discounts set by Niyo', redemption_type: 'partner_catalogue', inr_value_per_point: 0.1, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: null, effective_to: null }], partner_transfers: [] },
    sources: [
      { url: KFS('Niyo-KFS.pdf'), kind: 'Niyo Global SBM Credit Card KFS (SBM file dated 12 Oct 2026; illustrations use 2020-2022 dates): fees, interest, zero forex, Visa exchange rate wording', read: 'pdftotext' },
      { url: 'https://www.sbm.bank.in/pdf/terms-conditions/Niyo-Reward-TC_26-Feb-2026.pdf', kind: 'SBM Niyo Credit Card - Rewards Terms and Conditions (file name dated 26 Feb 2026, PDF created 2 Mar 2026): coin rates, value, cap, excluded MCCs', read: 'pdftotext' },
      tncSource, pageSource('consumer-niyo.webp'),
    ],
    unverified: [
      'Fees: the KFS shows joining and annual fee ₹500 "waived off"; MITC Table 01 (29 Oct 2026, later) shows 0. Modelled as 0. Neither document says whether the waiver is permanent or promotional.',
      'The annual limit of 5,00,000 coins does not say whether the year is the calendar year or the card year. Recorded as period annual.',
      '"Travel VAS booking through the Niyo App" and "International ECOM" are not defined in the rewards T&C. International e-commerce is modelled as stated; whether a foreign-currency or foreign-merchant test applies is not given.',
      'The rewards T&C does not mention UPI or bill payments, so they are not modelled as earning; the card image shows Visa Platinum, which is not UPI-linkable, so is_upi_linkable is left null.',
      'The excluded-MCC section is headed "Users will not earn any cashback"; treated as an exclusion of coins.',
      'Network: Visa from the KFS ("VISA exchange rates", Visa ATM compatibility) and the card image (Visa Platinum).',
    ],
    notes: [
      'Coins = % of transaction value: 20% coins on a ₹100 domestic e-commerce purchase is 20 coins = ₹2. Minimum transaction ₹100.',
      'Interest 3% a month (36% a year) on purchases and cash; cash fee 2.5% or ₹423 + GST; cash limit 100% of the credit limit (MITC Table 10). Over-limit fee ₹150.',
      'Zero forex mark-up: Niyo and SBM add no mark-up; Visa exchange rates only (KFS, MITC Table 07). Surcharge, rent and education fees 0%.',
    ],
  }),

  // ───────────────────────────────────────────── SBM Paisabazaar Step Up
  'sbm-paisabazaar-step-up': make({
    name: 'SBM Paisabazaar Step Up Credit Card', network: null, upi: null, forms: ['virtual_card', 'physical_plastic'],
    pv: 0.25, pvBasis: 'Step Up rewards structure: "1 Reward Point = Rs. 0.25"; no redemption fee; a minimum of 400 reward points is needed to redeem in the Paisabazaar app. Expiry is not stated.', expiry: null,
    elig: 'FD-backed: credit limit 90% of the FD; minimum FD ₹2,000 (KFS). Only a virtual card is issued for an FD of ₹2,000; the FD is on auto renewal and closes with the card (KFS).',
    eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 2000, allowed_values: [] }],
    accrual: { base_block_inr: 100, rounding_mode: 'N/A', base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.25, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    rules: [
      X('sbm-stepup-excl-wallet', 'wallet_load', [6540], 'E-wallet loading earns no reward points (Step Up rewards structure, disallowed categories).'),
      X('sbm-stepup-excl-rent', 'rent', [6513], 'Rent payment earns no reward points.'),
      X('sbm-stepup-excl-fuel', 'fuel', [5541], 'Fuel payment (MCC 5541) earns no reward points. The document lists only MCC 5541 for fuel.'),
      X('sbm-stepup-excl-utility', 'utility', [4900], 'Utility payment earns no reward points.'),
      X('sbm-stepup-excl-insurance', 'insurance', [6300], 'Insurance premium and related payments earn no reward points.'),
      X('sbm-stepup-excl-cash', 'cash_withdrawal', [6010, 6011], 'Cash disbursements and ATM cash advances earn no reward points.'),
      X('sbm-stepup-excl-emi', 'emi', [], 'EMI payments earn no reward points.'),
      R({ id: 'sbm-stepup-base-1', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 reward point on every purchase of ₹100 on regular purchases, worth ₹0.25 a point, about 0.25% (Step Up rewards structure).' }),
    ],
    caps: [],
    apr: [3, 36], forex: 3.5, fuel: 2, cash: [2.5, 250, 50],
    mad: ['5% of the outstanding amount (POS/ECOM)', '10% of cash transactions (MITC Table 11)', '100% of interest', '100% of fees', 'plus unpaid earlier minimum dues and any amount over the credit limit'],
    lateSlabs: [{ min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: 1000, fee_inr: 250 }, { min_balance_inr: 1001, max_balance_inr: 10000, fee_inr: 500 }, { min_balance_inr: 10001, max_balance_inr: null, fee_inr: 750 }],
    lateRule: 'up to ₹100 nil; ₹100 to ₹1,000 ₹250; ₹1,000 to ₹10,000 ₹500; above ₹10,000 ₹750 (+ GST), charged on the outstanding amount', lateSource: 'Step Up KFS (12 Oct 2026) and MITC Table 08',
    waiver: noFee('Annual and renewal fee ₹0 (KFS; MITC Table 01). Joining fee: MITC Table 01 (29 Oct 2026) shows 0; the KFS (12 Oct 2026) charges ₹500 + GST on a ₹2,000 FD, ₹250 + GST on a ₹5,000 FD and nil above ₹5,000. Card cancellation ₹499 + GST in the first six months; replacement ₹200 + GST.'),
    redemption: { direct_options: [{ channel: 'Paisabazaar app; redeemed points are adjusted in the next billing cycle', redemption_type: 'statement_credit', inr_value_per_point: 0.25, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 400, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null }], partner_transfers: [] },
    network2: dualNetwork({
      sourceUrl: PAGE,
      evidence: 'The card image for Paisabazaar Step Up on the SBM page (paisa-bazaar.webp) shows two cards: a Mastercard Platinum card and a RuPay Select credit card. No SBM document states which one is issued to a given applicant.',
      variants: [
        { network: 'mastercard', network_tier: 'mastercard_platinum', label: 'SBM Paisabazaar Step Up Credit Card (Mastercard Platinum)', source_url: ART('paisa-bazaar.webp'), evidence: 'Card image on the SBM secured credit card page shows the Mastercard logo and "Platinum".' },
        { network: 'rupay', network_tier: 'rupay_select', label: 'SBM Paisabazaar Step Up Credit Card (RuPay Select)', source_url: ART('paisa-bazaar.webp'), evidence: 'Card image on the SBM secured credit card page shows the RuPay credit logo and "Select".' },
      ],
    }),
    sources: [
      { url: KFS('PB_KFS.pdf'), kind: 'Paisabazaar Step-Up SBM Credit Card KFS, 11 pages (SBM file dated 12 Oct 2026; examples use 2020 dates): joining fee tiers, late fee, forex, interest', read: 'pdftotext' },
      { url: NB('Stepup-Reward-Structure.pdf'), kind: 'Step Up reward structure, 2 pages (PDF created 14 Feb 2025, modified 21 Feb 2025; SBM file dated 3 Feb 2026): 1 point per ₹100, ₹0.25 a point, disallowed MCCs', read: 'pdftotext' },
      tncSource, pageSource('paisa-bazaar.webp'),
    ],
    unverified: [
      'Joining fee: the KFS (12 Oct 2026) charges ₹500 + GST on a ₹2,000 FD, ₹250 + GST on a ₹5,000 FD and nil above ₹5,000; MITC Table 01 (29 Oct 2026, later) shows 0 for all. 0 is used; confirm for small FDs.',
      'The rewards structure is the oldest document in the set (PDF created 14 Feb 2025). It says "Currently, you will get 1 Reward Point on every purchase of Rs. 100" and states no cap, expiry or minimum spend.',
      'Network: the card image shows both a Mastercard Platinum and a RuPay Select card; no document says how the variant is assigned. Whether the RuPay Select card can be linked to UPI is not stated, so is_upi_linkable is left null.',
      'Annualised interest: the KFS shows 3.00% a month and 42.58% a year (compounded); MITC Table 03 shows 3% a month or 36% a year. 36 is used.',
      'Grace period: the KFS says 20 to 50 days, up to 48 days; the MITC says the interest-free period will not exceed 45 days. 45 is used.',
      'The disallowed list names fuel by MCC 5541 only, utilities by 4900 and insurance by 6300; other MCCs in those categories are not named.',
      'Fuel surcharge: the KFS says "up to 2% of transaction amount"; MITC Table 07 says 2%. No waiver is stated.',
    ],
    notes: [
      'ATM fee 2.5% or ₹250, whichever is higher; cash limit 50% of the credit limit; cash interest 3% a month from day one.',
      'Forex 3.5%; rent and education fees 0%.',
    ],
  }),
};
