// Wave 5, agent W5B (read 2026-11-15). Cards with no earlier base record: every overlay carries the full structure.
// BOBCARD (issuer_slug bobcard) and Canara Bank secured cards. Kotak, IndusInd and IDFC rows of this assignment are
// recorded in wave5/W5B.json only (held / variant), no overlay.
//
// BOBCARD sources (all read 2026-11-15, plain fetch or pdftotext):
//  MITC  = BOBCARD Consolidated MITC, PDF created 7 Oct 2026, footer "GENERIC MITC 2.0 JULY2026" (fees, finance charges, reward tables, Etihad and Uni GoldX sections)
//  FEAT  = Features & Rewards - Important T&C, PDF created 11 Nov 2026 (core rates, accelerated caps, lounge table, cashback card terms)
//  KFS   = BOBCARD Key Fact Statement, PDF created 17 Jul 2026
//  REV1  = Revision in product features and charges w.e.f. 1 Apr 2026 (PDF created 2 Mar 2026)
//  REV2  = Revision in product features / benefits (PDF created 16 Jun 2026): lounge spend rule from 1 Oct 2026, Eterna/Tiara finance charge 3.75% from 15 Jul 2026, insurance withdrawn for new cards
//  EKFS  = Etihad Guest MITC and KFS (PDF created 22 Jun 2026, "ETIHAD MITC 2.0 APR 2026"); EREV = Etihad revision w.e.f. 5 Aug 2026 (PDF created 12 Oct 2026)
//  UKFS  = BOBCARD Uni GoldX Key Fact Statement (PDF created 23 Oct 2026)
//  Product pages: https://www.bobcard.co.in/credit-card-types/<slug> (plain fetch, text read)
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const MEDIA = 'https://media.bobcard.co.in//media/';
const MITC = MEDIA + '4wnez0dz/bobcard-consolidated-mitc.pdf';
const FEAT = MEDIA + '0h5cim12/features-and-rewards-important-terms-conditions-11112026.pdf';
const KFS = MEDIA + 'rfnlbqkz/bobcard-kfs_4x8_17jul2026.pdf';
const REV1 = MEDIA + 'nfkmkemd/revision-in-product-features-charges-wef-1st-april-26v1.pdf';
const REV2 = MEDIA + 'lfhhmpw2/revision-in-charges-and-benefits-166.pdf';
const EKFS = MEDIA + '3mjfujsg/etihad-mitc-kfs-22062026.pdf';
const EREV = MEDIA + 'dlobtvcn/revision-in-etihad-features-charges-wef5th-aug26.pdf';
const ELOUNGE = MEDIA + 'utrlq3g0/bobcard-etihad-global-lounge-list.pdf';
const UKFS = MEDIA + '1qdnjbu5/bobcard-uni-goldx-key-fact-statement-4.pdf';
const HUB = 'https://www.bobcard.co.in/most-important-terms-and-condition/';
const page = (s) => `https://www.bobcard.co.in/credit-card-types/${s}`;
const FETCHED = { fetched_on: '2026-11-15' };

// Annexure 1 of FEAT / REV1 Table 2: MCCs that earn no core or accelerated points.
const ANNEX1 = [763, 780, 820, 821, 822, 823, 824, 825, 1520, 1711, 1731, 1740, 1750, 1761, 1771, 1799, 4111, 4112, 4131, 4784, 4789, 6513, 7349, 7211, 7230, 7276, 8111, 8641, 9211, 9222, 9311, 9399, 9402, 9405, 8211, 8220, 8241, 8244, 8249, 8299, 8011, 8062, 6539, 6540, 6541, 6542, 6543, 5261, 5331, 5411, 5499, 5960, 6300, 8398, 8661, 5814];
const FUEL_MCC = [5172, 5541, 5542, 5983]; // MITC fuel processing-fee row

const LATE = [
  { min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }, { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 400 },
  { min_balance_inr: 1001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 950 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
];
const MAD = { calculation_mode: 'fixed_percent', components: ['100% of fees, finance charges, GST and EMI amount', '2% of retail spends and cash advances', 'minimum ₹200 (MITC)'] };

const surcharges = (o = {}) => [
  { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction amount on every rent payment (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
  { category_id: 'wallet', mcc_list: [6539, 6540, 6541, 6542], fee_percent: 1, gst_applicable: true, trigger_condition: '1% processing fee on wallet loads (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
  { category_id: 'bills', mcc_list: [4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (maximum ₹3,000 per transaction) on utility payments of ₹50,000 or more (MITC)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
  { category_id: 'fuel', mcc_list: FUEL_MCC, fee_percent: 1, gst_applicable: true, trigger_condition: '1% processing fee on a fuel transaction of ₹10,000 or more (MITC)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
  { category_id: 'education', mcc_list: [8299, 8211, 8241, 8244, 8249, 8220], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (maximum ₹5,000 per transaction) on online education fees paid through third-party apps (Cheq, CRED, Ease My Deal, Mobikwik, NoBroker, Paytm, Phonepe, SuperPe), from 1 Apr 2026 (MITC, REV1)', threshold_spend_inr: null, effective_from: '2026-04-01', effective_to: null },
  { category_id: 'travel', mcc_list: [4784], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on toll and bus bookings (MCC 4784) of ₹5,000 or more, from 1 Apr 2026 (MITC, REV1)', threshold_spend_inr: 5000, effective_from: '2026-04-01', effective_to: null },
  { category_id: 'travel', mcc_list: [4112], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (maximum ₹5,000 per transaction) on railway bookings (MCC 4112) of ₹30,000 or more, from 1 Apr 2026 (MITC, REV1)', threshold_spend_inr: 30000, effective_from: '2026-04-01', effective_to: null },
].filter((s) => !(o.skip || []).includes(s.category_id + s.mcc_list[0]));

const addonDefault = { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: 18 };

/** Generic BOBCARD points card. o carries everything that differs per card. */
const bob = (o) => {
  const pv = o.pv;
  const pre = o.id;
  const accel = o.accel || [];
  return {
    card_product: {
      ...GST, name: o.name, issuer_slug: 'bobcard', card_type: 'credit', network: o.network ?? null, network_tier: null, card_tier: null, application_mode: 'open',
      joining_fee_inr: o.joining, annual_fee_inr: o.annual, is_upi_linkable: o.upi ?? false, form_factors: o.forms || [],
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: page(o.page), status: 'draft', verified_at: null,
      point_value_inr_baseline: pv ?? null, point_value_baseline_basis: o.pvBasis ?? null, point_expiry_months: o.expiry ?? 24,
    },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.eligNote ?? null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: o.core, base_cashback_percent: 'N/A', effective_base_return_percent: pv ? Math.round((o.core * pv) * 1000) / 1000 : null, cycle_accrual_ceiling_points: o.ceiling ?? null, capping_period_basis: o.ceiling ? 'statement_cycle' : null },
    reward_rules: [
      X(`${pre}-excl-annexure1`, 'excluded_spend', ANNEX1, 'Annexure 1 merchant categories (agriculture, contractors, transport, rent, cleaning and personal services, government, education, hospital, wallet, supermarkets and variety stores, insurance, charity, fast food) earn no core or accelerated points (FEAT section 1.1, annexure 1).'),
      X(`${pre}-excl-fuel`, 'fuel', FUEL_MCC, 'Fuel transactions earn no reward points on any BOBCARD except HPCL Energie (FEAT 1.1). Fuel MCCs taken from the MITC fuel processing-fee row.'),
      ...accel.map(([id, cat, ch, ppb, label, cond]) => R({ id: `${pre}-${id}`, cat, channel: ch, pri: 10, ppb, mult: ppb / o.core, cap: `${pre}-accel-cap`, cond, reason: `${ppb} reward points per ₹100 on ${label}; accelerated points capped at ${o.capPts.toLocaleString('en-IN')} a statement cycle (${o.accelSrc}). Credit-card-on-UPI spends and utility MCC 4900 do not earn accelerated points (FEAT 1.2).` })),
      R({ id: `${pre}-core`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: o.core, mult: 1, cond: { per_inr_block: 100, minimum_transaction_inr: 100 }, reason: `${o.core} reward points per ₹100 on eligible spends; transactions below ₹100 earn nothing (FEAT 1.1 core table, REV1 Table 1${o.coreNote ? '; ' + o.coreNote : ''}). Telecom MCC 4814 earns core points from 1 Apr 2026 (REV1).` }),
    ],
    cap_rules: accel.length ? [C({ id: `${pre}-accel-cap`, cat: o.capCat || 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: o.capPts, after: 'downgrade_to_base_rate', afterPpb: o.core })] : [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: o.apr?.[0] ?? 3.75, annual_interest_rate_percent: o.apr?.[1] ?? 45 },
      forex_markup: { markup_percent: o.forex, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: null },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: o.fuelMin ?? 400, max_txn_inr: 5000, monthly_waiver_cap_inr: o.fuelCap ?? 250 },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 40 },
      category_surcharges: surcharges(o.surchargeOpts),
      emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: null, foreclosure_charge_percent: null, gst_applicable: null },
      banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 600, gst_applicable: true }, auto_debit_bounce_charge_inr: 500, cheque_bounce_charge_inr: 500 },
      reward_redemption_fee: { fee_inr: 0, gst_applicable: null },
    },
    statement_and_late_fees: { grace_period_days: 50, grace_period_void_on_revolving_balance: true, minimum_amount_due_mad: MAD, late_payment_slabs: LATE },
    fee_waiver_and_milestones: {
      annual_fee_waiver: o.waiver
        ? { threshold_spend_inr: o.waiver, period: 'card_anniversary_year', evaluation_condition: `Annual fee ₹${o.annual.toLocaleString('en-IN')} + GST is not charged when spends in the preceding anniversary year reach ₹${o.waiver.toLocaleString('en-IN')} (MITC annual fee table); applies to non-delinquent cardholders (product page).`, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: o.annual }
        : { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No annual fee is charged (MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: o.welcome === null
        ? { trigger: null, benefit_points: null, effective_value_inr: null, condition: null }
        : { trigger: 'card_issuance', benefit_points: 500, effective_value_inr: pv ? 500 * pv : null, condition: o.welcome || '500 reward points on spends of ₹5,000 within 60 days of card issuance (MITC 1.4 welcome benefit; product page).' },
      spend_milestones: o.milestones || [],
    },
    addon_card_rules: { ...addonDefault, max_addon_cards: o.addons ?? null, ...(o.addonRules || {}) },
    lifestyle_and_network_benefits: o.benefits || [],
    insurance_and_protection: o.insurance || [],
    dynamic_promotions_registry: o.promos || [],
    redemption_matrix: pv ? { direct_options: [
      { channel: 'Redeem reward points as cashback (product page)', redemption_type: 'cashback', inr_value_per_point: pv, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: 1000, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
      { channel: 'TWID Pay with Rewards (FEAT section 4): up to 25% of the invoice, minimum 500 points', redemption_type: 'other', inr_value_per_point: 0.15, max_bill_percentage_payable_via_points: 25, min_points_per_txn: 500, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null },
    ], partner_transfers: [] } : { direct_options: [], partner_transfers: [] },
    additional_data: { items: [
      ...(o.dual ? [dualNetwork(o.dual)] : []),
      ...prov({
        sources: [
          { url: o.page ? page(o.page) : HUB, kind: `${o.name} product page (plain fetch, text read 2026-11-15)`, read: 'page text' },
          { url: MITC, kind: 'BOBCARD Consolidated MITC (PDF created 7 Oct 2026, GENERIC MITC 2.0 JULY2026): joining and annual fees, finance charges, forex, fuel, surcharges, late fee, reward T&C', read: 'pdftotext' },
          { url: FEAT, kind: 'Features & Rewards Important T&C (PDF created 11 Nov 2026): core rate, accelerated categories and caps, lounge table, TWID', read: 'pdftotext' },
          { url: KFS, kind: 'BOBCARD Key Fact Statement (PDF created 17 Jul 2026)', read: 'pdftotext' },
          { url: REV1, kind: 'Revision in product features and charges w.e.f. 1 Apr 2026 (core rates table, telecom, new surcharges)', read: 'pdftotext' },
          { url: REV2, kind: 'Revision in product features/benefits (PDF created 16 Jun 2026): lounge spend rule, finance charge, insurance withdrawn for new cards', read: 'pdftotext' },
          ...(o.extraSources || []),
        ],
        unverified: [
          ...(o.netOpen ? [o.netOpen] : []),
          ...(o.open || []),
          'Reward point value: only the cashback value shown on the product page is used; points expire 2 years after accrual except Eterna/Tiara (FEAT 1.4). Minimum 1,000 points to redeem against the statement (FEAT).',
          'EMI processing fee, foreclosure charge and merchant-EMI fees are in the separate "T&C for EMI on BOBCARD" PDF and were not read; those fields are null.',
          'Interest, cash-advance (2.5% or ₹500, limit 40% of available limit), overlimit (2.5% or ₹600) and cheque-return rows are the MITC "all other credit cards" rows; the MITC names this card in the fee tables but not in those rows.',
        ],
        notes: o.notes || [],
        extra: FETCHED,
      }),
    ] },
  };
};

const SPECIAL_NOTE = 'BOBCARD can change fees and benefits at its discretion with 30 days notice on its website (MITC).';

// ───────────────────────────────────────────────────────────── Defence and force cards (Yoddha, Rakshamah, Sentinel share every number)
const force = (o) => bob({
  ...o, joining: 0, annual: 0, waiver: null, core: 2, forex: 3, pv: 0.25,
  pvBasis: 'Product page: "All your accumulated reward points can be redeemed for cashback @ 1 reward point = ₹0.25". Page text is undated.',
  accel: [['dept-store-10rp', 'all_retail', 'all', 10, 'departmental stores (MCC 5311)', { mcc_list: [5311] }]],
  capPts: 1000, accelSrc: 'FEAT 1.2 table; product page footnote', coreNote: 'the product page says "2 Reward Point for every ₹100 spent on any other category"',
  addons: 3,
  network: 'rupay',
  forms: [], upi: false,
  benefits: [
    B({ id: `${o.id}-lounge`, cat: 'lounge', sponsor: 'BOBCARD', label: 'Domestic airport lounge access, 2 visits a quarter (8 a year)', cond: { min_net_spend_previous_calendar_quarter_inr: 20000 }, qty: 2, per: 'quarter' }),
    B({ id: `${o.id}-concierge`, cat: 'concierge', program: 'rupay', sponsor: 'NPCI RuPay', label: '24/7 domestic and international concierge assistance, powered by RuPay' }),
    B({ id: `${o.id}-prime`, cat: 'other', sponsor: 'BOBCARD', label: '12 months Amazon Prime membership on spends of ₹1 lakh within 90 days of issue (FEAT 1.3 milestone)', cond: { spend_inr: 100000, within_days: 90 } }),
    B({ id: `${o.id}-fitpass`, cat: 'health', sponsor: 'BOBCARD', label: 'Complimentary 12 months FITPASS PRO membership as a welcome gift (product page; terms behind the page "Know More" link not read)' }),
  ],
  insurance: [{ cover_type: 'other', coverage_inr: 2000000, coverage_usd: 'N/A', claim_condition: 'Personal accidental death cover, air and non-air ₹20 lakh each (product page). REV2 withdraws accidental-death cover for cards issued after 15 Jul 2026 on listed products; this product is not in that list.', effective_from: null, effective_to: null }],
  open: [
    'Accelerated rewards: the product page says 10 points per ₹100 on "Departmental Stores and Movies", but the FEAT table (11 Nov 2026) lists only departmental stores (MCC 5311) with a 1,000-point cap for this card. Only departmental stores is modelled. A person should confirm whether movies (MCC 7832) still earn the 5X rate.',
    'Network: no page or document states it. The concierge line says "Powered by RuPay" and "provided by NPCI-RuPay"; that is used as the network statement (RuPay). The card art shows no network wordmark, only the contactless symbol.',
    'Lounge: the product page says 8 complimentary visits a year (twice a quarter); FEAT adds a ₹20,000 spend in the preceding calendar quarter, waived in the quarter a new card is issued. The cooling period between visits is 5 hours (FEAT).',
    'Welcome gift FITPASS PRO and the Amazon Prime milestone conditions are summarised on the page; the linked "Know More" terms were not read.',
  ],
  notes: ['Exclusively for serving or retired personnel of the force named in the card name (product page).', SPECIAL_NOTE],
});

// ───────────────────────────────────────────────────────────── helper for FEAT/product pages that carry the same restricted-network open question
const NET_UNKNOWN = (name) => `Network: not stated by any BOBCARD page or document for ${name}. The card art on the product page shows only the contactless symbol (orange and green chevron) and no network wordmark; the chevron is not taken as proof of RuPay.`;

export const cards = {
  // ───────────────────────────────────────────── BOBCARD TIARA
  'bobcard-tiara': bob({
    id: 'tiara', name: 'BOBCARD TIARA', page: 'tiara', joining: 2499, annual: 2499, waiver: 250000, core: 3, forex: 2, pv: 0.25,
    pvBasis: 'Tiara product page: "Redeem your reward points as cashback ... (1 Reward Point = ₹ 0.25)". Page text is undated.',
    network: 'rupay', upi: true, expiry: 0, apr: [3.75, 45],
    accel: [
      ['international-15rp', 'international_spend', 'all', 15, 'international spends (international flag from the acquirer)', { transaction_type: 'international' }],
      ['dining-15rp', 'dining', 'all', 15, 'dining (MCC 5812)', { mcc_list: [5812] }],
      ['travel-15rp', 'travel', 'all', 15, 'travel (MCC 4722)', { mcc_list: [4722] }],
    ],
    capPts: 5000, capCat: 'all_retail', accelSrc: 'FEAT 1.2 table and the product page footnote ("5X Rewards are capped at 5,000 Reward Points on the mentioned categories per statement cycle")', addons: 3,
    welcome: '500 reward points on spends of ₹5,000 within 60 days of card issuance (MITC 1.4 "all other cards"; the Tiara page does not repeat it). Cards issued on or after 1 Aug 2026 also get a complimentary 12 month FITPASS PRO membership (page).',
    addonRules: { fee_per_card_inr: 0, min_age_years: 18 },
    forms: [],
    benefits: [
      B({ id: 'tiara-lounge', cat: 'lounge', sponsor: 'BOBCARD', label: 'Unlimited domestic airport lounge access', cond: { min_net_spend_previous_calendar_quarter_inr: 75000, note: 'INR 40,000 until 30 Sep 2026, INR 75,000 from 1 Oct 2026 (REV2)' }, qty: null, per: 'quarter' }),
      B({ id: 'tiara-health', cat: 'health', sponsor: 'BOBCARD', label: "Complimentary women's health package (pap smear, blood tests, mammography) for existing Tiara customers (page; package terms behind a login)" }),
      B({ id: 'tiara-fitpass', cat: 'health', sponsor: 'BOBCARD', label: 'Complimentary 12 month FITPASS PRO membership for cards issued on or after 1 Aug 2026 (page)' }),
    ],
    promos: [
      P({ id: 'tiara-myntra', cat: 'other', sponsor: 'Myntra', platform: 'Myntra', type: 'instant_discount', max: 500, quota: true }),
      P({ id: 'tiara-nykaa', cat: 'other', sponsor: 'Nykaa', platform: 'Nykaa', type: 'instant_discount', max: 500, quota: true }),
      P({ id: 'tiara-flipkart', cat: 'online', sponsor: 'Flipkart', platform: 'Flipkart', type: 'instant_discount', max: 500, quota: true }),
      P({ id: 'tiara-lakme', cat: 'other', sponsor: 'Lakmé Salon', platform: 'Lakmé Salon', type: 'instant_discount', max: 1500, quota: true }),
      P({ id: 'tiara-bigbasket', cat: 'groceries', sponsor: 'BigBasket', platform: 'BigBasket', type: 'instant_discount', max: 250, quota: true }),
      P({ id: 'tiara-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', max: 250, quota: true }),
    ],
    netOpen: 'Network (RuPay): the card image on the Tiara product page (tiara-card-cutout-01.png, opened and read) shows the RuPay Credit wordmark. Card art is accepted evidence under the wave 3 rule; no BOBCARD document states the network in words.',
    open: [
      'Quarterly vouchers (Myntra, Nykaa, Flipkart ₹500 each, Lakmé ₹1,500, BigBasket ₹250, BookMyShow ₹250 on two tickets), Swiggy One 3 months once a year and OTT/music memberships are listed by the page as "quarterly" or "annual" benefits for existing Tiara customers; the redemption terms are behind a login and were not read. They are recorded as capped offers, not as rewards.',
      'The page says "Reward Points on CC UPI are capped at ₹500 per statement cycle (1 Reward Point = ₹ 0.25)". It is not clear whether the cap is on points or on rupees, or whether it limits earning or redemption. Not modelled.',
      'Insurance: REV2 says accidental death cover is not applicable to Tiara cards issued after 15 Jul 2026, so no insurance is recorded.',
      'Lounge: the page and FEAT say unlimited domestic visits; the ₹75,000 previous-quarter spend rule starts 1 Oct 2026 (REV2, lounge reminder of 27 Aug 2026). Waived in the quarter of issue for new cards (FEAT 5.2).',
    ],
    notes: ['Women-only card (page).', 'Reward points on Eterna and Tiara are evergreen (FEAT 1.4), so point_expiry_months is 0; points carried from an upgraded card lapse on the old schedule.', SPECIAL_NOTE],
    extraSources: [{ url: MEDIA + '2nxfsa4a/reminder-for-lounge-access-in-oct-to-dec-2026.pdf', kind: 'Lounge access reminder for Oct-Dec 2026 (PDF created 27 Aug 2026)', read: 'pdftotext' }],
  }),

  // ───────────────────────────────────────────── BOBCARD Empower
  'bobcard-empower': bob({
    id: 'empower', name: 'BOBCARD EMPOWER', page: 'empower', joining: 0, annual: 500, waiver: 50000, core: 1, forex: 3.5, pv: 0.25,
    pvBasis: 'Empower product page: "redeemed for cashback @1 reward point = ₹0.25". Page text is undated.',
    network: null, upi: false, accel: [], addons: null,
    open: [
      'Accelerated rewards conflict: the Empower page and REV1 (1 Apr 2026) say 5 reward points per ₹100 on utilities (MCC 4900), capped at 1,000 points a statement cycle; the MITC (7 Oct 2026) and FEAT (11 Nov 2026), both later, say accelerated rewards are not available on Empower, and FEAT excludes MCC 4900 from accelerated points. Only the 1 point per ₹100 core rate is modelled. A person should confirm whether the 5X utility offer is still live.',
      NET_UNKNOWN('Empower'),
    ],
    notes: ['Business card for proprietors and self-employed, "Made for Proprietors and Self-Employed segments"; fourth-line embossing of the business name (page).', 'Utility payments of ₹50,000 or more attract a 1% processing fee, up to ₹3,000 (MITC).'],
    benefits: [],
  }),

  // ───────────────────────────────────────────── Pragati
  'bobcard-pragati': bob({
    id: 'pragati', name: 'BOBCARD UPGB/GGB/BRKGB PRAGATI', page: 'upgb-ggb-brkgb-pragati', joining: 0, annual: 250, waiver: 25000, core: 1, forex: 3.5, pv: 0.25,
    pvBasis: 'Pragati product page: "cashback @ 1 reward point = ₹0.25". Page text is undated.',
    network: null, upi: true, addons: 3,
    accel: [['dept-store-5rp', 'all_retail', 'all', 5, 'departmental stores (MCC 5311)', { mcc_list: [5311] }], ['movies-5rp', 'movie', 'all', 5, 'movies (MCC 7832)', { mcc_list: [7832] }]],
    capPts: 1000, accelSrc: 'FEAT 1.2 table; product page footnote ("5X Rewards are capped at 1,000 Reward Points on the mentioned categories per statement")', capCat: 'all_retail',
    open: [
      'Accelerated rewards: the page and the FEAT table (11 Nov 2026) agree: 5 points per ₹100 on departmental stores (MCC 5311) and movies (MCC 7832), one shared cap of 1,000 points a statement cycle. The cap is modelled as one cap over both categories (the documents state one figure for the product).',
      'Customers of regional rural banks only: the page says UPGB/GGB/BRKGB customers (UP, Gujarat, Rajasthan); the MITC names Pragati BGGB, BRKGB and BUPB. One fee and reward schedule is stated for all of them, so one card is drafted.',
      NET_UNKNOWN('Pragati'),
    ],
    notes: ['Co-branded with regional rural banks; the page says "the arrangements between BOBCARD and cobrand partners may involve sharing of revenue".', 'UPI transactions earn only core points, not bonus points (page).', SPECIAL_NOTE],
  }),

  // ───────────────────────────────────────────── Nainital Bank Renaissance
  'bobcard-nainital-bank-renaissance': bob({
    id: 'renaissance', name: 'Nainital Bank RENAISSANCE BOBCARD', page: 'nainital-bank-renaissance', joining: 0, annual: 250, waiver: 25000, core: 1, forex: 3.5, pv: 0.25,
    pvBasis: 'Renaissance product page: "cashback @ 1 reward point = ₹0.25". Page text is undated.',
    network: null, upi: true, addons: 3,
    accel: [['dept-store-5rp', 'all_retail', 'all', 5, 'departmental stores (MCC 5311)', { mcc_list: [5311] }], ['movies-5rp', 'movie', 'all', 5, 'movies (MCC 7832)', { mcc_list: [7832] }]],
    capPts: 1000, accelSrc: 'FEAT 1.2 table; product page footnote ("5X Rewards are capped at 1,000 Reward Points on the mentioned categories per statement")', capCat: 'all_retail',
    open: [
      'Accelerated rewards: the page and the FEAT table (11 Nov 2026) agree: 5 points per ₹100 on departmental stores (MCC 5311) and movies (MCC 7832), one shared cap of 1,000 points a statement cycle, modelled as one cap over both categories.',
      NET_UNKNOWN('Renaissance'),
    ],
    notes: ['For Nainital Bank customers (page).', 'UPI transactions earn only core points, not bonus points (page).', SPECIAL_NOTE],
  }),

  // ───────────────────────────────────────────── Yoddha, Rakshamah, Sentinel
  'bobcard-indian-army-yoddha': force({ id: 'yoddha', name: 'Indian Army YODDHA BOBCARD', page: 'indian-army-yoddha' }),
  'bobcard-indian-coast-guard-rakshamah': force({ id: 'rakshamah', name: 'Indian Coast Guard RAKSHAMAH BOBCARD', page: 'indian-coast-guard-rakshamah' }),
  'bobcard-assam-rifles-the-sentinel': force({ id: 'sentinel', name: 'Assam Rifles The SENTINEL BOBCARD', page: 'assam-rifles-the-sentinel' }),

  // ───────────────────────────────────────────── Navy Varunah Premium
  'bobcard-indian-navy-varunah-premium': bob({
    id: 'varunah', name: 'Indian Navy VARUNAH BOBCARD (Varunah Premium)', page: 'indian-navy-varunah', joining: 2499, annual: 2499, waiver: 150000, core: 3, forex: 2, pv: 0.25,
    pvBasis: 'Varunah product page: "cashback @ 1 reward point = ₹0.25". Page text is undated.',
    network: null, upi: false, addons: 3,
    accel: [
      ['international-15rp', 'international_spend', 'all', 15, 'international spends', { transaction_type: 'international' }],
      ['dining-15rp', 'dining', 'all', 15, 'dining (MCC 5812)', { mcc_list: [5812] }],
      ['travel-15rp', 'travel', 'all', 15, 'travel (MCC 4722)', { mcc_list: [4722] }],
      ['online-15rp', 'online', 'online', 15, 'online spends (online flag from the acquirer)', { transaction_type: 'ecom' }],
    ],
    capPts: 2500, capCat: 'all_retail', accelSrc: 'Varunah page footnote (cap 2,500 points a statement cycle, then 3 points per ₹100) and FEAT 1.2 (2,500); the MITC of 7 Oct 2026 still shows 5,000 and is superseded by the later FEAT and the page',
    welcome: '500 bonus reward points on spends of ₹5,000 or more within 60 days of card issuance (page). Joining fee ₹2,499 is charged in the first statement and reversed on spends of ₹25,000 within 180 days (MITC).',
    benefits: [
      B({ id: 'varunah-lounge', cat: 'lounge', sponsor: 'BOBCARD', label: 'Unlimited domestic airport lounge access', cond: { min_net_spend_previous_calendar_quarter_inr: 75000, note: 'INR 40,000 until 30 Sep 2026 for Varunah Premium (REV2), INR 75,000 from 1 Oct 2026 (FEAT table)' }, qty: null, per: 'quarter' }),
      B({ id: 'varunah-prime', cat: 'other', sponsor: 'BOBCARD', label: '12 months Amazon Prime membership on spends of ₹1 lakh within 90 days of issue (page)', cond: { spend_inr: 100000, within_days: 90 } }),
      B({ id: 'varunah-fitpass', cat: 'health', sponsor: 'BOBCARD', label: 'Complimentary 12 months FITPASS PRO membership as a welcome gift (page)' }),
    ],
    insurance: [
      { cover_type: 'other', coverage_inr: 10000000, coverage_usd: 'N/A', claim_condition: 'Personal accidental death cover, air accident ₹1 crore (product page).', effective_from: null, effective_to: null },
      { cover_type: 'other', coverage_inr: 1000000, coverage_usd: 'N/A', claim_condition: 'Personal accidental death cover, non-air accident including sea ₹10 lakh (product page).', effective_from: null, effective_to: null },
    ],
    open: [
      'Scope: the page and the Navy hub entry show Varunah Premium. The MITC also lists "Varunah" (1 point per ₹100, no fee, fuel waiver capped at ₹100) and "Varunah Plus" (joining and annual fee ₹1,499, 2 points per ₹100, ₹1.5 lakh waiver) as fee tiers. Only Premium is drafted; Plus and base Varunah are not on the product page and are not drafted.',
      'Accelerated cap: the MITC (7 Oct 2026) says 5,000 points a statement cycle for Varunah Premium; the page and the later FEAT (11 Nov 2026) say 2,500. 2,500 is used.',
      NET_UNKNOWN('Varunah Premium'),
    ],
    notes: ['Exclusively for Indian Navy personnel (page).', SPECIAL_NOTE],
  }),

  // ───────────────────────────────────────────── Micro Enterprise
  'bobcard-micro-enterprise': bob({
    id: 'micro', name: 'BOBCARD Micro Enterprise Credit Card', page: 'micro-enterprise-credit-card', joining: 0, annual: 500, waiver: 50000, core: 1, forex: 3.5, pv: 0.25,
    pvBasis: 'Micro Enterprise page: "Cashback – 1 RP = ₹0.25" and "Pay with Rewards – 1 RP = ₹0.15". Page text is undated.',
    network: 'rupay', upi: true, apr: [1.5, 18], accel: [], addons: null,
    surchargeOpts: { skip: ['wallet6539'] },
    welcome: null,
    open: [
      'Joining fee: the page says "₹500 Joining Fee (Waived as service gesture)" and the MITC says joining fee not applicable; 0 is used. The page also states a Credit Guarantee Fund Trust (CGTMSE) fee of 0.55% of the sanctioned credit limit, in the MITC and KFS as well; it is not modelled as a surcharge because it is a fee on the limit, not on spends.',
      'Wallet loads are not allowed on this card (MITC), so the wallet surcharge row is dropped.',
      'Network (RuPay): the card image on the Micro Enterprise page (bobcard-micro-enterprise.webp, opened and read) shows the RuPay Credit wordmark; no BOBCARD document names the network in words.',
      'Eligibility: the application must start from the Government of India Jan Samarth portal; the card is for registered micro enterprises (page).',
    ],
    notes: ['Finance charge 1.5% a month (18% a year) for this card (MITC, KFS, page).', 'Cash withdrawal: MITC "All other cards" row applies (2.5% or ₹500).', SPECIAL_NOTE],
  }),

  // ───────────────────────────────────────────── PM SVANidhi
  'bobcard-pm-svanidhi': bob({
    id: 'svanidhi', name: 'PM SVANidhi BOBCARD', page: 'pm-svanidhi', joining: 0, annual: 0, waiver: null, core: 1, forex: null, pv: 0.2,
    pvBasis: 'PM SVANidhi product page: "cashback @ 1 reward point = ₹0.20". Page text is undated.',
    network: null, upi: true, accel: [], addons: null, welcome: null,
    open: [
      'Rewards: the page says 1 reward point per ₹100 on eligible spends, not on select MCCs or fuel; the FEAT core table does not list this card. The Annexure 1 and fuel exclusions are applied from the generic FEAT text.',
      'Forex mark-up: international transactions and cash withdrawals are not allowed on this card (page), so the forex markup is null. Interest, cash-advance and overlimit figures here are the MITC "all other cards" rows and are shown for completeness only.',
      NET_UNKNOWN('PM SVANidhi BOBCARD'),
      'Eligibility: street vendors registered under the PM SVANidhi scheme who repaid their loans; application starts on the PM SVANidhi portal; starting credit limit ₹10,000; up to 51 interest-free days (page).',
    ],
    notes: ['Reward value for this card is ₹0.20 a point (page), different from the ₹0.25 shown on most other BOBCARD pages.', SPECIAL_NOTE],
  }),

  // ───────────────────────────────────────────── Cashback
  'bobcard-cashback': (() => {
    const id = 'cashback';
    const base = bob({
      id, name: 'BOBCARD Cashback', page: 'bobcard-cashback', joining: 499, annual: 499, waiver: null, core: 0, forex: 3.5, pv: null, accel: [], addons: 3, network: 'mastercard', upi: true, expiry: null, welcome: null,
      netOpen: 'Network (Mastercard): the Cashback page sentence "Add your Mastercard BOBCARD Cashback Credit Card to Google Pay" names the network; no tier is stated.',
      open: [
        'Fee plan: the cardholder picks either ₹49 a month or ₹499 a year; the fee plan can be changed once in the card life (page). The draft records ₹499 as joining and annual fee; the ₹49 monthly option is not modelled.',
        'Accelerated cashback cap: the page says "up to ₹1500/month"; the FEAT cashback table (11 Nov 2026) says "Max. Rs. 1,500 per statement". The statement-cycle cap from FEAT is used.',
        'Rail: the 4% accelerated cashback is for "Domestic Ecom transactions"; credit card on UPI is excluded from accelerated rewards in the generic FEAT rule but the cashback section does not repeat it. Not modelled either way.',
      ],
      notes: ['Existing BOBCARD variants cannot be upgraded to Cashback or the other way round, and the card cannot be an add-on card (page).', 'Cashback is posted automatically to the next statement; cashback on reversed transactions is reversed (FEAT section 2).', SPECIAL_NOTE],
    });
    base.reward_rules = [
      X('cashback-excl-annexure1', 'excluded_spend', ANNEX1, 'Annexure 1 merchant categories earn no cashback (FEAT section 2).'),
      X('cashback-excl-fuel', 'fuel', FUEL_MCC, 'Fuel transactions earn no cashback (FEAT section 2). Fuel MCCs taken from the MITC fuel processing-fee row.'),
      X('cashback-excl-cash', 'cash_withdrawal', [], 'ATM cash withdrawals and quasi-cash transactions earn no cashback (FEAT section 2).', { transaction_type: 'cash_or_quasi_cash' }),
      R({ id: 'cashback-ecom-4pct', cat: 'online', channel: 'online', pri: 10, cb: 4, mult: 1, cap: 'cashback-accel-cap', cond: { transaction_type: 'ecom', domestic: true, minimum_transactions_in_cycle: 4 }, reason: 'Accelerated 4% cashback on domestic e-commerce transactions (total 5% with the 1% base) when the cardholder makes at least 4 transactions in the statement cycle; capped at ₹1,500 a statement cycle (FEAT section 2).' }),
      R({ id: 'cashback-base-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { minimum_transaction_inr: 100 }, reason: '1% cashback on domestic POS, international and domestic e-commerce transactions; transactions below ₹100 earn nothing (FEAT section 2).' }),
    ];
    base.cap_rules = [C({ id: 'cashback-accel-cap', cat: 'online', metric: 'bonus_reward_points', period: 'statement_cycle', inr: 1500, after: 'downgrade_to_base_rate' })];
    base.accrual_engine = { base_block_inr: null, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: null };
    base.card_product.point_value_inr_baseline = 'N/A';
    base.card_product.point_value_baseline_basis = 'N/A';
    base.card_product.point_expiry_months = 'N/A';
    base.fee_waiver_and_milestones.annual_fee_waiver = { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No spend-based waiver: ₹499 a year or ₹49 a month, no waiver (MITC "spend based waiver not applicable").', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' };
    base.fee_waiver_and_milestones.welcome_and_renewal_gift = { trigger: null, benefit_points: null, effective_value_inr: null, condition: null };
    base.redemption_matrix = { direct_options: [], partner_transfers: [] };
    return base;
  })(),

  // ───────────────────────────────────────────── Etihad Guest and Etihad Guest Premium
  ...(() => {
    const etihad = (o) => {
      const b = bob({
        id: o.id, name: o.name, page: o.page, joining: o.fee, annual: o.fee, waiver: o.waiver, core: o.other, forex: o.forex, pv: null, expiry: null, network: null, upi: false, accel: [], addons: null, welcome: null,
        forms: o.forms || [], fuelMin: 500, fuelCap: 250,
        extraSources: [
          { url: EKFS, kind: 'Etihad Guest and Guest Premium MITC and KFS (PDF created 22 Jun 2026, ETIHAD MITC 2.0 APR 2026)', read: 'pdftotext, raw mode' },
          { url: EREV, kind: 'Revision in Etihad features w.e.f. 5 Aug 2026 (gold tier criterion)', read: 'pdftotext' },
          { url: MEDIA + '1funxwuy/miles-offer-tnc-003.pdf', kind: 'Etihad additional miles campaign T&C, 1 Aug to 30 Sep 2026 (expired; not modelled)', read: 'pdftotext' },
          { url: ELOUNGE, kind: 'Global airport lounge list for the Etihad cards', read: 'pdftotext' },
        ],
        open: [
          NET_UNKNOWN(o.name).replace('contactless symbol (orange and green chevron)', 'contactless symbol only'),
          'Miles: the issuer states no rupee value for an Etihad Guest mile and the miles are redeemed only on the Etihad platform, so point_value_inr_baseline is null and no effective return is computed.',
          ...o.open,
        ],
        notes: ['Miles are credited to the cardholder\'s Etihad Guest account; the validity of the miles follows the Etihad Guest tier; miles are redeemable only on Etihad (MITC D.3).', 'Linking the Etihad Guest membership number is the cardholder\'s responsibility and cannot be changed (MITC D.2).', 'Cash withdrawal limit for Etihad Guest is 30% of available limit (MITC).', SPECIAL_NOTE],
      });
      b.accrual_engine = { base_block_inr: 100, rounding_mode: null, base_points_per_block: o.other, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null };
      b.reward_rules = [
        X(`${o.id}-excl-annexure`, 'excluded_spend', [763, 780, 820, 821, 822, 823, 824, 825, 1520, 1711, 1731, 1740, 1750, 1761, 1771, 1799, 4111, 4112, 4131, 4784, 4789, 4814, 6513, 7349, 7211, 7230, 7276, 8111, 8641, 9211, 9222, 9311, 9399, 9402, 9405, 8211, 8220, 8241, 8244, 8249, 8299, 8011, 8062, 6539, 6541, 6542, 6543, 5960, 6300, 8398, 8661], 'Special merchant categories earn no base miles (MITC section D, exclusion list; this list differs from the points-card Annexure 1: it adds telecom 4814 and omits supermarkets, fast food and wallet MCC 6540).'),
        X(`${o.id}-excl-fuel`, 'fuel', FUEL_MCC, 'Fuel transactions earn no reward points (product page note "No Cashback/Reward Points are earned on fuel transactions"). Fuel MCCs from the MITC fuel processing-fee row.'),
        R({ id: `${o.id}-etihad-airways`, cat: 'travel', pri: 10, ppb: o.etihad, mult: o.etihad / o.other, cond: { per_inr_block: 100, merchant: 'Etihad Airways' }, reason: `${o.etihad} Etihad Guest Miles per ₹100 on Etihad Airways spends (product page; the Aug-Sep 2026 double-miles campaign is expired and not modelled).` }),
        R({ id: `${o.id}-other`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: o.other, mult: 1, cond: { per_inr_block: 100 }, reason: `${o.other} Etihad Guest Miles per ₹100 on every other domestic and cross-border spend (product page).` }),
      ];
      b.fee_waiver_and_milestones.annual_fee_waiver = { threshold_spend_inr: o.waiver, period: 'card_anniversary_year', evaluation_condition: `Joining and annual fee ₹${o.fee.toLocaleString('en-IN')} + GST; the annual fee is waived on spends of ₹${o.waiver.toLocaleString('en-IN')} in the card anniversary year. The joining fee is charged on the issuance date and is not reversed (MITC, KFS, page FAQ).`, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: o.fee };
      b.fee_waiver_and_milestones.welcome_and_renewal_gift = { trigger: 'card_issuance', benefit_points: o.welcomeMiles, effective_value_inr: null, condition: o.welcomeText };
      b.fee_waiver_and_milestones.spend_milestones = o.milestones;
      b.fees_and_surcharges.cash_advance.max_limit_percent = 30;
      b.statement_and_late_fees.grace_period_days = 50;
      b.lifestyle_and_network_benefits = o.benefits;
      b.redemption_matrix = { direct_options: [], partner_transfers: [] };
      return b;
    };
    const ms = (id, label, thr, miles, period) => ({ id, label, threshold_spend_inr: thr, reward_value_inr: null, period, is_repeatable: true, effective_from: null, effective_to: null });
    return {
      'bobcard-etihad-guest-premium': etihad({
        id: 'etihadprem', name: 'BOBCARD Etihad Guest Premium', page: 'bobcard-etihad-guest-premium', fee: 5000, waiver: 500000, forex: 0, etihad: 6, other: 2, forms: ['physical_metal'],
        welcomeMiles: 15000, welcomeText: 'Page: 15,000 Etihad Guest bonus miles: 10,000 welcome miles on ₹50,000 spent within 65 days of issue and payment of the joining fee, plus 5,000 miles on cumulative spends of ₹1,00,000. The MITC (7 Oct 2026) and the Etihad KFS (22 Jun 2026) say 5,000 miles on ₹25,000 within 60 days.',
        milestones: [ms('etihadprem-monthly', 'Bonus 500 miles on any 4 transactions totalling ₹50,000, once per month (page) or per billing cycle (MITC)', 50000, 500, 'statement_cycle'), ms('etihadprem-quarterly', 'Bonus 4,000 miles on ₹3,00,000 spends in a calendar quarter', 300000, 4000, 'quarter'), ms('etihadprem-annual', 'Bonus 24,000 miles on ₹12,00,000 spends in an anniversary year (MITC; the page tile shows 24,000 annual miles)', 1200000, 24000, 'card_anniversary_year')],
        benefits: [
          B({ id: 'etihadprem-lounge', cat: 'lounge', sponsor: 'BOBCARD', label: 'Domestic lounge access, 3 per quarter, and international lounge access, 2 per quarter, no spend criteria (MITC D.5; page: 12 domestic and 8 international a year)', qty: 5, per: 'quarter' }),
          B({ id: 'etihadprem-tier', cat: 'other', sponsor: 'Etihad Guest', label: 'Complimentary Etihad Guest Gold tier on a single ₹10,000 or higher transaction on Etihad.com within 6 months of issue (from 5 Aug 2026, EREV); tier lasts one year (MITC)' }),
        ],
        open: ['Welcome miles conflict: the page (undated, live) says 15,000 miles (10,000 on ₹50,000 within 65 days plus 5,000 on ₹1,00,000); the MITC and KFS say 5,000 miles on ₹25,000 within 60 days. The page figure is used for the welcome gift; a person should confirm which is current.', 'Monthly bonus: the page says "once per month", the MITC says "once per billing cycle"; statement_cycle is used.', 'Tier benefits listed on the page ("Complimentary Etihad Guest Tier Benefits") were truncated behind "Read more"; only the Gold upgrade rule from EREV is recorded.'],
      }),
      'bobcard-etihad-guest': etihad({
        id: 'etihad', name: 'BOBCARD Etihad Guest', page: 'bobcard-etihad-guest', fee: 2500, waiver: 300000, forex: 1, etihad: 3, other: 1,
        welcomeMiles: 7500, welcomeText: 'Page: 7,500 Etihad Guest bonus miles: 5,000 joining miles on ₹25,000 spent within 65 days of issue and payment of the joining fee, plus 2,500 miles on cumulative spends of ₹50,000. The MITC (7 Oct 2026) and the Etihad KFS say 2,500 miles on ₹10,000 within 60 days.',
        milestones: [ms('etihad-monthly', 'Bonus 250 miles on any 4 transactions totalling ₹25,000, once per month (page) or per billing cycle (MITC)', 25000, 250, 'statement_cycle'), ms('etihad-quarterly', 'Bonus 2,000 miles on ₹2,00,000 spends in a calendar quarter', 200000, 2000, 'quarter'), ms('etihad-annual', 'Bonus 12,000 miles on ₹7,50,000 spends in an anniversary year (MITC; the page tile shows 12,000 annual miles)', 750000, 12000, 'card_anniversary_year')],
        benefits: [B({ id: 'etihad-lounge', cat: 'lounge', sponsor: 'BOBCARD', label: 'Domestic lounge access, 2 per quarter, and international lounge access, 1 per quarter, no spend criteria (MITC D.5; page: 8 domestic and 4 international a year)', qty: 3, per: 'quarter' })],
        open: ['Welcome miles conflict: the page (undated, live) says 7,500 miles (5,000 on ₹25,000 within 65 days plus 2,500 on ₹50,000); the MITC and KFS say 2,500 miles on ₹10,000 within 60 days. The page figure is used; a person should confirm which is current.', 'Monthly bonus: "once per month" on the page, "once per billing cycle" in the MITC; statement_cycle is used.'],
      }),
    };
  })(),

  // ───────────────────────────────────────────── Uni GoldX
  'bobcard-uni-goldx': (() => {
    const b = bob({
      id: 'goldx', name: 'BOBCARD Uni GoldX', page: 'bobcard-uni-goldx', joining: 0, annual: 0, waiver: null, core: 1, forex: 0, pv: 0.01, expiry: 0, apr: [3.99, 47.88], accel: [], addons: null, welcome: null, upi: true,
      pvBasis: 'MITC section B: "1 Uni Coin on every purchase of ₹1. Each Uni Coin is valued at one paisa." Uni Coins do not expire except after 365 days of card inactivity.',
      fuelMin: 0, fuelCap: 500,
      dual: {
        sourceUrl: UKFS,
        evidence: 'Uni GoldX KFS (PDF created 23 Oct 2026): "The RuPay variant is a virtual-only card that shares its credit limit with the Visa variant"; MITC section B(k): GoldX RuPay variant is a virtual credit card issued as an additional card sharing the limit of the "Primary VISA Affiliated credit card", usable only for UPI and e-commerce.',
        variants: [
          { network: 'visa', network_tier: 'N/A', label: 'BOBCARD Uni GoldX (Visa, primary card)', source_url: UKFS, evidence: 'UKFS and MITC B(k) call the primary card the Visa variant.' },
          { network: 'rupay', network_tier: 'N/A', label: 'BOBCARD Uni GoldX UPI (RuPay, virtual, shares the Visa limit)', source_url: UKFS, evidence: 'UKFS Other Info: RuPay variant is virtual only, for e-commerce and UPI.' },
        ],
      },
      extraSources: [{ url: UKFS, kind: 'BOBCARD Uni GoldX Key Fact Statement (PDF created 23 Oct 2026): fees, 1% rewards, networks', read: 'pdftotext' }],
      netOpen: 'Network: two networks on one credit account: Visa primary card and a virtual RuPay UPI variant sharing the limit (UKFS, MITC B(k)). Recorded with dualNetwork.',
      open: [
        'Uni Store 5% value back: the page and FAQ say 5% value back in Uni Coins when buying vouchers at the Uni Store; no BOBCARD document states its terms, cap or eligible vouchers, so it is not modelled as a reward rule.',
        'MITC says 1 Uni Coin per ₹1, i.e. 1% value back, on all eligible spends; the KFS repeats it as "1% of transaction value ... subject to changes, revision, limits and exclusion". UPI transactions below ₹100 on the GoldX UPI card earn nothing (KFS, MITC).',
        'Fee note: Uni GoldX has a separate rent processing fee of 1.25% or ₹100 minimum, a card replacement fee of ₹100 and different overlimit and cash-advance minimums (₹300) in the MITC/KFS; the generic rows below were replaced where the MITC differs, others are not modelled.',
      ],
      notes: ['Co-branded with Uniorbit Platform Services Private Limited; Uni Coins are credited to the cardholder\'s Uni account and redeemed in the Uni App (MITC B).', 'Interest-free period up to 50 days including 3 days of grace; add-on cards are not available (MITC).', SPECIAL_NOTE],
    });
    b.reward_rules = [
      X('goldx-excl-categories', 'excluded_spend', [4829, 6513, 5541, 5542, 5983, 6540, 4812, 4814, 4815, 4816, 4821, 4899, 4900, 9034, 9211, 9222, 9223, 9311, 9399, 9402, 9405, 9700, 9701, 9702, 9751, 9754, 9950, 8299, 8211, 8241, 8244, 8249, 8220, 4784], 'No Uni Coins on money transfers, rent, fuel, wallet loads, utilities, government services, education or tolls (MITC B(b)). Cash withdrawals, EMI and international transactions also earn nothing.'),
      X('goldx-excl-international', 'international_spend', [], 'International transactions earn no Uni Coins (MITC B(b)).', { transaction_type: 'international' }),
      R({ id: 'goldx-transport-1pct-capped', cat: 'travel', pri: 20, ppb: 1, mult: 1, cap: 'goldx-transport-cap', cond: { per_inr_block: 1, mcc_list: [4111, 4112, 4131] }, reason: 'Uni Coins on transportation, passenger railways and bus lines (MCC 4111, 4112, 4131) apply up to ₹20,000 of monthly spends (MITC B(b)).' }),
      R({ id: 'goldx-insurance-1pct-capped', cat: 'insurance', pri: 20, ppb: 1, mult: 1, cap: 'goldx-insurance-cap', cond: { per_inr_block: 1, mcc_list: [6300, 5960] }, reason: 'Uni Coins on insurance (MCC 6300, 5960) apply up to ₹50,000 of monthly spends (MITC B(b)).' }),
      R({ id: 'goldx-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 1 }, reason: '1 Uni Coin per ₹1 on eligible spends; each Uni Coin is worth one paisa, so 1% (MITC B(b)).' }),
    ];
    b.cap_rules = [
      C({ id: 'goldx-transport-cap', cat: 'travel', metric: 'eligible_spend_amount', period: 'calendar_month', inr: 20000, mccs: [4111, 4112, 4131], after: 'zero_accrual' }),
      C({ id: 'goldx-insurance-cap', cat: 'insurance', metric: 'eligible_spend_amount', period: 'calendar_month', inr: 50000, mccs: [6300, 5960], after: 'zero_accrual' }),
    ];
    b.accrual_engine = { base_block_inr: 1, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: null };
    b.fees_and_surcharges.cash_advance = { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 300, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 30 };
    b.fees_and_surcharges.fuel_surcharge = { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 7500, monthly_waiver_cap_inr: 500 };
    b.fees_and_surcharges.banking_penalties = { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 300, gst_applicable: true }, auto_debit_bounce_charge_inr: 'N/A', cheque_bounce_charge_inr: 350 };
    b.fees_and_surcharges.category_surcharges = [
      { category_id: 'rent', mcc_list: [6513], fee_percent: 1.25, gst_applicable: true, trigger_condition: '1.25% of the rent payment or ₹100, whichever is higher (KFS, MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
      { category_id: 'fuel', mcc_list: FUEL_MCC, fee_percent: 1, gst_applicable: true, trigger_condition: '1% on fuel transactions of ₹10,000 or above (KFS)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
      { category_id: 'education', mcc_list: [8299, 8211, 8241, 8244, 8249, 8220], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on education payments through third-party apps such as CRED, PhonePe, Amazon Pay (KFS)', threshold_spend_inr: null, effective_from: null, effective_to: null },
      { category_id: 'bills', mcc_list: [4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% (maximum ₹3,000) on utility transactions of ₹50,000 or above (KFS)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
    ];
    b.addon_card_rules = { ...addonDefault, max_addon_cards: 0, fee_per_card_inr: 'N/A' };
    b.redemption_matrix = { direct_options: [{ channel: 'Uni App Rewards Store (MITC B(c))', redemption_type: 'partner_catalogue', inr_value_per_point: 0.01, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: null, cycle_points_burn_cap: 'N/A', redemption_fee_inr: 0, effective_from: null, effective_to: null }], partner_transfers: [] };
    return b;
  })(),
};

// ───────────────────────────────────────────────────────────── Canara Bank secured cards (FD-backed)
// Pages read 2026-11-15 (plain fetch): https://www.canarabank.bank.in/<slug> ; each page has benefits, features, eligibility and fee tabs in one HTML.
// The Canara MITC PDF linked from the pages (MOST IMPORTANT TERMS AND CONDITIONS 1812023001.pdf, file name dated 18 Dec 2023) now returns HTTP 404, so the pages are the only source.
const CP = (s) => `https://www.canarabank.bank.in/${s}`;
const canara = (o) => ({
  card_product: {
    ...GST, name: o.name, issuer_slug: 'canara-bank', card_type: 'credit', network: o.network, network_tier: null, card_tier: null, application_mode: 'open',
    joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: false, form_factors: [], data_source_tier: 'issuer_page', source_url: CP(o.page), status: 'draft', verified_at: null,
    point_value_inr_baseline: o.pv ?? null, point_value_baseline_basis: o.pvBasis ?? null, point_expiry_months: null,
  },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.elig, rules: [], required_documents: [] },
  accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: o.pv ? 2 * o.pv : null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  reward_rules: [R({ id: `${o.id}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 points per ₹100 on every POS and e-commerce spend (Features table on the card page). No category exclusions, accelerators or caps are stated on the page.' })],
  cap_rules: [],
  fees_and_surcharges: {
    apr: { monthly_interest_rate_percent: o.apr?.[0] ?? null, annual_interest_rate_percent: o.apr?.[1] ?? null },
    forex_markup: { markup_percent: 3, gst_applicable: true },
    dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: null },
    fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: null, monthly_waiver_cap_inr: 100 },
    cash_advance: { atm_transaction_fee_percent: 3, atm_transaction_fee_min_inr: 150, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 50 },
    category_surcharges: [{ category_id: 'travel', mcc_list: [4112], fee_percent: 1, gst_applicable: true, trigger_condition: 'Railway tickets on www.irctc.co.in: 1% of the transaction amount; at railway counters ₹30 + 2.5% of the transaction amount (Fee and Charges tab)', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 100, foreclosure_charge_percent: 2, gst_applicable: true },
    banking_penalties: { overlimit_charge: { fee_percent: null, min_fee_inr: null, gst_applicable: null }, auto_debit_bounce_charge_inr: 50, cheque_bounce_charge_inr: 50 },
    reward_redemption_fee: { fee_inr: null, gst_applicable: null },
  },
  statement_and_late_fees: { grace_period_days: 50, grace_period_void_on_revolving_balance: null, minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['5% of total outstanding (minimum ₹100)', 'all applicable charges, fees and taxes', 'EMI amount', 'over-limit amount'] }, late_payment_slabs: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 250 }] },
  fee_waiver_and_milestones: {
    annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Enrolment, joining and annual fees are nil (Fee and Charges tab).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
    welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
    spend_milestones: [],
  },
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
  lifestyle_and_network_benefits: o.benefits || [],
  insurance_and_protection: o.insurance,
  dynamic_promotions_registry: [],
  redemption_matrix: { direct_options: [{ channel: 'Canara Rewardz: cashback or goods purchase (canararewardz.com)', redemption_type: 'cashback', inr_value_per_point: o.pv ?? null, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: null, cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: null, effective_to: null }], partner_transfers: [] },
  additional_data: { items: prov({
    sources: [
      { url: CP(o.page), kind: `Canara Bank ${o.name} page (Benefits, Features, Eligibility, Fee and Charges tabs, plain fetch 2026-11-15)`, read: 'page text' },
      { url: 'https://www.canararewardz.com/', kind: 'Canara Rewardz home page (redemption site named by the card pages): states no point value', read: 'page text' },
    ],
    unverified: [
      `Network (${o.network}): stated by the card name and the Features table heading "${o.featHead}" on the Canara page; no tier is stated.`,
      o.pv ? `Point value: ₹0.25 a point is stated for this card on its page ("Value of each point is ₹. 0.25/-", Reward Points from M/s Loyalty Rewards).` : 'Point value: the page says points redeem for "Cashback or Goods Purchase through canararewardz.com" but states no rupee value for a point, and the Canara Rewardz home page states none. point_value_inr_baseline is null. A person should confirm from the Canara Rewardz catalogue or the Canara reward-points circular.',
      o.aprOpen,
      'Fee text on the page is shared across the Canara credit-card tabs: the Features table, eligibility block (credit limit as a share of the FD) and the Fee and Charges block are repeated for the secured and unsecured variants, and the eligible limit is stated as both 75% and 100% of the FD on the same page. Joining, enrolment and annual fees are "Nil" in the secured Features table itself, which is what is used; the limit rule is left as an open question.',
      'Fuel surcharge: the page says 1% (minimum ₹10) is charged and "maximum of ₹100 for the billing month would be reimbursed" if the card is used for at least ₹2,500 of purchases that month and each fuel purchase is at least ₹400; modelled as a 1% waiver with a ₹100 monthly cap and ₹400 minimum.',
      'Forex: the page says "Upto 3% of transaction amount" and 3% is used. Cash withdrawal at Canara ATMs 3% with a ₹150 minimum (Fee and Charges tab); Features tab says ₹30 per ₹1,000.',
      'The Canara MITC PDF linked from the page (file dated 18 Dec 2023 in its name) returned HTTP 404 on 2026-11-15, so no MITC was read.',
      'Inactivity fee when the annual turnover is below the stated threshold: ' + o.inactivity,
      o.extraOpen,
    ].filter(Boolean),
    notes: ['FD-backed secured card issued against deposits in the applicant\'s name (joint deposits with "Either or Survivor" accepted; add-on cards to other joint depositors).', 'Late payment fee ₹250 + GST, in addition to finance charges on the carried-over balance (Fee and Charges tab).', 'Insurance: personal accident cover for self and spouse; baggage cover and purchase protection up to ₹25,000 (Features table).'],
    extra: FETCHED,
  }) },
});

const cover = (airSelf, airSp, otherSelf, otherSp) => [
  { cover_type: 'other', coverage_inr: airSelf, coverage_usd: 'N/A', claim_condition: `Death due to air accident: ₹${airSelf.toLocaleString('en-IN')} for the cardholder, ₹${airSp.toLocaleString('en-IN')} for the spouse (Features table).`, effective_from: null, effective_to: null },
  { cover_type: 'other', coverage_inr: otherSelf, coverage_usd: 'N/A', claim_condition: `Death due to accident other than air: ₹${otherSelf.toLocaleString('en-IN')} for the cardholder, ₹${otherSp.toLocaleString('en-IN')} for the spouse (Features table).`, effective_from: null, effective_to: null },
];

Object.assign(cards, {
  'canara-rupay-select-secured-credit-card': canara({
    id: 'canara-select-sec', name: 'Canara RuPay Select Secured Credit Card', page: 'rupay-select-secured-credit-card', network: 'rupay', featHead: 'Rupay Select Secured Credit Card',
    pv: 0.25, pvBasis: 'Select Features table, "Reward Points from M/s Loyalty Rewards: 2 points for every ₹100/- transaction ... Value of each point is ₹. 0.25/-". Page text is undated.',
    elig: 'FD-backed; the page states the eligible limit as up to 100% of the FD with a ₹1,00,000 minimum (Eligibility tab) and as up to 75% with a ₹25,000 minimum (a repeated block); credit limit range ₹1 lakh to ₹50 lakh (Features).',
    insurance: cover(800000, 400000, 400000, 200000), aprOpen: 'Finance charge: the Select page gives 2.50% a month (30% a year) for "all other credit cards" and no separate secured-card rate, so interest is null here.',
    inactivity: '₹300 a year if turnover is below ₹1,00,000 (Fee and Charges tab).',
    extraOpen: 'The Select page also lists RuPay network benefits for the "RuPay Select Individual Credit Card" (₹10 lakh RuPay insurance, 5% cashback on utilities and restaurants capped at ₹50 a month each, lounge access 2 a quarter domestic and 2 a year international); those are NPCI programme features stated for the unsecured card and are not copied. The secured Benefits list shows domestic lounge 2 per quarter and international 2 per year for self.',
    benefits: [B({ id: 'canara-select-sec-lounge-dom', cat: 'lounge', sponsor: 'Canara Bank', label: 'Domestic airport lounge access, 2 per quarter for self (Benefits list)', qty: 2, per: 'quarter' }), B({ id: 'canara-select-sec-lounge-intl', cat: 'lounge', sponsor: 'Canara Bank', label: 'International airport lounge access, 2 per year for self (Benefits list)', qty: 2, per: 'annual' })],
  }),
  'canara-rupay-platinum-secured-credit-card': canara({
    id: 'canara-plat-sec', name: 'Canara RuPay Platinum Secured Credit Card', page: 'rupay-platinum-secured-credit-card', network: 'rupay', featHead: 'RuPay Platinum Secured Credit Card',
    pv: null, elig: 'FD-backed; eligible limit up to 75% of the FD, minimum card limit ₹25,000 (Eligibility tab); maximum limit per month ₹50,00,000 and minimum ₹50,000 (Features).',
    insurance: cover(800000, 400000, 400000, 200000), aprOpen: 'Finance charge: the Features table says 2.5% a month (30% a year) "for Unsecured Credit Cards" and the fee block says "for all other credit cards"; no secured-card rate is stated, so interest is null.',
    inactivity: '₹200 a year if turnover is below ₹50,000 (Fee and Charges tab).',
    extraOpen: 'Lounge: domestic 2 per quarter with a maximum of 4 a year, international nil (Benefits list).',
    benefits: [B({ id: 'canara-plat-sec-lounge', cat: 'lounge', sponsor: 'Canara Bank', label: 'Domestic airport lounge access, 2 per quarter and a maximum of 4 per year; no international access (Benefits list)', qty: 2, per: 'quarter' })],
  }),
  'canara-mastercard-gold-secured-credit-card': canara({
    id: 'canara-mcgold-sec', name: 'Canara Mastercard Gold Secured Credit Card', page: 'mastercard-gold-secured-credit-card', network: 'mastercard', featHead: 'Mastercard Gold Secured Credit Card',
    pv: null, elig: 'FD-backed; eligible limit up to 75% of the FD, minimum card limit ₹25,000 (Eligibility tab); maximum credit limit ₹25,00,000 (Features).',
    insurance: cover(800000, 400000, 400000, 200000), aprOpen: 'Finance charge: the Features table says 2.5% a month (30% a year) "for Unsecured Credit Cards" and the fee block says "for all other credit cards"; no secured-card rate is stated, so interest is null.',
    inactivity: '₹150 a year if turnover is below ₹25,000 (Fee and Charges tab); the Features table header says "if annual turnover of Rs.12,000 is not met", which conflicts with ₹25,000 and is left as an open question.',
    extraOpen: 'Lounge: "Available at selected lounges" with no quota stated (Features table).',
    benefits: [],
  }),
  'canara-visa-gold-secured-credit-card': canara({
    id: 'canara-visagold-sec', name: 'Canara Visa Gold Secured Credit Card', page: 'visa-gold-secured-credit-card', network: 'visa', featHead: 'VISA Gold Secured Credit Card',
    pv: null, apr: [2, 24], elig: 'FD-backed; the page states the eligible limit as up to 100% of the FD and, in a repeated block, as up to 75%; minimum card limit ₹25,000; maximum credit limit ₹25,00,000 (Features).',
    insurance: cover(400000, 200000, 200000, 100000), aprOpen: 'Finance charge: the Visa Gold Features table says 2% a month (24% a year) "for Secured Credit Cards"; the Fee and Charges tab still says 2.50% a month for "all other credit cards". The secured-card figure of 2% is used.',
    inactivity: '₹100 a year in the Features table versus ₹150 in the Fee and Charges tab (threshold ₹25,000); not modelled.',
    extraOpen: 'Lounge access: not available (Features table). The page lists a current GoIbibo offer (12% on domestic flights, 15% on hotels, 9% on buses, 10% on outstation cabs); an expired-by-default seasonal offer, not modelled.',
    benefits: [],
  }),
});

// ───────────────────────────────────────────────────────────── Kotak NRI Royale Signature (FD-backed, NRE/NRO holders)
// Pages read 2026-11-15 in the built-in browser (plain fetch returns HTTP 403):
//  https://www.kotak.bank.in/en/personal-banking/cards/credit-cards/nri-royale-signature-card.html (features), .../eligibility.html, .../fees-and-charges.html, .../reward-redemption.html
//  KMITC = https://www.kotak.bank.in/content/dam/Kotak/files/english-rcas.pdf (Kotak MITC and Cardholder Agreement, PDF created 30 Oct 2026, 74 pages, pdftotext)
const KOTAK_PAGE = 'https://www.kotak.bank.in/en/personal-banking/cards/credit-cards/nri-royale-signature-card';
const KMITC = 'https://www.kotak.bank.in/content/dam/Kotak/files/english-rcas.pdf';
Object.assign(cards, {
  'kotak-nri-royale-signature-credit-card': {
    card_product: {
      name: 'Kotak NRI Royale Signature Credit Card', issuer_slug: 'kotak-mahindra-bank', card_type: 'credit', network: null, network_tier: null, card_tier: null, application_mode: 'open',
      fee_gst_applicable: true, gst_rate_percent: null, joining_fee_inr: 0, annual_fee_inr: 1000, is_upi_linkable: false, form_factors: [],
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: KOTAK_PAGE + '.html', status: 'draft', verified_at: null,
      point_value_inr_baseline: 1, point_value_baseline_basis: 'Kotak NRI Royale Signature page, "2 Rewards on International Spends": "1 Reward Point = Re 1/-". The Reward Redemption tab states no value and links to the Kotak Rewards catalogue.', point_expiry_months: null,
    },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Eligibility tab: primary cardholder aged 21 to 60, add-on cardholder 18 or above; only NRE or NRO account holders; credit limit up to 80% of the fixed deposit; minimum FD ₹1 lakh; only individual FDs. MITC 34.2: issued against an NRE or NRO term deposit.', rules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 100000, allowed_values: [] }], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: 'N/A', effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      R({ id: 'kotak-nri-royale-international-2rp', cat: 'international_spend', pri: 10, ppb: 2, mult: 2, cond: { per_inr_block: 200, transaction_type: 'international' }, reason: 'Page: "earn 2 reward points for every Rs. 200/- spent" on spends outside India.' }),
      R({ id: 'kotak-nri-royale-domestic-1rp', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 200, transaction_type: 'domestic' }, reason: 'Page: "Earn 1 reward point for every Rs. 200/- spent within India".' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 3.5, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 3.5, gst_applicable: true, trigger_condition: 'MITC: 3.5% for all other cards on transactions in Indian currency at international locations or with foreign-registered merchants' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: 500, max_txn_inr: 5000, monthly_waiver_cap_inr: null },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
      category_surcharges: [
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction amount + GST on every rent payment (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'bills', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative utility spends above ₹50,000 per statement cycle, levied in the next cycle (MITC note 7)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
        { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative fuel spends above ₹35,000 per statement cycle, levied in the next cycle (MITC note 8)', threshold_spend_inr: 35000, effective_from: null, effective_to: null },
        { category_id: 'wallet', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative wallet loads above ₹10,000 per statement cycle (MITC)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
        { category_id: 'education', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on all education payments made through third-party apps (MITC)', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'gaming', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative online skill-based gaming spends above ₹10,000 per statement cycle (MITC)', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
      ],
      emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: null, foreclosure_charge_percent: null, gst_applicable: null },
      banking_penalties: { overlimit_charge: { fee_percent: null, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: 450, cheque_bounce_charge_inr: 500 },
      reward_redemption_fee: { fee_inr: null, gst_applicable: null },
    },
    statement_and_late_fees: {
      grace_period_days: null, grace_period_void_on_revolving_balance: null,
      minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['1% of all purchase transactions and cash advances', '100% of EMI, finance charges, fees, charges and tax', 'minimum ₹100, else up to the total amount due, whichever is lower (MITC)'] },
      late_payment_slabs: [{ min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 500 }, { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 600 }, { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 900 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 }],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Fees and Charges tab: joining fee nil, annual fee ₹1,000, no waiver condition (NA).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 599, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: 18 },
    lifestyle_and_network_benefits: [
      B({ id: 'kotak-nri-royale-lounge', cat: 'lounge', sponsor: 'Kotak Mahindra Bank', label: '2 complimentary visits every quarter to select lounges in India (page)', qty: 2, per: 'quarter' }),
      B({ id: 'kotak-nri-royale-railway', cat: 'other', sponsor: 'Kotak Mahindra Bank', label: 'Railway surcharge waiver on www.irctc.co.in and Indian Railways counters, maximum ₹500 a calendar year (page)', value: 500 }),
    ],
    insurance_and_protection: [],
    dynamic_promotions_registry: [],
    redemption_matrix: { direct_options: [{ channel: 'Kotak Rewards catalogue (mobile recharge, shopping, e-vouchers, BookMyShow, travel)', redemption_type: 'partner_catalogue', inr_value_per_point: 1, max_bill_percentage_payable_via_points: 'N/A', min_points_per_txn: null, cycle_points_burn_cap: 'N/A', redemption_fee_inr: null, effective_from: null, effective_to: null }], partner_transfers: [] },
    additional_data: { items: prov({
      sources: [
        { url: KOTAK_PAGE + '.html', kind: 'NRI Royale Signature features page (rewards, fuel and railway waivers, add-on fee, lounge); read in the built-in browser', read: 'rendered page text' },
        { url: KOTAK_PAGE + '/fees-and-charges.html', kind: 'Fees and Charges tab: joining fee nil, annual fee ₹1,000, no waiver', read: 'rendered page text' },
        { url: KOTAK_PAGE + '/eligibility.html', kind: 'Eligibility tab: NRE/NRO holders, age 21-60, 80% of FD, minimum FD ₹1 lakh', read: 'rendered page text' },
        { url: KOTAK_PAGE + '/reward-redemption.html', kind: 'Reward Redemption tab (Kotak Rewards, no value stated)', read: 'rendered page text' },
        { url: KMITC, kind: 'Kotak Mahindra Bank MITC and Cardholder Agreement (PDF created 30 Oct 2026): interest, forex, late fee, MAD, surcharges, fuel waiver rule', read: 'pdftotext' },
      ],
      unverified: [
        'Network: neither the pages nor the MITC state the network of the NRI Royale Signature card (the MITC says fees do not depend on the network variant and speaks of Visa/MasterCard/RuPay generally). Not taken from the resident Royale Signature card or the word "Signature". A person should confirm from the card art or the welcome kit.',
        'Fuel surcharge waiver: the page says waiver on transactions of ₹500 to ₹3,000, maximum ₹3,500 in a calendar year; the MITC (PDF created 30 Oct 2026, later than the page) says ₹500 to ₹5,000, maximum ₹3,500 in an anniversary year, and the waiver percentage is not stated for this card. The MITC range is used and waiver_percent, surcharge_percent and the yearly cap (the field is monthly) are left null.',
        'Reward exclusions, caps and expiry: neither the page nor the MITC special terms read lists excluded categories, caps or point expiry for this card; the special-terms section for Royale, Zen, Signature and NRI Royale cards covers the welcome gift and Priority Pass only. The "3x Reward Points on Spends" icon on the page has no matching text.',
        'Finance charge 3.75% a month (45% a year): read from the MITC finance-charge table where NRI Royale Signature sits in a merged cell group (the layout puts the 3.75% figure in the first group, 3.50% in the White/Infinite group). A person should eyeball the table row.',
        'Joining fee nil, annual fee ₹1,000 (page and MITC agree); GST is "as per the Finance Act" and no numeric rate is stated on the pages, so gst_rate_percent is null.',
        'Lounge: the page says 2 visits a quarter to select lounges in India; the MITC special terms describe a Priority Pass membership for the Signature family; the quota and any spend condition per card were not tied to NRI Royale in the MITC. Quota from the page used.',
        'Overlimit fee ₹500 (waived for some cards), cheque return 2% min ₹500, auto-debit failure 2% min ₹450 are MITC rows for "all other cards".',
      ],
      notes: ['FD-backed card: credit limit up to 80% of the deposit; deposits at least 1 year and 1 day with auto-renewal in the secured-card terms (MITC 34.4).', 'Payments can only be made through auto-debit from the cardholder\'s Kotak NRE account (MITC bill-payment section for NRI cardholders).'],
      extra: FETCHED,
    }) },
  },
});
