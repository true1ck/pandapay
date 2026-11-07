// Co-brand cards: Eternal SBI Card, BOBCARD Scapia, YES BANK POP-CLUB. Sources read 2026-11-07.
//  Eternal: SBI Card page (browser), "Eternal SBI Card T&C Booklet" (51 pages) and "Preferred Partners" one-pager (pdftotext)
//  BOB Scapia: BOBCARD Scapia KFS, General T&C (37 pages), MITC (pdftotext); product page (browser)
//  YES POP-CLUB: issuer page (footnotes now read), MITC CMITC_V18_05102026 and KFS V_20_28092026 (re-read 2026-11-07, W2); shared YES fee helpers live in ./yes.mjs
import { R, X, C, B, P, prov, dualNetwork, GST } from '../lib.mjs';
import { yesFees, yesStatement, lateFee as yesLateFee, otherFees as yesOtherFees, exclusionAfter, GOV_MCC, MKT_MCC, EDU_MCC, MITC as YES_MITC, MITC_DATE as YES_MITC_DATE, KFS as YES_KFS, KFS_DATE as YES_KFS_DATE, LISTING as YES_LISTING } from './yes.mjs';

const ETERNAL_BOOKLET = 'https://www.sbicard.com/sbi-card-en/assets/docs/pdf/eternal-sbi-card/Eternal-SBI-Card-T-and-C-Booklet.pdf';
const ETERNAL_PARTNERS = 'https://www.sbicard.com/sbi-card-en/assets/docs/pdf/eternal-sbi-card/Eternal-Card-Cashback-Preferred-Partners.pdf';
const BOB_KFS = 'https://media.bobcard.co.in//media/gj3mfwnu/bobcard-scapia-kfs-1.pdf';
const BOB_TC = 'https://media.bobcard.co.in//media/atehw542/bobcard-scapia-tc.pdf';
const BOB_MITC = 'https://media.bobcard.co.in//media/wldj0y5t/bobcard-scapia-mitc-1.pdf';

export const cards = {
  // ───────────────────────────────────────────── Eternal SBI Card
  'eternal-sbi-card': {
    card_product: { ...GST, card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: 499, annual_fee_inr: 499, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.sbicard.com/en/personal/credit-cards/eternal-sbi-card.html', status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'Cashback card: discounts and statement credit, no points.' },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: null, rules: [], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 'N/A', base_cashback_percent: 1, effective_base_return_percent: 1, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('eternal-excl-fuel', 'fuel', [], 'No cashback on fuel spends (Eternal FAQ, cashback Q8).'),
      R({ id: 'eternal-10pct-zomato-district-blinkit', cat: 'dining', pri: 5, cb: 10, mult: 1, channel: 'partner_instant_discount', cap: 'eternal-instant-discount-cap', cond: { merchants: ['Zomato', 'District', 'Blinkit (Beauty and Electronics categories)'], reward_type: 'instant_discount', minimum_transaction_inr: 100 }, reason: '10% instant discount (not statement cashback) on Zomato, District and Blinkit Beauty and Electronics, within one shared ₹2,000 monthly cap.' }),
      R({ id: 'eternal-5pct-blinkit-other', cat: 'groceries', pri: 6, cb: 5, mult: 1, channel: 'partner_instant_discount', cap: 'eternal-instant-discount-cap', cond: { merchants: ['Blinkit (all other categories)'], reward_type: 'instant_discount', minimum_transaction_inr: 100 }, reason: '5% instant discount on Blinkit in all other categories, counted in the same ₹2,000 monthly cap.' }),
      R({ id: 'eternal-5pct-preferred-partners', cat: 'all_retail', pri: 7, cb: 5, mult: 1, channel: 'preferred_partner', cap: 'eternal-preferred-partner-cap', cond: { merchants: ['Uber', 'Urban Company', 'Apollo'], minimum_transaction_inr: 100, merchant_id_based: true }, reason: 'Up to 5% cashback on Uber, Urban Company and Apollo; credit depends on merchant IDs the partner supplies to SBI Card.' }),
      R({ id: 'eternal-ixigo', cat: 'travel', pri: 8, cb: 5, mult: 1, channel: 'ixigo', cap: 'eternal-preferred-partner-cap', cond: { merchants: ['ixigo'], coupon_code: 'IXIGOSBI', split: '4% instant discount on flight and hotel booking + 1% statement-credit cashback', minimum_transaction_inr: 100 }, reason: 'ixigo: 4% instant discount with coupon IXIGOSBI plus 1% as statement credit. Inside the preferred-partner cap.' }),
      R({ id: 'eternal-upi-1pct', cat: 'upi', rail: 'upi_qr', pri: 20, cb: 1, mult: 1, cond: { variant: 'RuPay', minimum_transaction_inr: 100 }, reason: 'RuPay credit card on UPI: 1% cashback on all eligible spends.' }),
      R({ id: 'eternal-base-1pct', cat: 'all_retail', pri: 30, type: 'standard_accrual', cb: 1, mult: 1, cond: { minimum_transaction_inr: 100 }, reason: '1% cashback on all other eligible spends (issuer page); no card cashback below ₹100 (Preferred Partners document).' }),
    ],
    cap_rules: [
      C({ id: 'eternal-instant-discount-cap', cat: 'dining', metric: 'total_reward_points', period: 'calendar_month', inr: 2000, after: 'downgrade_to_base_rate' }),
      C({ id: 'eternal-preferred-partner-cap', cat: 'all_retail', metric: 'total_reward_points', period: 'statement_cycle', inr: 1000, after: 'downgrade_to_base_rate' }),
    ],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 3.5, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: 3.5, gst_applicable: true, trigger_condition: 'On transactions of ₹1,000 or more made in Indian currency at an international location or at merchants in India registered overseas (SBI Card MITC, Other Charges)' },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: 500, max_txn_inr: 4000, monthly_waiver_cap_inr: 200 },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: null },
      banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 600, gst_applicable: true }, auto_debit_bounce_charge_inr: null, cheque_bounce_charge_inr: null },
    },
    statement_and_late_fees: {
      late_payment_slabs: [
        { min_balance_inr: 0, max_balance_inr: 100, fee_inr: 0 }, { min_balance_inr: 101, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 500 },
        { min_balance_inr: 1001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 950 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
      ],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 200000, period: 'card_anniversary_year', evaluation_condition: 'Renewal fee reversed on annual spends of ₹2,00,000 (issuer page). Annual fee ₹499 + GST; renewal ₹499 + GST from the second year.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 499 },
      welcome_and_renewal_gift: { trigger: 'card_activation', benefit_points: 'N/A', effective_value_inr: null, condition: 'Complimentary Zomato Gold membership for 6 months on card activation.' },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: 0, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: 'eternal-district-bogo', cat: 'movie', sponsor: 'District', label: 'Buy 1 Get 1 movie ticket on the District app, up to ₹200 off the second ticket', cond: { platform: 'District app', tickets_per_transaction: 2 }, qty: 1, per: 'calendar_month' }),
    ],
    additional_data: { items: [
      dualNetwork({
        sourceUrl: ETERNAL_BOOKLET,
        evidence: 'Eternal T&C booklet FAQ 1: "co-branded credit card issued by SBI Card, available on both Mastercard and RuPay networks."',
        variants: [
          { network: 'mastercard', network_tier: 'N/A', label: 'Eternal SBI Card (Mastercard)', source_url: ETERNAL_BOOKLET, evidence: 'FAQ 1: available on both Mastercard and RuPay networks.' },
          { network: 'rupay', network_tier: 'N/A', label: 'Eternal SBI Card (RuPay)', source_url: ETERNAL_BOOKLET, evidence: 'Cashback Q13: RuPay credit card transactions on UPI earn 1% cashback on eligible spends.' },
        ],
      }),
      ...prov({
        sources: [
          { url: 'https://www.sbicard.com/en/personal/credit-cards/eternal-sbi-card.html', kind: 'issuer page', read: 'rendered page text' },
          { url: ETERNAL_BOOKLET, kind: 'Eternal SBI Card T&C booklet (FAQ, cashback tiers, caps, movie offer)', read: 'pdftotext' },
          { url: ETERNAL_PARTNERS, kind: 'Preferred Partners one-pager', read: 'pdftotext' },
          { url: 'https://www.sbicard.com/sbi-card-en/assets/docs/pdf/kfs/key-fact-statement.pdf', kind: 'SBI Card Key Fact Statement, 9 pages, file title "SBI Card_Key fact Statement for 14OCT2026" (annual and renewal fee row for Eternal SBI Card; finance charges; late payment slabs; forex)', date: '2026-10-14', read: 'pdftotext and page images' },
          { url: 'https://www.sbicard.com/sbi-card-en/assets/docs/pdf/most-important-terms-and-conditions/mitc-english.pdf', kind: 'SBI Cards Most Important Terms & Conditions, common to all cards, 60 pages, file title "MITC- Common-30OCT26" (finance charges, foreign currency fee, DCC fee, other charges)', date: '2026-10-30', read: 'pdftotext' },
        ],
        unverified: [
          'Preferred-partner cap period: the FAQ says "₹1,000 per month" and the Preferred Partners document says "in a statement cycle". Modelled as statement_cycle.',
          'The 1% base cashback figure is from the issuer page; the booklet FAQ says only "base cashback". The excluded MCC list for base cashback is not in the common SBI MITC.',
          'Interest 3.75% a month (45% a year) and forex 3.5% are SBI Card general rates: the KFS says 3.75% a month for unsecured cards, and the common MITC and KFS give 3.5% foreign currency fee for all cards except a named list (AURUM, Elite, Prime NRI secured, Tata Neu Infinity, SBI Card Miles variants) that does not include Eternal. Neither document names Eternal for these two charges, so they apply by exclusion; confirm with SBI Card that no Eternal-specific rate exists. The common MITC says "up to 3.75% per month" and that SBI Card can change it.',
          'Annual fee waiver conflict: the SBI Card KFS dated 14 Oct 2026 shows "Eternal SBI Card 499 / 499 (Waived off on annual spends of Rs. 1 Lakh or more in the preceding year)", while the Eternal issuer page (badge, Fees tab and FAQ) says the renewal fee is reversed on annual spends of ₹2,00,000. The draft keeps ₹2,00,000 (issuer product page); a person must confirm which is in force.',
          'Fee on fuel transactions (1% of total fuel spend when it exceeds ₹50,000 in a billing cycle) and on transportation (1% over ₹30,000 per transaction) apply from 1 Dec 2026 in the common MITC; not modelled. Rent processing fee ₹199, utility 1% over ₹50,000 a cycle, education 1% via third-party apps and wallet load 1% over ₹1,000 are also in the common MITC and not modelled.',
          'Neither the Eternal T&C booklet nor the Preferred Partners one-pager carries a revision date.',
          'The page says fuel surcharge waiver applies to transactions ₹500-₹4,000; the page text and the earlier note differ on ₹400 versus ₹500, the page figure is used.',
        ],
        notes: [
          'The 10% and 5% on Zomato, District and Blinkit are INSTANT DISCOUNTS at checkout, not statement cashback; the 5% on Uber, Urban Company and Apollo is statement cashback.',
          'Cashback does not expire; it is adjusted automatically in the next statement. Cashback earned on this card expires if the card is flipped to another co-brand card.',
          'Fuel surcharge waiver up to ₹200 per statement cycle per card account.',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── BOBCARD Scapia
  'bobcard-scapia-credit-card': {
    card_product: { ...GST, card_type: 'credit', network: null, application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 0, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.bobcard.co.in/credit-card-types/bobcard-scapia-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: 0.2, point_value_baseline_basis: 'BOBCARD Scapia T&C: 5 Scapia Coins = ₹1 for flights, hotels, buses and other services on the Scapia app; value can change on one month\'s notice. Coins last 36 months and are nullified if the card is unused for more than 365 days.', point_expiry_months: 36 },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Product page: Indian resident, age 21-60, salaried or self-employed; PAN mandatory; Aadhaar-based digital verification. Indicative.', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] }, { parameter: 'age_years', operator: '<=', threshold_value: 60, allowed_values: [] }, { parameter: 'residency', operator: 'in', threshold_value: null, allowed_values: ['resident_indian'] }], required_documents: ['PAN'] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 10, base_cashback_percent: 'N/A', effective_base_return_percent: 2, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('bobscapia-excl-transfer', 'excluded_spend', [], 'Money transfers, gift cards, card repayments and crypto earn nothing (T&C Earn Rewards b).'),
      X('bobscapia-excl-rent', 'rent', [], 'Rent earns nothing.'), X('bobscapia-excl-cash', 'cash_withdrawal', [], 'Cash withdrawals earn nothing.'), X('bobscapia-excl-emi', 'emi', [], 'EMI transactions earn nothing.'),
      X('bobscapia-excl-education', 'education', [], 'Education and school fees earn nothing.'), X('bobscapia-excl-utility', 'utility', [], 'Utility payments earn nothing.'), X('bobscapia-excl-insurance', 'insurance', [], 'Insurance earns nothing.'),
      X('bobscapia-excl-fuel', 'fuel', [], 'Fuel and fuel surcharge earn nothing.'), X('bobscapia-excl-wallet', 'wallet_load', [], 'Digital wallet loading and top-up earn nothing.'), X('bobscapia-excl-forex', 'international_spend', [], 'Forex transactions earn nothing (T&C Earn Rewards b).'),
      R({ id: 'bobscapia-travel-20pct', cat: 'travel', pri: 5, ppb: 20, mult: 20, channel: 'scapia_app', cond: { platform: 'Scapia app', purchases: 'travel' }, reason: '20% rewards on travel purchases made on the Scapia app (T&C f). At 5 coins = ₹1 that is 4% in value.' }),
      R({ id: 'bobscapia-visa-10pct', cat: 'all_retail', pri: 20, type: 'standard_accrual', ppb: 10, mult: 10, cond: { variant: 'Visa', minimum_transaction_inr: 20 }, reason: '10% rewards on every purchase of ₹20 and above on the Visa card, in all eligible categories (T&C e). 1 reward = 1 Scapia Coin, so about 2% in value.' }),
      R({ id: 'bobscapia-rupay-5pct', cat: 'all_retail', pri: 21, type: 'standard_accrual', ppb: 5, mult: 5, cond: { variant: 'RuPay', minimum_transaction_inr: 500 }, reason: '5% rewards on eligible spends above ₹500 on the RuPay card (T&C e). About 1% in value.' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      apr: { monthly_interest_rate_percent: 3.75, annual_interest_rate_percent: 45 },
      forex_markup: { markup_percent: 0, gst_applicable: true },
      dynamic_currency_conversion_dcc: { fee_percent: null, gst_applicable: null, trigger_condition: null },
      fuel_surcharge: { category_id: 'fuel', surcharge_percent: 1, waiver_percent: 1, min_txn_inr: null, max_txn_inr: 5000, monthly_waiver_cap_inr: 500 },
      cash_advance: { atm_transaction_fee_percent: 2.5, atm_transaction_fee_min_inr: 500, interest_applicable_from_day_one: true, daily_interest_percent: null, max_limit_percent: 10 },
      category_surcharges: [
        { category_id: 'fuel', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: 'Fuel spends above ₹50,000 in a month attract a 1% + GST convenience fee, capped at ₹3,000 per transaction', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
        { category_id: 'utility', mcc_list: [], fee_percent: 1, gst_applicable: true, trigger_condition: 'Utility transactions above ₹50,000 in a month attract 1% + GST, capped at ₹3,000 per transaction', threshold_spend_inr: 50000, effective_from: null, effective_to: null },
        { category_id: 'rent', mcc_list: [6513], fee_percent: 1, gst_applicable: true, trigger_condition: 'Rent spends attract 1% + GST, capped at ₹3,000 per transaction', threshold_spend_inr: null, effective_from: null, effective_to: null },
        { category_id: 'wallet_load', mcc_list: [6540], fee_percent: 1, gst_applicable: true, trigger_condition: 'Wallet load attracts 1% + GST, capped at ₹3,000 per transaction', threshold_spend_inr: null, effective_from: null, effective_to: null },
      ],
      emi_charges: { merchant_instant_emi_processing_fee_inr: null, post_purchase_emi_processing_fee_inr: 99, foreclosure_charge_percent: null, gst_applicable: true },
      banking_penalties: { overlimit_charge: { fee_percent: 2.5, min_fee_inr: 500, gst_applicable: null }, auto_debit_bounce_charge_inr: 450, cheque_bounce_charge_inr: null },
    },
    statement_and_late_fees: {
      grace_period_days: 50,
      grace_period_void_on_revolving_balance: null,
      minimum_amount_due_mad: { calculation_mode: 'fixed_percent', components: ['2% of retail spends and cash advance', '100% of all fees, finance charges, GST and EMI'] },
      late_payment_slabs: [
        { min_balance_inr: 0, max_balance_inr: 99, fee_inr: 0 }, { min_balance_inr: 100, max_balance_inr: 500, fee_inr: 100 }, { min_balance_inr: 501, max_balance_inr: 1000, fee_inr: 400 },
        { min_balance_inr: 1001, max_balance_inr: 10000, fee_inr: 750 }, { min_balance_inr: 10001, max_balance_inr: 25000, fee_inr: 950 }, { min_balance_inr: 25001, max_balance_inr: 50000, fee_inr: 1100 }, { min_balance_inr: 50001, max_balance_inr: null, fee_inr: 1300 },
      ],
    },
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 'N/A', period: 'N/A', evaluation_condition: 'Joining and annual fees are nil (KFS).', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 'N/A' },
      welcome_and_renewal_gift: { trigger: null, benefit_points: null, effective_value_inr: null, condition: null },
      spend_milestones: [],
    },
    addon_card_rules: { max_addon_cards: 0, fee_per_card_inr: 'N/A', separate_priority_pass: 'N/A', lounge_quota_shared: 'N/A', reward_points_pooled: 'N/A', min_age_years: null },
    lifestyle_and_network_benefits: [
      B({ id: 'bobscapia-domestic-lounge', cat: 'lounge', sponsor: 'BOBCARD / Scapia', label: 'Unlimited complimentary domestic lounge access', cond: { min_spend_inr_per_billing_cycle: 20000, must_be_active_monthly: true, enabled_after_billing_date_working_days: '3-5' }, qty: null, per: 'N/A' }),
      B({ id: 'bobscapia-airport-privilege', cat: 'other', sponsor: 'BOBCARD / Scapia', label: 'Scapia Coins equal to spend at eligible airport eat and shop outlets', cond: { max_coins_top_6_cities: 5000, max_coins_other_cities: 2500 } }),
    ],
    redemption_matrix: { direct_options: [{ channel: 'Scapia app: flights, hotels, buses and other services', redemption_type: 'flight_hotel_booking', inr_value_per_point: 0.2, max_bill_percentage_payable_via_points: 100, min_points_per_txn: 'N/A', cycle_points_burn_cap: 'N/A', redemption_fee_inr: 'N/A', effective_from: null, effective_to: null }], partner_transfers: [] },
    additional_data: { items: [
      dualNetwork({
        sourceUrl: BOB_TC,
        evidence: 'BOBCARD Scapia T&C Earn Rewards (e) describes a Visa card and a RuPay card with different earn rates.',
        variants: [
          { network: 'visa', network_tier: 'N/A', label: 'BOBCARD Scapia Credit Card (Visa)', source_url: BOB_TC, evidence: 'T&C e: 10% rewards on purchases of ₹20 and above.' },
          { network: 'rupay', network_tier: 'N/A', label: 'BOBCARD Scapia Credit Card (RuPay)', source_url: BOB_TC, evidence: 'T&C e: 5% rewards on eligible spends above ₹500.' },
        ],
      }),
      ...prov({
        sources: [
          { url: BOB_KFS, kind: 'BOBCARD Scapia Key Fact Sheet (fees, interest, late fee, fuel, convenience fees)', read: 'pdftotext' },
          { url: BOB_TC, kind: 'General Terms and Conditions, 37 pages (rewards, coin value, lounge, forex)', read: 'pdftotext' },
          { url: BOB_MITC, kind: 'MITC', read: 'extracted, not read in detail' },
          { url: 'https://www.bobcard.co.in/credit-card-types/bobcard-scapia-credit-card', kind: 'issuer page', read: 'rendered page text' },
        ],
        unverified: [
          'None of the three PDFs carries a revision date in the extracted text.',
          'The MITC was extracted but not read line by line; fees were taken from the KFS and the T&C.',
          'The "above ₹500" RuPay threshold is stated as "more than Rs. 500" in the T&C and "minimum Rs. 500" on the product page.',
          'EMI is listed as coming soon in the KFS; the EMI processing fee is shown as stated.',
        ],
        notes: [
          'The headline "10% / 5% / 20% rewards" are Scapia-coin percentages. At 5 coins = ₹1, the real value is about 2% (Visa), 1% (RuPay) and 4% on Scapia-app travel.',
          'Zero forex mark-up (T&C Benefits 2).',
          'Fuel surcharge waiver for transactions up to ₹5,000, maximum ₹500 per month (KFS).',
          'Card re-issue/replacement fee ₹200 + GST (KFS).',
        ],
      }),
    ] },
  },

  // ───────────────────────────────────────────── YES BANK POP-CLUB
  'yes-bank-pop-club-rupay': {
    card_product: { ...GST, card_type: 'credit', network: 'rupay', application_mode: 'open', joining_fee_inr: 0, annual_fee_inr: 399, is_upi_linkable: true, data_source_tier: 'issuer_mitc_plus_manual_audit', source_url: 'https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards/pop-club-credit-card', status: 'draft', verified_at: null, point_value_inr_baseline: null, point_value_baseline_basis: 'No YES BANK page or document states the rupee value of a POPcoin. The partner (POPtech) home page says "1 POPcoin = ₹1" but its Terms (mypop.in/tnc) say coins are redeemed as a discount up to a maximum per purchase set by the company, or converted to cashback "at a rate the Company sets". The earlier partner-app read (₹0.10 per coin on cash conversion) conflicts. Left null.', point_expiry_months: 12 },
    eligibility_engine: { evaluation_mode: 'guideline_only', notes: 'Apply through the partner (Pop Club) website or app; the partner may charge a platform fee. Page: age 21 to 60, salaried or self-employed, minimum net salary ₹25,000 a month or ITR of ₹7.5 lakh; existing YES BANK credit cardholders are not eligible.', rules: [{ parameter: 'age_years', operator: '>=', threshold_value: 21, allowed_values: [] }, { parameter: 'age_years', operator: '<=', threshold_value: 60, allowed_values: [] }, { parameter: 'net_monthly_salary_inr_or_itr_inr', operator: '>=', threshold_value: 25000, allowed_values: [] }, { parameter: 'employment_type', operator: 'in', threshold_value: null, allowed_values: ['salaried', 'self_employed'] }], required_documents: [] },
    accrual_engine: { base_block_inr: 100, rounding_mode: null, base_points_per_block: 2, base_cashback_percent: 'N/A', effective_base_return_percent: null, cycle_accrual_ceiling_points: null, capping_period_basis: null },
    reward_rules: [
      X('popclub-excl-fuel', 'fuel', [5542, 5983, 5172, 5540], 'No POPcoins on fuel (page T&C asterisk note).'),
      X('popclub-excl-rent', 'rent', [6513], 'No POPcoins on rent; at most 5 rental transactions in every 30 days (page T&C).'),
      X('popclub-excl-wallet', 'wallet', [6540], 'No POPcoins on wallet loads (page T&C).'),
      X('popclub-excl-government', 'government', GOV_MCC, 'No POPcoins on government services (page T&C).'),
      X('popclub-excl-marketing', 'other', MKT_MCC, 'No POPcoins on marketing / advertising categories (page T&C).'),
      X('popclub-excl-cash', 'other', [6011], 'No POPcoins on ATM withdrawals / cash advance (page T&C).'),
      X('popclub-excl-utility', 'bills', [4900], 'No POPcoins on utility payments (page T&C).'),
      X('popclub-excl-insurance', 'insurance', [6300], 'No POPcoins on insurance premiums (page T&C).'),
      X('popclub-excl-poi', 'other', [6538], 'No POPcoins on POI funding transactions (page T&C).'),
      X('popclub-excl-emi', 'emi', [], 'No POPcoins on transactions converted into EMI (page T&C).'),
      exclusionAfter('popclub-excl-education', 'education', EDU_MCC, 'From 1 Jun 2026: no POPcoins on education transactions (page T&C).', '2026-06-01'),
      R({ id: 'popclub-online-10', cat: 'online', rail: 'online', pri: 10, type: 'standard_accrual', ppb: 10, mult: 10, cond: { minimum_transaction_inr: 100, per_inr_block: 100, personal_spends_only: true }, reason: 'Page: earn 10 POPcoins on every ₹100 spent on e-commerce / online transactions. Minimum transaction ₹100. Personal spends only.' }),
      R({ id: 'popclub-other-2', cat: 'all_retail', rail: 'any', pri: 30, type: 'standard_accrual', ppb: 2, mult: 2, cond: { minimum_transaction_inr: 100, not_online: true, per_inr_block: 100 }, reason: 'FAQ: earn 2 POPcoins on every ₹100 spent on all other transactions. Minimum transaction ₹100.' }),
    ],
    cap_rules: [],
    fees_and_surcharges: {
      ...yesFees({ forex: 3.5, fuelMin: 1000, fuelMax: 3500, fuelCap: 100, fuelThreshold: 25000, utilityThreshold: 25000, tollThreshold: 50000 }),
      reward_redemption_fee: { fee_inr: null, gst_applicable: null, exempted_channels: [], notes: 'The ₹100 + GST redemption fee in the YES MITC is for YES Rewardz points. POPcoins are the partner currency redeemed on the partner platform; no redemption fee is stated for them.' },
    },
    statement_and_late_fees: yesStatement,
    fee_waiver_and_milestones: {
      annual_fee_waiver: { threshold_spend_inr: 150000, period: 'card_anniversary_year', evaluation_condition: 'Zero joining fee. Annual membership fee ₹399 + taxes is charged if the spend condition is not met; spending ₹1.5 lakh in the card anniversary year waives it (page T&C 2, MITC fee table, KFS). Cards issued under the "Lifetime Free" offer are exempt from the annual fee (page); the page calls lifetime free a limited-time offer and the cohort for a new applicant is not stated.', excluded_category_ids: [], excluded_mcc_list: [], waives_fee_inr: 399 },
      welcome_and_renewal_gift: { trigger: 'annual_fee_payment', benefit_points: 400, effective_value_inr: null, condition: 'On payment of the ₹399 annual fee, 400 POPcoins are credited (page T&C 2). Rupee value of a POPcoin is not stated by YES BANK.' },
      spend_milestones: [
        { id: 'popclub-1-5l', label: '1,500 extra POPcoins on crossing ₹1.5 lakh spend in the card anniversary year (also waives the annual fee; lifetime-free cards get the POPcoins too)', threshold_spend_inr: 150000, reward_value_inr: null, period: 'card_anniversary_year', is_repeatable: null, effective_from: null, effective_to: null },
      ],
    },
    addon_card_rules: { max_addon_cards: null, fee_per_card_inr: null, separate_priority_pass: null, lounge_quota_shared: null, reward_points_pooled: null, min_age_years: null },
    lifestyle_and_network_benefits: [],
    additional_data: { items: [
      ...prov({
        sources: [
          { url: 'https://www.yes.bank.in/personal-banking/yes-individual/cards/credit-cards/pop-club-credit-card', kind: 'issuer page incl. FAQ and T&C footnotes (rendered page text; footnotes captured on the 7 Nov 2026 re-read)', read: 'browser' },
          { url: YES_MITC, kind: `YES BANK Credit Card MITC, ${YES_MITC_DATE}: fee table, interest, forex, fuel waiver, late fee`, read: 'pdf.js text, opened from the site link' },
          { url: YES_KFS, kind: `Key Fact Statement - Credit Cards, ${YES_KFS_DATE}: fee table, waiver spend, forex, fuel waiver`, read: 'pdf.js text' },
          { url: 'https://www.yes.bank.in/pdf?name=ybagreement_credit_cardmember.pdf', kind: 'Credit Card Cardmember Agreement, header V08_28072026 (28 Jul 2026): generic legal terms; no POP-CLUB rates or POPcoin terms in it', read: 'pdf.js text' },
          { url: 'https://mypop.in/', kind: 'Partner (POPtech) home page linked from the YES page "What is POPcoins? Click here": states 1 POPcoin = ₹1 (marketing line, not a YES document)', read: 'browser' },
          { url: 'https://mypop.in/tnc', kind: 'Partner Terms and Conditions (undated): coin redemption as a capped discount, cashback conversion at a company-set rate', read: 'browser' },
        ],
        unverified: [
          'POPcoin rupee value: still not stated in any YES BANK page or document. The partner home page says 1 POPcoin = ₹1 but the partner Terms say coins redeem as a discount up to a per-purchase maximum or convert to cashback at a rate the company sets, and an earlier partner-app read gave 10 coins per ₹1 for cash conversion. point_value_inr_baseline stays null until a person decides which, if any, to rely on.',
          'Fee cohort: the page calls "Lifetime Free" a limited-time offer. A new applicant may get a lifetime-free card (no renewal fee) or the ₹399 card; the page does not say which cohort is open. annual_fee_inr 399 is the standard fee (page, MITC, KFS).',
          'Fuel surcharge waiver cap: the page footnote and the MITC/KFS bullet say ₹100 per statement cycle on ₹1,000 to ₹3,500 from 1 Jun 2026, but the MITC and KFS cap tables still list "POP-CLUB INR 300" (the pre-1-Jun figure). ₹100 is stored.',
          'Whether the card is physical or virtual is not stated; the cash-advance fee (2.5% or ₹650, MITC) is written for a physical card.',
          'The 1,500-POPcoin milestone is described per "anniversary year"; the page does not say whether it repeats each year, so is_repeatable is null. Whether the 400 POPcoins on paying the annual fee repeats on every renewal is also not stated.',
          'POPcoin exclusions on the page are listed by MCC and are "not exhaustive and only indicative"; the education exclusion starts 1 Jun 2026.',
        ],
        notes: [
          'FIXED: annual fee ₹399 is now confirmed by the page, the MITC fee table (POP-CLUB: joining NIL, annual ₹399, waiver on ₹1,50,000 spend) and the KFS.',
          'FIXED: forex mark-up 3.50% from 15 Jun 2026 (3.40% before) and DCC 1% (MITC 3(q), KFS); interest 3.99% a month / 47.88% a year (MITC, KFS, page).',
          'FIXED: fuel surcharge waiver footnote found: valid on ₹1,000 to ₹3,500 and ₹100 per statement cycle from 1 Jun 2026; before that ₹400 to ₹5,000 and ₹300.',
          'POPcoins are credited after the monthly statement and expire 365 days after credit (FAQ). Minimum transaction ₹100. POPcoins are awarded on personal spends only; at most 5 rental transactions are allowed in every 30 days.',
          'Credit on UPI with RuPay (page). The MITC lists POP-CLUB with Anq Phi and Paisabazaar Paisasave for forex and in the fuel-cap tables.',
        ],
      }),
      yesLateFee, yesOtherFees,
    ] },
  },
};
