// YES BANK co-brand / fintech cards (issuer_slug `yes`). Sources read 2026-11-07 in a real browser session
// (curl and the fetch tool are refused by yes.bank.in; the PDFs were opened from the site's own links and read with pdf.js).
//  LISTING = https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards (rendered grid + FAQ "value of 1 YES Rewardz")
//  MITC    = YES BANK Credit Card MITC, file title CMITC_V18_05102026 (page header "CMITC_V18_0510 2026", i.e. 5 Oct 2026), 45 pp
//            https://www.yes.bank.in/pdf?name=ybl_mitc_pdf.pdf  (every product page's "MITC" link, and the old co-brand MITC link, resolve to it)
//  KFS     = Key Fact Statement - Credit Cards, header V_20_28092026 (28 Sep 2026), 14 pp
//  REDEMPTION = "YES BANK CREDIT CARD REDEMPTION RULES" (undated) https://www.yes.bank.in/pdf?name=redemption_rules.pdf
//  LOUNGE  = "YES BANK DOMESTIC LOUNGE PROGRAM" (undated, threshold text effective 1 Apr 2025)
// Candidates that are not drafted here (recorded in wave2/W2.json instead): ANQ Phi, ANQ Pi, FREO, FREO RuPay, FinBooster RuPay.
import { R, X, C, B, prov, GST } from '../lib.mjs';

export const LISTING = 'https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards';
const PAGE = (slug) => `https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards/${slug}`;
export const MITC = 'https://www.yes.bank.in/pdf?name=ybl_mitc_pdf.pdf';
export const MITC_DATE = 'CMITC_V18_05102026 (5 Oct 2026)';
export const KFS = 'https://www.yes.bank.in/sites/web/content/published/api/v1.1/assets/CONT07A77C257C7A4BDD85DB97E51D2B5B8F/native/yesbank_key_fact_statement.pdf?download=false&channelToken=21f7ccfa2fc3401091938f541a6f8f2a';
export const KFS_DATE = 'V_20_28092026 (28 Sep 2026)';
const REDEMPTION = 'https://www.yes.bank.in/pdf?name=redemption_rules.pdf';
const LOUNGE = 'https://www.yes.bank.in/pdf?name=ybl_yes_bank_domestic_lounge_access.pdf';

export const GOV_MCC = [9034, 9211, 9222, 9223, 9311, 9399, 9402, 9405, 9700, 9701, 9702, 9751, 9754, 9950];
export const MKT_MCC = [5960, 5962, 5964, 5965, 5966, 5967, 5968, 5969, 7311];
export const EDU_MCC = [8211, 8220, 8249, 8299, 8241, 8244];
export const FUEL_MCC = [5172, 5541, 5542, 5983, 9752];
const UTILITY_FEE_MCC = [4900, 4814, 825, 1520, 4899, 1799, 1731, 5261, 7349, 822, 820, 1761, 1771, 1740, 823, 1750, 821, 824, 780, 1711, 9402, 7211, 8999, 4816];

/** Fees every YES BANK card in the MITC/KFS shares; per-card values come in through `o`. */
export const yesFees = (o) => ({
  apr: { monthly_interest_rate_percent: 3.99, annual_interest_rate_percent: 47.88 },
  forex_markup: o.noForex ? { markup_percent: 0, gst_applicable: null } : { markup_percent: o.forex, gst_applicable: true },
  dynamic_currency_conversion_dcc: o.noForex
    ? { fee_percent: 0, gst_applicable: null, trigger_condition: 'MITC/KFS: foreign currency conversion and DCC charges are not applicable to this card' }
    : { fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST when a transaction is billed in INR at an international location or at an overseas-registered merchant in India (MITC 3(q), KFS)' },
  fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: o.fuelMin, max_txn_inr: o.fuelMax, monthly_waiver_cap_inr: o.fuelCap },
  cash_advance: o.virtual
    ? { atm_transaction_fee_percent: 'N/A', atm_transaction_fee_min_inr: 'N/A', interest_applicable_from_day_one: 'N/A', daily_interest_percent: 'N/A', max_limit_percent: 'N/A' }
    : { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 650, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 30 },
  category_surcharges: [
    { category_id: 'fuel', mcc_list: FUEL_MCC, fee_percent: 1, gst_applicable: true, trigger_condition: `1% + GST when one fuel transaction exceeds ₹10,000 or the calendar-month fuel spend exceeds ₹${o.fuelThreshold.toLocaleString('en-IN')}; fee capped at ₹5,000 per transaction (MITC 3(i))`, threshold_spend_inr: o.fuelThreshold, effective_from: null, effective_to: null },
    { category_id: 'utility', mcc_list: UTILITY_FEE_MCC, fee_percent: 1, gst_applicable: true, trigger_condition: `1% + GST on utility and service transactions when the previous calendar month's utility spend exceeded ₹${o.utilityThreshold.toLocaleString('en-IN')}; fee capped at ₹5,000 per transaction (MITC 3(h))`, threshold_spend_inr: o.utilityThreshold, effective_from: null, effective_to: null },
    { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% of the transaction (minimum ₹1 up to ₹1,000; minimum ₹199 above ₹1,000) + GST; at most 5 rental transactions in 30 days (MITC 3(e))', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'wallet', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: 'No fee on third-party wallet loads up to ₹2,000; 1% + GST above ₹2,000, at most ₹5,000 per transaction (MITC 3(f))', threshold_spend_inr: 2000, effective_from: null, effective_to: null },
    { category_id: 'education', mcc_list: [...EDU_MCC, 7911], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST on education paid through third-party sites and apps (CRED, PhonePe, Housing.com, NoBroker, CheQ etc.), capped at ₹5,000 per calendar month; direct school/college site, POS and international education payments are not charged (MITC 3(g))', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'transportation', mcc_list: [4784, 4131, 4214, 4789, 4011], fee_percent: 1, gst_applicable: true, trigger_condition: `1% + GST when one toll/transport transaction exceeds ₹10,000 or the calendar-month spend exceeds ₹${o.tollThreshold.toLocaleString('en-IN')}; capped at ₹5,000 per transaction (MITC 3(j))`, threshold_spend_inr: o.tollThreshold, effective_from: null, effective_to: null },
    { category_id: 'passenger_railways', mcc_list: [4111, 4112], fee_percent: 1, gst_applicable: true, trigger_condition: '1% + GST when one transaction exceeds ₹30,000 or the calendar-month spend exceeds ₹80,000; capped at ₹5,000 per transaction (MITC 3(k))', threshold_spend_inr: 80000, effective_from: null, effective_to: null },
  ],
  banking_penalties: { overlimit_charge: { fee_percent: null, min_fee_inr: 550, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: 450 },
  reward_redemption_fee: { fee_inr: o.redemptionFee ?? 100, gst_applicable: true, exempted_channels: [], notes: o.redemptionNote ?? 'MITC 3(l): ₹100 + GST per redemption request regardless of points; ₹99 + GST convenience fee on flight bookings through points. Not applicable on cards without reward points.' },
});

export const yesStatement = {
  grace_period_days: 50,
  grace_period_void_on_revolving_balance: true,
  minimum_amount_due_mad: {
    calculation_mode: 'fixed_percent',
    components: [
      '100% of GST + EMI amount + membership/rental/wallet fees + any amount over the credit limit',
      'plus the higher of (finance charges + other fees + 2% of retail/cash outstanding) or ₹200 (MITC 6, KFS)',
    ],
  },
  late_payment_slabs: [],
};

const yesRules = [
  'Late payment charge: no charge if the current outstanding (statement balance + unbilled) is up to ₹500; above ₹500, 10% of the statement balance or ₹1,350, whichever is lower, per statement (MITC 3(b), KFS).',
  'Auto-debit / payment return failure: from 15 Jun 2026, 2.5% or ₹500 whichever is higher on the net payable amount, capped at ₹5,000 per customer per statement (before that 2% or ₹450, cap ₹1,500); cheque return ₹450 (MITC 3(d)).',
  'Overlimit: ₹550 + GST per transaction that exceeds the limit (facility reintroduced 1 Jun 2026) (MITC 3(c)).',
  'Cash advance: from 15 Jun 2026, 2.5% or ₹650 whichever is higher; before that 2.5% or ₹500; not applicable to virtual cards; cash withdrawal suspended for the first 6 months after onboarding; limit up to 30% of the credit limit (MITC 3(a), 5).',
];
export const lateFee = { key: 'late_payment_fee_rule', value: { rule: '10% of the statement balance or ₹1,350, whichever is lower, per statement; nothing if the current outstanding (statement balance + unbilled) is ₹500 or less', source: `MITC ${MITC_DATE} 3(b); KFS ${KFS_DATE}`, note: 'A percentage fee cannot be written as fixed slabs, so late_payment_slabs is empty.' } };
export const otherFees = { key: 'other_charges_rule', value: { rules: yesRules, source: `MITC ${MITC_DATE}; KFS ${KFS_DATE}`, gst: '18% on all fees and charges (MITC 3(u))' } };

const eligibility = (extra = {}) => ({
  evaluation_mode: 'guideline_only',
  notes: extra.notes ?? 'Apply through the partner website or app. Existing YES BANK credit cardholders are not eligible. YES BANK decides on approval.',
  rules: [
    { parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] },
    { parameter: 'age_years', operator: '<=', threshold_value: 60, allowed_values: [] },
    { parameter: 'net_monthly_salary_inr_or_itr_inr', operator: '>=', threshold_value: 25000, allowed_values: [] },
    { parameter: 'employment_type', operator: 'in', threshold_value: null, allowed_values: ['salaried', 'self_employed'] },
  ],
  required_documents: [],
});

const addon = { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null };

export const exclusionAfter = (id, cat, mccs, reason, from) => ({ ...X(id, cat, mccs, reason), effective_from: from });

export const cards = {
  // ───────────────────────────────────────────── FinBooster (BankBazaar co-brand)
  'yes-bank-finbooster': {
    card_product: {
      ...GST, slug: 'yes-bank-finbooster', name: 'YES BANK FinBooster Credit Card', issuer_slug: 'yes', card_type: 'credit',
      network: 'visa', network_tier: 'visa_platinum', form_factors: ['physical_plastic'], application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: null,
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: PAGE('finbooster-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: 0.1,
      point_value_baseline_basis: 'YES BANK Credit Card Redemption Rules, "Other Credit Cards": 1 YES Reward Point = ₹0.10 as statement credit, e-gift voucher or merchandise, and ₹0.25 on flight and hotel bookings (capped at 70% of the invoice); minimum 2,000 points per redemption; ₹100 + GST per redemption request. Listing FAQ: "value of 1 YES CC Rewardz is up to 0.25p". Baseline uses the ₹0.10 statement-credit rate.',
      point_expiry_months: 36,
    },
    eligibility_engine: eligibility({ notes: 'Apply on the partner (BankBazaar) website or app. Page: age 21 to 60, salaried or self-employed, minimum net salary ₹25,000 a month or ITR of ₹7.5 lakh; existing YES BANK credit cardholders are not eligible.' }),
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('finbooster-excl-fuel', 'fuel', FUEL_MCC, 'No reward points on fuel (FinBooster page glossary d).'),
      X('finbooster-excl-rent', 'rent', [6513], 'No reward points on rent (page glossary d).'),
      X('finbooster-excl-wallet', 'wallet', [6540], 'No reward points on wallet loads (page glossary d).'),
      X('finbooster-excl-government', 'government', GOV_MCC, 'No reward points on government services (page glossary d).'),
      X('finbooster-excl-marketing', 'other', MKT_MCC, 'No reward points on marketing / advertising categories (page glossary d).'),
      X('finbooster-excl-utilities', 'bills', [4900], 'No reward points on utility spends (page glossary d).'),
      X('finbooster-excl-emi', 'emi', [], 'No reward points on EMI on Call and Instant EMI transactions, or on cash advance fees and Priority Pass charges (page glossary b, c, d).'),
      exclusionAfter('finbooster-excl-insurance', 'insurance', [6300, 6381], 'From 15 Jun 2026: no reward points on insurance (page glossary d).', '2026-06-15'),
      exclusionAfter('finbooster-excl-education', 'education', [...EDU_MCC, 7911], 'From 15 Jun 2026: no reward points on education (page glossary d).', '2026-06-15'),
      exclusionAfter('finbooster-excl-railways', 'travel', [4112, 4011], 'From 15 Jun 2026: no reward points on railways (page glossary d).', '2026-06-15'),
      exclusionAfter('finbooster-excl-toll', 'travel', [4784], 'From 15 Jun 2026: no reward points on toll (page glossary d).', '2026-06-15'),
      exclusionAfter('finbooster-excl-ferry', 'travel', [4111], 'From 15 Jun 2026: no reward points on ferry (page glossary d).', '2026-06-15'),
      exclusionAfter('finbooster-excl-jewellery', 'other', [5094, 5944], 'From 15 Jun 2026: no reward points on jewellery (page glossary d).', '2026-06-15'),
      R({ id: 'finbooster-online-dining-10', cat: 'dining', rail: 'online', pri: 10, ppb: 10, mult: 5, cond: { mcc_list: [5262, 5499, 5814], per_inr_block: 200, online_only: true, excludes: 'EMI on Call and Instant EMI transactions' }, reason: 'Page: online dining, INR 200 = 10 points ("5X"); MCCs 5262, 5499, 5814 as defined by VISA (glossary b).' }),
      R({ id: 'finbooster-online-grocery-apparel-6', cat: 'groceries', rail: 'online', pri: 11, ppb: 6, mult: 3, cond: { mcc_list: [5411, 5812, 5699, 5964], per_inr_block: 200, online_only: true, categories: ['grocery stores (5411)', 'eating places (5812)', 'apparel (5699, 5964)'], excludes: 'EMI on Call and Instant EMI transactions' }, reason: 'Page: online grocery / apparel, INR 200 = 6 points ("3X"); glossary c lists grocery stores 5411, eating places 5812 and apparel 5699, 5964 as defined by VISA.' }),
      R({ id: 'finbooster-base-2', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cond: { per_inr_block: 200, scope: 'retail transactions only' }, reason: 'Page: other retail spends (except fuel), INR 200 = 2 points; glossary d limits this to retail transactions.' }),
    ],
    cap_rules: [],
    fees_and_surcharges: yesFees({ forex: 3.5, fuelMin: 500, fuelMax: 3000, fuelCap: 100, fuelThreshold: 25000, utilityThreshold: 25000, tollThreshold: 50000 }),
    statement_and_late_fees: yesStatement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: page says zero first-year and zero renewal membership fee; MITC and KFS list FinBooster at NIL / NIL.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: 'card_issuance', benefit_points: 'N/A', effective_value_inr: null, condition: 'Complimentary CreditStrong report (page "What comes with FinBooster"; listing: free subscription to CreditStrong).' },
      spend_milestones: [],
    },
    addon_card_rules: addon,
    lifestyle_and_network_benefits: [
      B({ id: 'finbooster-creditstrong', cat: 'other', sponsor: 'BankBazaar', label: 'Complimentary CreditStrong credit report / credit-building subscription', cond: { source: 'product page and listing; the CreditStrong user guide was not read' } }),
    ],
    additional_data: { items: [
      ...prov({
        sources: [
          { url: PAGE('finbooster-card'), kind: 'issuer product page incl. glossary (rendered page text)', date: 'read 2026-11-07' },
          { url: LISTING, kind: 'issuer card listing incl. FAQ on YES Rewardz value', date: 'read 2026-11-07' },
          { url: MITC, kind: `MITC: fees, interest, forex, fuel waiver, late fee, redemption; ${MITC_DATE}`, read: 'pdf.js text' },
          { url: KFS, kind: `Key Fact Statement; ${KFS_DATE}`, read: 'pdf.js text' },
          { url: REDEMPTION, kind: 'YES BANK Credit Card Redemption Rules (undated)', read: 'pdf.js text' },
          { url: 'https://www.yes.bank.in/pdf?name=experience_guide_finbooster_credit_card_pdf.pdf', kind: 'YES BANK FinBooster Credit Card Experience Guide, 11 pp (undated and older than the current MITC: it shows a fuel waiver cap of ₹125 and "interest up to 3.5% p.m."). Page 1 shows the FinBooster card art with "YES BANK" and "VISA Platinum". Page 3 says "Never expiring Reward Points with no capping on accrual". Pages 4 to 7 describe a chip-and-PIN contactless card used at POS and ATMs.', read: 'pdf.js text; page 1 rendered and viewed (W11, 2026-11-07)' },
          { url: 'https://www.yes.bank.in/credit-card-services/rewards-subscription-plan', kind: 'YES BANK Rewards Subscription Plan page (read 2026-11-07, undated; fees "revised effective 27 Aug 2026" for other cards): lists "YES Prosperity Rewards / FinBooster Credit Card" for both plans', read: 'browser page text (W11)' },
        ],
        unverified: [
          'Network (settled 2026-11-07, W11): Visa, from card art in YES BANK\'s own FinBooster Experience Guide (page 1: "YES BANK ... VISA Platinum"). The tiny listing image (cc-finbooster-card-img.png) shows no network mark, and the current product page, MITC and KFS never name the network; the "as defined by VISA" MCC footnotes agree but are not used as evidence. The older co-brand MITC mentions a "FinBooster RuPay" variant that the current MITC, KFS, listing and menus do not carry.',
          'Physical or virtual (W11): the Experience Guide describes a physical chip-and-PIN, contactless card with ATM withdrawals, so form_factors is physical_plastic. The guide is undated and older than the current MITC; the MITC fee row that groups FinBooster with RuPay virtual cards is only a fee grouping. UPI linking is not stated for this card and is left null.',
          'No cap on the 10-point and 6-point tiers is stated on the current page, MITC or KFS; the older Experience Guide says "no capping on accrual of Reward Points". The only cap YES states is on the optional Rewards Subscription Plan (75,000 additional points per calendar month).',
          'Reward expiry conflict: the Experience Guide says "Never expiring Reward Points", while MITC 3(l) (5 Oct 2026) and the Redemption Rules say points expire 36 months after earning. The MITC is later; 36 months is stored.',
          'Rewards Subscription Plan (read 2026-11-07, W11): an optional paid plan lists FinBooster. Plan 1 (₹1,000 for 1 year) gives 3 times the regular points on all eligible categories; Plan 2 (₹2,000 for 1 year) gives 5 times on travel, dining, fashion and healthcare MCCs. Extra points are counted per calendar month, credited by the 10th of the next month, and capped at 75,000 per customer per calendar month. Stored in additional_data (rewards_subscription_plan), NOT as reward rules, because the app cannot see whether a holder has subscribed. The plan page is undated.',
          'Page glossary d is printed twice with different exclusions (before and from 15 Jun 2026); the newer list is stored with effective_from 2026-06-15. The "Rewards Subscription Plan" link was read in wave 3 (see the plan item above).',
          'Fuel surcharge waiver: from 15 Jun 2026 ₹500 to ₹3,000 and ₹100 per statement cycle (MITC, KFS); the page glossary says the cap is ₹100 and the earlier range was ₹400 to ₹5,000. No waiver on UPI fuel transactions (MITC 4).',
          'Whether the card can be linked to UPI, and its add-on card rules, are not stated for the current card.',
        ],
        notes: [
          'Forex mark-up is 3.50% from 15 Jun 2026 (3.40% before), listed with POP-CLUB / Paisasave in the MITC and KFS tables; DCC is 1%.',
          'YES Rewardz points expire 36 months after earning (MITC 3(l), Redemption Rules).',
          'Partner: BankBazaar; the partner may charge a platform fee (page). The older co-brand MITC (undated Mizo translation) also lists a "FinBooster RuPay" variant that is not in the current MITC, KFS, listing or menus.',
        ],
      }),
      lateFee, otherFees,
      { key: 'rewards_subscription_plan', value: {
        source: 'https://www.yes.bank.in/credit-card-services/rewards-subscription-plan (read 2026-11-07, undated page; row "YES Prosperity Rewards / FinBooster Credit Card")',
        status: 'optional paid add-on; not modelled as reward rules because a holder\'s subscription is not visible to the app',
        plans: [
          { plan: 'Plan 1', fee_inr_per_year: 1000, benefit: '3 times the regular Reward points for the respective categories, on all spends that earn regular points', validity: '1 year' },
          { plan: 'Plan 2', fee_inr_per_year: 2000, benefit: '5 times the regular Reward points on travel, dining, fashion and healthcare spends (eligible MCCs: healthcare 8011, 8021, 8031, 8041, 8042, 8043, 8044, 8049, 8050, 8062, 8071, 8099, 5912, 5047; travel 4511, 3012, 4582, 4131, 4722, 7011, 3020; dining 5812, 5814; apparel 5611, 5621, 5631, 5641, 5651, 5655, 5661, 5681, 5691, 5697, 5698, 5699)', validity: '1 year' },
        ],
        terms: ['Categories not eligible for regular points are excluded', 'The fee is charged to the card and the plan activates in 1-2 working days', 'Additional points are calculated on spends in a calendar month and credited by the 10th of the next month', 'Additional points are capped at 75,000 per customer per calendar month; a transaction that exceeds the cap earns no points that month'],
      } },
    ] },
  },

  // ───────────────────────────────────────────── Uni (Uni co-brand)
  'yes-bank-uni': {
    card_product: {
      ...GST, slug: 'yes-bank-uni', name: 'YES BANK Uni Credit Card', issuer_slug: 'yes', card_type: 'credit',
      network: 'mastercard', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 499, is_upi_linkable: null,
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: PAGE('uni-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: null,
      point_value_baseline_basis: 'Rewards are issued as Uni coins. The listing calls the reward "1% cashback in uni coins" and the product page "1% Reward points (issued as Uni coins)"; no YES BANK page or document states what one Uni coin is worth in rupees.',
      point_expiry_months: null,
    },
    eligibility_engine: eligibility({ notes: 'Apply on the partner (Uni) website or app; the partner may charge a platform fee. Page: age 21 to 60, salaried or self-employed, minimum net salary ₹25,000 a month or ITR of ₹7.5 lakh; existing YES BANK credit cardholders are not eligible.' }),
    accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('uni-excl-fuel', 'fuel', [5542, 5983, 5172, 5540], 'No Uni coins on fuel (Uni page T&C 1).'),
      X('uni-excl-wallet', 'wallet', [6540], 'No Uni coins on wallet loads (T&C 1).'),
      X('uni-excl-rent', 'rent', [6513], 'No Uni coins on rent (T&C 1).'),
      X('uni-excl-government', 'government', GOV_MCC, 'No Uni coins on government payments (T&C 1).'),
      X('uni-excl-education', 'education', EDU_MCC, 'No Uni coins on education (T&C 1).'),
      X('uni-excl-utility', 'bills', [4900, 4812, 4814, 4815, 4816, 4821, 4829, 4899], 'No Uni coins on utility payments (T&C 1).'),
      X('uni-excl-emi', 'emi', [], 'No Uni coins on EMI transactions or cash advance / withdrawals (T&C 1).'),
      X('uni-excl-marketing', 'other', MKT_MCC, 'No Uni coins on marketing and advertising services (T&C 1).'),
      X('uni-excl-international', 'other', [], 'No Uni coins on international transactions (T&C 1).', { transaction_type: 'international' }),
      R({ id: 'uni-base-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { reward_currency: 'Uni coins', personal_spends_only: false }, reason: 'Page: unlimited 1% reward points (rewards issued as Uni coins); listing: 1% cashback in uni coins on all transactions. The rupee value of a Uni coin is not stated, so 1% is the advertised figure.' }),
    ],
    cap_rules: [],
    fees_and_surcharges: yesFees({ noForex: true, fuelMin: null, fuelMax: 7500, fuelCap: 500, fuelThreshold: 50000, utilityThreshold: 50000, tollThreshold: 75000 }),
    statement_and_late_fees: yesStatement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 50000, period: 'card_anniversary_year', evaluation_condition: 'Renewal fee ₹499 + taxes waived on retail spends of ₹50,000 or more within the 12 months before the renewal date; not applicable to lifetime-free cards (Uni page; MITC; KFS). Zero joining fee.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 499 },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: addon,
    lifestyle_and_network_benefits: [],
    additional_data: { items: [
      ...prov({
        sources: [
          { url: PAGE('uni-credit-card'), kind: 'issuer product page incl. T&C (rendered page text)', date: 'read 2026-11-07' },
          { url: LISTING, kind: 'issuer card listing (1% cashback in uni coins; renewal ₹499)', date: 'read 2026-11-07' },
          { url: MITC, kind: `MITC: fees, interest, forex, fuel waiver, late fee; ${MITC_DATE}`, read: 'pdf.js text' },
          { url: KFS, kind: `Key Fact Statement; ${KFS_DATE}`, read: 'pdf.js text' },
          { url: 'https://www.yes.bank.in/sites/web/content/published/api/v1.1/assets/CONTE31749D516FF442DB73D463B9277341A/native?siteId=yesbank', kind: 'Card art (uni-card-icon.png, 293x139 px) attached to the "UNI Credit Card" tile on the YES BANK credit card listing, whose Know More link is the uni-credit-card page: teal card with "uni" and "YES BANK" and the Mastercard logo (viewed, W11 2026-11-07)', read: 'image opened in a browser tab' },
          { url: 'https://www.yes.bank.in/sites/web/content/published/api/v1.1/items?q=(type eq "ybl-sa-get-familiar" AND fields.group_name eq "unicreditcardsalider")', kind: 'The Uni page\'s own "Top Benefits" slider data (the page text omits it): one slide reads "Secure online transactions with MasterCard Secure Code". Card-specific slider group, but a generic security line, so corroboration only.', read: 'page content API, read in the browser (W11)' },
        ],
        unverified: [
          'Value of one Uni coin in rupees is not stated by YES BANK (re-checked in wave 3: product page, the page\'s Top Benefits and More-from items, its FAQs, the listing, MITC V18, the Cardmember Agreement and the Redemption Rules say nothing), so point_value_inr_baseline and effective_base_return_percent are null. The 1% is the advertised rate; the listing calls it "1% cashback in uni coins", the product page "Unlimited 1% Reward points (rewards issued as Uni coins)". Whether a partner-side coin conversion differs from the 1% is not stated by YES.',
          'Network (settled 2026-11-07, W11): Mastercard, from card art on the YES BANK listing tile for "UNI Credit Card" (Mastercard logo). The product page, MITC and KFS do not name it; the MITC lists a separate "Uni RuPay Virtual" and the listing a separate "UNI Rupay Credit Card" page (lifetime free), which is a different product and not covered by this record.',
          'Physical or virtual, and UPI linking, are not stated. The cash-advance fee (2.5% or ₹650) is written for a physical card. The listing compare-record for this card carries "unlimited international lounge access, 6 domestic" text that the product page and MITC do not state and that also appears on the virtual-only Klick record; it looks like template filler and is not stored.',
          'The page "Top Benefits" slider and "More from this card" items were read in wave 3 from the page\'s content API: shop and earn Uni coins, zero forex mark-up, 1% fuel surcharge waiver up to ₹500, annual fee waiver on ₹50,000 spend within 12 months of the card anniversary, contactless, MasterCard Secure Code. They add no rate, cap or coin value.',
          'The page footnote says no coins on "international transactions"; the MITC does not repeat this. Reward expiry for Uni coins is not stated (MITC refers co-brand currencies to the product page).',
          'The MITC fee table shows ₹5,000 in the joining-fee-waiver column for Uni although the joining fee is NIL; ignored as a table artefact.',
        ],
        notes: [
          'Forex mark-up and DCC are not applicable to this card (MITC 3(q), KFS), so both are stored as 0.',
          'Fuel surcharge waiver: transactions up to ₹7,500, maximum ₹500 per statement cycle (page T&C 2, MITC 4); no waiver on UPI fuel transactions.',
          'Fuel and utility fee thresholds for Uni are ₹50,000 (the higher tier in the MITC); toll threshold ₹75,000.',
        ],
      }),
      lateFee, otherFees,
    ] },
  },

  // ───────────────────────────────────────────── PaisaSave RuPay (Paisabazaar co-brand, existing-cardholder upgrade)
  'yes-bank-paisasave-rupay': {
    card_product: {
      ...GST, slug: 'yes-bank-paisasave-rupay', name: 'YES BANK Paisabazaar PaisaSave RuPay Credit Card', issuer_slug: 'yes', card_type: 'credit',
      network: 'rupay', application_mode: 'invite_only', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, form_factors: ['virtual_card'],
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: PAGE('paisabazaar-rupay-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: 1,
      point_value_baseline_basis: 'Page footnote a: cashback is credited as reward points, "1 RP = INR 1", no charges on redemption; FAQ: redeem against statement credit in a 1:1 ratio on the YES Rewardz platform.',
      point_expiry_months: null,
    },
    eligibility_engine: {
      evaluation_mode: 'guideline_only',
      notes: 'Only existing holders of the YES BANK Paisabazaar PaisaSave Credit Card can get this virtual RuPay variant, by applying in the iris by YES app (page: "This Card can be availed by existing Paisabazaar Paisasave Cardholders only").',
      rules: [{ parameter: 'existing_card', operator: 'in', threshold_value: null, allowed_values: ['YES BANK Paisabazaar PaisaSave Credit Card'] }],
      required_documents: [],
    },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: 3000, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('yes-psr-excl-fuel', 'fuel', [5172, 5541, 5542, 5983], 'No cashback on fuel (page footnote c).'),
      X('yes-psr-excl-rent', 'rent', [6513], 'No cashback on rent payments (footnote c).'),
      X('yes-psr-excl-wallet', 'wallet', [], 'No cashback on wallet loading (footnote c).'),
      X('yes-psr-excl-bills', 'bills', [4900, 4812, 4814], 'No cashback on utility and telecom payments (footnote c).'),
      X('yes-psr-excl-insurance', 'insurance', [6300], 'No cashback on insurance (footnote c).'),
      X('yes-psr-excl-education', 'education', [8299, 8211, 8220, 8241, 8249], 'No cashback on education and vocational schools (footnote c).'),
      X('yes-psr-excl-government', 'government', [9399, 9311], 'No cashback on government services (footnote c).'),
      X('yes-psr-excl-health', 'health', [8062, 5912, 8099, 8071, 8050, 8011, 8931], 'No cashback on hospitals, pharmacy stores, doctors, medical services and laboratories (footnote c).'),
      X('yes-psr-excl-emi', 'emi', [], 'No cashback on EMI transactions or cash advances (footnote c).'),
      X('yes-psr-excl-other', 'other', [5094, 5944, 6538, 4784, 4112, 7538, 5511, 5521, 5571, 5533, 5013, 5960, 5965, 7299, 7311, 7392, 7399, 8999], 'No cashback on jewellery, POI funding, toll, passenger railways, automotive dealers / service / parts, direct marketing, advertising, consulting and miscellaneous business services (footnote c MCC list).'),
      X('yes-psr-excl-upi-small', 'other', [], 'No cashback on UPI transactions below ₹2,000 (footnote c).', { rail: 'upi', transaction_amount_lt_inr: 2000 }),
      R({ id: 'yes-psr-dining-6pct', cat: 'dining', pri: 10, ppb: 12, mult: 6, cb: 6, cap: 'yes-psr-6pct-cycle-cap', from: '2025-12-15', cond: { mcc_list: [5812, 5813, 5814], per_inr_block: 200, not_upi: true }, reason: 'Page: 6% cashback = 12 reward points per ₹200 on dining and travel, except UPI transactions; dining MCCs 5812, 5813, 5814 (footnote a). 1 RP = ₹1.' }),
      R({ id: 'yes-psr-travel-6pct', cat: 'travel', pri: 10, ppb: 12, mult: 6, cb: 6, cap: 'yes-psr-6pct-cycle-cap', from: '2025-12-15', cond: { mcc_list: [4511, 4582, 4722, 7011, 3501, 3509, 3513, 3520, 3530, 3543, 3553, 3583, 3637, 3640, 3642, 3649, 3657, 3659, 3690, 3812, 3020], per_inr_block: 200, not_upi: true }, reason: 'Page: 6% cashback = 12 reward points per ₹200 on travel MCCs (airlines, travel agencies, hotels) (footnote a), except UPI.' }),
      R({ id: 'yes-psr-base-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 1, cb: 1, from: '2025-12-15', cond: { per_inr_block: 200, upi_minimum_inr: 2000 }, reason: 'Page: 1% cashback = 2 reward points per ₹200 on other spends; UPI transactions above ₹2,000 on all categories also earn 1% (footnote a); UPI below ₹2,000 earns nothing.' }),
    ],
    cap_rules: [C({ id: 'yes-psr-6pct-cycle-cap', cat: 'dining', metric: 'bonus_reward_points', period: 'statement_cycle', points: 3000, after: 'downgrade_to_base_rate', afterPpb: 2 })],
    fees_and_surcharges: yesFees({ forex: 3.5, virtual: true, fuelMin: 500, fuelMax: 3000, fuelCap: 125, fuelThreshold: 25000, utilityThreshold: 25000, tollThreshold: 50000, redemptionFee: 0, redemptionNote: 'Page footnote a and FAQ: no charges on redemption; MITC 3(l): redemption fee waived for the Paisabazaar Paisasave card.' }),
    statement_and_late_fees: yesStatement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: page says zero joining fee and no annual membership fee; MITC and KFS list the PaisaSave RuPay Virtual card at NIL / NIL.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: 0, fee_per_card_inr: 'N/A', separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    additional_data: { items: [
      ...prov({
        sources: [
          { url: PAGE('paisabazaar-rupay-credit-card'), kind: 'issuer product page incl. FAQ and T&C footnotes (rendered page text)', date: 'read 2026-11-07' },
          { url: LISTING, kind: 'issuer card listing (card shown as virtual only, 0 / 0)', date: 'read 2026-11-07' },
          { url: MITC, kind: `MITC: fees, interest, forex, fuel waiver, late fee; ${MITC_DATE}`, read: 'pdf.js text' },
          { url: KFS, kind: `Key Fact Statement; ${KFS_DATE}`, read: 'pdf.js text' },
        ],
        unverified: [
          'Availability: only existing PaisaSave cardholders can apply (page). application_mode is stored as invite_only; a new customer cannot get this card directly.',
          'The 3,000-point cap (footnote d) is attached to the 6% line; it says rewards are capped at 3,000 per statement cycle and base points keep accruing after that. Modelled as a cap on bonus points that falls back to 2 points per ₹200; it could also be read as a cap on total points.',
          'Reward rates before 15 Dec 2025 were different (3% as 6 points per ₹200 online; 1.5% on UPI above ₹2,000); the current rules carry effective_from 2025-12-15.',
          'Footnote c lists category names and MCCs together; the exclusion rules group the MCCs by closest category and the grouping is a judgement. Exclusion for "wallet loading" and "EMI" has no MCC.',
          'Fuel surcharge waiver: the MITC cap table gives ₹125 per cycle for the PaisaSave RuPay virtual card and says no waiver on UPI fuel transactions, while another MITC line says UPI fuel waiver on RuPay virtual cards is capped at ₹125; the page says only "1% waiver on fuel surcharge". Stored as ₹500 to ₹3,000, ₹125 per cycle.',
          'Cash-advance fee and card re-issue fee are marked not applicable because the MITC says they do not apply to virtual cards; the page still lists a 3.99% rate on cash advances.',
          'Reward-point expiry is not stated for this card.',
        ],
        notes: [
          'The page interest line says 3.99% a month without the annual figure; the MITC and KFS give 47.88% a year for "other credit cards".',
          'Forex mark-up 3.50% from 15 Jun 2026 (3.40% before), DCC 1% (MITC, KFS).',
          'This is a virtual-only card issued on RuPay and linked to UPI apps; the YES BANK PaisaSave (non-RuPay) card is a separate product and is not in this draft set.',
        ],
      }),
      lateFee, otherFees,
    ] },
  },

  // ───────────────────────────────────────────── Zagg (formerly Rio) - HELD: no current reward rate published
  'yes-bank-zagg': {
    card_product: {
      ...GST, slug: 'yes-bank-zagg', name: 'YES BANK Zagg Credit Card', issuer_slug: 'yes', card_type: 'credit',
      network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true,
      data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: PAGE('zagg-credit-card'), status: 'draft', verified_at: null,
      point_value_inr_baseline: null,
      point_value_baseline_basis: 'The product page, MITC and KFS publish no reward rate for the current Zagg card. Cards issued before 10 Jan 2025 earned Rio coins; the value of a Rio coin is not stated.',
      point_expiry_months: null,
    },
    eligibility_engine: eligibility({ notes: 'Apply in the partner (Zagg) app; the partner may charge a platform fee. Page: age 21 to 60, salaried or self-employed, minimum net salary ₹25,000 a month or ITR of ₹7.5 lakh; existing YES BANK credit cardholders are not eligible.' }),
    accrual_engine: { base_block_inr: null, rounding_mode: null, base_points_per_block: null, base_cashback_percent: null, effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [],
    cap_rules: [],
    fees_and_surcharges: yesFees({ forex: 3.5, fuelMin: 400, fuelMax: 5000, fuelCap: 250, fuelThreshold: 25000, utilityThreshold: 25000, tollThreshold: 50000 }),
    statement_and_late_fees: yesStatement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Current Zagg card: zero first-year and zero renewal fee (page, MITC NIL / NIL). Cards issued before 10 Jan 2025 carry a ₹399 + GST annual fee waived on annual spends of ₹1,80,000 (page footnote, MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: addon,
    lifestyle_and_network_benefits: [
      B({ id: 'zagg-domestic-lounge', cat: 'lounge', program: 'N/A', sponsor: 'YES BANK', label: 'Domestic airport lounge access (spend-based)', cond: { rule: 'Spend ₹50,000 or more in the previous calendar quarter to unlock access in the next quarter; not available in the quarter of issuance; spends exclude fees, reversals, rent and wallet', validation_swipe_inr: 2, booking: 'Lounge One web access or card swipe' }, qty: 2, per: 'quarter', from: '2025-04-01' }),
    ],
    additional_data: { items: [
      ...prov({
        sources: [
          { url: PAGE('zagg-credit-card'), kind: 'issuer product page incl. glossary and FAQ (rendered page text)', date: 'read 2026-11-07' },
          { url: LISTING, kind: 'issuer card listing (0 / 0, 1% fuel surcharge waiver, 2 domestic lounges a quarter)', date: 'read 2026-11-07' },
          { url: MITC, kind: `MITC: fees, interest, forex, fuel waiver, lounge threshold; ${MITC_DATE}`, read: 'pdf.js text' },
          { url: KFS, kind: `Key Fact Statement; ${KFS_DATE}`, read: 'pdf.js text' },
          { url: LOUNGE, kind: 'YES BANK Domestic Lounge Program terms (undated; threshold text effective 1 Apr 2025)', read: 'pdf.js text' },
          { url: 'https://www.yes.bank.in/pdf?name=zagg_one_pager_usage_guide.pdf', kind: 'YES BANK "Zagg credit card User guide", 1-page image PDF (undated): title "Power of Credit, Ease of UPI with YES BANK Zagg Credit Card"; the card shown carries "YES BANK" and the RuPay logo. Text: "Bringing together the cashbacks on credit cards with the convenience of UPI" (no rate)', read: 'PDF page rendered and viewed in a browser tab (W11, 2026-11-07)' },
          { url: 'https://www.yes.bank.in/sites/web/content/management/api/v1.1/assets/CONTC0C27676083547F6A5FFD83A5B248A9C/native/zag-credit-card-px-web-banner-3.jpeg', kind: 'Hero banner on the YES BANK Zagg product page (6002x1584 px): the card in the model\'s hand reads "zagg.money", "YES BANK" and the RuPay logo (cropped and enlarged, viewed). The page\'s "Top Benefits" slide "Power Up Your Credit Card On UPI and credit card spends" (rio-credit-card-features-earn-cashbacks.png) shows the same card with RuPay and states no rate', read: 'images opened in a browser tab (W11)' },
        ],
        unverified: [
          'HELD: no reward rate for the current card is published. Re-read in wave 3 (W11, 2026-11-07): the product page, its Top Benefits slider (earn cashbacks, works everywhere, 1-click controls on the app, scan and pay for UPI: all images with headline text only), the What-comes-with-the-card items (lifetime free, works everywhere, 1% fuel surcharge waiver, lounge), the 7 FAQs, the usage guide, MITC V18 (the "English" MITC link on the page resolves to it; no Zagg or Rio coin terms in it) and the Cardmember Agreement state no cashback or coin rate. The only rate is the footnote for cards issued before 10 Jan 2025 (0.5 Rio coins per ₹50 on non-UPI and 1.5 Rio coins per ₹50 on UPI, outside exclusion categories). The page says any programme run by the Zagg app is the app provider\'s sole responsibility, so the current cashback programme sits outside YES documents. The value of a Rio coin is not stated. No reward rules are written. To unblock: ask YES BANK or Zagg for the Zagg card rewards terms.',
          'Network (settled 2026-11-07, W11): RuPay, from card art on YES BANK\'s own Zagg pages (the usage guide PDF, the hero banner and the Top Benefits slide all show "YES BANK" and the RuPay logo). The product FAQ also says the card links to UPI apps ("NPCI recognised TPAPs"). The MITC and KFS do not name the network.',
          'RIO and Zagg: the issuer lists one product. The page assets are named "rio_*" and the pre-10-Jan-2025 footnote speaks of Rio coins, so Rio is the earlier name of the same card; the old co-brand MITC (undated Mizo translation) lists "Rio" and the current MITC lists "Zagg". Treated as one card.',
          'Lounge: two domestic visits a calendar quarter (page, listing) with a ₹50,000 prior-quarter spend condition (MITC 3(r), Lounge Program). Whether any international lounge access exists is not stated.',
          'Fuel surcharge waiver: from 15 Jun 2026 ₹400 to ₹5,000 and ₹250 per statement cycle (MITC 4, KFS); the page glossary says the cap is ₹250 and states no range. No waiver on UPI fuel transactions.',
        ],
        notes: [
          'Forex mark-up is 3.50% (MITC and KFS list Zagg with BYOC / EMI / Wellness / Novio / Max).',
          'The Zagg usage guide PDF is a single image page with no extractable text.',
        ],
      }),
      lateFee, otherFees,
    ] },
  },
};
