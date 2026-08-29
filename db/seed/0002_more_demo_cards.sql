-- Chunk 22 (UA-1.1): 16 more real Indian credit cards, same honesty contract
-- as db/seed/0001_demo_cards.sql's header — structurally accurate (real
-- issuers, real product names, real network/reward-unit/cap shapes) but
-- rates/fees are approximate publicly-known figures for development/demo
-- use, NOT verified against current bank T&C. Every row is `status =
-- 'draft'`; UA-1.1.4's human verification pass (setting verified_at) has
-- not happened for any of these, same as the original 4. This does not
-- attempt full accuracy on every sub-clause of every card's real T&C
-- (e.g. exact merchant exclusion lists, exact spend-category MCC mappings)
-- — it aims for "recognizable real card, plausible real numbers, exercises
-- a wide variety of reward/cap/milestone/forex shapes for the engine and UI
-- to be tested against," same scope as 0001.
--
-- Idempotent: safe to re-run (upserts by slug).

insert into issuers (slug, name, short_name)
values
  ('kotak', 'Kotak Mahindra Bank', 'Kotak'),
  ('yes', 'Yes Bank', 'Yes Bank'),
  ('idfc', 'IDFC FIRST Bank', 'IDFC FIRST'),
  ('indusind', 'IndusInd Bank', 'IndusInd'),
  ('au', 'AU Small Finance Bank', 'AU Bank'),
  ('scb', 'Standard Chartered', 'SC'),
  ('rbl', 'RBL Bank', 'RBL'),
  ('amex', 'American Express', 'Amex'),
  ('slice', 'Slice', 'Slice')
on conflict (slug) do nothing;

-- >>> Card 5: HDFC Regalia Gold — travel/lifestyle, milestone-heavy --------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'hdfc-regalia-gold', 'HDFC Regalia Gold', 'visa', 'credit', 2500, 2500,
       false, 'points_per_150', 4.0, 1.0, 'draft'
from issuers where slug = 'hdfc'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_150', 8.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-regalia-gold' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into milestone_rules (card_product_id, label, period, threshold_spend_inr, reward_description, reward_value_inr, is_repeatable)
select id, 'Quarterly spend milestone — 2,500 bonus points', 'quarter', 150000, '2,500 Reward Points', 625, true
from card_products where slug = 'hdfc-regalia-gold'
  and not exists (select 1 from milestone_rules m where m.card_product_id = card_products.id);

insert into forex_rules (card_product_id, markup_percent, gst_on_markup)
select id, 2.0, true from card_products where slug = 'hdfc-regalia-gold'
  and not exists (select 1 from forex_rules f where f.card_product_id = card_products.id);

-- >>> Card 6: HDFC Swiggy Card — RuPay, high app-linked cashback -----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'hdfc-swiggy', 'HDFC Swiggy Card', 'rupay', 'credit', 500, 500,
       true, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'hdfc'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 10.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-swiggy' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '10% on Swiggy — capped at ₹1,500 cashback/month',
       'reward_value', 'calendar_month', 1500, 'cashback_percent', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'dining'
where cp.slug = 'hdfc-swiggy'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 7: SBI SimplyCLICK — online shopping partners --------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'sbi-simplyclick', 'SBI SimplyCLICK', 'visa', 'credit', 499, 499,
       false, 'points_per_100', 1.0, 0.25, 'draft'
from issuers where slug = 'sbi'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 10.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'sbi-simplyclick' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '10x on partner sites — capped at 15,000 points/cycle',
       'reward_value', 'statement_cycle', 3750, 'points_per_100', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where cp.slug = 'sbi-simplyclick'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 8: SBI Card ELITE — premium, lounge + milestone -----------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'sbi-elite', 'SBI Card ELITE', 'visa', 'credit', 4999, 4999,
       false, 'points_per_100', 2.0, 0.25, 'draft'
from issuers where slug = 'sbi'
on conflict (slug) do nothing;

insert into milestone_rules (card_product_id, label, period, threshold_spend_inr, reward_description, reward_value_inr, is_repeatable)
select id, 'Annual spend milestone — fee waiver + bonus', 'annual', 1000000, 'Annual fee reversal + 10,000 points', 7499, false
from card_products where slug = 'sbi-elite'
  and not exists (select 1 from milestone_rules m where m.card_product_id = card_products.id);

insert into forex_rules (card_product_id, markup_percent, gst_on_markup)
select id, 1.99, true from card_products where slug = 'sbi-elite'
  and not exists (select 1 from forex_rules f where f.card_product_id = card_products.id);

-- >>> Card 9: Axis Flipkart — RuPay, e-commerce cashback --------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'axis-flipkart', 'Axis Flipkart Card', 'rupay', 'credit', 500, 500,
       true, 'cashback_percent', 1.5, 1.0, 'draft'
from issuers where slug = 'axis'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'axis-flipkart' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '5% on Flipkart/Myntra — capped at ₹4,000 cashback/statement',
       'reward_value', 'statement_cycle', 4000, 'cashback_percent', 1.5
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where cp.slug = 'axis-flipkart'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 10: Axis Magnus — super-premium travel, high milestone ----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'axis-magnus', 'Axis Magnus', 'visa', 'credit', 12500, 12500,
       false, 'points_per_200', 12.0, 0.2, 'draft'
from issuers where slug = 'axis'
on conflict (slug) do nothing;

insert into milestone_rules (card_product_id, label, period, threshold_spend_inr, reward_description, reward_value_inr, is_repeatable)
select id, 'Annual spend milestone — 25,000 bonus points', 'annual', 2500000, '25,000 Edge Reward Points', 5000, false
from card_products where slug = 'axis-magnus'
  and not exists (select 1 from milestone_rules m where m.card_product_id = card_products.id);

insert into forex_rules (card_product_id, markup_percent, gst_on_markup)
select id, 2.0, true from card_products where slug = 'axis-magnus'
  and not exists (select 1 from forex_rules f where f.card_product_id = card_products.id);

-- >>> Card 11: ICICI Sapphiro — premium travel/dining -----------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'icici-sapphiro', 'ICICI Sapphiro', 'visa', 'credit', 3500, 3500,
       false, 'points_per_100', 2.0, 0.25, 'draft'
from issuers where slug = 'icici'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 4.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-sapphiro' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into forex_rules (card_product_id, markup_percent, gst_on_markup)
select id, 3.5, true from card_products where slug = 'icici-sapphiro'
  and not exists (select 1 from forex_rules f where f.card_product_id = card_products.id);

-- >>> Card 12: ICICI Coral RuPay — UPI-linkable, entry-level ---------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'icici-coral-rupay', 'ICICI Coral RuPay', 'rupay', 'credit', 0, 500,
       true, 'points_per_100', 1.0, 0.25, 'draft'
from issuers where slug = 'icici'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 2.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-coral-rupay' and sc.slug = 'groceries'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr)
select id, 75000, 'annual', 500 from card_products where slug = 'icici-coral-rupay'
  and not exists (select 1 from fee_waiver_rules f where f.card_product_id = card_products.id);

-- >>> Card 13: Kotak Myntra — RuPay, fashion cashback ----------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'kotak-myntra', 'Kotak Myntra Card', 'rupay', 'credit', 500, 500,
       true, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'kotak'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 7.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'kotak-myntra' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '7% on Myntra — capped at ₹1,000 cashback/month',
       'reward_value', 'calendar_month', 1000, 'cashback_percent', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where cp.slug = 'kotak-myntra'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 14: Yes Bank Paisabazaar PaisaSave — flat cashback, no annual fee -
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'yes-paisasave', 'Yes Bank PaisaSave', 'rupay', 'credit', 0, 0,
       true, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'yes'
on conflict (slug) do nothing;

-- Flat 1% on everything, no category rule needed — base_reward_rate covers
-- it; deliberately no reward_rules row (exercises the "flat/no-cap simple
-- card" shape distinct from every category-heavy card above).

-- >>> Card 15: IDFC FIRST Select — lifetime-free, uncapped points ----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'idfc-first-select', 'IDFC FIRST Select', 'visa', 'credit', 0, 0,
       true, 'points_per_150', 3.0, 0.25, 'draft'
from issuers where slug = 'idfc'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_150', 10.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'idfc-first-select' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- Deliberately uncapped (IDFC FIRST cards are commonly marketed as
-- "lifetime free, no reward cap") — exercises a category-rate card with no
-- cap_rules row at all, distinct from card 14's flat-rate-with-no-rule shape.

-- >>> Card 16: IndusInd Tiger — travel, fuel surcharge waiver --------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'indusind-tiger', 'IndusInd Tiger', 'visa', 'credit', 2999, 2999,
       false, 'points_per_100', 1.5, 0.25, 'draft'
from issuers where slug = 'indusind'
on conflict (slug) do nothing;

insert into fuel_surcharge_rules (card_product_id, surcharge_percent, waiver_percent, min_txn_inr, max_txn_inr)
select id, 1.0, 1.0, 400, 5000 from card_products where slug = 'indusind-tiger'
  and not exists (select 1 from fuel_surcharge_rules f where f.card_product_id = card_products.id);

insert into forex_rules (card_product_id, markup_percent, gst_on_markup)
select id, 1.8, true from card_products where slug = 'indusind-tiger'
  and not exists (select 1 from forex_rules f where f.card_product_id = card_products.id);

-- >>> Card 17: AU LIT — RuPay, fully configurable category ------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'au-lit', 'AU Bank LIT Card', 'rupay', 'credit', 0, 499,
       true, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'au'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'au-lit' and sc.slug = 'entertainment'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '5% on chosen category — capped at ₹1,000 cashback/month',
       'reward_value', 'calendar_month', 1000, 'cashback_percent', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'entertainment'
where cp.slug = 'au-lit'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 18: Standard Chartered EaseMyTrip — travel booking bonus --------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'scb-easemytrip', 'Standard Chartered EaseMyTrip', 'visa', 'credit', 0, 0,
       false, 'cashback_percent', 1.5, 1.0, 'draft'
from issuers where slug = 'scb'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 20.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'scb-easemytrip' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '20% on EaseMyTrip bookings — capped at ₹800 cashback/txn',
       'reward_value', 'lifetime', 800, 'cashback_percent', 1.5
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'travel'
where cp.slug = 'scb-easemytrip'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 19: RBL World Safari — travel, transaction-count cap -----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'rbl-world-safari', 'RBL World Safari', 'mastercard', 'credit', 3000, 3000,
       false, 'points_per_100', 1.0, 0.5, 'draft'
from issuers where slug = 'rbl'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'rbl-world-safari' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- Airport-lounge-style "first 4 bookings" cap, encoded as a txn_count
-- measure — deliberately a different measure shape than the cashback-heavy
-- cards above.
insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, 'Bonus travel rate applies to first 4 bookings/quarter',
       'txn_count', 'quarter', 4, 'points_per_100', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'travel'
where cp.slug = 'rbl-world-safari'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 20: Amex Membership Rewards Credit Card — flat, no UPI ----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'amex-membership-rewards', 'Amex Membership Rewards Credit Card', 'amex', 'credit', 1000, 4500,
       false, 'flat_points', 1.0, 0.25, 'draft'
from issuers where slug = 'amex'
on conflict (slug) do nothing;

-- Deliberately flat_points as the base unit (the one RewardUnit the engine
-- treats as a fixed bonus, not a per-rupee rate — see card_rules.dart's
-- `effectiveRatePerRupee` doc comment) with no category reward_rules at
-- all, exercising the "1 base point per ₹ spent, engine falls through to
-- 0 effective rate for flat_points, no cap" shape.

-- >>> Card 21: HDFC Moneyback+ Credit Card — entry level rewards -----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'hdfc-moneyback-plus', 'HDFC Moneyback+ Credit Card', 'visa', 'credit', 500, 500,
       false, 'points_per_150', 2.0, 0.25, 'draft'
from issuers where slug = 'hdfc'
on conflict (slug) do nothing;

-- >>> Card 22: Kotak League Platinum Card — entry level --------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'kotak-league', 'Kotak League Platinum Card', 'visa', 'credit', 500, 500,
       false, 'points_per_150', 8.0, 0.25, 'draft'
from issuers where slug = 'kotak'
on conflict (slug) do nothing;

-- >>> Card 23: Slice Super Card — prepaid/credit card ----------------------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'slice-super', 'Slice Super Card', 'visa', 'credit', 0, 0,
       false, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'slice'
on conflict (slug) do nothing;

-- >>> Publish gate: verified_at required before status='published' --------
-- Left as 'draft' deliberately (see header comment) — publishing these for
-- real users requires the actual UA-1.1.4 human verification pass, exactly
-- as noted in 0001_demo_cards.sql.
