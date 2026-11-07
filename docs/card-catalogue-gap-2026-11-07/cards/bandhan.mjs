// Bandhan Bank credit cards: Sparks, Ignite, Flare, Lumina. Sources read 2026-11-07.
//  MITC = Bandhan Bank Credit Cards MITC, ref CC/MITC/OA/090726/03/V-01, file dated 19 Aug 2026 (16 pages, pdftotext)
//         https://creditcards.bandhan.bank.in/landing/uploads/Credit_Card_MITC_English_19082026_2b514a85e4.pdf
//  COMPARE = https://creditcards.bandhan.bank.in/compare-card/ (rendered page text, reached through the site's own Compare link)
//  Lumina page = https://creditcards.bandhan.bank.in/card-details/Lumina/
// A guessed direct URL was rejected by the site's firewall, so no other pages were tried.
// Wave 2 (W6, 2026-11-07) added, all reached through the site's own links (Important Documents page, card pages, Delights menu):
//  GUIDE = Credit Card Product Usage Guide with T&C, file dated 14 Aug 2026 (11 pages): lounge, golf, concierge, accelerated-reward caps, network wording
//  KFS   = Key Fact Statement, ref CC/KFS/OA/080426/02/V-01, file dated 30 Apr 2026 (2 pages)
//  EXCL  = Excluded Merchant Category Codes, file dated 23 Jun 2026 (1 page)
//  FAQ   = Bandhan Bank Delights FAQ (value of one Delight Point)
//  Card pages: /card-details/Flare/ and /card-details/Lumina/ (fuel cap, golf tile naming the networks, Value Chart)
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const MITC = 'https://creditcards.bandhan.bank.in/landing/uploads/Credit_Card_MITC_English_19082026_2b514a85e4.pdf';
const COMPARE = 'https://creditcards.bandhan.bank.in/compare-card/';
const GUIDE = 'https://creditcards.bandhan.bank.in/landing/uploads/Credit_Card_Product_Usage_Guidelines_14082026_892e11470c.pdf';
const KFS = 'https://creditcards.bandhan.bank.in/landing/uploads/Credit_Card_KFS_30042026_d588f85ac2.pdf';
const EXCL = 'https://creditcards.bandhan.bank.in/landing/uploads/Excluded_Merchant_Category_Code_23062026_853953ff5a.pdf';
const FAQ = 'https://delights.bandhan.bank.in/content/faq';
const FLARE_PAGE = 'https://creditcards.bandhan.bank.in/card-details/Flare/';
const LUMINA_PAGE = 'https://creditcards.bandhan.bank.in/card-details/Lumina/';

// Delight Point value stated by the issuer: Delights FAQ (Accrual) says 1 Delight Point = INR 0.25 and the Bank may change it.
// The four Value Charts on the card pages use the same 0.25 (Sparks 500 activation points = 125; Ignite 1,000 = 250; Ignite 1,200 monthly milestone points x 12 = 3,600).
const POINT_VALUE = 0.25;
const POINT_BASIS = 'Bandhan Bank Delights FAQ, Accrual: 1 Delight Point = INR 0.25; the Bank may change the value from time to time. Card-page Value Charts use the same 0.25 (Sparks: 500 activation points = INR 125; Ignite: 1,000 points = INR 250). Minimum redemption 400 points; no convenience fee (FAQ). FAQ page is undated.';

const make = (v, o) => ({
  card_product: { ...GST, card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: o.joining, annual_fee_inr: o.renewal, is_upi_linkable: false, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: COMPARE, status: 'draft', verified_at: null, point_value_inr_baseline: POINT_VALUE, point_value_baseline_basis: POINT_BASIS, point_expiry_months: 0 },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
  accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: o.base, base_cashback_percent: 'N/A', effective_base_return_percent: o.base * POINT_VALUE / 200 * 100, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  reward_rules: [
    X(`bandhan-${v}-excluded-mccs`, 'excluded_spend', [6513, 5542, 5983, 5541, 7800, 7801, 7802, 9034, 9211, 9222, 9223, 9311, 9399, 9401, 9402, 9405, 9700, 9701, 9702, 9751, 9752, 9754, 9950], 'Rent, fuel and government-sector MCCs earn no reward points (Excluded Merchant Category Codes list, 23 Jun 2026).'),
    ...o.accel.map(([id, cat, rail, ppb, label, cond]) => R({ id: `bandhan-${v}-${id}`, cat, rail, pri: 10, ppb, mult: ppb / o.base, cap: `bandhan-${v}-accel-monthly-cap`, cond, reason: `${ppb} reward points per ₹200 on ${label} (Compare page); accelerated points capped at ${o.capPoints.toLocaleString('en-IN')} a month (Product Usage Guide).` })),
    R({ id: `bandhan-${v}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: o.base, mult: 1, cond: { per_inr_block: 200 }, reason: `${o.base} reward points per ₹200 on all categories (Compare page; Product Usage Guide base rate).` }),
  ],
  cap_rules: [C({ id: `bandhan-${v}-accel-monthly-cap`, cat: o.capCat, metric: 'total_reward_points', period: 'calendar_month', points: o.capPoints, after: 'downgrade_to_base_rate', afterPpb: o.base })],
  fees_and_surcharges: {
    apr: { monthly_interest_rate_percent: 3.5, annual_interest_rate_percent: 42 },
    forex_markup: { markup_percent: o.forex, gst_applicable: true },
    dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: 'MITC: DCC mark-up applies to international ATM withdrawals' },
    fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 500, max_txn_inr: o.fuelMax, monthly_waiver_cap_inr: o.fuelCap },
    cash_advance: { atm_transaction_fee_percent: o.cashFee, atm_transaction_fee_min_inr: o.cashFee === 0 ? 0 : 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
    category_surcharges: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: o.rentCap ? `1% + GST per rent transaction, capped at ₹${o.rentCap} per transaction` : '1% + GST per rent transaction, no cap stated', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 99, foreclosure_charge_percent: 3, gst_applicable: true },
    banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: o.returned, cheque_bounce_charge_inr: o.returned },
    reward_redemption_fee: { fee_inr: 0, gst_applicable: null },
  },
  statement_and_late_fees: {
    late_payment_slabs: o.lateNil
      ? [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 0 }]
      : [{ min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }, { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 500 }, { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: null, fee_inr: 1100 }],
  },
  fee_waiver_and_milestones: {
    annual_fee_waiver: o.waiver
      ? { threshold_spend_inr: o.waiver, period: 'card_anniversary_year', evaluation_condition: `Renewal fee waived on annual spend of ₹${o.waiver.toLocaleString('en-IN')}; rent payments, wallet loads and their processing fees do not count (MITC).`, excluded_category_ids: ['rent', 'wallet'], excluded_mcc_list: [], waives_fee_inr: o.renewal }
      : { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No renewal fee waiver condition applies.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
    welcome_and_renewal_gift: { trigger: o.activation.trigger, benefit_points: o.activation.points, effective_value_inr: o.activation.value, condition: o.activation.text },
    spend_milestones: [],
  },
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
  lifestyle_and_network_benefits: o.benefits,
  dynamic_promotions_registry: o.promos,
  additional_data: { items: [
    ...(o.network ? [dualNetwork(o.network)] : []),
    ...prov({
    sources: [
      { url: MITC, kind: 'MITC: fees, interest, forex, penalties, fuel waiver (file dated 19 Aug 2026)', read: 'pdftotext' },
      { url: COMPARE, kind: 'Compare Credit Cards page: earn rates, activation offers, milestones, lounges, lifestyle offers', read: 'rendered page text' },
      { url: GUIDE, kind: 'Credit Card Product Usage Guide with Terms & Conditions (file dated 14 Aug 2026): network wording for lounge, golf and concierge; accelerated-reward monthly caps; base rates', read: 'pdftotext' },
      { url: KFS, kind: 'Key Fact Statement CC/KFS/OA/080426/02/V-01 (file dated 30 Apr 2026): fees, interest, fuel waiver caps, forex; confirms Flash footnote', read: 'pdftotext' },
      { url: EXCL, kind: 'Excluded Merchant Category Codes (file dated 23 Jun 2026)', read: 'pdftotext' },
      { url: FAQ, kind: 'Bandhan Bank Delights FAQ, Accrual: value of 1 Delight Point (undated)', read: 'rendered page text' },
      ...(o.page ? [o.page] : []),
    ],
    unverified: [
      'Delights earn rules and redemption catalogue sit behind the Delights login ("About Delights"); only the FAQ value (INR 0.25 per point, minimum 400 points to redeem) was readable without signing in. The FAQ is undated and says the Bank may change the value.',
      'The card-page Value Charts do not reconcile with the stated base rates for the "all other transactions" line (for example Lumina shows INR 4,800 a year on INR 1,00,000 monthly spend, which is about 0.4%, against 16 points per INR 200 at INR 0.25 = 2%). The stated base rate is used and the charts are treated as illustrations.',
      o.netOpen,
      'Accelerated-reward cap: the Product Usage Guide says "per month" without saying calendar month or statement cycle; calendar_month is assumed (milestones are stated per calendar month). The cap value matches the Value Chart arithmetic (cap points x 12 x INR 0.25), so it is read as total accelerated points, not bonus-only.',
      `Interest on purchases is 3.5% a month for new-to-bank customers; existing-to-bank customers get ${o.etb} (MITC and KFS agree). The draft uses the new-to-bank rate.`,
      'MITC document reference CC/MITC/OA/090726/03/V-01; the file is dated 19 Aug 2026.',
      ...(o.conflict ? [o.conflict] : []),
    ],
    notes: [
      'Rewards are "Delight Points" and never expire (home page: never-expiring rewards).',
      'Rewards earn no points on the MCCs in the Excluded Merchant Category Codes list (rent, fuel, government sector); the same list also bars those MCCs from EMI conversion (Product Usage Guide).',
      `Milestone and activation offers are event bonuses (spend within 30 days, or monthly spend), so they are not modelled as spend rates: ${o.milestoneNote}`,
      'MITC also lists a fifth variant, "Flash": a fully digital RuPay credit card issued only to existing physical Visa or Mastercard cardholders, sharing the physical card\'s credit limit on a separate card account, with no POS use. Joining and renewal fee nil; interest 3.5% a month (42% a year); forex 3.5%; fuel waiver 1% up to INR 150 a cycle on INR 500-2,500; no accelerated rewards, base 2 points per INR 200 (MITC, KFS, Product Usage Guide). It is not drafted here because it is not a standalone product.',
    ],
  }) ] },
});

export const cards = {
  'bandhan-sparks': make('sparks', {
    joining: 0, renewal: 499, waiver: 50000, base: 2, forex: 3.5, fuelMax: 2500, fuelCap: 150, cashFee: 3.5, rentCap: null, returned: 350, lateNil: false, etb: '3.5% a month (42% a year)',
    accel: [['grocery-apparel-4', 'groceries', 'any', 4, 'grocery and apparel', { categories: ['grocery', 'apparel'] }]],
    capPoints: 400, capCat: 'groceries',
    page: { url: 'https://creditcards.bandhan.bank.in/card-details/Sparks/', kind: 'Sparks card page, Compare page tile and card-art images reached through the site\'s own links (read 2026-11-07 for a network mark: none on any image; no network wording on any page)', read: 'rendered page text, DOM and the images opened in a browser tab' },
    netOpen: 'Network (re-checked 2026-11-07, STILL UNRESOLVED): no Bandhan document or card art names the network for Sparks. Read: MITC (19 Aug 2026), KFS (30 Apr 2026), Cardholder\'s Agreement (30 Apr 2026; says only "VISA / MasterCard or RuPay network" generically), Product Usage Guide (14 Aug 2026; names a network only for Flare and Lumina in the golf and concierge sections, and links Visa, Mastercard and RuPay lounge lists generically for all four cards), EMI T&C, Credit Card Program Policy, Excluded MCC list, the Sparks card page, the Compare page, the home page and the contactless credit card FAQ on bandhan.bank.in. The Sparks card art (card-page hero, the Compare-page tile and the step-2 and step-4 phone mock-ups) shows only the card front with no network mark. The Visa domestic lounge list (visa.co.in) is by airport, not by card; the Mastercard lounge list link returned 403 and was not pursued. The MITC and KFS Flash footnote says the RuPay Flash card is issued only to existing physical Visa or Mastercard cardholders, which implies the physical cards are Visa or Mastercard but does not say which one Sparks ships on or whether the customer chooses. Press headlines listed on bandhan.bank.in/news (CNBC-TV18, Business Standard) say the four variants are "on Mastercard", but they are third-party and conflict with the Guide, which says Flare and Lumina ship on Visa or Mastercard, so they are not used. The application flow (applycc.bandhan.bank.in) asks for a mobile number first and was not opened. Action: ask Bandhan credit-card support in writing which network Sparks ships on (and whether the customer can choose), or read it off an issued card or welcome kit. card_product.network is null and no network candidates are recorded.',
    activation: { trigger: 'spend_within_30_days_of_issue', points: 500, value: 125, text: '500 reward points with ₹5,000 spent within 30 days of card issuance (Compare page); the Sparks Value Chart prices them at ₹125.' },
    milestoneNote: 'Sparks has no monthly milestone.',
    benefits: [B({ id: 'bandhan-sparks-lounge', cat: 'lounge', sponsor: 'Bandhan Bank', label: 'Domestic airport lounge access', qty: 1, per: 'quarter' })],
    promos: [P({ id: 'bandhan-sparks-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', pct: 20, max: 100, quota: true })],
  }),
  'bandhan-ignite': make('ignite', {
    joining: 0, renewal: 999, waiver: 100000, base: 4, forex: 3.5, fuelMax: 4000, fuelCap: 250, cashFee: 3.5, rentCap: null, returned: 350, lateNil: false, etb: '3.5% a month (42% a year)',
    accel: [['grocery-8', 'groceries', 'any', 8, 'grocery', { categories: ['grocery'] }], ['travel-8', 'travel', 'any', 8, 'travel', { categories: ['travel'] }]],
    capPoints: 800, capCat: 'groceries',
    page: { url: 'https://creditcards.bandhan.bank.in/card-details/Ignite/', kind: 'Ignite card page, Compare page tile and card-art images reached through the site\'s own links (read 2026-11-07 for a network mark: none on any image; no network wording on any page)', read: 'rendered page text, DOM and the images opened in a browser tab' },
    netOpen: 'Network (re-checked 2026-11-07, STILL UNRESOLVED): no Bandhan document or card art names the network for Ignite. Read: MITC (19 Aug 2026), KFS (30 Apr 2026), Cardholder\'s Agreement (30 Apr 2026; says only "VISA / MasterCard or RuPay network" generically), Product Usage Guide (14 Aug 2026; names a network only for Flare and Lumina in the golf and concierge sections, and links Visa, Mastercard and RuPay lounge lists generically for all four cards), EMI T&C, Credit Card Program Policy, Excluded MCC list, the Ignite card page, the Compare page, the home page and the contactless credit card FAQ on bandhan.bank.in. The Ignite card art (card-page hero, the Compare-page tile and the step-2 and step-4 phone mock-ups) shows only the card front with no network mark. The Visa domestic lounge list (visa.co.in) is by airport, not by card; the Mastercard lounge list link returned 403 and was not pursued. The MITC and KFS Flash footnote says the RuPay Flash card is issued only to existing physical Visa or Mastercard cardholders, which implies the physical cards are Visa or Mastercard but does not say which one Ignite ships on or whether the customer chooses. Press headlines listed on bandhan.bank.in/news (CNBC-TV18, Business Standard) say the four variants are "on Mastercard", but they are third-party and conflict with the Guide, which says Flare and Lumina ship on Visa or Mastercard, so they are not used. The application flow (applycc.bandhan.bank.in) asks for a mobile number first and was not opened. Action: ask Bandhan credit-card support in writing which network Ignite ships on (and whether the customer can choose), or read it off an issued card or welcome kit. card_product.network is null and no network candidates are recorded. The 800-point accelerated cap is shared by grocery and travel (Product Usage Guide).',
    activation: { trigger: 'spend_within_30_days_of_issue', points: 1000, value: 250, text: '1,000 reward points with ₹10,000 spent within 30 days of card issuance (Compare page); the Ignite Value Chart prices them at ₹250.' },
    milestoneNote: '1,200 reward points on a monthly spend of ₹30,000.',
    benefits: [B({ id: 'bandhan-ignite-lounge', cat: 'lounge', sponsor: 'Bandhan Bank', label: 'Domestic and international airport lounge access', cond: { domestic_per_quarter: 1, international_per_quarter: 1 }, qty: 2, per: 'quarter' })],
    promos: [
      P({ id: 'bandhan-ignite-eazydiner', cat: 'dining', sponsor: 'EazyDiner', platform: 'EazyDiner', type: 'instant_discount', pct: 15, max: 500, quota: true }),
      P({ id: 'bandhan-ignite-emi', cat: 'emi', sponsor: 'Bandhan Bank', platform: 'first EMI', type: 'cashback', pct: 10, max: 500, quota: false, permanent: true }),
    ],
  }),
  'bandhan-flare': make('flare', {
    joining: 2499, renewal: 2499, waiver: 600000, base: 10, forex: 1.99, fuelMax: 5000, fuelCap: 500, cashFee: 3.5, rentCap: 250, returned: 350, lateNil: false, etb: '2% a month (24% a year)',
    accel: [['travel-20', 'travel', 'any', 20, 'travel', { categories: ['travel'] }]],
    capPoints: 2500, capCat: 'travel',
    page: { url: FLARE_PAGE, kind: 'Flare card page: golf-lessons tile names the networks; fuel waiver; Value Chart', read: 'rendered page text' },
    network: {
      sourceUrl: GUIDE,
      evidence: 'Bandhan Product Usage Guide (file dated 14 Aug 2026), golf section: "Flare Cards issued under Mastercard Network" and "Lumina and Flare Cards on Visa" ("Flare and Lumina cardholders issued on Visa network"). The Flare card page golf tile adds "Applicable for Mastercard World and Visa Sign". A cardholder gets one network or the other.',
      variants: [
        { network: 'mastercard', network_tier: 'mastercard_world', label: 'Bandhan Bank Flare Credit Card (Mastercard World)', source_url: GUIDE, evidence: 'Guide: "Flare Cards issued under Mastercard Network"; Flare page golf tile: "Mastercard World".' },
        { network: 'visa', network_tier: 'visa_signature', label: 'Bandhan Bank Flare Credit Card (Visa Signature)', source_url: GUIDE, evidence: 'Guide: "For Flare and Lumina cardholders issued on Visa network"; Flare page golf tile says "Visa Sign" (read as Visa Signature).' },
      ],
    },
    netOpen: 'Network: Flare ships on Mastercard or Visa (Product Usage Guide, 14 Aug 2026). The MITC does not say which card a new customer is issued; the tier names come from the Flare page golf tile ("Mastercard World and Visa Sign"), where "Sign" is read as Visa Signature. A person should confirm the tiers and whether the choice is the customer\'s.',
    activation: { trigger: 'spend_within_30_days_of_issue', points: 'N/A', value: 2000, text: 'Amazon Pay gift card worth ₹2,000 with ₹10,000 spent within 30 days of card issuance (Compare page).' },
    milestoneNote: '5,000 reward points on a monthly spend of ₹75,000.',
    benefits: [
      B({ id: 'bandhan-flare-lounge', cat: 'lounge', sponsor: 'Bandhan Bank', label: 'Domestic and international airport lounge access', cond: { domestic_per_quarter: 4, international_per_quarter: 1 }, qty: 5, per: 'quarter' }),
      B({ id: 'bandhan-flare-golf', cat: 'golf', sponsor: 'Bandhan Bank', label: 'Complimentary golf lessons', qty: 4, per: 'annual' }),
    ],
    promos: [
      P({ id: 'bandhan-flare-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', pct: 25, max: 500, quota: true }),
      P({ id: 'bandhan-flare-eazydiner', cat: 'dining', sponsor: 'EazyDiner', platform: 'EazyDiner', type: 'instant_discount', pct: 15, max: 750, quota: true }),
      P({ id: 'bandhan-flare-emi', cat: 'emi', sponsor: 'Bandhan Bank', platform: 'first EMI', type: 'cashback', pct: 10, max: 750, quota: false, permanent: true }),
    ],
  }),
  'bandhan-lumina': make('lumina', {
    joining: 9999, renewal: 9999, waiver: 1200000, base: 16, forex: 1, fuelMax: 5000, fuelCap: 500, cashFee: 0, rentCap: 500, returned: 0, lateNil: true, etb: '1.5% a month (18% a year)',
    conflict: 'Fuel surcharge waiver cap: the MITC (19 Aug 2026) and the KFS (30 Apr 2026) both say a maximum waiver of ₹500 per statement cycle for Lumina (1% on transactions of ₹500 to ₹5,000), while the Compare page, the Lumina card page and its Value Chart say ₹1,000. Two regulatory documents agree, so ₹500 is used. The website figure is unexplained (the website could be newer than both documents), so a person should confirm with the issuer before publishing.',
    accel: [['international-24', 'international_spend', 'any', 24, 'international spends (1.5x)', { transaction_type: 'international' }]],
    capPoints: 5000, capCat: 'international_spend',
    page: { url: LUMINA_PAGE, kind: 'Lumina card page: fuel waiver cap of INR 1,000 (conflicts with MITC and KFS), joining benefit, Value Chart', read: 'rendered page text' },
    network: {
      sourceUrl: GUIDE,
      evidence: 'Bandhan Product Usage Guide (file dated 14 Aug 2026), concierge section lists contact routes "For Lumina Credit Cardholders on VISA network" and "on MASTERCARD network"; golf section: "Flare and Lumina cardholders issued on Visa network". A cardholder gets one network or the other.',
      variants: [
        { network: 'mastercard', network_tier: 'N/A', label: 'Bandhan Bank Lumina Credit Card (Mastercard)', source_url: GUIDE, evidence: 'Guide, Concierge Service: "For Lumina Credit Cardholders on MASTERCARD network". Tier not stated.' },
        { network: 'visa', network_tier: 'N/A', label: 'Bandhan Bank Lumina Credit Card (Visa)', source_url: GUIDE, evidence: 'Guide, Concierge Service: "For Lumina Credit Cardholders on VISA network"; Golf: Visa-issued Flare and Lumina cardholders. Tier not stated (the Visa concierge address contains "Infinite", which is not a tier statement).' },
      ],
    },
    netOpen: 'Network: Lumina ships on Visa or Mastercard (Product Usage Guide, 14 Aug 2026). Tier names are not stated for Lumina. The MITC does not say which card a new customer is issued.',
    activation: { trigger: 'spend_within_30_days_of_issue_and_joining_fee_paid', points: 'N/A', value: 10000, text: '₹10,000 "Giftwrapped by Oberoi" e-voucher on spending ₹20,000 within 30 days of card issuance and payment of the joining fee (Lumina page).' },
    milestoneNote: '10,000 reward points on a monthly spend of ₹1,00,000.',
    benefits: [
      B({ id: 'bandhan-lumina-lounge', cat: 'lounge', program: 'priority_pass', sponsor: 'Bandhan Bank', label: 'Domestic and unlimited international airport lounge access', cond: { domestic_per_quarter: 8, international: 'unlimited' }, qty: 8, per: 'quarter' }),
      B({ id: 'bandhan-lumina-golf', cat: 'golf', sponsor: 'Bandhan Bank', label: 'Complimentary 4 golf games and 4 golf lessons per year (1 lesson per quarter)', qty: 4, per: 'annual' }),
      B({ id: 'bandhan-lumina-concierge', cat: 'concierge', sponsor: 'Bandhan Bank', label: 'Exclusive concierge for online reservations, travel and gifts' }),
      B({ id: 'bandhan-lumina-meet-greet', cat: 'other', sponsor: 'Bandhan Bank', label: 'Complimentary airport meet and greet', qty: 4, per: 'annual' }),
      B({ id: 'bandhan-lumina-air-cover', cat: 'insurance_related_perk', sponsor: 'ICICI Lombard', label: '₹1 crore accidental air death cover', value: 10000000 }),
    ],
    promos: [
      P({ id: 'bandhan-lumina-bms', cat: 'movie', sponsor: 'BookMyShow', platform: 'BookMyShow', type: 'instant_discount', pct: 25, max: 1000, quota: true }),
      P({ id: 'bandhan-lumina-eazydiner', cat: 'dining', sponsor: 'EazyDiner', platform: 'EazyDiner', type: 'instant_discount', pct: 25, max: 1000, quota: true }),
    ],
  }),
};
