// Wave 5, agent W5E (15 Nov 2026): City Union Bank, Tamilnad Mercantile Bank, Dhanlaxmi Bank, J&K Bank, Saraswat Co-operative Bank.
// Every value below comes from an issuer page or issuer document read on 2026-11-15 (pages fetched with curl and stripped to text,
// PDFs read with pdftotext; the Saraswat main MITC is a scanned booklet and was read with tesseract OCR). Unknown stays null.
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const FETCHED = { fetched_on: '2026-11-15' };
const NA = 'N/A';

// ───────────────────────────── shared builders
function fees(o) {
  return {
    apr: { monthly_interest_rate_percent: o.apr?.[0] ?? null, annual_interest_rate_percent: o.apr?.[1] ?? null },
    forex_markup: { markup_percent: o.forex ?? null, gst_applicable: o.forex === undefined || o.forex === null ? null : true },
    dynamic_currency_conversion_dcc: { fee_percent: o.dcc ?? null, gst_applicable: o.dcc ? true : null, trigger_condition: o.dccNote ?? null },
    fuel_surcharge: o.fuel ?? { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
    cash_advance: { atm_transaction_fee_percent: o.cash?.[0] ?? null, atm_transaction_fee_min_inr: o.cash?.[1] ?? null, interest_applicable_from_day_one: o.cashDay1 ?? null, daily_interest_percent: null, max_limit_percent: o.cashLimit ?? null },
    category_surcharges: o.surch ?? [],
    emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: o.emiFee ?? null, foreclosure_charge_percent: o.emiForeclose ?? null, gst_applicable: o.emiFee || o.emiForeclose ? true : null },
    banking_penalties: { overlimit_charge: { fee_percent: o.over?.[0] ?? null, min_fee_inr: o.over?.[1] ?? null, gst_applicable: o.over ? true : null }, auto_debit_bounce_charge_inr: o.bounce ?? null, cheque_bounce_charge_inr: o.bounce ?? null },
  };
}
const rentSurch = (pct = 1) => ({ category_id: 'rent', mcc_list: [6513], fee_percent: pct, gst_applicable: true, trigger_condition: `${pct}% of each rent payment under MCC 6513 (issuer fee table)`, threshold_spend_inr: null, effective_from: null, effective_to: null });

const card = (o) => ({
  card_product: {
    ...GST, name: o.name, issuer_slug: o.issuer, card_type: 'credit', network: o.network ?? null, network_tier: o.tier ?? null,
    application_mode: 'open', joining_fee_inr: o.joining ?? null, annual_fee_inr: o.annual ?? null, is_upi_linkable: o.upi ?? false,
    data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: o.page, status: 'draft', verified_at: null,
    point_value_inr_baseline: o.pv ?? null, point_value_baseline_basis: o.pvBasis ?? null, point_expiry_months: o.expiry ?? null,
    ...(o.cp ?? {}),
  },
  eligibility_engine: { evaluation_mode: 'guideline_only', notes: o.elig ?? null, rules: o.eligRules ?? [], required_documents: [] },
  accrual_engine: o.accrual ?? { base_block_inr: null, rounding_mode: null, base_points_per_block: null, base_cashback_percent: null, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  reward_rules: o.rules ?? [],
  cap_rules: o.caps ?? [],
  fees_and_surcharges: fees(o),
  statement_and_late_fees: {
    grace_period_days: null, grace_period_void_on_revolving_balance: null,
    minimum_amount_due_mad: o.mad ?? { calculation_mode: null, components: [] },
    late_payment_slabs: o.late ?? [],
  },
  fee_waiver_and_milestones: {
    annual_fee_waiver: o.waiver ?? { threshold_spend_inr: NA, period: NA, evaluation_condition: 'No annual fee to waive (issuer states nil annual fee).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: NA },
    welcome_and_renewal_gift: o.welcome ?? { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
    spend_milestones: o.milestones ?? [],
  },
  addon_card_rules: { max_addon_cards: null, fee_per_card_inr: o.addon ?? null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
  lifestyle_and_network_benefits: o.benefits ?? [],
  dynamic_promotions_registry: o.promos ?? [],
  additional_data: { items: [
    ...(o.dual ? [dualNetwork(o.dual)] : []),
    ...prov({ sources: o.sources, unverified: o.open, notes: o.notes ?? [], extra: FETCHED }),
    ...(o.extraItems ?? []),
  ] },
});

// ───────────────────────────── City Union Bank
const CUB_KFS = 'https://cityunionbank.bank.in/filemanager/Oct26/KFS_V6%20English.pdf';
const CUB_REW = 'https://cityunionbank.bank.in/filemanager/Apr26/CSK_SRHRewards_Features.pdf';
const CUB_PAGE = 'https://cityunionbank.bank.in/co-branded-creditcard';
const CUB_KAV_KFS = 'https://cityunionbank.bank.in/filemanager/Jun26/KFS%20Kavach.pdf';
const CUB_KAV_REW = 'https://cityunionbank.bank.in/filemanager/Sep26/Kavachh_Reward_Document.pdf';
const CUB_KAV_PAGE = 'https://cityunionbank.bank.in/cub-kavach-terms-and-conditions';
const CUB_KAV_MITC = 'https://cityunionbank.bank.in/filemanager/Jun26/MITC%20Kavach.pdf';

const cubExclMccs = [5094, 5944, 6513, 6538, 6539, 6540, 6541, 6542, 5172, 5541, 5542, 5983, 6010, 6011, 6012, 6050, 6051, 7801, 7995, 9754, 5111, 5192, 5942, 5943, 8211, 8220, 8241, 8244, 8249, 8299, 8351];
const cubExclRanges = [[4800, 4999], [5960, 6399], [9000, 9999]];
const cubExcl = (v) => X(`cub-${v}-excluded`, 'excluded_spend', cubExclMccs, 'No reward points on utilities and telecom, gold and jewellery, rent, wallet loads, insurance, government payments, fuel, cash, gambling and educational services (CSK/SRH Rewards Document section 5).', { mcc_ranges: cubExclRanges });
const cubLate = [{ min_balance_inr: 0, max_balance_inr: 25000, fee_inr: 350 }, { min_balance_inr: 25001, max_balance_inr: null, fee_inr: 450 }];
const cubSurch = [rentSurch(1),
  { category_id: 'wallet', mcc_list: [6538, 6539, 6540, 6541, 6542], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of each wallet load (KFS V6)', threshold_spend_inr: null, effective_from: null, effective_to: null },
  { category_id: 'fuel', mcc_list: [5983, 5541, 5542, 5172], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative fuel spends of INR 50,000 or more in a statement cycle (KFS V6)', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
  { category_id: 'bills', mcc_list: [4814, 4899, 4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative utility spends of INR 25,000 or more in a statement cycle (KFS V6, Kavach KFS names MCC 4814, 4899, 4900)', threshold_spend_inr: 25000, effective_from: null, effective_to: null },
  { category_id: 'entertainment', mcc_list: [5816], fee_percent: 1, gst_applicable: true, trigger_condition: '1% on cumulative online skill-gaming spends of INR 10,000 or more in a statement cycle (KFS V6; MCC 5816 per the Kavach KFS)', threshold_spend_inr: 10000, effective_from: null, effective_to: null }];
const cubSources = (extra = []) => [
  { url: CUB_KFS, kind: 'CUB Key Fact Statement for Credit Cards KFS_V6, updated 03.10.2026 (8 pages): fees, interest, forex, fuel waiver, late fee', read: 'pdftotext' },
  { url: CUB_REW, kind: 'Card Product Reward Document, CUB CSK/SRH Credit Card (6 pages, issuer folder Apr26): earn rates, redemption value per variant, excluded MCCs', read: 'pdftotext' },
  { url: CUB_PAGE, kind: 'Issuer co-brand page: 302-redirects to the application app (cubcard.cub.bank.in), which showed only a loading screen with no product text', read: 'curl + page fetch' },
  ...extra,
];
const cubCsOpen = [
  'Welcome benefit, lounge access, milestone offers and insurance cover for the CSK/SRH cards: none appears in the KFS V6 or the Rewards Document. The issuer page https://cityunionbank.bank.in/co-branded-creditcard redirects to an application app that shows no product text, so no features page was readable. A person should read the CSK and SRH product pages in a browser (or ask the bank) for these.',
  'Team editions: the issuer offers a Chennai Super Kings edition and a Sunrisers Hyderabad edition (per the 7 Nov sweep of the issuer page); the KFS and Rewards Document treat them as one product with the same fees and rewards, so one record covers both.',
  'Annual fee waiver period (card anniversary year or calendar year) is not stated; threshold_spend and period left as stated or null.',
  'Network wording: the variant names in the KFS and Rewards Document carry the network (RUPAY / MASTER); no network tier is stated except World in "Master World".',
  'Reward expiry: the Rewards Document says only "Reward Points may expire as per the Bank\'s policy" with no period, so point_expiry_months is null.',
];

const cubRuPay = card({
  name: 'CUB CSK/SRH RuPay Platinum Credit Card (lifetime free)', issuer: 'city-union-bank', network: 'rupay', tier: 'rupay_platinum', joining: 0, annual: 0, upi: true, page: CUB_PAGE,
  pv: 0.5, pvBasis: 'CUB CSK/SRH Rewards Document section 4.1: redemption value RuPay Platinum INR 0.50 per Reward Point (1,000 RP = INR 500) at the rewards portal https://rewards.cub.bank.in/; minimum redemption criteria may apply.',
  accrual: { base_block_inr: 150, rounding_mode: 'floor', base_points_per_block: 1, base_cashback_percent: NA, effective_base_return_percent: 0.333, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  rules: [
    cubExcl('rupay-plat'),
    R({ id: 'cub-rupay-plat-merch-3x', cat: 'entertainment', pri: 5, mult: 3, ppb: 3, cond: { merchants: 'CSK/SRH merchandise and match ticket purchases', per_inr_block: 150 }, reason: '3X reward points on CSK/SRH merchandise and match ticket purchases (Rewards Document 2.1); a transaction earns under one structure only.' }),
    R({ id: 'cub-rupay-plat-upi', cat: 'upi', rail: 'upi_qr', pri: 9, mult: 2, ppb: 2, cond: { per_inr_block: 150 }, reason: '2 RP per INR 150 on UPI transactions (Rewards Document 2.1).' }),
    R({ id: 'cub-rupay-plat-apparel-2x', cat: 'other', pri: 10, mult: 2, ppb: 2, cond: { categories: ['apparel', 'department_stores'], per_inr_block: 150 }, reason: '2X (2 RP per INR 150 instead of 1) on apparel and department stores (Rewards Document 2.1). MCC lists are not stated.' }),
    R({ id: 'cub-rupay-plat-fooddelivery-2x', cat: 'dining', pri: 10, mult: 2, ppb: 2, cond: { categories: ['food_delivery'], per_inr_block: 150 }, reason: '2X on food delivery (Rewards Document 2.1). MCC list not stated.' }),
    R({ id: 'cub-rupay-plat-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 150 }, reason: '1 RP per INR 150 on other transactions (Rewards Document 2.1).' }),
  ],
  forex: 3.5, apr: [3.5, 42], cash: [3, 250], cashLimit: null, cashDay1: true, over: [3, 250], late: cubLate, surch: cubSurch, emiFee: 200, emiForeclose: 5, bounce: 300, addon: 500,
  fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 3000, monthly_waiver_cap_inr: 300 },
  welcome: null,
  sources: cubSources(),
  open: [...cubCsOpen,
    'Cash advance fee is "3% of cash withdrawal amount or INR 250 whichever is higher" at Indian ATMs (KFS V6); atm_transaction_fee_min_inr holds the INR 250 floor. Abroad: 3.5% or INR 1,000.',
    'EMI conversion fee is 2% with a minimum of INR 200 and a maximum of INR 1,000 (KFS V6); only the INR 200 minimum fits the single numeric field, so the percentage and the cap are in this note. Foreclosure 5% of the outstanding amount.',
    'Cheque return / invalid cheque fee INR 300 per return (KFS V6).',
    'Add-on card fee INR 500 + GST one time (KFS V6).',
    'Minimum amount due formula: 5% of purchases and cash withdrawals plus 100% of interest, fees and taxes (KFS V6 illustration).',
    'RuPay UPI: the Rewards Document gives a UPI earn rate for the RuPay card, so is_upi_linkable is true; the document does not say how a RuPay credit card is linked to UPI.',
  ],
  notes: ['Reward Points are calculated in whole numbers rounded down; reversed or refunded transactions reverse the points (Rewards Document section 6).', 'Interest 3.5% a month (42% a year) on extended credit and cash advances (KFS V6).'],
});

const cubMaster = (v, o) => card({
  name: o.name, issuer: 'city-union-bank', network: 'mastercard', tier: o.tier, joining: 0, annual: o.annual, upi: false, page: CUB_PAGE,
  pv: o.pv, pvBasis: `CUB CSK/SRH Rewards Document section 4.1: redemption value ${o.label} INR ${o.pv} per Reward Point at https://rewards.cub.bank.in/; minimum redemption criteria may apply.`,
  accrual: { base_block_inr: o.block, rounding_mode: 'floor', base_points_per_block: 1, base_cashback_percent: NA, effective_base_return_percent: Number((o.pv / o.block * 100).toFixed(3)), cycle_accrual_ceiling_points: null, capping_period_basis: null },
  rules: [
    cubExcl(v),
    R({ id: `cub-${v}-merch-3x`, cat: 'entertainment', pri: 5, mult: 3, ppb: 3, cond: { merchants: 'CSK/SRH merchandise and match ticket purchases', per_inr_block: o.block }, reason: `3X reward points on CSK/SRH merchandise and match ticket purchases (Rewards Document ${o.sec}).` }),
    ...o.accel.map(([id, cat, cats]) => R({ id: `cub-${v}-${id}-2x`, cat, pri: 10, mult: 2, ppb: 2, cond: { categories: cats, per_inr_block: o.block }, reason: `2X (2 RP per INR ${o.block}) on ${cats.join(', ').replace(/_/g, ' ')} (Rewards Document ${o.sec}). MCC lists are not stated.` })),
    R({ id: `cub-${v}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: o.block }, reason: `1 RP per INR ${o.block} on physical-card (Mastercard) transactions${o.intl ? ', domestic and international' : ''} (Rewards Document ${o.sec} and 3).` }),
  ],
  forex: o.forex, apr: [3.5, 42], cash: [3, 250], cashDay1: true, over: [3, 250], late: cubLate, surch: cubSurch, emiFee: 200, emiForeclose: 5, bounce: 300, addon: 500,
  fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 },
  waiver: { threshold_spend_inr: o.waiveAt, period: null, evaluation_condition: `Annual fee INR ${o.annual} + GST from the second year, waived on spends of INR ${o.waiveAt.toLocaleString('en-IN')} (KFS V6); the period over which the spend is measured is not stated.`, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: o.annual },
  sources: cubSources(),
  open: [...cubCsOpen,
    `Fees: joining nil; annual INR ${o.annual} + GST from year 2, waived on spends of INR ${o.waiveAt.toLocaleString('en-IN')} (KFS V6). The KFS header says joining fee is "levied after card activation" and the variant name says first year free.`,
    'Virtual RuPay card: holders of the Mastercard variants may also be issued a virtual RuPay credit card on the same account; reward points depend on the card used (physical Mastercard 1 RP per INR ' + o.block + '; virtual RuPay 2 RP per INR 150 on UPI and 1 RP per INR 150 otherwise, Rewards Document 3). The draft models the physical Mastercard; the virtual RuPay earn is a separate card behaviour not modelled here.',
    'Physical RuPay card for Master Platinum / Master World holders costs INR 250 (KFS V6).',
    'Cash advance fee 3% or INR 250 whichever is higher in India (KFS V6). EMI fee 2% (min INR 200, max INR 1,000); foreclosure 5%.',
    ...(o.extraOpen ?? []),
  ],
  notes: ['Interest 3.5% a month (42% a year) (KFS V6).', ...(o.notes ?? [])],
});

const cubMasterPlat = cubMaster('master-plat', { name: 'CUB CSK/SRH Master Platinum Credit Card (first year free)', tier: 'mastercard_platinum', annual: 1000, waiveAt: 300000, pv: 0.75, label: 'Master Platinum', block: 125, sec: '2.2', forex: 3.5, accel: [['apparel', 'other', ['apparel', 'department_stores']], ['dining', 'dining', ['dining']], ['fooddelivery', 'dining', ['food_delivery']]] });
const cubMasterWorld = cubMaster('master-world', { name: 'CUB CSK/SRH Master World Credit Card (first year free)', tier: 'mastercard_world', annual: 4000, waiveAt: 500000, pv: 1, label: 'Master World', block: 100, sec: '2.3', intl: true, forex: 0, accel: [['travel', 'travel', ['travel', 'flight_bookings', 'hotel_bookings']]], notes: ['Foreign currency transaction (markup) fee is 0% on the CSK/SRH Master World card (KFS V6).'] });

// Kavach (secured, RuPay or Mastercard)
const kavachCard = card({
  name: 'CUB Kavach Credit Card (secured, RuPay / Mastercard)', issuer: 'city-union-bank', network: null, joining: 0, annual: 0, upi: false, page: CUB_KAV_PAGE,
  pv: 0.2, pvBasis: 'CUB Kavachh Reward Document section 5.1: 1 Reward Point = INR 0.20 (100 RP = INR 20) at https://rewards.cub.bank.in/; minimum redemption criteria may apply.',
  accrual: { base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: 1, base_cashback_percent: NA, effective_base_return_percent: 0.2, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
  rules: [
    X('cub-kavach-excluded', 'excluded_spend', [5094, 5944, 6513, 6538, 6539, 6540, 6541, 6542, 5172, 5541, 5542, 5983, 6010, 6011, 6012, 6051, 7801, 7995, 9754, 5111, 5192, 5942, 5943, 8211, 8220, 8241, 8244, 8249, 8299, 8351], 'No reward points on utilities and telecom, gold and jewellery, rent, wallet, insurance, government payments, fuel, cash, gambling, educational services (Kavachh Reward Document section 6). Also excluded: low-interchange categories railways, contracted services, agriculture, transportation and transit, post office, and transactions under INR 2,000 at small offline merchants (sections 2.1 and 3); their MCCs are not listed.', { mcc_ranges: [[4800, 4999], [5960, 6399], [9000, 9999]] }),
    R({ id: 'cub-kavach-super-10', cat: 'all_retail', pri: 10, mult: 10, ppb: 10, cap: 'cub-kavach-cycle-cap', cond: { monthly_eligible_spend_above_inr: 50000, channel: 'online (physical or virtual card) or in-store with the physical card', per_inr_block: 100, tiered: 'only the spend above INR 50,000 in the billing month earns 10 RP per INR 100' }, reason: '10 RP per INR 100 on eligible spend above INR 50,000 in a billing month (Kavachh Reward Document 2.3 and example 3).' }),
    R({ id: 'cub-kavach-accel-5', cat: 'all_retail', pri: 11, mult: 5, ppb: 5, cap: 'cub-kavach-cycle-cap', cond: { monthly_eligible_spend_from_inr: 20000, monthly_eligible_spend_to_inr: 50000, channel: 'online (physical or virtual card) or in-store with the physical card', per_inr_block: 100, tiered: 'only the spend between INR 20,000 and INR 50,000 in the billing month earns 5 RP per INR 100' }, reason: '5 RP per INR 100 on eligible spend from INR 20,000 to INR 50,000 in a billing month (Kavachh Reward Document 2.2 and example 2).' }),
    R({ id: 'cub-kavach-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cap: 'cub-kavach-cycle-cap', cond: { per_inr_block: 100, note: 'first INR 20,000 of eligible spend in the billing month' }, reason: '1 RP per INR 100 on the first INR 20,000 of eligible monthly spend (Kavachh Reward Document 2.1).' }),
  ],
  caps: [C({ id: 'cub-kavach-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', after: 'zero_accrual' })],
  forex: 2, apr: [2, 24], cash: [2, 250], cashDay1: true, over: [3, 250], late: cubLate, surch: [rentSurch(1), cubSurch[1], cubSurch[2], cubSurch[3], cubSurch[4]], emiFee: 200, emiForeclose: 5, bounce: 300, addon: null,
  fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 3000, monthly_waiver_cap_inr: 300 },
  dual: {
    sourceUrl: CUB_KAV_KFS,
    evidence: 'CUB Kavach Key Fact Statement (file Kfs_v1_050126, Jun26 folder) lists two separate rows, "CUB KAVACH RUPAY CREDIT CARD" and "CUB KAVACH MASTER CREDIT CARD", with identical fees; KFS V6 (3 Oct 2026) lists one row "CUB KAVACH RUPAY / MASTER CREDIT CARD". The issuer does not say whether the customer chooses.',
    variants: [
      { network: 'rupay', network_tier: NA, label: 'CUB Kavach RuPay Credit Card', source_url: CUB_KAV_KFS, evidence: 'KFS: "CUB KAVACH RUPAY CREDIT CARD", joining/annual/add-on NIL, 2% a month.' },
      { network: 'mastercard', network_tier: NA, label: 'CUB Kavach Master Credit Card', source_url: CUB_KAV_KFS, evidence: 'KFS: "CUB KAVACH MASTER CREDIT CARD", joining/annual/add-on NIL, 2% a month.' },
    ],
  },
  sources: [
    { url: CUB_KAV_KFS, kind: 'CUB Kavach Key Fact Statement (file Kfs_v1_050126, Jun26 folder), 8 pages: fees, interest, fuel waiver, forex', read: 'pdftotext' },
    { url: CUB_KFS, kind: 'KFS V6 (3 Oct 2026): combined row for RuPay / Master; Kavach exceptions (cash 2%, forex 2%, statement fee)', read: 'pdftotext' },
    { url: CUB_KAV_REW, kind: 'CUB Kavachh Credit Card Reward Document (5 pages, Sep26 folder): earn tiers, INR 0.20 per RP, exclusions', read: 'pdftotext' },
    { url: CUB_KAV_MITC, kind: 'Kavach MITC (Jun26 folder): secured-card clauses (FD as continuing security, lien); no margin or limit ratio', read: 'pdftotext' },
    { url: CUB_KAV_PAGE, kind: 'Issuer Kavach T&C page (last updated 05-10-2026 per page): links the MITC, KFS and Reward Document; states no fees, margin or network', read: 'page text via fetch tool' },
  ],
  open: [
    'Network: two networks (RuPay and Mastercard) are listed; whether the customer chooses, and the Mastercard tier, are not stated. Recorded as dual network with no single network.',
    'Secured-card terms: the FD amount, minimum deposit, margin (credit limit as a percentage of the FD) and whether the card is only against a CUB fixed deposit are not stated in the KFS, the MITC or the Reward Document read (the MITC says only that the fixed deposit is continuing security). The issuer page lists an application link at cubdigital.cub.bank.in/cub-depend-webapp, not opened (a form flow).',
    'Reward cap: "Max RP is 2% of your limit in a billing cycle" (Reward Document 2.1 to 2.3). The cap depends on the individual credit limit, so no fixed number is stored; the cap rule carries limit_value N/A.',
    'Reward tiers are on cumulative eligible spend in a billing month; the document\'s examples treat them as marginal slabs (first INR 20,000 at 1 RP, next up to INR 50,000 at 5 RP, rest at 10 RP) and the reward rules are written that way. Whether "billing month" means the statement cycle is not stated; statement_cycle is assumed for the cap period only because the document says billing cycle.',
    'Accelerated and super-accelerated rewards apply to online purchases with physical or virtual card, or in-store with the physical card only; the base-reward categories are said to be excluded from acceleration ("NA for base reward categories") without naming them.',
    'Welcome benefit, lounge access, fuel waiver details beyond the KFS, and card-art networks: no document states a welcome benefit or lounge for Kavach.',
    'Cash advance: up to 2% or INR 250, whichever is higher, at Indian ATMs; abroad up to 2% or INR 1,000 (Kavach KFS; the abroad line prints "Up to 2 of cash withdrawal amount").',
    'Point validity: "Reward Points may expire as per the Bank\'s policy", no period stated.',
    'The KFS says Kavach has no add-on card and no re-issue fee.',
  ],
  notes: ['Interest 2% a month (24% a year) on extended credit and cash advances (KFS).'],
});

// ───────────────────────────── Tamilnad Mercantile Bank (deposit-linked and income-linked cards; the issuer pages publish no reward programme)
const TMB = 'https://www.tmb.bank.in/personal';
const TMB_FOREX = 'https://s3.ap-south-2.amazonaws.com/tmbwebsite-prod-v1.0-s3/s3fs-public/2026-10/Forex%20Charges.pdf';
const tmbCommonOpen = [
  'Rewards: no reward rate, points, cashback, lounge, fuel waiver or welcome benefit appears anywhere on the issuer card page; the page links only TMB Rewards (rewards.tmbdigital.bank.in), a portal behind a login that was not opened. No earn rule is written; the card is held until TMB publishes a reward structure for it.',
  'Purchase interest rate (APR) and minimum amount due are not stated on the page; only the finance charge on cash withdrawals (2% a month, 24% a year) is given.',
  'Foreign currency conversion markup is "Up to 3.5%" (page); the separate Forex Charges PDF linked from the page was not read for a card-specific figure.',
  'Cash withdrawal fee 3% of the amount (page: "Min Rs.30 per Rs.1,000 or part", wording ambiguous) at TMB ATMs; 3% plus other bank charges elsewhere.',
  'Network wording: the "Card Type" row of the page table names it. No separate network tier is stated.',
  'Other charges stated: charge slip retrieval INR 100 + GST, outstation cheque collection INR 100 + GST + bank charges, duplicate statement older than 2 months INR 100 + GST, cheque dishonour / failed payment INR 150 + GST. Add-on cards free for spouse and children above 18. Free credit period up to 45 days. Card validity 3 years. Cash advance limit 25% of sanctioned limit.',
];
const tmb = (o) => card({
  name: o.name, issuer: 'tamilnad-mercantile-bank', network: o.network, tier: null, joining: 0, annual: 0, upi: false, page: o.page,
  elig: o.elig, forex: 3.5, cash: [3, null], cashLimit: null, cashDay1: null, bounce: 150, addon: 0,
  late: o.late ?? [],
  sources: [{ url: o.page, kind: `TMB card page: key features table (card type, limits, deposit/eligibility), interest and finance charges, other charges${o.hasFeeTable ? ', fees and charges table' : ''}`, read: 'curl, stripped to text' }, { url: TMB_FOREX, kind: 'Forex Charges PDF linked from the page (not read for card-specific rates)', read: 'link only' }],
  open: [...o.open, ...tmbCommonOpen],
  notes: o.notes ?? [],
});
const tmbVibe = tmb({
  name: 'TMB VIBE360 Credit Card', network: 'visa', page: `${TMB}/retail-cards/tmb-vibe360-credit-card`,
  elig: 'Page: NRI or resident individual holding a TMB Term Deposit of INR 50,000 or more for a minimum 3-year tenure; no income documentation ("automatic eligibility"). Secured card against Term Deposit. Limit INR 30,000 to INR 10,00,000, up to 75% of the Term Deposit value.',
  open: ['Fees: the page says "Free issuance with zero annual fee" and "no joining or annual fees" in prose, but this page has no fees-and-charges table, so the late payment fee, renewal fee and replacement fee are not stated (the Vertex and Titanium pages carry a table with a late fee of INR 250 + GST; it is not copied here). joining_fee_inr and annual_fee_inr 0 come from the prose.',
    'Daily cash withdrawal limit INR 25,000 (subject to RBI norms, if applicable).'],
});
const tmbVertex = tmb({
  name: 'TMB Vertex Credit Card', network: 'visa', page: `${TMB}/retail-cards/tmb-vertex-credit-card`, hasFeeTable: true,
  elig: 'Page table: any individual holding an account with the bank with a source of income; limit INR 20,000 to INR 5,00,000, restricted to 25% of annual income. The page overview says "backed by Term Deposit" and "depending on your Term Deposit eligibility".',
  late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 250 }],
  open: ['Secured or unsecured: the overview calls the card "backed by Term Deposit" and says limits depend on Term Deposit eligibility, but the eligibility table says "any individual holding account with the Bank with source of income" and the limit is "Restricted to 25% of annual income". The deposit amount or ratio is not stated. A person should ask TMB whether a Term Deposit is required.',
    'The eligibility FAQ text on the page still says "TMB VIBE360" (a copy slip on the issuer page).',
    'Fees table: issuance free, joining free, annual fee free; renewal INR 250 + GST (primary) and INR 150 + GST (add-on); replacement INR 250 + GST; late payment INR 250 + GST (flat, no slab or condition stated); hotlisting free. The page lists renewal 250 while annual is free, which looks inconsistent; annual_fee_inr is 0 as stated.',
    'No daily cash withdrawal limit ("No such limit").'],
});
const tmbTitanium = tmb({
  name: 'TMB Titanium Credit Card', network: 'rupay', page: `${TMB}/savings/tmb-titanium-credit-card`, hasFeeTable: true,
  elig: 'Page table: any individual with gross annual income of INR 2,00,000 or above; "Income-based (Unsecured)". Limit INR 20,000 to INR 5,00,000, restricted to 25% of annual income.',
  late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 250 }],
  open: ['Secured or unsecured: the page overview says the card is "backed by a customer\'s Term Deposit" and limits are "based on deposit value", while the eligibility table says "Income-based (Unsecured)" and limits are 25% of annual income. The two statements conflict. The 7 Nov sweep described it as Term-Deposit-backed.',
    'Network: the Card Type row says "RuPay Titanium Credit Card"; the page tagline says "A premium RuPay Credit Card".',
    'Fees table: issuance, joining and annual free; renewal INR 250 + GST (primary), INR 150 + GST (add-on); replacement INR 250 + GST; late payment INR 250 + GST (flat); hotlisting free.',
    'Daily cash withdrawal limit INR 25,000 (subject to RBI norms, if applicable).'],
});
const tmbPlatinum = tmb({
  name: 'TMB Platinum Credit Card', network: 'rupay', page: `${TMB}/savings/tmb-platinum-credit-card`,
  elig: 'Page: individual holding a TMB Term Deposit of INR 50,000 or more for a minimum 3 years; secured card against Term Deposit; limit INR 20,000 to INR 5,00,000, up to 75% of the Term Deposit value; no income documentation.',
  open: ['Fees: the page says "no joining or annual fees" in prose and has no fees-and-charges table, so the late payment fee, renewal fee and replacement fee are not stated.',
    'Card type row reads "RuPay Platinum Credit Card"; tagline "A Premium RuPay Platinum Credit Card".',
    'Daily cash withdrawal limit INR 25,000 (subject to RBI norms, if applicable).'],
});

// ───────────────────────────── Dhanlaxmi Bank
const DHAN_MITC = 'https://www.dhan.bank.in/pdf/Most_Imp_Terms_Conditions.pdf';
const DHAN_POLICY = 'https://www.dhan.bank.in/pdf/Credit-Card-Policy.pdf';
const DHAN_TC = 'https://www.dhan.bank.in/pdf/cc/Credit_Card_Terms_Conditions.pdf';
const dhanSources = (page, kind) => [
  { url: page, kind, read: 'curl, stripped to text' },
  { url: DHAN_MITC, kind: 'Most Important Terms and Conditions (2 pages; one fee table for Visa/RuPay Platinum and RuPay Select; the EMI illustration is dated Dec 2023 to Jun 2024)', read: 'pdftotext -raw' },
  { url: DHAN_POLICY, kind: 'Credit Card Policy Version 6.0 (18 pages, PDF created 9 Jan 2026): product lines, reward programme, schedule of charges', read: 'pdftotext' },
  { url: DHAN_TC, kind: 'Credit Card Terms & Conditions (12 pages, undated): general terms; EMI transactions earn no reward points (clause 11.9)', read: 'pdftotext' },
];
const dhanCommonOpen = [
  'Fuel transaction surcharge: the MITC table says "10 or 2.5%" and the Credit Card Policy v6.0 (Jan 2026) says "Rs.10 or 1.0% of transaction amount whichever is high". The two conflict; the newer Policy value (1.0%) is stored; no fuel surcharge waiver is stated for these cards.',
  'Late payment fee is 30% of the Minimum Amount Due with a minimum of INR 400 and a maximum of INR 600 (MITC and Policy); it cannot be shown as fixed slabs, so late_payment_slabs is empty and the rule is stored in additional_data.',
  'Joining fee is nil for new customers but INR 400 for customers who earlier took and closed a Dhanlaxmi credit card within the last three years (MITC footnote); stored joining_fee_inr is 0.',
  'Annual fee INR 400 + GST (Platinum) / INR 800 + GST (Select); waived on annual usage of INR 50,000 (Platinum) / INR 1,00,000 (Select); add-on usage counts (MITC footnote). Policy says renewal fee nil and the annual fee is applicable for activated cards closed within 12 months.',
  'Interest: 1.90% a month (22.80% a year) on revolving credit, 36% a year on cash advances, 3.5% a month (42% a year) from the date of default (MITC, Policy). The Policy says the rate is benchmarked to the 1-year MCLR with spread capped at 32%.',
  'Interest free credit period 20 to 50 days on retail purchases if the previous balance is paid in full.',
  'Cash advance fee INR 400 per transaction; cash limit 15% of the total credit limit; overlimit 2.5% of the amount over the limit (min INR 300); cheque return / auto-debit dishonour INR 500; EMI processing fee 1% of the converted amount, foreclosure 2% of outstanding EMIs; reward redemption fee INR 75 for gifts and nil for cash (MITC).',
  'Forex markup 3.5% (MITC, Policy).',
  'Reward expiry: the Credit Card Policy says "Point Expiry: Every 2 years (on 20th September)" in its general loyalty section; it is not tied to a card variant, so 24 months is used only for the variants whose pages list the same programme.',
];
const dhanFees = { apr: [1.9, 22.8], forex: 3.5, cash: [null, 400], cashLimit: 15, cashDay1: true, over: [2.5, 300], bounce: 500, emiFee: null, emiForeclose: 2, addon: 0,
  fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null } };
const dhanLate = { key: 'late_payment_fee_rule', value: { rule: '30% of the Minimum Amount Due, minimum INR 400, maximum INR 600', source: 'MITC and Credit Card Policy v6.0' } };
const dhanRewardRules = (v) => [
  X(`dhan-${v}-excluded`, 'excluded_spend', null, 'No reward points on cash withdrawals, EMI conversions or cashback transactions (Credit Card Policy v6.0, loyalty programme); a retail transaction converted to EMI earns no points (Terms and Conditions 11.9). MCC lists are not stated.'),
  R({ id: `dhan-${v}-grocery-cashback`, cat: 'groceries', pri: 10, mult: 1, cb: 5, cap: `dhan-${v}-grocery-cap`, cond: { categories: ['grocery'] }, reason: '5% cashback on grocery spends, maximum INR 50 per billing cycle (card page; Policy v6.0). The Namaste page words it "supermarkets and departmental stores, maximum INR 50 a month".' }),
  R({ id: `dhan-${v}-base`, cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 100 }, reason: '2 reward points per INR 100 spent (card page; Policy v6.0). Redeemed at INR 0.05 per point.' }),
];
const dhanRupay = (v, o) => card({
  name: o.name, issuer: 'dhanlaxmi-bank', network: 'rupay', tier: o.tier, joining: 0, annual: o.annual, upi: true, page: o.page,
  pv: 0.05, pvBasis: 'Issuer card page: "Redemption of reward points @ Rs.0.05/point" (also Credit Card Policy v6.0: cashback at INR 0.05 per point). Redemption fee nil for cash redemption, INR 75 for gifts (MITC).', expiry: 24,
  accrual: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: NA, effective_base_return_percent: 0.1, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
  rules: dhanRewardRules(v),
  caps: [C({ id: `dhan-${v}-grocery-cap`, cat: 'groceries', metric: 'bonus_reward_points', period: 'statement_cycle', inr: 50, after: 'downgrade_to_base_rate', afterPpb: 2 })],
  ...dhanFees,
  waiver: { threshold_spend_inr: o.waiveAt, period: null, evaluation_condition: `Annual fee INR ${o.annual} + GST waived on annual usage of INR ${o.waiveAt.toLocaleString('en-IN')} (MITC footnote and card page); the page does not say card anniversary year or calendar year.`, excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: o.annual },
  welcome: { trigger: 'spend_within_90_days_of_issuance', benefit_points: 1000, effective_value_inr: 50, condition: '1,000 points for spends above INR 10,000 within 90 days of issuance (card page). Rupee value is 1,000 x INR 0.05 = INR 50 at the stated redemption rate.' },
  benefits: o.benefits,
  sources: dhanSources(o.page, `Issuer card page for ${o.name} (benefits, annual fee, lounge, reward line)`),
  open: [...dhanCommonOpen, ...o.open,
    'The INR 50 cap is on the cashback amount (not on spend), stored as limit_value_inr 50 under a bonus-reward metric.',
    'Reward-points exclusions beyond cash withdrawals, EMI conversions and cashback transactions: no MCC list is published in the documents read.',
    'Lounge access: the page lists the quota; the "Lounge Access" link on the page opens no separate document in the HTML read, so the lounge programme, eligibility spend and per-visit rules are not stated.',
    'Credit Card on UPI is listed as a feature; the setup is not described.',
    'The page footnote marks reward points with "#" (conditions not shown in the page text) and the benefits with "T & C Apply"; the "Terms and Conditions of platinum Credit Card Offers" (cc-offer-tc.pdf) is only a generic offer disclaimer with no terms for these benefits.',
    'Bonus reward: the Credit Card Policy v6.0 lists 4,000 points on annual spends of INR 3,00,000 or more; the card page does not list it, so it is not modelled.',
    'Network tier: the page title says RuPay ' + o.tier.replace('rupay_', '') + '; no other tier information.'],
  extraItems: [{ key: 'late_payment_fee_rule', value: dhanLate.value }],
});
const dhanVriddhi = dhanRupay('vriddhi', { name: 'Dhan Vriddhi Credit Card (RuPay Platinum)', tier: 'rupay_platinum', annual: 400, waiveAt: 50000, page: 'https://www.dhan.bank.in/rupay-cc-Dhan-Vriddhi/',
  benefits: [B({ id: 'dhan-vriddhi-lounge', cat: 'lounge', sponsor: 'Dhanlaxmi Bank', label: 'Domestic airport lounge access', qty: 1, per: 'half_year' })], open: [] });
const dhanSamriddhi = dhanRupay('samriddhi', { name: 'Dhan Samriddhi Credit Card (RuPay Select)', tier: 'rupay_select', annual: 800, waiveAt: 100000, page: 'https://www.dhan.bank.in/rupay-CC-Dhan-Samriddhi/',
  benefits: [B({ id: 'dhan-samriddhi-lounge-dom', cat: 'lounge', sponsor: 'Dhanlaxmi Bank', label: 'Domestic airport lounge access', qty: 1, per: 'quarter' }), B({ id: 'dhan-samriddhi-lounge-intl', cat: 'lounge', sponsor: 'Dhanlaxmi Bank', label: 'International (abroad) airport lounge access', qty: 1, per: 'half_year' })],
  open: ['The page says waived "if annual spend > Rs. 1,00,000" while the MITC says "Rs.100000 or more"; the MITC reading (at or above INR 1,00,000) is not adopted over the page, the threshold is stored as INR 1,00,000 and the strict-or-not wording is unsettled.'] });

const dhanNamaste = card({
  name: 'Dhan Namaste Credit Card (VISA Platinum)', issuer: 'dhanlaxmi-bank', network: 'visa', tier: 'visa_platinum', joining: 0, annual: 400, upi: false, page: 'https://www.dhan.bank.in/credit-card-pl/',
  pv: null, pvBasis: null, expiry: null,
  elig: 'Page: salaried and self-employed, minimum gross annual income INR 6 lakh.',
  accrual: { base_block_inr: null, rounding_mode: null, base_points_per_block: null, base_cashback_percent: null, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: 'calendar_month' },
  rules: [R({ id: 'dhan-namaste-grocery-cashback', cat: 'groceries', pri: 10, mult: 1, cb: 5, cap: 'dhan-namaste-cashback-cap', cond: { categories: ['supermarkets', 'department_stores'] }, reason: '5% cashback on supermarkets and department store purchases, subject to a maximum of INR 50 per month per card (card page).' })],
  caps: [C({ id: 'dhan-namaste-cashback-cap', cat: 'groceries', metric: 'bonus_reward_points', period: 'calendar_month', inr: 50, after: 'zero_accrual' })],
  ...dhanFees,
  waiver: { threshold_spend_inr: 50000, period: null, evaluation_condition: 'Annual fee INR 400 + GST waived on annual usage of INR 50,000 or more for the Visa/RuPay Platinum variant (MITC footnote). The Namaste page itself states no fee.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 400 },
  welcome: null,
  benefits: [B({ id: 'dhan-namaste-concierge', cat: 'concierge', sponsor: 'Dhanlaxmi Bank', label: 'Online concierge facility' })],
  sources: dhanSources('https://www.dhan.bank.in/credit-card-pl/', 'Issuer page "VISA Namaste Credit Card" (page body says "Dhanlaxmi Bank Platinum Credit Card"; benefits list; eligibility)'),
  open: [...dhanCommonOpen,
    'Base earn: the page lists only the 5% cashback (INR 50 a month cap), concierge, insurance and lounge links. It states no reward-point rate, welcome bonus or lounge quota. The Credit Card Policy v6.0 describes a bank-wide 2 points per INR 100 scheme (INR 0.05 per point) but does not tie it to the Namaste card, so it is not applied. A person should confirm with Dhanlaxmi whether Namaste earns points.',
    'Fees: the Namaste page states no fee. Fee values (annual INR 400 + GST, waiver INR 50,000, joining nil) are taken from the MITC column "[Visa/RuPay] Platinum", which the MITC does not name as this card; the Policy lists "VISA Platinum Credit Card" as a product line, so the match is by variant, not by card name.',
    'Name: the listing and page title say "VISA Namaste Credit Card"; the body text says "Dhanlaxmi Bank Platinum Credit Card". Network Visa is from the card name on the issuer listing and the Policy product line "VISA Platinum Credit Card"; no card art or MITC page names the Visa tier beyond "Platinum".',
    'Insurance and lounge access are page tabs without stated terms; no lounge quota is given.',
    'The page words the cashback cap per month per card; the Vriddhi and Samriddhi pages word it per billing cycle.',
    'Reward point value and expiry for Namaste: not stated.'],
  extraItems: [{ key: 'late_payment_fee_rule', value: dhanLate.value }],
});

// ───────────────────────────── Jammu & Kashmir Bank
const JK = 'https://jkb.bank.in/transactions/services/credit-cards';
const JK_APPLY = 'https://digital.jkbank.com/JKBCreditCard';
const jkOpenCommon = [
  'Reward point value: no issuer document states what one J&K Bank reward point is worth (the MITC says only that points are valid 3 years from the transaction date and are viewed at https://rewards.jkb.bank.in). point_value_inr_baseline is null.',
  'Reward exclusions: the page excludes insurance, educational institutions, rent, wallet, fuel, cash withdrawals and "select transportation and toll transactions" for all variants; the MITC says points are earned on all spends except fuel and cash. The page is newer (revised reward structure effective 1 Apr 2026) and is used; MCC lists are not published except MCC 6513 for rent (MITC).',
  'Interest: 3% a month (36% a year, APR 42.57%) on purchases and cash (MITC). Cash advance charge 3% with a minimum of INR 300; cash limit 20% of the credit limit. Overlimit 2.5% (min INR 400). Late payment fee: nil up to INR 100 due, INR 250 above. EMI processing fee INR 99, pre-closure 3%. Rental payment charge 1% (MCC 6513).',
  'Annual and renewal fee: the page says annual fee only; the MITC fee table also lists a renewal fee of INR 200 + GST for these variants and says the annual or renewal fee applies from 1 May 2026 (page). The renewal fee is not modelled.',
  'Effective dates (page): revised reward structure from 1 Apr 2026; welcome benefits on cards issued from 1 Apr 2026; quarterly milestones counted from 1 Apr 2026; travel, lifestyle and entertainment benefits from 12 Mar 2026.',
  'Voucher categories and fulfilment options "may vary from time to time" (page), so voucher values are stated face values, not guaranteed benefits.',
  'Fuel surcharge waiver is described as "1% fuel surcharge waiver up to INR X on fuel transactions in a month"; whether X is the fuel spend eligible or the waiver amount is not clear. The fuel spend reading is stored in the note below; monthly_waiver_cap_inr is null.',
];
const jkSources = [
  { url: JK, kind: 'Issuer credit-cards page: Types of Cards tab (fees, rewards, milestones, benefits), MITC section and fee schedule, T&C', read: 'curl, stripped to text' },
  { url: JK_APPLY, kind: 'Issuer online application link (a form, not opened)', read: 'link only' },
];
const jkExcl = (v) => X(`jk-${v}-excluded`, 'excluded_spend', [6513], 'No reward points on insurance, educational institutions, rent (MCC 6513), wallet, fuel, cash withdrawals and select transportation and toll transactions (page, MCC exclusions for all variants). Only MCC 6513 is named in an issuer document.');
const jkEminent = card({
  name: 'J&K Bank Eminent Credit Card (earlier World Credit Card)', issuer: 'jammu-and-kashmir-bank', network: 'mastercard', tier: null, joining: 0, annual: 1500, upi: false, page: JK,
  pv: null, pvBasis: 'No issuer document states the rupee value of one reward point.', expiry: 36,
  elig: 'Credit limit INR 4.00 lakh to INR 25.00 lakh (T&C, World Credit Card).',
  accrual: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: NA, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  rules: [
    jkExcl('eminent'),
    R({ id: 'jk-eminent-3x', cat: 'travel', pri: 10, mult: 3, ppb: 3, cond: { categories: ['online_flights_hotels', 'apparel', 'dining', 'electronics'], per_inr_block: 100 }, reason: '3 reward points per INR 100 on online travel bookings (flights and hotels), apparel, dining and electronics (page, Eminent Reward Points Program). Cap not stated.' }),
    R({ id: 'jk-eminent-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 reward point per INR 100 on all eligible transactions not in the accelerated categories (page).' }),
  ],
  apr: [3, 36], forex: 1.99, cash: [3, 300], cashDay1: true, cashLimit: 20, over: [2.5, 400], emiFee: 99, emiForeclose: 3, surch: [rentSurch(1)],
  fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
  late: [{ min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: null, fee_inr: 250 }],
  waiver: { threshold_spend_inr: 300000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee INR 1,500 waived on annual spends of INR 3,00,000 during the year (page); MITC: World card, purchases above INR 3,00,000 so the fee is not levied. "During the year" read as the card year; the page does not name anniversary or calendar year.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 1500 },
  welcome: { trigger: 'first_transaction', benefit_points: NA, effective_value_inr: 500, condition: 'Gift voucher worth INR 500 on the first eligible transaction, new customers (page); applies to cards issued from 1 Apr 2026.' },
  milestones: [
    { id: 'jk-eminent-q', label: 'Gift voucher worth INR 750', threshold_spend_inr: 150000, reward_value_inr: 750, period: 'quarter', is_repeatable: true, effective_from: '2026-04-01', effective_to: null },
    { id: 'jk-eminent-a', label: 'Dining experience voucher worth INR 1,000', threshold_spend_inr: 600000, reward_value_inr: 1000, period: 'annual', is_repeatable: true, effective_from: null, effective_to: null },
  ],
  benefits: [
    B({ id: 'jk-eminent-lounge-dom', cat: 'lounge', sponsor: 'J&K Bank', label: 'Complimentary domestic airport lounge visits', qty: 2, per: 'quarter', from: '2026-03-12' }),
    B({ id: 'jk-eminent-lounge-intl', cat: 'lounge', sponsor: 'J&K Bank', label: 'Complimentary international airport lounge visit', qty: 1, per: 'half_year', from: '2026-03-12' }),
    B({ id: 'jk-eminent-golf', cat: 'golf', program: 'mastercard_golf', sponsor: 'Mastercard', label: 'Golf privileges through the Mastercard World Card India Golf Program (1800-102-6263)', from: '2026-03-12' }),
  ],
  promos: [
    P({ id: 'jk-eminent-food', cat: 'dining', sponsor: 'J&K Bank', platform: 'online food delivery apps', type: 'cashback', pct: 'N/A', max: 150, quota: true, permanent: true, from: '2026-03-12' }),
    P({ id: 'jk-eminent-movie', cat: 'movie', sponsor: 'J&K Bank', platform: 'movie ticket bookings', type: 'bogo', max: 500, quota: true, permanent: true, from: '2026-03-12' }),
  ],
  sources: jkSources,
  open: [...jkOpenCommon,
    'Network: the Eminent section of the issuer page names golf privileges through the "Mastercard World Card India Golf Program" (a Mastercard programme page) and the card was earlier the "World" card, but no issuer line says "Eminent is issued on Mastercard" and no card art was seen. The MITC/T&C acceptance clauses name MasterCard and VISA generically. A person should confirm the network (and whether Visa is also issued).',
    'Annual fee: page INR 1,500; MITC fee table INR 1,500 + GST plus a renewal fee of INR 200 + GST.',
    'Food delivery benefit: INR 150 a month on a minimum spend of INR 500 on online mobile food delivery apps (stored as a promo with a maximum INR 150); movie BOGO capped at INR 500 a month.',
    'Fuel waiver: 1% on fuel transactions up to INR 10,000 a month (page).'],
  notes: ['Platinum Privilege (earlier Government card) is a separate card and is not in this assignment.'],
});
const jkPlatinum = card({
  name: 'J&K Bank Platinum Credit Card', issuer: 'jammu-and-kashmir-bank', network: null, tier: null, joining: 0, annual: 500, upi: true, page: JK,
  pv: null, pvBasis: 'No issuer document states the rupee value of one reward point.', expiry: 36,
  elig: 'Credit limit up to INR 4 lakh; cash limit 20% of the credit limit up to INR 80,000 (page).',
  accrual: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 1, base_cashback_percent: NA, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
  rules: [
    jkExcl('platinum'),
    R({ id: 'jk-platinum-online-2x', cat: 'online', pri: 10, mult: 2, ppb: 2, cond: { per_inr_block: 100 }, reason: '2 reward points per INR 100 on online transactions (page, Platinum Reward Points Program).' }),
    R({ id: 'jk-platinum-dept-2x', cat: 'other', pri: 10, mult: 2, ppb: 2, cond: { categories: ['department_stores'], per_inr_block: 100 }, reason: '2 reward points per INR 100 on department store purchases (page).' }),
    R({ id: 'jk-platinum-health-2x', cat: 'health', pri: 10, mult: 2, ppb: 2, cond: { categories: ['pharmacy', 'medical'], per_inr_block: 100 }, reason: '2 reward points per INR 100 on pharmacy and medical spends (page).' }),
    R({ id: 'jk-platinum-bills-2x', cat: 'bills', pri: 10, mult: 2, ppb: 2, cond: { categories: ['utility_payments'], per_inr_block: 100 }, reason: '2 reward points per INR 100 on utility payments (page).' }),
    R({ id: 'jk-platinum-base', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 1, mult: 1, cond: { per_inr_block: 100 }, reason: '1 reward point per INR 100 on all eligible transactions (page).' }),
  ],
  apr: [3, 36], forex: 3.5, cash: [3, 300], cashDay1: true, cashLimit: 20, over: [2.5, 400], emiFee: 99, emiForeclose: 3, surch: [rentSurch(1)],
  fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: 1, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null },
  late: [{ min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: null, fee_inr: 250 }],
  waiver: { threshold_spend_inr: 100000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee INR 500 waived on annual spends of INR 1,00,000 within the card anniversary year; the fee for the subsequent year is waived (page).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 500 },
  welcome: { trigger: 'first_transaction', benefit_points: NA, effective_value_inr: 250, condition: 'Gift voucher worth INR 250 on the first eligible transaction, new customers (page); applies to cards issued from 1 Apr 2026.' },
  milestones: [{ id: 'jk-platinum-q', label: 'Gift voucher worth INR 500', threshold_spend_inr: 75000, reward_value_inr: 500, period: 'quarter', is_repeatable: true, effective_from: '2026-04-01', effective_to: null }],
  benefits: [
    B({ id: 'jk-platinum-lounge', cat: 'lounge', sponsor: 'J&K Bank', label: 'Complimentary domestic airport lounge visits, 2 a year (1 per half-year)', qty: 2, per: 'annual', from: '2026-03-12' }),
  ],
  promos: [P({ id: 'jk-platinum-utility', cat: 'bills', sponsor: 'J&K Bank', platform: 'utility bill payments', type: 'instant_discount', pct: 10, max: 50, quota: true, permanent: true, from: '2026-03-12' })],
  dual: {
    sourceUrl: JK,
    evidence: 'Issuer page, Platinum Card: "This variant includes cards from MasterCard, VISA and RuPay networks." The page also says a RuPay credit card is UPI-enabled and can be bundled with any variant. Whether the customer chooses the network is not stated.',
    variants: [
      { network: 'mastercard', network_tier: NA, label: 'J&K Bank Platinum Credit Card (Mastercard)', source_url: JK, evidence: 'Issuer page: Platinum Card variant includes cards from MasterCard.' },
      { network: 'visa', network_tier: NA, label: 'J&K Bank Platinum Credit Card (Visa)', source_url: JK, evidence: 'Issuer page: Platinum Card variant includes cards from VISA.' },
      { network: 'rupay', network_tier: NA, label: 'J&K Bank Platinum Credit Card (RuPay)', source_url: JK, evidence: 'Issuer page: Platinum Card variant includes cards from RuPay networks; RuPay credit card is UPI enabled.' },
    ],
  },
  sources: jkSources,
  open: [...jkOpenCommon,
    'Network: three networks are listed for the one product; the tiers are not stated and whether the customer chooses is not stated. Recorded as dual network with no single network. is_upi_linkable is true for the RuPay version only.',
    'Annual fee: page INR 500; MITC fee table INR 500 + GST plus a renewal fee of INR 200 + GST.',
    'Utility benefit: 10% discount up to INR 50 on utility bill payments, once a month, on eligible transactions (page).',
    'Fuel waiver: 1% on fuel transactions up to INR 5,000 a month (page).'],
});

// ───────────────────────────── Saraswat Co-operative Bank (no reward earn rate published; welcome points only)
const SRS = 'https://www.saraswat.bank.in';
const SR_MITC = 'https://www.saraswat.bank.in/Assets/Saraswat%20-%2027508%20-%20MITC%20Booklet%20-%20English%202026.pdf';
const SRS_MITC = 'https://www.saraswat.bank.in/Assets/MITC-Secured-Card-points-final.pdf';
const srCommon = [
  'Rewards: the page states only "500 Welcome Bonus points on card activation and 300 Reward points on 1st successful transaction" and a "Rewards & Cashbacks" tab with no rate. No earn rate per amount spent, no point value and no expiry is published on the page or in the MITC booklet; the points sit behind a rewards-portal login. No earn rule is written; the card is held until Saraswat publishes one.',
  'Network: stated as RuPay (RuPay Platinum) on the issuer pages, the MITC booklet "RuPay Credit Cards" (v2.3 January 2026) and the Secured MITC; the offers link points to the RuPay Platinum page on rupay.co.in. No other network is mentioned.',
  'Fee schedule is "applicable for all RuPay Credit Cards w.e.f. January 2026" (page). The MITC booklet says the annual fee "may vary for each Cardholder and from offer to offer", so the figures are the page schedule only.',
  'Railway ticket fee 1.8% + GST; fuel surcharge "varies by fuel station and acquirer" (MITC); no fuel waiver is stated.',
  'Welcome points: 500 on activation and 300 on the first successful transaction; the rupee value per point is not stated, so effective_value_inr is null.',
  'Cash payment of the bill: nil up to INR 5,000, INR 125 above (page).',
  'How to apply: "visit your nearest branch" (page); no online application.',
  'Main MITC (34 pages) is a scanned image booklet read with OCR; wording was read from the OCR and the headline fee table from the page.',
];
const srSources = (extra) => [
  { url: `${SRS}/content.aspx?id=Credit-Card`, kind: 'Issuer Credit Card page: eligibility, schedule of charges for all RuPay credit cards w.e.f. January 2026, rewards line', read: 'curl, stripped to text' },
  { url: SR_MITC, kind: 'RuPay Credit Cards MITC booklet, Version 2.3 January 2026 (34 pages, image PDF created 29 Jun 2026)', read: 'tesseract OCR' },
  ...extra,
];
const srPlatinum = card({
  name: 'Saraswat Bank RuPay Platinum Credit Card', issuer: 'saraswat-co-operative-bank', network: 'rupay', tier: 'rupay_platinum', joining: 0, annual: 500, upi: false, page: `${SRS}/content.aspx?id=Credit-Card`,
  elig: 'Page: resident individuals; salaried net take-home from INR 25,000 (unsecured regular scheme) or INR 10,000 (other schemes); business or professional gross income at least INR 1.5 lakh a year; limit INR 10,000 to INR 5,00,000 (within the unsecured limit of INR 5,00,000 per individual); nominal membership INR 100 for limits up to INR 1,00,000 and regular shareholding INR 500 above.',
  apr: [2.25, 27], forex: 3, cash: [null, 100], cashLimit: 40, cashDay1: true, bounce: 250, addon: 0,
  late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 250 }],
  mad: { calculation_mode: 'fixed_percent', components: ['5% of outstanding usage', '100% of all pending charges and taxes', 'EMI if any', 'minimum INR 200, whichever is higher'] },
  waiver: { threshold_spend_inr: 10000, period: null, evaluation_condition: 'Page: annual spends of INR 10,000 or more means AMC nil; below INR 10,000 the AMC is INR 500. Period not stated.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 500 },
  welcome: { trigger: 'card_activation', benefit_points: 500, effective_value_inr: null, condition: '500 welcome bonus points on card activation and 300 reward points on the 1st successful transaction (page).' },
  sources: srSources([]),
  open: [...srCommon,
    'Annual fee: INR 500 applies only when annual spends are below INR 10,000; stored annual_fee_inr is 500 with the waiver recorded. Add-on cards: joining nil, annual lifetime free.',
    'Finance charges 2.25% a month (27% a year) from the transaction date on purchases and cash; interest free up to 50 days (plus 3 grace days per the MITC) if the previous balance is paid in full. EMI on purchase 1.75% a month; conversion and pre-closure nil. Late payment INR 250; card replacement INR 200; auto debit return INR 250.'],
});
const srSecured = card({
  name: 'Saraswat Bank Secured RuPay Platinum Credit Card', issuer: 'saraswat-co-operative-bank', network: 'rupay', tier: 'rupay_platinum', joining: 0, annual: 0, upi: false, page: `${SRS}/content.aspx?id=Secured-Credit-Card`,
  elig: 'Page: Indian resident, minimum age 18; only against a Saraswat Co-operative Bank term deposit (not against tax-saving deposits or deposits of minors, HUF, companies, trusts, societies and firms); minimum face value INR 6,500 for at least 1 year, all schemes with 12 months auto renewal except Kar Mukti, Short Term and Minor. Credit limit 80% of face value, minimum INR 5,000, maximum INR 25,00,000; cash limit 40% of the card limit.',
  apr: [1.25, 15], forex: 3, cash: [null, 100], cashLimit: 40, cashDay1: true, addon: 0,
  late: [{ min_balance_inr: 0, max_balance_inr: null, fee_inr: 150 }],
  mad: { calculation_mode: 'fixed_percent', components: ['5% of outstanding usage', '100% of all pending charges and taxes', 'EMI if any', 'minimum INR 200, whichever is higher'] },
  welcome: { trigger: 'card_activation', benefit_points: 500, effective_value_inr: null, condition: '500 welcome bonus points on card activation and 300 reward points on the 1st successful transaction (page).' },
  sources: srSources([{ url: `${SRS}/content.aspx?id=Secured-Credit-Card`, kind: 'Issuer Secured Credit Card page: eligibility, FD terms, schedule of charges w.e.f. January 2026', read: 'curl, stripped to text' }, { url: SRS_MITC, kind: 'Additional terms and conditions for the Secured RuPay Platinum Credit Card (2 pages, PDF dated Aug 2019): lien on the term deposit, 80% limit', read: 'pdftotext' }]),
  open: [...srCommon,
    'Annual fee: lifetime free card (page). The additional-terms PDF is dated Aug 2019 (PDF metadata) while the page schedule is w.e.f. January 2026; the schedule on the page is used.',
    'Finance charges 1.25% a month (15% a year); EMI on purchase 1% a month, total outstanding into EMI 1.25% a month; conversion and pre-closure nil. Late payment INR 150; replacement INR 200. Auto debit return fee not applicable.',
    'Secured card terms: term deposit stays in auto-renewal for the life of the card, lien on the deposit excluding interest; deposit liquidated if the minimum due is not paid within 90 days (Secured MITC).'],
  notes: ['Differs from the unsecured RuPay Platinum card in fees (lifetime free, interest 1.25% a month, late fee INR 150), so it is its own card.'],
});

export const cards = {
  'city-union-bank-csk-srh-rupay-platinum': cubRuPay,
  'city-union-bank-csk-srh-master-platinum': cubMasterPlat,
  'city-union-bank-csk-srh-master-world': cubMasterWorld,
  'city-union-bank-kavach': kavachCard,
  'tamilnad-mercantile-bank-vibe360': tmbVibe,
  'tamilnad-mercantile-bank-vertex': tmbVertex,
  'tamilnad-mercantile-bank-titanium': tmbTitanium,
  'tamilnad-mercantile-bank-platinum': tmbPlatinum,
  'dhanlaxmi-bank-namaste-visa-platinum': dhanNamaste,
  'dhanlaxmi-bank-dhan-vriddhi': dhanVriddhi,
  'dhanlaxmi-bank-dhan-samriddhi': dhanSamriddhi,
  'jammu-and-kashmir-bank-eminent': jkEminent,
  'jammu-and-kashmir-bank-platinum': jkPlatinum,
  'saraswat-co-operative-bank-rupay-platinum': srPlatinum,
  'saraswat-co-operative-bank-secured-rupay-platinum': srSecured,
};
