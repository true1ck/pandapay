// Wave 5, agent W5D: Axis (6), Utkarsh SFB (5), DCB (5), Unity SFB (4), South Indian Bank (2), ESAF SFB (1). Read 2026-11-15.
// Every value below comes from an issuer page or issuer document named in that card's prov(). Unknown stays null.
// Not drafted here: Secured SIB One (recorded as variant of sib-one-co-branded-credit-card, same fees and same issuer documents).
import { R, X, C, B, P, prov, GST } from '../lib.mjs';

const D = '2026-11-15';
const X15 = { fetched_on: D };

// late fee slab sets
const AXIS_LATE = [{ min_balance_inr: 0, max_balance_inr: 500, fee_inr: 0 }, { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 500 }, { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 50000, fee_inr: 1200 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 }];
const DCB_LATE = [{ min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: 1000, fee_inr: 100 }, { min_balance_inr: 1001, max_balance_inr: null, fee_inr: 500 }];

const common = (o) => ({
  card_product: {
    ...GST, name: o.name, issuer_slug: o.issuer, network: o.network ?? null, network_tier: o.tier ?? null, card_tier: null, card_type: 'credit',
    joining_fee_inr: o.joining ?? null, annual_fee_inr: o.annual ?? null, is_upi_linkable: o.upi ?? null, application_mode: o.mode ?? null,
    point_value_inr_baseline: o.pv ?? null, point_value_baseline_basis: o.pvBasis ?? null, point_expiry_months: o.expiry ?? null,
    data_source_tier: 'issuer_page', source_url: o.url, status: 'draft', verified_at: null,
  },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.eligNote ?? null, rules: o.eligRules ?? [], required_documents: [] },
  accrual_engine: { base_block_inr: o.block ?? null, rounding_mode: null, base_points_per_block: o.basePts ?? null, base_cashback_percent: o.baseCb ?? 'N/A', effective_base_return_percent: o.baseRet ?? null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  reward_rules: o.rules ?? [],
  cap_rules: o.caps ?? [],
  fees_and_surcharges: {
    apr: { monthly_interest_rate_percent: o.apr?.[0] ?? null, annual_interest_rate_percent: o.apr?.[1] ?? null },
    forex_markup: { markup_percent: o.forex ?? null, gst_applicable: o.forex == null ? null : true },
    fuel_surcharge: o.fuel ?? { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    category_surcharges: o.catSur ?? [],
  },
  statement_and_late_fees: { grace_period_days: o.grace ?? null, late_payment_slabs: o.late ?? [] },
  fee_waiver_and_milestones: {
    annual_fee_waiver: o.waiver
      ? { threshold_spend_inr: o.waiver, period: o.waiverPeriod ?? 'card_anniversary_year', evaluation_condition: o.waiverText, excluded_category_ids: o.waiverExcl ?? [], excluded_mcc_list: o.waiverMcc ?? [], waives_fee_inr: o.annual }
      : { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: o.waiverText ?? 'No renewal fee waiver condition is stated.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
    welcome_and_renewal_gift: o.welcome ?? { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
    spend_milestones: o.milestones ?? [],
  },
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: o.addonFee ?? null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
  lifestyle_and_network_benefits: o.benefits ?? [],
  dynamic_promotions_registry: o.promos ?? [],
  additional_data: { items: prov({ sources: o.sources, unverified: o.unverified, notes: o.notes ?? [], extra: { ...X15, ...(o.extra ?? {}) } }) },
});

// ───────────────────────────── AXIS
const AX = 'https://www.axis.bank.in';
const AXMITC = { url: `${AX}/docs/default-source/default-document-library/mitc-credit-cards.pdf`, kind: 'Axis Credit Card MITC, 62 pages, PDF created 8 Oct 2026: fee table, interest rates, fuel waiver caps', read: 'pdftotext' };
const edgeExcl = (id) => X(id, 'excluded_spend', [], 'No EDGE REWARD Points on utilities, educational services, insurance, government institutions, wallet, rent, fuel, gift cards, bridge fees, road fees and tolls (Axis EDGE REWARD Points T&Cs PDF for the card).');

const axisCards = {
  'axis-bank-pride-platinum': common({
    name: 'Axis Bank Pride Platinum Credit Card', issuer: 'axis-bank', network: null, joining: 0, annual: 250, url: `${AX}/cards/credit-card/pride-platinum-credit-card`, upi: false, mode: 'open',
    block: 200, basePts: 4, apr: [3.75, 55.55], forex: 3.5, grace: null,
    waiver: 20000, waiverText: 'Annual fee INR 250 from the 2nd year, waived on spends in the preceding card anniversary year. The Axis MITC (8 Oct 2026) says INR 20,000; the product page says INR 40,000 (see open questions). Rent (6513), wallet load (6540), gift cards (5947) and tolls (4784) do not count.', waiverExcl: ['rent', 'wallet'], waiverMcc: [6513, 6540, 5947, 4784],
    rules: [edgeExcl('axis-pride-platinum-excl'), R({ id: 'axis-pride-platinum-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 4, mult: 1, cond: { per_inr_block: 200 }, reason: '4 EDGE REWARD Points on every INR 200 spent (product page). Rupee value of a point not stated for this card.' })],
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 4000, monthly_waiver_cap_inr: 250 },
    late: AXIS_LATE, catSur: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee per rent transaction', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    benefits: [B({ id: 'axis-pride-platinum-dining', cat: 'dining', sponsor: 'Axis Bank Dining Delights', label: '15% off up to INR 500 at partner restaurants, minimum order INR 2,500, once per card per month' })],
    sources: [
      { url: `${AX}/cards/credit-card/pride-platinum-credit-card`, kind: 'Axis product page: features, fees, EDGE earn, fuel waiver (page says T&Cs updated w.e.f. 28 Aug 2026)', read: 'rendered page text' },
      AXMITC,
      { url: `${AX}/docs/default-source/default-document-library/credits-cards/pride-platinum-edge-rewards-mcc-exclusions.pdf`.replace('credits-cards', 'credit-cards'), kind: 'Pride Platinum EDGE REWARD Points T&Cs: excluded categories', read: 'pdftotext' },
      { url: `${AX}/images/default-source/l4-banner/card/phase-2-cards_copy-and-without-copy/axis-bank-pride-platinum-credit-card_copy/axis-bank-rewamp-banner-credit-cards--shopping-axis-bank-pride-platinum-credit-card-1366x400-desktop3a2d7ee4-6470-4d12-aa01-6c2cf58e4954.webp`, kind: 'Hero image on the product page, opened and looked at: shows the card with a Visa Signature mark; the identical image is the hero on the Pride Signature page, so it is shared art', read: 'image viewed' },
    ],
    unverified: [
      'Network not settled: the only network mark is a Visa Signature logo on a hero image that is identical on the Pride Platinum and Pride Signature pages (shared art for a Platinum-named card). No Axis document names the network. A person should read it off an issued card or ask Axis.',
      'Annual-fee waiver conflict: Axis MITC (PDF created 8 Oct 2026) says INR 250 waived at INR 20,000 spend; the product page fee table says waived on INR 40,000 (the Pride Signature figure). MITC used as the newer regulatory document; confirm with Axis.',
      'Value of one EDGE REWARD Point in rupees is not stated for this card; left null.',
      'Eligibility: page says the card is tailored to Indian Defence Forces and Government of India personnel, but its eligibility section lists only age 18-70 and residency; unclear whether issuance is restricted.',
      'The EDGE exclusion PDF gives category names without MCC lists; no MCC list is modelled.',
    ],
  }),
  'axis-bank-pride-signature': common({
    name: 'Axis Bank Pride Signature Credit Card', issuer: 'axis-bank', network: 'visa', tier: 'visa_signature', joining: 0, annual: 500, url: `${AX}/cards/credit-card/pride-signature-credit-card`, upi: false, mode: 'open',
    block: 200, basePts: 8, apr: [3.75, 55.55], forex: 3.5,
    waiver: 40000, waiverText: 'Annual fee INR 500 from the 2nd year, waived on INR 40,000 spend in the preceding year (page and MITC agree). Rent (6513), wallet load (6540), gift cards (5947) and tolls (4784) do not count.', waiverExcl: ['rent', 'wallet'], waiverMcc: [6513, 6540, 5947, 4784],
    rules: [edgeExcl('axis-pride-signature-excl'), R({ id: 'axis-pride-signature-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 8, mult: 1, cond: { per_inr_block: 200 }, reason: '8 EDGE REWARD Points for every INR 200 spent (product page). Rupee value of a point not stated for this card.' })],
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 4000, monthly_waiver_cap_inr: 400 },
    late: AXIS_LATE, catSur: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee per rent transaction', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    benefits: [
      B({ id: 'axis-pride-signature-lounge', cat: 'lounge', sponsor: 'Axis Bank', label: 'Complimentary domestic airport lounge access', qty: 2, per: 'quarter' }),
      B({ id: 'axis-pride-signature-dining', cat: 'dining', sponsor: 'Axis Bank Dining Delights', label: '15% off up to INR 500 at partner restaurants, minimum order INR 2,500, once per card per month' }),
    ],
    sources: [
      { url: `${AX}/cards/credit-card/pride-signature-credit-card`, kind: 'Axis product page (T&Cs updated w.e.f. 28 Aug 2026)', read: 'rendered page text' },
      AXMITC,
      { url: `${AX}/docs/default-source/default-document-library/credit-cards/pride-signature-edge-rewards-mcc-exclusions.pdf`, kind: 'Pride Signature EDGE REWARD Points T&Cs: excluded categories', read: 'pdftotext' },
      { url: `${AX}/docs/default-source/default-document-library/axis-bank-airport-lounge-access-program.pdf`, kind: 'Axis domestic airport lounge program (PDF created 16 Apr 2026): lists Pride Signature at 2 per quarter', read: 'pdftotext' },
      { url: `${AX}/images/default-source/l4-banner/card/phase-2-cards_copy-and-without-copy/axis-bank-pride-signature-credit-card_copy/axis-bank-rewamp-banner-credit-cards--shopping-axis-bank-pride-platinum-credit-card-1366x400-desktop1f7efe83-3c31-416a-84ec-9751979bc2ab.webp`, kind: 'Hero image on the product page, opened and looked at: card art with a Visa Signature mark (card art, not a text statement)', read: 'image viewed' },
    ],
    unverified: [
      'Network Visa Signature comes from card art on the issuer page only; no Axis document states it. The same art appears on the Pride Platinum page.',
      'Value of one EDGE REWARD Point in rupees is not stated for this card; left null.',
      'Fuel waiver cap period: the product page says INR 400 per statement cycle in one place and per month in the fee table; modelled as monthly_waiver_cap_inr 400, period unresolved.',
      'Lounge access is subject to the Axis spend criteria in the lounge program document (spend in previous 3 months); the amount for this card was not extracted.',
      'Eligibility: the page refers to defence personnel; the eligibility section lists only age and residency.',
    ],
  }),
  'flipkart-axis-bank-super-elite': common({
    name: 'Flipkart Axis Bank Super Elite Credit Card', issuer: 'axis-bank', network: null, joining: 500, annual: 500, url: `${AX}/cards/credit-card/flipkart-axis-bank-super-elite-credit-card`, upi: false, mode: 'open',
    block: 100, basePts: 2, apr: [3.75, 55.55], forex: 3.5,
    waiver: 200000, waiverText: 'Product page: annual fee INR 500 from the 2nd year, waived on annual spends greater than INR 2,00,000 (rent 6513 and wallet load 6540 do not count). The Axis MITC (8 Oct 2026) fee table lists no waiver for this card; conflict noted.', waiverExcl: ['rent', 'wallet'], waiverMcc: [6513, 6540],
    welcome: { trigger: 'card_activation', benefit_points: 500, effective_value_inr: null, condition: '500 SuperCoins on card activation (product page); SuperCoin rupee value not stated by Axis.' },
    rules: [
      X('axis-fkse-excl', 'excluded_spend', [6012, 6051, 5541, 5983, 5542, 5944, 6011, 6540, 6513], 'No SuperCoins on fuel, wallet load, jewellery, cash advances, EMI transactions, gift cards on Flipkart, card payments and fees, or Flipkart Health (SuperCoin T&Cs, Axis PDF dated 2023).'),
      R({ id: 'axis-fkse-flipkart-plus', cat: 'online', pri: 10, mult: 6, ppb: 12, cap: 'axis-fkse-flipkart-plus-cap', cond: { merchant: 'flipkart', customer: 'plus', per_inr_block: 100 }, reason: 'Additional 12 SuperCoins per INR 100 on Flipkart for Plus members, on top of the 2 per INR 100 base, capped at 300 per transaction (page FAQ and T&Cs).' }),
      R({ id: 'axis-fkse-flipkart-nonplus', cat: 'online', pri: 11, mult: 3, ppb: 6, cap: 'axis-fkse-flipkart-nonplus-cap', cond: { merchant: 'flipkart', customer: 'non_plus', per_inr_block: 100 }, reason: 'Additional 6 SuperCoins per INR 100 on Flipkart for non-Plus customers, capped at 150 per transaction (page FAQ and T&Cs).' }),
      R({ id: 'axis-fkse-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 SuperCoins per INR 100 on all other eligible spends, uncapped (page FAQ and T&Cs).' }),
    ],
    caps: [
      C({ id: 'axis-fkse-flipkart-plus-cap', cat: 'online', metric: 'bonus_reward_points', period: 'per_transaction', points: 300, after: 'downgrade_to_base_rate', afterPpb: 2 }),
      C({ id: 'axis-fkse-flipkart-nonplus-cap', cat: 'online', metric: 'bonus_reward_points', period: 'per_transaction', points: 150, after: 'downgrade_to_base_rate', afterPpb: 2 }),
    ],
    late: AXIS_LATE, catSur: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee per rent transaction', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    sources: [
      { url: `${AX}/cards/credit-card/flipkart-axis-bank-super-elite-credit-card`, kind: 'Axis product page: features, fees, FAQ on SuperCoin earn (T&Cs updated w.e.f. 28 Aug 2026)', read: 'rendered page text' },
      { url: `${AX}/docs/default-source/default-document-library/credit-cards/terms-and-conditions-for-flipkart-superelite-axis-bank-credit-card.pdf`, kind: 'SuperCoin T&Cs (PDF created 19 May 2023): earn rates, caps, excluded MCCs', read: 'pdftotext' },
      AXMITC,
      { url: `${AX}/images/default-source/l4-banner/card/phase-2-cards_copy-and-without-copy/flipkart-axis-bank-super-elite-credit-card_copy/19_hero-pages_set-02_axis-bank_rewamp-banner_feedback_desktop_1366-x-400-px_04-dec-2024_1-to-100-copy.webp`, kind: 'Hero image opened and looked at: card shows Axis Bank, Flipkart and SUPER ELITE marks and no network mark', read: 'image viewed' },
    ],
    unverified: [
      'Network not found: no Axis page or document read names it, and the card art shows no network mark. Do not copy from the Flipkart Axis Bank Credit Card (a different card).',
      'Rupee value of one SuperCoin is not stated by Axis; left null.',
      'Annual-fee waiver conflict: page says waived above INR 2,00,000; the MITC table shows INR 500 with no waiver. Page used and flagged; ask Axis.',
      'SuperCoin T&Cs PDF is dated May 2023 and may predate the 28 Aug 2026 revision the page mentions.',
      'Joining benefits (YouTube Premium trial, Gaana Plus, Lenskart Gold, Myntra, Flipkart Flights, Flipkart Health) are listed on the page with a separate T&C link and are not modelled.',
      'Cap period: Flipkart accelerator caps are per transaction (300 and 150 SuperCoins).',
    ],
  }),
  'miles-more-axis-bank-world': common({
    name: 'Miles & More Axis Bank World Credit Card', issuer: 'axis-bank', network: 'mastercard', tier: 'mastercard_world', joining: 3500, annual: 3500, url: `${AX}/cards/credit-card/miles-more-credit-card`, upi: false, mode: 'open',
    block: 200, basePts: 4, apr: [3.75, 55.55], forex: 3.5, pv: null,
    waiverText: 'Joining and annual fee are waived for HON and Senator status members of Miles & More (page). No spend-based waiver is stated.',
    welcome: { trigger: 'first_transaction_within_30_days', benefit_points: 5000, effective_value_inr: null, condition: '5,000 award miles welcome bonus on first transaction within 30 days of issuance (page).' },
    milestones: [],
    rules: [
      X('axis-mm-world-excl', 'excluded_spend', [], 'No award miles on utilities and telecom, rent, wallet load, government services, insurance, gold and jewellery, gift cards, fuel, cash advances, tolls, repayments, EMI, fees and interest (Axis T&C revision effective 20 Jun 2025; product page).'),
      R({ id: 'axis-mm-world-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 4, mult: 1, cond: { per_inr_block: 200 }, reason: '4 award miles per INR 200 of eligible spend (product page). Value of a mile not stated by Axis; redemption is through Miles & More.' }),
    ],
    late: AXIS_LATE,
    benefits: [
      B({ id: 'axis-mm-world-lounge-dom', cat: 'lounge', program: 'mastercard_lounge', sponsor: 'Axis Bank', label: 'Complimentary domestic lounge visits, subject to INR 50,000 spend in the previous 3 calendar months (T&C revision effective 1 May 2024)', qty: 4, per: 'quarter' }),
      B({ id: 'axis-mm-world-lounge-pp', cat: 'lounge', program: 'priority_pass', sponsor: 'Axis Bank', label: 'Priority Pass lounge visits, primary cardholder only', qty: 2, per: 'annual' }),
    ],
    sources: [
      { url: `${AX}/cards/credit-card/miles-more-credit-card`, kind: 'Axis Miles & More page (T&Cs updated w.e.f. 28 Aug 2026): earn, welcome miles, fees, lounge, MasterCard lounge section', read: 'rendered page text' },
      { url: `${AX}/images/default-source/l4-banner/card/phase-2-cards_copy-and-without-copy/miles-and-more-axis-bank-credit-card_copy/23_hero-pages_set-02_axis-bank_rewamp-banner_feedback_desktop_1366-x-400-px_04-dec-2024_1-to-100-copy.webp`, kind: 'Hero image opened and looked at: two Miles & More cards, both with Mastercard WORLD marks', read: 'image viewed' },
      { url: `${AX}/docs/default-source/default-document-library/credit-cards/terms-and-conditions-mmi-world-credit-card.pdf`, kind: 'Miles & More World T&C revision (PDF created 21 Aug 2026; text effective 20 Apr 2024): excluded MCCs, lounge spend rule', read: 'pdftotext' },
      { url: `${AX}/docs/default-source/default-document-library/credit-cards/terms-and-conditions-mmi-world-select-credit-card.pdf`, kind: 'Miles & More card T&C revision effective 20 Jun 2025: excluded spend categories', read: 'pdftotext' },
      AXMITC,
    ],
    unverified: [
      'Network Mastercard World: stated by the issuer page ("MasterCard Lounge Access", Mastercard lounge programme for these two cards) and shown on the card art in the hero image.',
      'Value of one award mile in rupees is not stated by Axis (redemption sits on the Miles & More site); left null.',
      'Interest: Axis MITC says 3.75% a month (55.55% a year); the product page says 3.7%. MITC used.',
      'Annual bonus 3,000 miles on renewal is stated on the page; not modelled as a milestone (renewal event).',
      'Dining Delights and Wednesday offers on the page are partner offers not modelled.',
    ],
  }),
  'miles-more-axis-bank-world-select': common({
    name: 'Miles & More Axis Bank World Select Credit Card', issuer: 'axis-bank', network: 'mastercard', tier: 'mastercard_world', joining: 10000, annual: 4500, url: `${AX}/cards/credit-card/miles-more-credit-card`, upi: false, mode: 'open',
    block: 200, basePts: 6, apr: [3.75, 55.55], forex: 3.5,
    waiverText: 'Joining and annual fee are waived for HON and Senator status members of Miles & More (page). No spend-based waiver is stated.',
    welcome: { trigger: 'first_transaction_within_30_days', benefit_points: 15000, effective_value_inr: null, condition: '15,000 award miles welcome bonus on first transaction within 30 days of issuance (page).' },
    rules: [
      X('axis-mm-select-excl', 'excluded_spend', [], 'No award miles on utilities and telecom, rent, wallet load, government services, insurance, gold and jewellery, gift cards, fuel, cash advances, tolls, repayments, EMI, fees and interest (Axis T&C revision effective 20 Jun 2025; product page).'),
      R({ id: 'axis-mm-select-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 6, mult: 1, cond: { per_inr_block: 200 }, reason: '6 award miles per INR 200 of eligible spend (product page). Value of a mile not stated by Axis.' }),
    ],
    late: AXIS_LATE,
    benefits: [
      B({ id: 'axis-mm-select-lounge-dom', cat: 'lounge', program: 'mastercard_lounge', sponsor: 'Axis Bank', label: 'Complimentary domestic lounge visits, subject to the Axis spend criteria', qty: 8, per: 'quarter' }),
      B({ id: 'axis-mm-select-lounge-pp', cat: 'lounge', program: 'priority_pass', sponsor: 'Axis Bank', label: 'Priority Pass lounge visits, primary cardholder only', qty: 4, per: 'annual' }),
    ],
    sources: [
      { url: `${AX}/cards/credit-card/miles-more-credit-card`, kind: 'Axis Miles & More page (T&Cs updated w.e.f. 28 Aug 2026)', read: 'rendered page text' },
      { url: `${AX}/images/default-source/l4-banner/card/phase-2-cards_copy-and-without-copy/miles-and-more-axis-bank-credit-card_copy/23_hero-pages_set-02_axis-bank_rewamp-banner_feedback_desktop_1366-x-400-px_04-dec-2024_1-to-100-copy.webp`, kind: 'Hero image opened and looked at: Select card with a Mastercard WORLD mark', read: 'image viewed' },
      { url: `${AX}/docs/default-source/default-document-library/credit-cards/terms-and-conditions-mmi-world-select-credit-card.pdf`, kind: 'Miles & More card T&C revision effective 20 Jun 2025', read: 'pdftotext' },
      AXMITC,
    ],
    unverified: [
      'Network Mastercard World: issuer page (Mastercard lounge programme) and card art in the hero image.',
      'Value of one award mile in rupees is not stated by Axis; left null.',
      'Annual bonus of 4,000 miles on renewal is stated on the page; not modelled (renewal event).',
      'The INR 50,000 three-month spend rule for lounges is documented for the World card (revision dated 20 Apr 2024); the Select amount was not found in the documents read.',
      'Page and MITC agree on fees (joining 10,000, annual 4,500).',
    ],
  }),
  'axis-bank-privilege-easy': common({
    name: 'Axis Bank Privilege Easy Credit Card', issuer: 'axis-bank', network: null, joining: 1500, annual: 1500, url: `${AX}/cards/credit-card/privilege-easy-credit-card`, upi: false, mode: 'open',
    block: 200, basePts: 10, apr: [3.4, 49.36], forex: 3.5,
    eligNote: 'Fixed-deposit-backed secured card: minimum FD INR 65,000, maximum INR 25,00,000 (page). Joining fee nil for Priority customers only.',
    eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 65000, allowed_values: [] }],
    waiver: 500000, waiverText: 'Annual fee INR 1,500 reversed on achieving spends of INR 5 lakh in the previous card anniversary year; spends on utility and telecom, rent, wallet, government, insurance, gold and jewellery, fuel, education and tolls are excluded (page).', waiverExcl: ['bills', 'rent', 'wallet', 'government', 'insurance', 'fuel', 'education'],
    welcome: { trigger: 'first_transaction_within_30_days_and_joining_fee_levied', benefit_points: 12500, effective_value_inr: 2500, condition: '12,500 EDGE REWARD Points, stated as worth INR 2,500 redeemable against vouchers, on levy of joining fee and first transaction within 30 days; not for free, first-year-free or priority-segment cards (page).' },
    milestones: [{ id: 'axis-priveasy-milestone-2-5l', label: '10,000 additional EDGE REWARD Points, stated as worth INR 2,000, on INR 2.5 lakh spend in a card anniversary year (page)', threshold_spend_inr: 250000, reward_value_inr: 2000, period: 'card_anniversary_year', is_repeatable: null, effective_from: null, effective_to: null }],
    rules: [
      X('axis-priveasy-excl', 'excluded_spend', [], 'No reward points on utility and telecom, rent, wallet, government services, insurance, gold and jewellery, fuel, education, bridge, road and toll fees; gift cards moved to a separate excluded category w.e.f. 28 Aug 2026 (page and Axis T&C revision).'),
      R({ id: 'axis-priveasy-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 10, mult: 1, cond: { per_inr_block: 200 }, reason: '10 EDGE REWARDS on every INR 200 spent (page).' }),
    ],
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 4001, monthly_waiver_cap_inr: 400 },
    late: AXIS_LATE, catSur: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee per rent transaction', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    benefits: [
      B({ id: 'axis-priveasy-lounge', cat: 'lounge', sponsor: 'Axis Bank', label: 'Complimentary domestic airport lounge access', qty: 2, per: 'quarter' }),
      B({ id: 'axis-priveasy-ppp', cat: 'insurance_related_perk', sponsor: 'Axis Bank', label: 'Purchase Protection Plan up to INR 1 lakh and Credit Shield INR 1 lakh (page)', value: 100000 }),
    ],
    promos: [P({ id: 'axis-priveasy-district-bogo', cat: 'movie', sponsor: 'District', platform: 'District app', type: 'instant_discount', pct: 100, quota: true })],
    sources: [
      { url: `${AX}/cards/credit-card/privilege-easy-credit-card`, kind: 'Axis product page (T&Cs updated w.e.f. 28 Aug 2026): features, fees, FD eligibility', read: 'rendered page text' },
      { url: 'https://campaign.axis.bank.in/generic/terms-and-conditions-privilegeeasy.pdf', kind: 'Privilege Easy T&C revision effective 28 Aug 2026 and 1 Nov 2026 (DCC 3.5%, late fee, District offer spend rule)', read: 'pdftotext' },
      AXMITC,
      { url: `${AX}/images/default-source/credit-card/s2_cuv-tracker_rest-of-the-pages_privilege-easy-credit-card_desktop_1366x400-px.jpg`, kind: 'Hero image opened and looked at: Axis Privilege card art with no network mark', read: 'image viewed' },
    ],
    unverified: [
      'Network not stated: the card art has no network mark and no Axis document names it for Privilege Easy. The page Value Chart (headed "Privilege Credit Card") mentions Mastercard-affiliated lounges, but it is the parent Privilege card chart, so it is not used.',
      'Value of one EDGE point: activation (12,500 = INR 2,500) and milestone (10,000 = INR 2,000) imply INR 0.20, but the Value Chart shows INR 2,000 for INR 2.5 lakh of spends (12,500 points), implying INR 0.16. Left null; ask Axis which is current.',
      'Fuel waiver band upper limit reads INR 4,001 on the page and INR 4,000 in the fee table; page value kept.',
      'FD-backed credit limit percentage is not stated on the page read.',
      'Reward points are cashable only as vouchers per the page; the redemption matrix is not modelled.',
    ],
  }),
};

// ───────────────────────────── SOUTH INDIAN BANK
const SIBU = 'https://www.southindianbank.bank.in/userfiles/upload';
const sibOne = common({
  name: 'SIB One Co-Branded Credit Card', issuer: 'south-indian-bank', network: 'visa', tier: 'visa_signature', joining: 0, annual: 0, url: 'https://www.southindianbank.bank.in/personal/cards/credit-card/sib-one-co-branded-credit-card', upi: null, mode: 'open',
  block: 50, basePts: 1, apr: [3.75, 45], forex: 1, grace: 48, expiry: null,
  waiverText: 'Joining and annual fee are nil (KFS w.e.f. 15 Sep 2026). Metal card add-on issuance fee INR 3,000; card cancellation fee within 6 months INR 3,000 metal or INR 500 plastic.',
  rules: [
    X('sib-one-excl', 'excluded_spend', [], 'No reward points on money transfers, rent payments, fuel purchases, cash withdrawals, digital wallet loads, and (effective 15 Sep 2026) bills and utilities (SIB One general T&Cs, clause 20).'),
    R({ id: 'sib-one-5x-top2', cat: 'all_retail', pri: 10, mult: 5, cond: { top_categories_per_month: 2, min_categories_in_month: 3, min_spend_per_category_inr: 750, per_inr_block: 50 }, reason: '5X reward points on the top 2 spend categories of a month if purchases span at least 3 categories with at least INR 750 in each (T&Cs clause 20, from 6 Jan 2025); credited on the 10th of the next month.' }),
    R({ id: 'sib-one-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 50, fractional_points: true }, reason: '1 reward point on every INR 50 of regular purchases; fractional points for amounts below INR 50 (T&Cs clause 20).' }),
  ],
  fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: 400 },
  late: [{ min_balance_inr: 0, max_balance_inr: 250, fee_inr: 0 }, { min_balance_inr: 251, max_balance_inr: 1000, fee_inr: 250 }, { min_balance_inr: 1001, max_balance_inr: 5000, fee_inr: 500 }, { min_balance_inr: 5001, max_balance_inr: 25000, fee_inr: 1000 }, { min_balance_inr: 25001, max_balance_inr: null, fee_inr: 1250 }],
  catSur: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 2, gst_applicable: true, trigger_condition: '2% of the transaction amount on rent through third-party merchants, w.e.f. 1 Feb 2026', threshold_spend_inr: null, effective_from: '2026-02-01', effective_to: null }, { category_id: 'wallet', mcc_list: [6540], fee_percent: 2, gst_applicable: true, trigger_condition: '2% on wallet upload/transfer on cumulative spends of INR 10,000 or more a month, w.e.f. 1 Feb 2026', threshold_spend_inr: 10000, effective_from: '2026-02-01', effective_to: null }],
  sources: [
    { url: 'https://www.southindianbank.bank.in/personal/cards/credit-card/sib-one-co-branded-credit-card', kind: 'SIB product page (read in the built-in browser; plain fetch returned 403): features, Visa Signature, 1% forex', read: 'rendered page text' },
    { url: `${SIBU}/sib_onecard_kfs.pdf`, kind: 'SIB One Key Fact Statement w.e.f. 15 Sep 2026 (PDF created 14 Aug 2026): fees, interest, late fee, fuel waiver', read: 'pdftotext' },
    { url: `${SIBU}/sib_onecard_credit_card_most_imp_terms_conditions.pdf`, kind: 'SIB One MITC (PDF created 14 Aug 2026): "VISA powered credit card", fuel waiver, rent and wallet fees', read: 'pdftotext' },
    { url: `${SIBU}/sib_onecard_credit_card_general_terms_and_conditions.pdf`, kind: 'SIB One general T&Cs (PDF created 14 Aug 2026), clause 20: reward earn, 5X, exclusions, validity', read: 'pdftotext' },
    { url: `${SIBU}/faq_sib_onecard_credit_card.pdf`, kind: 'SIB One FAQ (PDF created 19 Oct 2026): Visa powered, points never expire', read: 'pdftotext' },
  ],
  notes: ['Secured SIB One Co-Branded Credit Card (FD-backed, limit 100% of deposit, Visa Signature, zero joining and annual fee, 1% forex per the SIB page) links the same KFS, MITC and rewards T&Cs, so it is recorded as a variant of this card, not a separate draft. Its own T&C PDF (updated 10 Jan 2024) covers only the FD lien terms.'],
  unverified: [
    'Rupee value of one reward point is not stated in the issuer documents read (the T&Cs say the rate may change); left null. The OneCard rewards page (getonecard.app) is a partner site and was not read.',
    'Fuel waiver: capped INR 400 per calendar month per account (MITC); no per-transaction band stated; KFS says 1% of the amount.',
    'The 25,000-point ceiling on incremental 5X points in education, bills and insurance categories (T&Cs 20.h) is not modelled as a cap rule because the T&Cs give no period. Bills and utilities earn nothing from 15 Sep 2026.',
    'Which categories exist for the 5X top-2 rule is defined by the app, not by the documents.',
    'Eligibility: a search snippet claiming the card is issued only to pre-approved customers is not issuer evidence; the issuer page carries no such restriction.',
    'Reward points are nullified if the card is unused for more than 365 days (T&Cs).',
    'Card is metal; physical form-factor fees (INR 3,000 metal add-on) are in the KFS; EMI fees are shown only in the OneCard app.',
  ],
});

// ───────────────────────────── UTKARSH
const UT = 'https://www.utkarsh.bank.in';
const utSource = (slug, kfs) => [
  { url: `${UT}/personal/cards/credit-card/${slug}`, kind: 'Utkarsh product page (read in the built-in browser; plain fetch returned 406): features and Limits and Charges table', read: 'rendered page text' },
  { url: kfs, kind: 'Key Fact Statement / MITC linked from the page: NOT READ (plain fetch returned 406 and the browser only offers a download), so earn rules, caps and exclusions are unconfirmed', read: 'not read' },
];
const utCommon = { issuer: 'utkarsh-small-finance-bank', mode: 'invite_only', block: null };
const utEligNote = 'Page eligibility: existing Utkarsh customers with an active current, savings, FD or loan account; eligible customers receive a pre-approved or pre-qualified card link on their registered email. Age 21-65 unsecured, 18-65 FD-backed.';
const utCards = {
  'utkarsh-eternal': common({ ...utCommon, name: 'Utkarsh Eternal Credit Card', joining: 0, annual: 1999, url: `${UT}/personal/cards/credit-card/eternal`, eligNote: utEligNote, apr: [3, 36], grace: 50, baseCb: 1.25,
    waiver: 150000, waiverText: 'No annual fee for the first year; INR 1,999 from the 2nd year, waived when INR 1.5 lakh is spent during the previous year (page).',
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 5000, monthly_waiver_cap_inr: null },
    late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 500 }], rules: [],
    sources: utSource('eternal', `${UT}/assests/personal_credit_card/Eternal_KFS.pdf`),
    unverified: ['Earn rule: the page says 1.25% cashback on all eligible transactions and refers to the Key Fact Statement for details; the KFS was not readable, so eligible and excluded transactions, caps and the cashback period are unknown. No reward rules drafted.', 'Network: the page FAQ says chip cards work wherever "Mastercard/ RuPay" are accepted; no network is stated for this card. Foreign currency surcharge row is missing from the Eternal page table (the Rhodium page states 3%).', 'Page FAQ states a flat INR 500 late fee in addition to interest, cash advance 5% or INR 500 whichever is higher, overlimit INR 500, replacement INR 500; modelled only the late fee.', 'Fuel waiver cap per cycle not stated.', 'Eligibility looks invite-only (pre-approved link to existing customers); application_mode set to invite_only on that basis.'] }),
  'utkarsh-rhodium': common({ ...utCommon, name: 'Utkarsh Rhodium Credit Card', joining: 0, annual: 4999, url: `${UT}/personal/cards/credit-card/rhodium`, eligNote: utEligNote, apr: [2, 24], grace: 50, forex: 3, baseCb: 1.25,
    waiver: 500000, waiverText: 'No annual fee for the first year; INR 4,999 from the 2nd year, waived when INR 5 lakh is spent during the previous year (page).',
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 5000, monthly_waiver_cap_inr: null },
    late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 500 }], rules: [],
    benefits: [B({ id: 'utkarsh-rhodium-lounge', cat: 'lounge', sponsor: 'Utkarsh Small Finance Bank', label: 'Complimentary lounge access at select domestic airports', qty: 4, per: 'quarter' })],
    sources: utSource('rhodium', `${UT}/assests/personal_credit_card/Credit_Card_MITC.pdf`),
    unverified: ['Earn rule: 1.25% cashback on eligible transactions per the page; KFS unreadable, so exclusions, caps and period unknown. No reward rules drafted.', 'Network not stated: the forex row says "Visa currency conversion" but that is not a statement of the card network; Mastercard/RuPay appear only in a shared FAQ.', 'Lounge: 4 visits in a calendar quarter per the page; spend conditions unknown.', 'Return payment charge 2.5% and foreign currency surcharge 3% are on the page; foreign currency surcharge modelled.'] }),
  'utkarsh-smartgen': common({ ...utCommon, name: 'Utkarsh SmartGen Credit Card', joining: 0, annual: 199, url: `${UT}/personal/cards/credit-card/smartgen`, eligNote: utEligNote, apr: [3.6, 43.2], grace: 50, baseCb: 1,
    waiver: 50000, waiverText: 'No annual fee for the first year; INR 199 plus taxes from the 2nd year, waived when INR 50,000 is spent during the previous year (page).',
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 5000, monthly_waiver_cap_inr: null },
    late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 500 }], rules: [],
    sources: utSource('smartgen', `${UT}/assests/personal_credit_card/Credit_Card_MITC.pdf`),
    unverified: ['Earn rule: 1% cashback on eligible transactions per the page; KFS unreadable. No reward rules drafted.', 'Network not stated for this card.', 'Forex markup not on the page table; unknown.','The common Utkarsh credit card MITC linked from the card pages was not readable (406 to plain fetch, download only in the browser).'] }),
  'utkarsh-supercard': common({ ...utCommon, name: 'Utkarsh superCard', joining: 0, annual: 0, url: `${UT}/personal/cards/credit-card/supercard`, mode: 'open', upi: true, apr: [3, 36], grace: 45, baseCb: 1,
    eligNote: 'FD-backed credit card applied for through the Supermoney app; individual with valid PAN, mobile and email, Indian resident, age 18 and above (page).',
    waiverText: 'No joining or annual fee (page).',
    rules: [
      R({ id: 'utkarsh-supercard-myntra', cat: 'online', pri: 10, cb: 5, mult: 1, cond: { merchant: 'myntra', rail: 'non_upi' }, reason: '5% cashback on non-UPI spends on Myntra (page; MITC referred to for details, not read).' }),
      R({ id: 'utkarsh-supercard-flipkart', cat: 'online', pri: 11, cb: 2, mult: 1, cond: { merchant: 'flipkart', rail: 'non_upi' }, reason: '2% cashback on non-UPI spends on Flipkart (page).' }),
      R({ id: 'utkarsh-supercard-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, reason: '1% cashback on all other UPI and non-UPI credit card transactions (page).' }),
    ],
    late: [{ min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }],
    sources: utSource('supercard', `${UT}/xsite/assests/personal_credit_card/SuperCard_Most_Important_Terms_&_Conditions_MITC.pdf`),
    unverified: ['Cashback caps, excluded categories and period are in the MITC, which was not readable; no cap or exclusion rules drafted.', 'Network not stated on the page (UPI works on the card, which suggests RuPay, but that is an inference and is not recorded).', 'Late fee on the page: nil below INR 100 of limit; 5% of total amount due below INR 2,000; 10% of total amount due capped at INR 1,250 at INR 2,000 or above (stated against "credit limit" on the page, likely meaning amount due); only the nil band is modelled.', 'Domestic cash advance 5% or INR 25 whichever is higher; international 5% or INR 500; physical card fee INR 249.', 'Partner brand Supermoney; revenue-sharing statement on the page says it funds the reward proposition.'] }),
  'utkarsh-wish': common({ ...utCommon, name: 'Utkarsh Wish Credit Card', joining: 0, annual: 0, url: `${UT}/personal/cards/credit-card/wish-credit-card`, mode: 'open', upi: true, apr: [3, 36], grace: 45,
    eligNote: 'FD-backed credit card applied for in the PhonePe app; individual with valid PAN, mobile and email, Indian resident, age 18 to 80 (page).',
    waiverText: 'No joining or annual fee (page).',
    rules: [
      R({ id: 'utkarsh-wish-phonepe-bills', cat: 'bills', pri: 10, mult: 1, ppb: null, cb: null, cond: { platform: 'phonepe', kind: 'recharge_and_bill_payments' }, reason: '3% reward points on recharges and bill payments through the PhonePe app (page; MITC for details, not read).' }),
      R({ id: 'utkarsh-wish-phonepe-scan', cat: 'all_retail', pri: 11, mult: 1, cond: { platform: 'phonepe', kind: 'scan_and_pay' }, reason: '1% reward points on scan and pay through PhonePe (page).' }),
      R({ id: 'utkarsh-wish-online-brands', cat: 'online', pri: 12, mult: 1, cond: { kind: 'select_online_brands' }, reason: '1% reward points on select online brands (page; brand list not read).' }),
    ],
    
    late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: null }],
    sources: utSource('wish-credit-card', `${UT}/xsite/assests/personal_credit_card/Wish_KFS.pdf`),
    unverified: ['Rupee value of a reward point is not stated on the page; the MITC was not readable. Percent rates are stated as "reward points" so cannot be converted.', 'Reward rule percentages are held as text conditions only; points per block not stated. The page also lists 200 reward points on monthly spends of INR 15,000, not modelled because the schema has no monthly milestone period.', 'Network not stated on the page.', 'Late fee: 10% of outstanding amount (total amount due less payments received by the due date), capped at INR 1,250; modelled as no numeric slab because it is percentage-based.', 'Domestic cash advance 5% or INR 25 whichever is higher; international 5% or INR 500; physical card fee INR 249.', 'Partner PhonePe.'] }),
};

// ───────────────────────────── DCB
const DCB = 'https://www.dcb.bank.in';
const dcbMcc = [6010, 6011, 6012, 6051, 6513, 6540, 7800, 7801, 7995, 8651, 5541, 5542, 5172];
const dcbCommon = { issuer: 'dcb-bank', mode: 'open', upi: true };
const dcbCards = {
  'dcb-zet': common({ ...dcbCommon, name: 'DCB ZET Credit Card', network: 'rupay', tier: 'rupay_select', joining: 0, annual: 0, url: `${DCB}/personal/cards/secured-card/dcb-zet-credit-card`, apr: [3.5, 42], forex: 2.49,
    eligNote: 'Fixed-deposit-backed: FD INR 2,000 to INR 10 lakh, minimum tenure 1 year, limit 90% of FD, applied for in the ZET app. Free physical card from cumulative FD of INR 5,000 (KFS).',
    eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 2000, allowed_values: [] }],
    waiverText: 'Joining fee, annual fee and minimum spend for waiver all Nil (KFS). Card closure INR 499 if closed within a year.',
    late: DCB_LATE, rules: [],
    sources: [
      { url: `${DCB}/personal/cards/secured-card/dcb-zet-credit-card`, kind: 'DCB product page (embedded page data): features, fee table, FAQ', read: 'rendered page data' },
      { url: `${DCB}/api/dcb/assets/2026-02/KFS-for-DCB-Zet-Credit-Card.pdf`, kind: 'KFS (file dated Feb 2026): table lists "DCB ZET Card (Rupay Select)"; fees, interest, late fee, forex 2.49%', read: 'pdftotext' },
      { url: `${DCB}/api/dcb/assets/2026-02/MITC-for-DCB-ZET-Credit-Card.pdf`, kind: 'MITC: RuPay Select; no reward table', read: 'pdftotext' },
    ],
    unverified: ['No earn rate published: the page says it "offers similar rewards as regular Credit Cards" and a revenue-sharing PDF exists, but no rate, cap or exclusion is stated in the page, KFS or MITC. No reward rules drafted. Card is held for that reason.', 'Forex conflict: KFS, MITC and the fee table say cross currency markup 2.49%; the page FAQ says 3.5%. KFS value used.', 'Late fee text reads "greater than INR 100 or less than or equal to INR 100 INR 1,000" on the page (typo); KFS reads INR 100 to INR 1,000: INR 100; above INR 1,000: INR 500.', 'MITC lists RuPay Select insurance cover subject to nominee details; amount not extracted.'] }),
  'dcb-novio': common({ ...dcbCommon, name: 'DCB novio Credit Card (RuPay Platinum / RuPay Select)', network: 'rupay', tier: 'rupay_platinum', joining: 0, annual: 0, url: `${DCB}/personal/cards/secured-card/dcb-novio-credit-card`, apr: [3, 36], forex: 2.5,
    eligNote: 'Fixed-deposit-backed (DCB FD from INR 2,000), applied for in the novio app. Variant by FD: INR 2,000-9,999 Platinum virtual only; 10,000-24,999 Platinum virtual and physical; 25,000 and above Select virtual and physical (page). Limit 90% of FD.',
    waiverText: 'Joining and annual fee Nil for both RuPay Platinum and RuPay Select (MITC v1.1 dated 20 Apr 2026). Closure INR 599 within a year.',
    late: DCB_LATE, fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 100 }, rules: [],
    benefits: [B({ id: 'dcb-novio-select-lounge', cat: 'lounge', program: 'rupay', sponsor: 'DCB Bank', label: 'RuPay Select variant: domestic lounge visits, 4 a year', qty: 1, per: 'quarter' })],
    sources: [
      { url: `${DCB}/personal/cards/secured-card/dcb-novio-credit-card`, kind: 'DCB product page (embedded page data)', read: 'rendered page data' },
      { url: `${DCB}/api/dcb/assets/2026-04/KFS-DCB-Novio-Card.pdf`, kind: 'KFS (file dated Apr 2026): Platinum and Select fees', read: 'pdftotext' },
      { url: `${DCB}/api/dcb/assets/2026-04/MITC-DCB-Novio-Card.pdf`, kind: 'MITC v1.1, 20 Apr 2026: fees, fuel waiver, lounge, rewards clause (table is blank in the PDF)', read: 'pdftotext and page images viewed' },
    ],
    unverified: ['No earn rate published: the MITC rewards clause 10 says the rewards programme is powered by novio, refers to the novio app for T&Cs, and says rewards are paid in the first month of the next quarter on a spend milestone, but the milestone table is blank in the PDF (pages 7-8 viewed). Card is held for that reason.', 'Exclusions stated: rent, wallet loading, online gaming, gambling, fuel and cash withdrawal earn nothing (MITC).', 'Two variants share one slug; fees are identical (nil) so they are not split. Lounge is Select only: 1 domestic visit a quarter, 4 a year (MITC); Platinum none.', 'ATM cash fee 2.5% or INR 299; cash advance fee 2.5%; penal interest 3% a month.'] }),
  'dcb-niyo': common({ ...dcbCommon, name: 'DCB Niyo Credit Card', network: 'visa', joining: 0, annual: 0, url: `${DCB}/personal/cards/secured-card/dcb-niyo-credit-card`, upi: null, apr: [3, 36], forex: 0,
    eligNote: 'Secured by a lien on a DCB Niyo Savings Account: limit 90% of lien amount; minimum limit INR 5,000, maximum INR 25 lakh (page).',
    waiverText: 'Joining and annual fee nil; closure nil (KFS, page).',
    late: DCB_LATE, rules: [],
    sources: [
      { url: `${DCB}/personal/cards/secured-card/dcb-niyo-credit-card`, kind: 'DCB product page (embedded page data)', read: 'rendered page data' },
      { url: `${DCB}/api/dcb/assets/2025-10/KFS-for-DCB-Niyo-Secured-Credit-Card.pdf`, kind: 'KFS titled "DCB Niyo Global Credit Card (Visa Card network)": fees, forex nil with Visa exchange rates', read: 'pdftotext' },
      { url: `${DCB}/api/dcb/assets/2026-04/DCB%20-Niyo-Global-Credit-Card-MITC.pdf`, kind: 'MITC (Version 1.0, August 2025): "Visa Card network exchange rates apply"', read: 'pdftotext' },
    ],
    unverified: ['Network Visa: stated in the KFS table ("Visa Card network") and the MITC forex row. The tier is not stated.', 'No earn rate published on the page, KFS or MITC; a revenue-sharing PDF exists. Card is held for that reason.', 'KFS and MITC call the card "DCB Niyo Global Credit Card"; the page calls it "DCB Niyo Secured Credit Card".', 'Cash advance: 2.5% or INR 250 whichever is higher; 3% a month interest on cash advance.'] }),
  'dcb-payless-platinum': common({ ...dcbCommon, name: 'DCB PayLess Platinum Credit Card', network: 'rupay', tier: 'rupay_platinum', joining: 0, annual: 350, url: `${DCB}/personal/cards/secured-card/dcb-payless-platinum-card`, apr: [3, 36], forex: 3.5, baseCb: 0,
    eligNote: 'Fixed-deposit-backed; minimum DCB FD INR 15,000, tenure at least 1 year, age 18-75 (page).', eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 15000, allowed_values: [] }],
    waiver: 50000, waiverText: 'Annual fee INR 350 waived on spending INR 50,000 in the previous calendar year (INR 0 as part of a limited offer, per the page).', waiverPeriod: 'calendar_year',
    late: DCB_LATE, fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 100 },
    rules: [X('dcb-payless-plat-excl', 'excluded_spend', dcbMcc, 'Rent, wallet loading, online gaming, gambling, fuel and cash withdrawal are not counted for the cashback (page footnote; MCCs 6010, 6011, 6012, 6051, 6513, 6540, 7800, 7801, 7995, 8651, 5541, 5542, 5172).')],
    milestones: [{ id: 'dcb-payless-plat-quarterly-50k', label: 'INR 250 cashback on spending INR 50,000 in a quarter (page)', threshold_spend_inr: 50000, reward_value_inr: 250, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null }],
    benefits: [B({ id: 'dcb-payless-plat-lounge', cat: 'lounge', program: 'rupay', sponsor: 'DCB Bank', label: 'Domestic airport lounge access, 4 times per calendar year (1 per quarter)', qty: 1, per: 'quarter' }), B({ id: 'dcb-payless-plat-pai', cat: 'insurance_related_perk', sponsor: 'RuPay', label: 'Personal accident insurance cover INR 2,00,000 provided by RuPay', value: 200000 })],
    sources: [
      { url: `${DCB}/personal/cards/secured-card/dcb-payless-platinum-card`, kind: 'DCB product page (embedded page data): features, fee table, MCC footnote; page text says "powered by RuPay"', read: 'rendered page data' },
    ],
    unverified: ['Network RuPay (Platinum tier from the card name): page text "feature packed secured Credit Card powered by RuPay"; the RuPay Platinum insurance annexures are linked from the page. No KFS or MITC link was found on the page, so fees come from the page table only.', 'Cashback is a quarterly spend milestone (INR 250 on INR 50,000); the page does not define the quarter (calendar or card quarter) or whether it is cash or points; modelled as cash value.', 'Annual fee is INR 350 on the page table, with a note that it is INR 0 as part of a limited offer; the offer end date is not stated.', 'Fuel waiver on MCC 5541, 5542, 5172 up to INR 100 a statement cycle on transactions up to INR 5,000; the lower transaction bound is not stated.', 'Lounge program is managed under RuPay; spend conditions for lounge are not stated on the page.'] }),
  'dcb-payless-select': common({ ...dcbCommon, name: 'DCB PayLess Select Credit Card', network: 'rupay', tier: 'rupay_select', joining: 0, annual: 1000, url: `${DCB}/personal/cards/secured-card/dcb-payless-select-card`, apr: [3, 36], forex: 3.5, baseCb: 0,
    eligNote: 'Fixed-deposit-backed; minimum DCB FD INR 1,50,000, tenure at least 1 year (page).', eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 150000, allowed_values: [] }],
    waiver: 200000, waiverText: 'Annual fee INR 1,000 waived on spending INR 2,00,000 in the previous calendar year (INR 0 as part of a limited offer, per the page).', waiverPeriod: 'calendar_year',
    late: DCB_LATE, fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 100 },
    rules: [X('dcb-payless-select-excl', 'excluded_spend', dcbMcc, 'Rent, wallet loading, online gaming, gambling, fuel and cash withdrawal are not counted for the cashback (page footnote).')],
    milestones: [{ id: 'dcb-payless-select-quarterly-1l', label: 'INR 1,000 cashback on spending INR 1,00,000 in a quarter (page)', threshold_spend_inr: 100000, reward_value_inr: 1000, period: 'quarter', is_repeatable: true, effective_from: null, effective_to: null }],
    benefits: [B({ id: 'dcb-payless-select-lounge', cat: 'lounge', program: 'rupay', sponsor: 'DCB Bank', label: 'Lounge access: 9 visits a year, 1 international a year and 2 domestic a quarter', qty: 9, per: 'annual' }), B({ id: 'dcb-payless-select-pai', cat: 'insurance_related_perk', sponsor: 'RuPay', label: 'Personal accident insurance cover INR 10,00,000 provided by RuPay', value: 1000000 })],
    sources: [{ url: `${DCB}/personal/cards/secured-card/dcb-payless-select-card`, kind: 'DCB product page (embedded page data); text says "premium secured Credit Card powered by RuPay"', read: 'rendered page data' }],
    unverified: ['Network RuPay (Select tier from the card name): page text "powered by RuPay"; no KFS or MITC link on the page, fees from the page table only.', 'Cashback is a quarterly spend milestone; quarter definition and cash-versus-points not stated; modelled as cash value.', 'Annual fee INR 1,000 on the page table with an INR 0 limited-offer note; offer end date not stated.', 'Fuel waiver lower transaction bound not stated.'] }),
};

// ───────────────────────────── UNITY
const UN = 'https://unity.bank.in';
const unityCards = {
  'unity-bank-zero': common({ issuer: 'unity-small-finance-bank', name: 'Unity Bank Zero Credit Card', network: 'rupay', joining: 0, annual: 0, url: 'https://cards.unity.bank.in/', upi: true, mode: 'open', block: 100, basePts: 1, forex: 0, pv: 0.25, pvBasis: 'Unity ZERO Credit Card Rewards and Benefits T&Cs (Version 1.0, October 2026) clause 2.1: for redemption as cashback or statement credit, 1 Reward Point = INR 0.25; other redemption options may differ.', expiry: 24, baseRet: 0.25,
    eligNote: 'Fixed-deposit-backed: start with an FD of INR 2,000; assured approval, no income proof or credit history needed (page).', eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 2000, allowed_values: [] }],
    waiverText: 'Joining fee, annual fee, EMI processing fee, rewards redemption fee and late payment fee all stated as none on the issuer card page.',
    rules: [
      X('unity-zero-excl-intl', 'international_spend', [], 'International and foreign-currency transactions earn no reward points (T&Cs 2.5 and 2.7).'),
      X('unity-zero-excl-upi-small', 'upi', [], 'Credit-card-on-UPI transactions of INR 2,000 or below at small offline merchants earn no reward points (T&Cs 2.5 and 2.7).', { transaction_amount_lte_inr: 2000, rail: 'upi' }),
      X('unity-zero-excl-fuel', 'fuel', [5541, 5983, 5542], 'Fuel earns 0 reward points (T&Cs 2.7).'),
      R({ id: 'unity-zero-essentials', cat: 'bills', pri: 10, mult: 3, ppb: 3, cond: { per_inr_block: 100, mcc_list: [5812, 5811, 5814, 5462, 5813, 4900, 4814, 4816, 4899, 5411, 5451, 5499, 5422, 5441, 5912, 8062, 8099, 8071, 742, 5122, 8021, 6513] }, reason: 'Monthly Essentials (dining, utilities, groceries, medical, rent) 3 reward points per INR 100, each point INR 0.25 (0.75%) (T&Cs 2.7).' }),
      R({ id: 'unity-zero-shopping', cat: 'online', pri: 11, mult: 4, ppb: 4, cond: { per_inr_block: 100, mcc_list: [5699, 5691, 5651, 5311, 5331, 5137, 5611, 5621, 5631, 5641, 5661, 5697, 5977, 5712, 5999, 5947, 5943, 5942, 5995, 5945, 5948, 5310, 5940, 5941, 5949, 5946, 5719, 5309, 5733, 5950, 5931, 5714, 5735, 5262, 5399, 7311, 5944, 5094] }, reason: 'Shopping 4 reward points per INR 100 (1%) (T&Cs 2.7).' }),
      R({ id: 'unity-zero-electronics', cat: 'online', pri: 12, mult: 4, ppb: 4, cond: { per_inr_block: 100, mcc_list: [5732, 4812, 5722, 5045, 5099] }, reason: 'Electronics 4 reward points per INR 100 (1%) (T&Cs 2.7).' }),
      R({ id: 'unity-zero-wallet', cat: 'wallet', pri: 13, mult: 4, ppb: 4, cond: { per_inr_block: 100, mcc_list: [6540] }, reason: 'Wallet loads 4 reward points per INR 100 (1%) (T&Cs 2.7).' }),
      R({ id: 'unity-zero-udeals', cat: 'online', pri: 9, mult: 6, ppb: 6, cond: { per_inr_block: 100, merchant: 'u_deals_gift_cards' }, reason: 'Eligible U-Deals gift card and voucher purchases 6 points per INR 100 (1.5%), the total earn, not additional; card journey only, credit-card-on-UPI disabled (T&Cs 4).' }),
      R({ id: 'unity-zero-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100, rounding: 'nearest_100_then_multiply', min_txn_inr: 100 }, reason: 'Other eligible transactions 1 reward point per INR 100 (0.25%); points = round(amount / 100) x rate; under INR 100 earns nothing; no accrual cap (T&Cs 2.2, 2.6, 2.7).' }),
    ],
    fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 1000, max_txn_inr: 5000, monthly_waiver_cap_inr: 100 },
    late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 0 }],
    sources: [
      { url: 'https://cards.unity.bank.in/', kind: 'Unity ZERO card page (read in the built-in browser): fees, up to 1.5% cashback, exclusions', read: 'rendered page text' },
      { url: 'https://cards.unity.bank.in/docs/credit-cards/zero-credit-card-terms', kind: 'ZERO Credit Card Rewards and Benefits T&Cs, Version 1.0, October 2026 (PDF created 28 Oct 2026): earn table, point value, expiry, fuel waiver, forex, RuPay exchange rate', read: 'pdftotext' },
      { url: `${UN}/personal-banking/cards/credit-card`, kind: 'Unity credit card listing page: Zero card summary', read: 'page text' },
    ],
    unverified: ['Network RuPay: the T&Cs (5.3) say non-DCC conversion uses the "applicable RuPay exchange rate" and the Unity listing is titled RuPay; tier not stated.', 'Interest rate on revolving balances, MITC, KFS and per-card fee schedule were not found on the Unity site (the cardholder agreement of Oct 2026 is generic); APR left null. The page says the late payment fee is nil.', 'Page says up to 1.5% cashback; the T&Cs give 0.25% base, 0.75% essentials, 1% shopping, electronics and wallet, 1.5% U-Deals, which is consistent.', 'Rent MCC 6513 is listed under Monthly Essentials in the T&Cs (3 points per INR 100), while the page footer groups rent with essentials; no conflict, noted because other issuers exclude rent.', 'Reward points expire 24 months from accrual; minimum redemption 250 points (INR 62.50).', 'Rewards T&Cs mention an optional "Reward Plan" concept (used on Vibe); Zero has none stated.'] }),
  'unity-bank-vibe': common({ issuer: 'unity-small-finance-bank', name: 'Unity Bank Vibe Credit Card', network: null, joining: null, annual: null, url: `${UN}/personal-banking/cards/credit-card`, upi: true, mode: 'open', forex: 0,
    eligNote: 'Fixed-deposit-backed: start with an FD of INR 25,000 (listing).', eligRules: [{ parameter: 'fd_amount_inr', operator: '>=', threshold_value: 25000, allowed_values: [] }],
    waiverText: 'Listing says "Lifetime Free Options" for the card range but gives no Vibe-specific fee table.',
    benefits: [B({ id: 'unity-vibe-lounge', cat: 'lounge', sponsor: 'Unity Small Finance Bank', label: '10 complimentary airport lounge accesses every year (listing)', qty: 10, per: 'annual' })],
    sources: [{ url: `${UN}/personal-banking/cards/credit-card`, kind: 'Unity credit card listing: Vibe summary only', read: 'page text' }, { url: 'https://cards.unity.bank.in/', kind: 'Unity cards site (Zero only; no Vibe page or T&C reachable from it)', read: 'rendered page text' }],
    unverified: ['No Vibe-specific terms were found: the cards.unity.bank.in site shows only the Zero card and links only a Zero rewards T&C; the listing gives headline claims (0% forex, 10 lounge visits a year, flexible reward plan, up to 2% cashback, rewards retained on EMI conversion).', 'No earn rate, reward plan table, fees, network or point value is stated. Card is held for that reason.'] }),
  'roarbank-unity-credit-card': common({ issuer: 'unity-small-finance-bank', name: 'Roarbank Credit Card (Unity SFB)', network: null, joining: 0, annual: 0, url: `${UN}/personal-banking/cards/credit-card/usfb-roarbank-credit-card`, upi: true, mode: 'open', apr: [3.3, 39.6], forex: 3.5, grace: 62,
    eligNote: 'Indian residents aged 21-60, valid PAN and Aadhaar, salaried or self-employed; starter limit for those with no credit score (page). 2-in-1 card with a Roarbank savings account.',
    waiverText: 'Joining, annual, renewal, reissue and replacement fees all nil (MITC dated 12 May 2025).',
    late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 500 }],
    rules: [R({ id: 'roarbank-utilities-topups', cat: 'bills', pri: 20, mult: 1, cb: 1, reason: '1% cashback on utility payments and mobile top-ups at all times, regardless of category selection (MITC clause 8.b).' })],
    caps: [C({ id: 'roarbank-monthly-cashback-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'calendar_month', inr: 2500, after: 'zero_accrual' })],
    catSur: [{ category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of amount paid on rent under MCC 6513', threshold_spend_inr: null, effective_from: null, effective_to: null }],
    sources: [
      { url: `${UN}/personal-banking/cards/credit-card/usfb-roarbank-credit-card`, kind: 'Unity Roarbank page: features, fee summary', read: 'page text' },
      { url: 'https://theunitybank.com/docs/roarbank/roarbank-credit-card-most-important-terms-and-conditions.pdf', kind: 'Roarbank credit card MITC (Google Docs export, file title dated 12 May 2025): fees, cashback scheme clause 8, forex', read: 'pdftotext' },
    ],
    unverified: ['Cashback: the user picks 2 categories each month; each category has its own percentage that "may vary on a monthly basis" and is capped at 20%; the actual percentages are not published in the MITC or page, so no category earn rule can be drafted. Card is held for that reason.', 'Cap: maximum cashback INR 2,500 per calendar month; minimum withdrawal INR 250 (MITC).', 'Network not stated on the page or MITC ("Card Network" is defined generically).', 'Late fee: 2% of amount due, minimum INR 500; modelled as a single INR 500 slab.', 'The MITC file is dated May 2025 by its title; the page may be newer.'] }),
  'unity-bank-bharatpe': common({ issuer: 'unity-small-finance-bank', name: 'Unity Bank BharatPe Credit Card', network: 'rupay', tier: 'rupay_select', joining: 0, annual: 0, url: `${UN}/personal-banking/cards/credit-card/usfb-bharatpe-credit-card`, upi: true, mode: 'open', block: 100, baseCb: 2, baseRet: 2, forex: 3.5, grace: 48, apr: [2, 24], pv: 0.25, pvBasis: 'Unity BharatPe MITC (file dated Aug 2026), Reward Points clause H: 4 Zillion Coins = INR 1.',
    eligNote: 'Salaried: age 21-65, income at least INR 2.5 lakh a year; self-employed: age 21-65, income at least INR 5 lakh a year; applied for only through the BharatPe app (page).',
    waiverText: 'Joining and annual membership fee nil (KFS).',
    late: [{ min_balance_inr: 0, max_balance_inr: 100, fee_inr: 40 }, { min_balance_inr: 101, max_balance_inr: 250, fee_inr: 90 }, { min_balance_inr: 251, max_balance_inr: 500, fee_inr: 150 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 250 }, { min_balance_inr: 1001, max_balance_inr: 2500, fee_inr: 500 }, { min_balance_inr: 2501, max_balance_inr: 5000, fee_inr: 750 }, { min_balance_inr: 5001, max_balance_inr: 7500, fee_inr: 900 }, { min_balance_inr: 7501, max_balance_inr: 10000, fee_inr: 1000 }, { min_balance_inr: 10001, max_balance_inr: null, fee_inr: 1500 }],
    rules: [R({ id: 'unity-bharatpe-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 2, mult: 1, reason: '2% cashback in Zillion Coins on bill-period spends, earned on repayment of the bill principal (excluding fees, interest, charges, tax), no merchant category restriction (page and MITC; w.e.f. 14 Aug 2025). 4 coins = INR 1.' })],
    benefits: [B({ id: 'unity-bharatpe-lounge-dom', cat: 'lounge', program: 'rupay', sponsor: 'Unity Small Finance Bank', label: 'RuPay domestic airport lounge visits (RuPay Exclusive Delhi T3 lounge excluded)', qty: 2, per: 'quarter' }), B({ id: 'unity-bharatpe-lounge-intl', cat: 'lounge', program: 'rupay', sponsor: 'Unity Small Finance Bank', label: 'Complimentary international lounge visits at 500+ lounges', qty: 2, per: 'annual' }), B({ id: 'unity-bharatpe-health', cat: 'other', sponsor: 'RuPay', label: 'One complimentary health checkup package a year', qty: 1, per: 'annual' })],
    sources: [
      { url: `${UN}/personal-banking/cards/credit-card/usfb-bharatpe-credit-card`, kind: 'Unity BharatPe page: "Unity BharatPe RuPay Credit Card", features, eligibility, lounge, rewards', read: 'page text' },
      { url: `${UN}/docs/credit-cards/mitc-unity-bank-bharatpe-credit-card.pdf`, kind: 'MITC (file title "Aug 26", PDF created 11 Sep 2026): LPC table, rewards clause H, forex, grace, EMI', read: 'pdftotext' },
      { url: `${UN}/docs/credit-cards/key-fact-statement-unity-bharatpe-credit-card-final.pdf`, kind: 'KFS (file title Feb 2025): fees; APR 24%', read: 'pdftotext' },
    ],
    unverified: ['Interest: 2% a month (24% a year) is stated as the Auto-EMI interest and overdue interest rate; the rate on any other revolving balance was not separately stated.', 'Reward is earned on repayment of bill-period unpaid spends (after auto-EMI conversion), not at swipe time, and credited as Zillion Coins on the next billing date; modelled as a flat 2% on spends.', 'Table B in the MITC prints the 2% rate only against the INR 1,000 to INR 9,999 row but the page shows 2% for all bands w.e.f. 14 Aug 2025; page used.', 'Network RuPay stated on the page ("Unity BharatPe RuPay Credit Card"); tier Select is inferred from the RuPay Select link next to the lounge section, so network_tier is only indicative.', 'KFS file title is Feb 2025 and lists forex 3.5% and 1% fuel surcharge with no waiver; the MITC is newer (Aug 2026) and agrees on forex.', 'Cash advance fee: online cash withdrawal INR 15 per transaction.'] }),
};

// ───────────────────────────── ESAF
const esafCards = {
  'esaf-inori-rupay-platinum': common({ issuer: 'esaf-small-finance-bank', name: 'ESAF INORI RuPay Platinum Credit Card', network: 'rupay', tier: 'rupay_platinum', joining: null, annual: null, url: 'https://www.esaf.bank.in/credit-card/', upi: null, mode: 'open', baseCb: 1.25,
    waiverText: 'Fees are in the MITC, which could not be read (see open questions).',
    benefits: [B({ id: 'esaf-inori-insurance', cat: 'insurance_related_perk', sponsor: 'ESAF Small Finance Bank', label: 'Personal accident and permanent disability cover up to INR 2 lakh (page)', value: 200000 }), B({ id: 'esaf-inori-concierge', cat: 'concierge', sponsor: 'ESAF Small Finance Bank', label: '24/7 concierge service (page)' })],
    sources: [
      { url: 'https://www.esaf.bank.in/credit-card/', kind: 'ESAF INORI page (read in the built-in browser; plain fetch returned 403)', read: 'rendered page text' },
      { url: 'https://www.esaf.bank.in/wp-content/uploads/2026/08/Most-Important-Terms-And-Conditions-MITC-Inori_English.pdf', kind: 'INORI MITC Aug 2026: NOT READ (403 to plain fetch; the browser only offers a download)', read: 'not read' },
    ],
    unverified: ['Fees, interest, forex, late fee, fuel cashback terms, exclusions and caps are all in the MITC and fuel cashback T&C PDFs, which could not be read; only the page headline is known.', 'Earn: page says 1.25% cashback "on all bill amounts" with T&Cs apply; exclusions and caps unknown. No reward rules drafted.', 'Network RuPay Platinum is in the card name and page heading ("RuPay Platinum Credit Card"); no MITC confirmation read.'] }),
};

export const cards = { ...axisCards, 'sib-one-co-branded-credit-card': sibOne, ...utCards, ...dcbCards, ...unityCards, ...esafCards };
