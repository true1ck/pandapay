// Axis Bank cards. Sources (read 2026-11-07):
//  MITC     = Axis Bank "Most Important Terms and Conditions" (62 pages) https://www.axis.bank.in/docs/default-source/default-document-library/mitc-credit-cards.pdf
//  *_TNC    = card member T&C PDFs on axis.bank.in (read with pdftotext)
//  Kwik page read rendered in a browser session.
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';

const MITC = 'https://www.axis.bank.in/docs/default-source/default-document-library/mitc-credit-cards.pdf';
const mitcSrc = { url: MITC, kind: 'MITC (fees, interest, forex, penalties)', read: 'pdftotext + page images for the interest table' };

// Fees in the MITC that apply to all five cards (Scapia differs on forex).
const axisFees = ({ forex = 3.5, fuel }) => ({
  apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 55.55 },
  forex_markup: { markup_percent: forex, gst_applicable: true },
  dynamic_currency_conversion_dcc: { fee_percent: forex, gst_applicable: true, trigger_condition: 'MITC: same markup on international transactions in Indian currency and on INR transactions with foreign-registered merchants' },
  fuel_surcharge: fuel,
  category_surcharges: [
    { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: '1% fee on each rental transaction', threshold_spend_inr: null, effective_from: null, effective_to: null },
    { category_id: 'wallet_load', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once cumulative wallet loads reach ₹10,000 in a statement cycle (from 20 Dec 2024)', threshold_spend_inr: 10000, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once cumulative fuel spend reaches ₹50,000 in a statement cycle (from 20 Dec 2024)', threshold_spend_inr: 50000, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'utility', mcc_list: [4814, 4899, 4900], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once cumulative utility payments reach ₹25,000 in a statement cycle', threshold_spend_inr: 25000, effective_from: '2024-12-20', effective_to: null },
    { category_id: 'gaming', mcc_list: [5816], fee_percent: 1, gst_applicable: true, trigger_condition: '1% once online skill-gaming spend reaches ₹10,000 in a statement cycle', threshold_spend_inr: 10000, effective_from: null, effective_to: null },
  ],
  banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
});

const axisStatement = {
  late_payment_slabs: [
    { min_balance_inr: 0, max_balance_inr: 500, fee_inr: 0 },
    { min_balance_inr: 501, max_balance_inr: 5000, fee_inr: 500 },
    { min_balance_inr: 5001, max_balance_inr: 10000, fee_inr: 750 },
    { min_balance_inr: 10001, max_balance_inr: 50000, fee_inr: 1200 },
    { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
  ],
};

const common = (pageUrl, o = {}) => ({
  card_product: { ...GST, card_type: 'credit', data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: pageUrl, status: 'draft', verified_at: null, application_mode: 'open', ...o },
  statement_and_late_fees: axisStatement,
});

export const cards = {
  // ───────────────────────────────────────────── Scapia Axis
  'axis-bank-scapia-credit-card': {
    ...common('https://www.axis.bank.in/cards/credit-card/scapia-axis-bank-credit-card', { network: null, joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, point_value_inr_baseline: 0.2, point_value_baseline_basis: 'Scapia terms: 5 Scapia Coins = ₹1, redeemable only on the Scapia app (flights, hotels, buses and other services). Value can be revised on one month\'s notice.' }),
    fees_and_surcharges: axisFees({ forex: 0, fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 } }),
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Scapia terms: activate within 30 days of issue; up to ₹5,000 limit released before physical delivery.', rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 10, base_cashback_percent: 'N/A', effective_base_return_percent: 2, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('scapia-excl-wallet', 'wallet_load', [], 'Wallet loading earns nothing (Scapia T&C 4.3).'),
      X('scapia-excl-education', 'education', [], 'Education and school fees earn nothing (T&C 4.3).'),
      X('scapia-excl-fuel', 'fuel', [], 'Fuel and fuel surcharge earn nothing (T&C 4.3).'),
      X('scapia-excl-government', 'government', [], 'Government services earn nothing (T&C 4.3).'),
      X('scapia-excl-emi', 'emi', [], 'EMI transactions earn nothing; rewards are not reinstated on EMI cancellation (T&C 4.3).'),
      X('scapia-excl-rent', 'rent', [], 'Real-estate rentals earn nothing (T&C 4.3).'),
      X('scapia-excl-insurance', 'insurance', [], 'Insurance earns nothing (T&C 4.3).'),
      X('scapia-excl-utility', 'utility', [], 'Utility payments earn nothing (T&C 4.3).'),
      X('scapia-excl-other', 'excluded_spend', [], 'Business services, crypto and MOTO, financial institutions, gift cards, bridge/road fees and tolls earn nothing (T&C 4.3 and MCC table; the table lists categories, the MCC numbers were not extractable).'),
      R({ id: 'scapia-app-travel-20pct', cat: 'travel', pri: 5, ppb: 20, mult: 20, channel: 'scapia_app', cond: { platform: 'Scapia app', bookings: ['flights', 'hotels', 'bus'] }, reason: '4% value back (equivalent to 20% rewards, at 5 coins = ₹1) on eligible Scapia-app flight, hotel and bus bookings; no maximum cap (T&C 4.7).' }),
      R({ id: 'scapia-mastercard-2pct', cat: 'all_retail', pri: 20, type: 'standard_accrual', ppb: 10, mult: 10, cond: { minimum_transaction_inr: 20, variant: 'Mastercard' }, reason: '2% value back (equivalent to 10% rewards) on all eligible spends of ₹20 and above on the Mastercard card (T&C 4.6).' }),
      R({ id: 'scapia-rupay-1pct', cat: 'all_retail', pri: 21, type: 'standard_accrual', ppb: 5, mult: 5, cond: { minimum_transaction_inr: 500, variant: 'RuPay' }, reason: '1% value back (equivalent to 5% rewards) on all eligible spends of ₹500 and above on the RuPay card (T&C 4.6).' }),
    ],
    cap_rules: [],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No joining or annual fee (T&C 3.1, MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [
      B({ id: 'scapia-domestic-lounge', cat: 'lounge', sponsor: 'Axis Bank / Scapia', label: 'Unlimited complimentary domestic lounge, meals, shopping and spa access', cond: { min_net_spend_inr_per_billing_cycle: 20000, spend_aggregated_across_variants: true, entry: 'complimentary entry for the cardholder only via a Scapia-app QR code', enabled_after_billing_date_working_days: '3-5' }, qty: null, per: 'N/A' }),
    ],
    dynamic_promotions_registry: [],
    additional_data: { items: [
      dualNetwork({
        sourceUrl: 'https://www.axis.bank.in/docs/default-source/default-document-library/terms-and-conditions-for-scapia-credit-card.pdf',
        evidence: 'Scapia Axis T&C 4.6 and 7.2 describe a Mastercard variant and a RuPay variant that share one credit account and one spend threshold.',
        variants: [
          { network: 'mastercard', network_tier: 'N/A', label: 'Scapia Axis Bank Credit Card (Mastercard)', source_url: 'https://www.axis.bank.in/docs/default-source/default-document-library/terms-and-conditions-for-scapia-credit-card.pdf', evidence: 'T&C 4.6: 2% value back on eligible spends of ₹20 and above.' },
          { network: 'rupay', network_tier: 'N/A', label: 'Scapia Axis Bank Credit Card (RuPay)', source_url: 'https://www.axis.bank.in/docs/default-source/default-document-library/terms-and-conditions-for-scapia-credit-card.pdf', evidence: 'T&C 4.6: 1% value back on eligible spends of ₹500 and above.' },
        ],
      }),
      ...prov({
        sources: [
          { url: 'https://www.axis.bank.in/docs/default-source/default-document-library/terms-and-conditions-for-scapia-credit-card.pdf', kind: 'Scapia Axis member T&C (earn, coins, forex, lounge)', read: 'pdftotext' },
          mitcSrc,
        ],
        unverified: [
          'T&C carries no revision date.',
          'The MCC numbers behind the ineligible categories were not extractable from the PDF table; exclusions are category-level.',
          'Scapia Coin value can change on one month\'s notice (T&C 5.2.2); 5 coins = ₹1 is the current value.',
          'Lounge visit count: terms say "Unlimited" once the ₹20,000 cycle spend is met; guest entry is paid.',
        ],
        notes: [
          'The headline "10% rewards" and "20% rewards" are Scapia-coin percentages. At 5 coins = ₹1 the real value is 2% (Mastercard), 1% (RuPay) and 4% on Scapia-app travel bookings, as the T&C itself states ("2% value back (equivalent to 10% rewards)").',
          'Fuel surcharge waiver for fuel transactions up to ₹5,000, maximum ₹500 per statement cycle (MITC).',
          'Zero forex mark-up on international transactions (T&C 6, MITC).',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── Google Pay Flex Axis
  'google-pay-flex-axis-bank': {
    ...common('https://www.axis.bank.in/cards/credit-card/google-pay-flex-axis-bank-credit-card', { network: 'rupay', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, point_value_inr_baseline: 1, point_value_baseline_basis: 'T&C: each Star has a fixed value of ₹1, redeemable only inside Google Pay; Stars expire after 1 year.', point_expiry_months: 12 }),
    fees_and_surcharges: axisFees({ fuel: { category_id: 'fuel', surcharge_percent: null, waiver_percent: null, min_txn_inr: null, max_txn_inr: null, monthly_waiver_cap_inr: null } }),
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 500, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 0.4, effective_base_return_percent: 0.4, cycle_accrual_ceiling_points: 1500, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      X('flex-excl-rent', 'rent', [], 'Rental payments earn no Stars (T&C).'),
      X('flex-excl-cash', 'cash_withdrawal', [], 'Cash withdrawals earn no Stars (T&C).'),
      X('flex-excl-fi', 'excluded_spend', [], 'Financial institution payments, card fees and charges, gift cards, bridge/road fees and tolls earn no Stars (T&C).'),
      X('flex-excl-insurance', 'insurance', [], 'Insurance premiums earn no Stars (T&C).'),
      X('flex-excl-education', 'education', [], 'Educational institutions and services earn no Stars (T&C).'),
      X('flex-excl-government', 'government', [], 'Government payments and fees earn no Stars (T&C).'),
      X('flex-excl-wallet', 'wallet', [], 'Wallet spends earn no Stars (T&C).'),
      X('flex-excl-jewellery', 'jewellery', [], 'Clock, jewellery, watch and silverware stores earn no Stars (T&C).'),
      R({ id: 'flex-base-floor', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 0.4, mult: 1, cap: 'flex-cycle-cap', cond: { rule: '2 Stars per ₹500 of cumulative cycle spend (account level)', applies_when: 'first reward cycle, or previous reward cycle net spend below ₹100 for a non-Google One member', reward_cycle: '16th to 15th' }, reason: 'Floor rate: 0.4% (2 Stars per ₹500, each Star ₹1). Applies in the joining cycle and when the previous cycle was not spend-active.' }),
      R({ id: 'flex-0-8pct', cat: 'all_retail', pri: 25, type: 'standard_accrual', cb: 0.8, mult: 1, cap: 'flex-cycle-cap', cond: { effective_from_cycle: '2026-10-16', previous_cycle_net_spend_ge_inr: 100, google_one_member: false, cycle_spend_le_inr: 15000 }, reason: '0.8% on all spends in the cycle for a Flex user who spent at least ₹100 in the previous cycle and is not a Google One member, while cycle spend is up to ₹15,000 (T&C milestone table).' }),
      R({ id: 'flex-1-6pct', cat: 'all_retail', pri: 24, type: 'standard_accrual', cb: 1.6, mult: 1, cap: 'flex-cycle-cap', cond: { effective_from_cycle: '2026-10-16', previous_cycle_net_spend_ge_inr: 100, google_one_member: false, cycle_spend_gt_inr: 15000, applies_to: 'all spends in the cycle, not only the excess' }, reason: '1.6% on all cycle spends once cycle spend crosses ₹15,000, for a non-Google One member (T&C).' }),
      R({ id: 'flex-google-one-1-6pct', cat: 'all_retail', pri: 23, type: 'standard_accrual', cb: 1.6, mult: 1, cap: 'flex-cycle-cap', cond: { effective_from_cycle: '2026-10-16', previous_cycle_net_spend_ge_inr: 100, google_one_member: true, cycle_spend_le_inr: 15000 }, reason: '1.6% for a Google One member with previous-cycle spend of at least ₹100, while cycle spend is up to ₹15,000 (T&C).' }),
      R({ id: 'flex-google-one-3-2pct', cat: 'all_retail', pri: 22, type: 'standard_accrual', cb: 3.2, mult: 1, cap: 'flex-cycle-cap', cond: { effective_from_cycle: '2026-10-16', previous_cycle_net_spend_ge_inr: 100, google_one_member: true, cycle_spend_gt_inr: 15000, applies_to: 'all spends in the cycle, not only the excess' }, reason: '3.2% on all cycle spends once cycle spend crosses ₹15,000, for a Google One member (T&C). Swipe and tap payments qualify as well.' }),
    ],
    cap_rules: [C({ id: 'flex-cycle-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', points: 1500, after: 'zero_accrual' })],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'No joining or annual fee (MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [],
    dynamic_promotions_registry: [
      P({ id: 'flex-google-one-bills', cat: 'utility', sponsor: 'Google Pay', platform: 'Google Pay bills and recharges (Google One members only)', type: 'extra_stars_15pct_up_to_450_on_3000_monthly_spend', pct: 15, max: 450, quota: true, permanent: false, from: '2026-10-16', to: '2027-10-15' }),
      P({ id: 'flex-google-one-food-grocery', cat: 'groceries', sponsor: 'Google Pay', platform: 'UPI on Swiggy, Zomato, Zepto, Blinkit, BigBasket, Milkbasket, Jiomart, Instamart, DMart, FK Minutes, Amazon Now, District (Google One members only)', type: 'extra_stars_5pct_up_to_250_on_5000_monthly_spend', pct: 5, max: 250, quota: true, permanent: false, from: '2026-10-16', to: '2027-10-15' }),
    ],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.axis.bank.in/docs/default-source/default-document-library/credit-card/terms-and-conditions-for-google-pay-flex-axis-bank-credit-card.pdf', kind: 'Flex Axis member T&C (PDF metadata dated 2026-10-15)', read: 'pdftotext' },
        { url: 'https://support.google.com/pay/india/answer/16547967?hl=en', kind: 'Google Pay support page (agrees with the T&C table)', read: 'earlier fetch, matches T&C' },
        mitcSrc,
      ],
      unverified: [
        'Network: RuPay, read from the card art on the issuer page banner (https://www.axis.bank.in/images/default-source/l4-banner/credit-card/google-pay-flex-credit-card-1366x400-w1.webp, RuPay logo beside the Axis Bank mark). The T&C and page text never name the network, so a human should confirm it against the issued card. Card variant name is not stated in the T&C.',
        'Welcome benefit: the earlier read of the issuer page and the Google support page disagree (₹1,750 + ₹250 gift card versus ₹750 + bonuses); not modelled until the issuer page is read verbatim.',
        'The promotional structure runs 16 Oct 2026 to 15 Oct 2027 and can be extended or changed by Google Pay and Axis.',
        'Fuel surcharge waiver: not stated in the T&C or MITC for this card.',
        'Of the 1,500-Star cycle cap, at most 750 Stars are awarded by Axis Bank (T&C); the rest come from Google Pay.',
        'The old "1/2/4/8 stars per ₹500" model in the Nov 5 research notes is not in any document read and is dropped.',
      ],
      notes: [
        'Every rate above depends on user attributes (Google One membership, previous-cycle spend of at least ₹100, cycle spend above ₹15,000), so the ranking engine cannot choose one without user state. The floor is 0.4%.',
        'Reward cycle is 16th to 15th. Stars expire after 1 year.',
        'Stars earned on transactions converted to EMI are reversed.',
      ],
    }) },
  },

  // ───────────────────────────────────────────── super.money RuPay
  'axis-bank-supermoney-rupay': {
    ...common('https://www.axis.bank.in/cards/credit-card/supermoney-credit-card', { network: 'rupay', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, form_factors: ['virtual_card'] }),
    fees_and_surcharges: axisFees({ fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 4000, monthly_waiver_cap_inr: 400 } }),
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: 'statement_cycle' },
    reward_rules: [
      ...[
        ['supermoney-excl-repayments', 'excluded_spend', [], 'Repayments'], ['supermoney-excl-utility', 'utility', [], 'Utility services'], ['supermoney-excl-fuel', 'fuel', [], 'Fuel'],
        ['supermoney-excl-jewellery', 'jewellery', [], 'Clock, jewellery, watch and silverware stores'], ['supermoney-excl-cash', 'cash_withdrawal', [], 'Cash withdrawal'], ['supermoney-excl-wallet', 'wallet_load', [], 'Wallet load'],
        ['supermoney-excl-insurance', 'insurance', [], 'Insurance services'], ['supermoney-excl-education', 'education', [], 'Education services'], ['supermoney-excl-government', 'government', [], 'Government services'],
        ['supermoney-excl-fi', 'excluded_spend', [], 'Financial institutions'], ['supermoney-excl-rent', 'rent', [], 'Rental payments'], ['supermoney-excl-emi', 'emi', [], 'EMI transactions and purchases converted to EMI post facto'],
        ['supermoney-excl-telecom', 'excluded_spend', [], 'Telecom, gift cards, bridge fees, road fees and tolls'],
      ].map(([id, cat, mccs, label]) => X(id, cat, mccs, `${label} earns no cashback (Cashback T&C, merchant category exclusions).`)),
      R({ id: 'supermoney-app-3pct', cat: 'upi', rail: 'upi_qr', pri: 10, cb: 3, mult: 3, channel: 'super_money_app', cond: { platform: 'super.money app', minimum_transaction_inr: 100, cap_rule: 'cashback on super.money UPI is capped at the larger of ₹100 and the cashback earned that cycle on all other eligible spends' }, cap: 'supermoney-app-dependent-cap', reason: '3% cashback on QR transactions through the super.money platform, subject to a cap tied to other cashback in the same statement cycle.' }),
      R({ id: 'supermoney-other-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { minimum_transaction_inr: 100, includes: 'UPI outside the super.money app and all non-UPI purchases' }, reason: 'Unlimited 1% cashback on all other eligible spends; spends below ₹100 earn nothing.' }),
    ],
    cap_rules: [C({ id: 'supermoney-app-dependent-cap', cat: 'upi', metric: 'total_reward_points', period: 'statement_cycle', inr: 100, after: 'downgrade_to_base_rate' })],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free (Cashback T&C).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [],
    dynamic_promotions_registry: [],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.axis.bank.in/docs/default-source/default-document-library/credit-cards/axis-bank-supermoney-rupay-credit-card.pdf?sfvrsn=b2de24db_4', kind: 'Cashback T&C, newest file (PDF created 29 Sep 2026), linked from the issuer page under "Cashback structure" and "Lifetime Free Credit Card" (earn rates, cap, exclusions, examples, fuel waiver by UPI or non-UPI)', date: 'PDF created 2026-09-29', read: 'pdftotext' },
        { url: 'https://www.axis.bank.in/docs/default-source/default-document-library/credit-cards/terms-and-conditions-for-axis-bank-supermoney-rupay-credit-card.pdf', kind: 'Cashback T&C, earlier file (PDF created 24 Aug 2026), linked from the issuer page "Terms and Conditions" section whose sentence says "updated w.e.f. 1st January, 2026"', date: 'PDF created 2026-08-24', read: 'pdftotext' },
        { url: 'https://campaign.axis.bank.in/generic/terms-and-conditions-generic-all.pdf', kind: 'Axis revision notice "Effective 28-08-2026" linked from the issuer page banner (DCC markup 3.5%, late fee above ₹50,000, payment allocation, gift card category, no cashback on bridge fees, road fees and tolls)', date: 'PDF created 2026-07-27', read: 'pdftotext' },
        { url: 'https://www.axis.bank.in/cards/credit-card/supermoney-credit-card', kind: 'issuer page: card named "AXIS BANK SUPERMONEY RuPay Credit Card" (network evidence), fees table, links to the three documents above', read: 'rendered page text and link targets' },
        mitcSrc,
      ],
      unverified: [
        'In-force version (checked 2026-11-07, W9): partly settled. The issuer page has three pointers: a banner saying the T&C "will be updated w.e.f 28th August\'26" (links the 28-08-2026 revision notice above), a Terms and Conditions section saying "updated w.e.f. 1st January, 2026" (links the 24 Aug 2026 file), and Cashback structure / Lifetime Free links to a newer file (29 Sep 2026). The two Cashback T&C files are word for word the same on every earn rate, the 3% dependent cap, the ₹100 minimum, the exclusion list and the examples; the only substantive difference is the fuel waiver (see notes). The 24 Aug file already lists Gift Card and "Bridge Fees, Road Fees & Tolls" as exclusions, which is what the 28 Aug notice introduces, so it cannot be a 1 Jan 2026 text. No document anywhere carries the date 1 January 2026, so that sentence on the page is unsupported and was not used. Neither PDF prints a revision date (the dates above are the PDF file-creation dates), so Axis does not state in words which file governs; the newest file (29 Sep 2026, linked from the cashback section) was used for the fuel waiver. A person may still want Axis to confirm the in-force date, but no modelled earn field depends on it.',
        'The MCC numbers behind each exclusion category were not extractable; exclusions are category-level.',
        'Cashback is credited in the next billing cycle, 3 days before the statement date.',
      ],
      notes: [
        'The 3% cap is dynamic: cashback on super.money UPI spends is capped at the larger of ₹100 and the cashback earned on other eligible spends in the same cycle. The T&C examples: other cashback ₹90 gives a ₹100 cap; other cashback ₹300 gives a ₹300 cap. The cap_rules row records only the ₹100 floor, so the engine must not project the 3% rate until the dependent cap is implemented.',
        'Fuel surcharge waiver, ₹400-₹4,000, maximum ₹400 per statement cycle (MITC 8 Oct 2026 lists the card in the refunded group). Newest Cashback T&C (29 Sep 2026): 1% on eligible fuel transactions made using UPI and 0.989% on non-UPI/offline transactions; the 24 Aug 2026 file said 1% with "the waiver calculated and posted is 0.989%" of the fuel amount. waiver_percent keeps 1 (the UPI rate).',
        'Network: RuPay is named in the card name on the issuer page, in both Cashback T&C titles and in the MITC fee table ("SUPERMONEY RuPay Credit Card"). The thumbnail the Axis all-credit-cards listing shows for this card is an unrelated Flipkart Mastercard image file and was not used.',
      ],
    }) },
  },

  // ───────────────────────────────────────────── Kwik
  'axis-bank-kwik': {
    ...common('https://www.axis.bank.in/cards/credit-card/axis-bank-kwik-credit-card', { network: 'rupay', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, form_factors: ['virtual_card'], point_value_inr_baseline: null, point_value_baseline_basis: 'Not stated by Axis for the Kwik card. Checked 2026-11-07: the EDGE REWARDS Terms and Conditions (https://edgerewards.axis.bank.in/lms/terms-and-conditions, undated) give a "Cashback Value per Point / Mile" table that lists only nine cards (REWARDS, IndianOil Premium, Olympus, Horizon, Atlas, Magnus, Magnus for Burgundy, Reserve, Burgundy Private) and an SMS-redemption value grid for four cards; Kwik is named nowhere on that page. The only other rupee figure, INR 0.20 per point in the MITC (8 Oct 2026) negative-balance example, is a general conversion example that says the value "may vary for different card variants", so it is not used. The Kwik page gives no value.' }),
    fees_and_surcharges: axisFees({ fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 4000, monthly_waiver_cap_inr: 150 } }),
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('kwik-excl-wallet', 'wallet_load', [], 'Wallet load earns no EDGE points.'), X('kwik-excl-fuel', 'fuel', [], 'Fuel earns no EDGE points.'), X('kwik-excl-rent', 'rent', [], 'Rental payments earn no EDGE points.'),
      X('kwik-excl-cash', 'cash_withdrawal', [], 'Cash withdrawals earn no EDGE points.'), X('kwik-excl-insurance', 'insurance', [], 'Insurance earns no EDGE points.'), X('kwik-excl-repay', 'excluded_spend', [], 'Repayments and jewellery earn no EDGE points.'),
      X('kwik-excl-education', 'education', [], 'Education earns no EDGE points.'), X('kwik-excl-government', 'government', [], 'Government services earn no EDGE points.'), X('kwik-excl-emi', 'emi', [], 'EMI transactions earn no EDGE points.'),
      X('kwik-excl-cc-upi-small', 'upi', [], 'Credit-card-on-UPI transactions below ₹2,000 earn no EDGE points.', { transaction_amount_lt_inr: 2000, rail: 'credit_card_on_upi' }),
      R({ id: 'kwik-base-2edge', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 2, cond: { per_inr_block: 200 }, reason: '2 EDGE REWARD points on every ₹200 spent on domestic and international transactions (issuer page).' }),
    ],
    cap_rules: [],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Lifetime free: zero joining and annual fees (issuer page, MITC).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [],
    dynamic_promotions_registry: [],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.axis.bank.in/cards/credit-card/axis-bank-kwik-credit-card', kind: 'issuer page (Features and Benefits expanded; page subtitle "KWIK Rupay Credit Card" is the network evidence)', read: 'rendered page text' },
        { url: 'https://edgerewards.axis.bank.in/lms/terms-and-conditions', kind: 'EDGE REWARDS Terms and Conditions (undated; the Kwik page links it as ".../lms/terms-conditions", which returns 404, the page loads at ".../lms/terms-and-conditions"): cashback value per point for nine named cards, Kwik not among them', read: 'rendered page text' },
        { url: 'https://campaign.axis.bank.in/generic/terms-and-conditions-generic-all.pdf', kind: 'Axis revision notice effective 28-08-2026 linked from the Kwik page banner (DCC markup 3.5%, late fee above ₹50,000, payment allocation, gift card category; nothing on Kwik earn)', date: 'PDF created 2026-07-27', read: 'pdftotext' },
        mitcSrc,
      ],
      unverified: [
        'Value of one EDGE REWARD point: NOT stated by Axis for the Kwik card, so point_value_inr_baseline and effective_base_return_percent are null (re-checked 2026-11-07, W9; the earlier 0.20 was dropped). The EDGE REWARDS Terms and Conditions list a rupee value per point for nine other cards only (0.20 for REWARDS, Magnus, Magnus for Burgundy, Reserve and Burgundy Private; 1 for the EDGE Miles cards), the Kwik page gives none, and the MITC INR 0.20 is a general negative-balance example that "may vary for different card variants". To fill it, Axis must state the Kwik rate (customer care 1860 419 5555) or a redemption screen on an issued Kwik card must be read.',
        'Fuel waiver period: the page says "maximum waiver of up to ₹150 per month"; the MITC (8 Oct 2026) says "up to INR 150 for AXIS BANK KWIK Credit Card" inside a clause that is per statement cycle. Modelled as ₹150 per month (page).',
        'Interest: the Kwik page prints "3.7% per month (55.55% per annum)"; the MITC says 3.75% per month i.e. 55.55% per annum (the page figure looks truncated). The MITC rate is used.',
      ],
      notes: [
        'Network: RuPay, stated by the issuer page ("your KWIK Rupay Credit Card", Credit Card on UPI). The listing thumbnail of the card carries no network mark.',
        'RuPay credit card on UPI with an instant virtual card; linked to any UPI app (issuer page).',
        'Fuel surcharge waiver: 1% on ₹400-₹4,000, maximum ₹150 per month. On some fuel transactions the surcharge is ₹10 + GST instead of 1% (issuer page).',
        'Points are credited to the EDGE REWARDS account by 7 working days of the following week.',
        'The page banner says the card terms "will be updated w.e.f 28th August\'26" and links the generic revision notice (read; it changes DCC, late fee above ₹50,000, payment allocation and the gift card category, not Kwik earn). No card-specific T&C PDF is linked; the earn terms are on the page itself, which sends readers to the EDGE REWARDS terms.',
      ],
    }) },
  },

  // ───────────────────────────────────────────── Shoppers Stop Axis
  'axis-bank-shoppers-stop': {
    ...common('https://www.axis.bank.in/cards/credit-card/axis-bank-shoppers-stop-credit-card', { network: 'visa', network_tier: 'visa_platinum', joining_fee_inr: 500, annual_fee_inr: 500, point_value_inr_baseline: 0.5, point_value_baseline_basis: 'Axis product page (read 2026-11-07), Value Chart footnote: "The Redemption Value of Each FC Point = Rs. 0.50". The Value Chart rows agree with it (₹1,50,000 of other spend at 2 FC per ₹200 = 1,500 FC shown as ₹750; ₹50,000 on exclusive brands at 20 FC per ₹200 = 5,000 FC shown as ₹2,500; welcome FC "worth Rs. 300"). The member T&C does not state a per-point value. FC points redeem only at Shoppers Stop, Homestop, Arcelia, MAC, Clinique, Estee Lauder, Bobbi Brown, Jo Malone and Smashbox (T&C 6); Shoppers Stop can change its programme terms.' }),
    fees_and_surcharges: axisFees({ fuel: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 400, max_txn_inr: 5000, monthly_waiver_cap_inr: 400 } }),
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Issuer page (read 2026-11-07): primary cardholder 18-70, resident of India; indicative only. Documents: PAN copy, proof of income (latest payslip, Form 16 or IT return), residence proof (driving licence, electricity bill or landline bill).', rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 200, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: 0.5, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('shoppers-excl-transport', 'excluded_spend', [], 'Transportation, bridge fees, road fees and tolls earn no First Citizen points (T&C 5).'),
      X('shoppers-excl-utilities', 'utility', [], 'Utilities earn no points (T&C 5; the 20 Jun 2025 notice words it "Utility & Telecom").'), X('shoppers-excl-insurance', 'insurance', [], 'Insurance earns no points.'),
      X('shoppers-excl-education', 'education', [], 'Educational institutions earn no points.'), X('shoppers-excl-government', 'government', [], 'Government institutions earn no points.'),
      X('shoppers-excl-wallet', 'wallet', [], 'Wallet earns no points.'), X('shoppers-excl-rent', 'rent', [], 'Rent earns no points.'),
      X('shoppers-excl-fuel', 'fuel', [], 'Fuel earns no points.'), X('shoppers-excl-gift', 'excluded_spend', [], 'Gift cards earn no points.'),
      X('shoppers-excl-cash', 'cash_withdrawal', [], 'Cash advances earn no points (Axis revision notice effective 20 Jun 2025, linked from the issuer page).'),
      X('shoppers-excl-repay', 'excluded_spend', [], 'Repayments earn no points (Axis revision notice effective 20 Jun 2025, linked from the issuer page).'),
      R({ id: 'shoppers-exclusive-brands-20fc', cat: 'all_retail', pri: 5, ppb: 20, mult: 20, channel: 'shoppers_stop_exclusive_brands', cond: { merchant: 'Shoppers Stop Exclusive Brands (in-store, website, app)', per_inr_block: 200, split: '12 points from Shoppers Stop + 8 from Axis Bank', merchant_id_based: true }, reason: '20 First Citizen points per ₹200 on Shoppers Stop Exclusive Brands (T&C 5).' }),
      R({ id: 'shoppers-other-brands-12fc', cat: 'all_retail', pri: 10, ppb: 12, mult: 12, channel: 'shoppers_stop', cond: { merchant: 'Other brands at Shoppers Stop', per_inr_block: 200, split: '4 points from Shoppers Stop + 8 from Axis Bank', merchant_id_based: true }, reason: '12 First Citizen points per ₹200 on other brands at Shoppers Stop (T&C 5).' }),
      R({ id: 'shoppers-base-2fc', cat: 'all_retail', pri: 30, type: 'standard_accrual', ppb: 2, mult: 2, cond: { per_inr_block: 200, excludes: 'spends at Shoppers Stop, Homestop, Arcelia, MAC, Clinique, Estee Lauder, Bobbi Brown, Jo Malone and Smashbox' }, reason: '2 First Citizen points per ₹200 on all other spends (T&C 5 base points).' }),
    ],
    cap_rules: [],
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 100000, period: 'card_anniversary_year', evaluation_condition: 'Annual fee waived at ₹1 lakh spend in the anniversary year; rent and wallet MCCs excluded from the spend (T&C 3; MITC says waived on spends of ₹1,00,000 in the preceding year; the issuer page says "Waived for cumulative spend of Rs. 1 L and above"). The T&C ties the waiver to cardholders issued on or after 1 May 2024 and onboarded through the Axis platform.', excluded_category_ids: ['rent', 'wallet'], excluded_mcc_list: [], waives_fee_inr: 500 },
      welcome_and_renewal_gift: { trigger: 'first_transaction', benefit_points: null, effective_value_inr: 2550, condition: 'First Citizen points worth ₹300 after the first transaction within 30 days of issue (issuer page: points worth ₹300; vouchers worth ₹2,250), plus 3 Shoppers Stop vouchers of ₹500 (each needs a ₹5,000 purchase), 1 voucher of ₹500 (needs ₹2,500 on exclusive brands, apparel) and a Shoppers Stop online voucher saving ₹250 on shoppersstop.com (₹1,500 + ₹500 + ₹250 = ₹2,250), plus a complimentary Golden Glow membership. In-store vouchers expire 2 months after issue and are not valid on shoppersstop.com; welcome benefits are for cardholders issued on or after 1 May 2024 through the Axis platform and not for customers swapped or migrated before 31 Jul 2024 (T&C 4 and Annexure 1).' },
      spend_milestones: [],
    },
    lifestyle_and_network_benefits: [],
    dynamic_promotions_registry: [
      P({ id: 'shoppers-eazydiner-15', cat: 'dining', sponsor: 'EazyDiner (Axis Bank Dining Delights programme)', platform: 'EazyDiner website and app', type: 'instant_discount_percent', pct: 15, max: 500, quota: false, permanent: true }),
    ],
    additional_data: { items: prov({
      sources: [
        { url: 'https://www.axis.bank.in/cards/credit-card/axis-bank-shoppers-stop-credit-card', kind: 'issuer page read 2026-11-07 (Features, Fees & Charges, Value Chart): fees, earn rates, fuel waiver, EazyDiner offer, and the Value Chart footnote "The Redemption Value of Each FC Point = Rs. 0.50"', read: 'rendered page text' },
        { url: 'https://www.axis.bank.in/docs/default-source/default-document-library/credit-cards/terms-and-conditions-for-axis-bank-shoppers-stop-credit-card.pdf', kind: 'Shoppers Stop Axis member T&C (fees, welcome, earn, exclusions)', date: 'PDF created 2026-08-07', read: 'pdftotext' },
        { url: 'https://www.axis.bank.in/docs/default-source/default-document-library/credit-cards/terms-and-conditions-shoppers-stop.pdf', kind: 'Axis revision notice effective 20 Jun 2025 linked from the page "Terms and Conditions" section: excluded spend categories for reward earn (adds cash advances and repayments; utilities worded "Utility & Telecom")', date: 'PDF created 2025-05-30', read: 'pdftotext' },
        { url: 'https://campaign.axis.bank.in/generic/terms-and-conditions-generic-all.pdf', kind: 'Axis revision notice effective 28-08-2026 linked from the page banner (DCC markup, late fee above ₹50,000, payment allocation, gift card category)', date: 'PDF created 2026-07-27', read: 'pdftotext' },
        { url: 'https://www.axis.bank.in/images/default-source/l4-banner/credit-card/shopper-stop-credit-card-desktop-1366x400-v1.webp', kind: 'card art on the issuer page banner (desktop; the tablet and mobile banners are served from the same page): Visa logo with "Platinum" under it', read: 'image opened and read' },
        mitcSrc,
      ],
      unverified: [
        'Network: Visa Platinum, read from the card art on the issuer page banner (Visa logo with "Platinum" under it, Shoppers Stop mark; the banner is the live one on the page, 7 Nov 2026). Second source looked for and not found: the Axis all-credit-cards listing thumbnail for this card carries no network mark; the member T&C only says "Merchant Category Codes (MCC) as allotted by Mastercard & Visa"; the page text and the Axis Citi-migration page do not name a network; Axis\'s Citi-Axis migration FAQ PDF (axisbank.com .../download-faq/faq_credit_card.pdf) was refused with 403 and was not pursued. Card art on the issuer\'s own product page is accepted network evidence, so network is set to Visa with tier Visa Platinum; a person holding an issued card can confirm.',
        'Renewal fee: the MITC row shows ₹500 with a ₹1,00,000 waiver; the T&C bills the annual fee at the first statement date after the anniversary year. Both agree on ₹500.',
        'First Citizen point value is ₹0.50 per the issuer page Value Chart footnote only; the member T&C states no per-point value, and the points are governed by the Shoppers Stop First Citizen programme, which can change its terms.',
        'EazyDiner offer (issuer page): 15% instant discount, maximum ₹500 per month, minimum order ₹2,500. The "terms and conditions" link points to Axis\'s generic Dining Delights T&C (PDF created 30 Jun 2023), so this card\'s offer wording is the page only; whether the offer is limited to a number of uses is not stated.',
        'The page "Terms and Conditions" section still says "updated w.e.f. 20th June 2025" while the banner says the terms "have been updated w.e.f. 28th August \'26"; the member T&C PDF (created 7 Aug 2026) carries no revision date. Fees, earn rates and exclusions in the page, the PDF and the MITC agree, so nothing modelled depends on it.',
        'The T&C notes the First Citizen points are shared between Shoppers Stop and Axis (e.g. 12 + 8), credited at different times.',
      ],
      notes: ['Points have lifetime validity while the card is open and expire 365 days after closure (T&C).', 'Fuel surcharge waiver: 1% for ₹400-₹5,000, maximum ₹400 per statement month (T&C 8; page and MITC agree).', 'Interest 3.75% per month (55.55% a year), forex 3.5%, cash advance 2.5% (minimum ₹500), late fee slabs ₹500 to ₹1,300 (page and MITC).'],
    }) },
  },
};
