-- Seed data: a handful of real Indian credit cards, structurally accurate
-- (real issuers, real product names, real reward mechanics: cap types,
-- RuPay/UPI linkability, milestone/fee-waiver shapes) but reward rates are
-- approximate publicly-known figures for development/demo use, NOT verified
-- against current bank T&C. UA-1.1.4 (human verification, sets verified_at)
-- has NOT been done on any of these — every row here is `status = 'draft'`
-- until that verification pass happens for real. This is what makes UA-2
-- (the recommendation engine) and UA-3 (Home screen) testable against
-- realistic data shapes instead of only synthetic test fixtures.
--
-- Idempotent: safe to re-run (upserts by slug).

-- >>> Issuers ------------------------------------------------------------
insert into issuers (slug, name, short_name)
values
  ('hdfc', 'HDFC Bank', 'HDFC'),
  ('sbi', 'State Bank of India', 'SBI'),
  ('axis', 'Axis Bank', 'Axis'),
  ('icici', 'ICICI Bank', 'ICICI')
on conflict (slug) do nothing;

-- >>> Card 1: HDFC Millennia — cashback, capped, high online rate ---------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'hdfc-millennia', 'HDFC Millennia', 'visa', 'credit', 1000, 1000,
       false, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'hdfc'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-millennia' and sc.slug = 'online'
  and not exists (
    select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id
  );

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '5% online spends — capped at ₹1,000 cashback/cycle',
       'reward_value', 'statement_cycle', 1000, 'cashback_percent', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where cp.slug = 'hdfc-millennia'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

insert into fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr)
select id, 100000, 'annual', 1000 from card_products where slug = 'hdfc-millennia'
  and not exists (select 1 from fee_waiver_rules f where f.card_product_id = card_products.id);

-- >>> Card 2: SBI Cashback Card — high uncapped online cashback -----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'sbi-cashback', 'SBI Cashback Card', 'mastercard', 'credit', 999, 999,
       false, 'cashback_percent', 1.0, 1.0, 'draft'
from issuers where slug = 'sbi'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'sbi-cashback' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '5% online spends — capped at ₹5,000 cashback/month',
       'reward_value', 'calendar_month', 5000, 'cashback_percent', 1.0
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where cp.slug = 'sbi-cashback'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 3: Axis Ace — RuPay, UPI-linkable, flat bill-pay rate ----------
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'axis-ace', 'Axis Ace', 'rupay', 'credit', 499, 499,
       true, 'cashback_percent', 1.5, 1.0, 'draft'
from issuers where slug = 'axis'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'axis-ace' and sc.slug = 'bills'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 2.0, 20
from card_products cp, spend_categories sc
where cp.slug = 'axis-ace' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into cap_rules (card_product_id, reward_rule_id, category_id, label, measure, period, cap_value, post_cap_unit, post_cap_rate)
select cp.id, rr.id, sc.id, '5% bill payments — capped at ₹500 cashback/month',
       'reward_value', 'calendar_month', 500, 'cashback_percent', 1.5
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'bills'
where cp.slug = 'axis-ace'
  and not exists (select 1 from cap_rules c where c.reward_rule_id = rr.id);

-- >>> Card 4: ICICI Amazon Pay — points/₹100, travel forex, milestone ----
insert into card_products (
  issuer_id, slug, name, network, card_type, joining_fee_inr, annual_fee_inr,
  is_upi_linkable, base_reward_unit, base_reward_rate, point_value_inr, status
)
select id, 'icici-amazon-pay', 'ICICI Amazon Pay', 'visa', 'credit', 0, 0,
       false, 'points_per_100', 1.0, 1.0, 'draft'
from issuers where slug = 'icici'
on conflict (slug) do nothing;

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-amazon-pay' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into forex_rules (card_product_id, markup_percent, gst_on_markup)
select id, 3.5, true from card_products where slug = 'icici-amazon-pay'
  and not exists (select 1 from forex_rules f where f.card_product_id = card_products.id);

insert into milestone_rules (card_product_id, label, period, threshold_spend_inr, reward_description, reward_value_inr, is_repeatable)
select id, 'Prime membership value milestone', 'annual', 1000000, '₹1,000 Amazon Pay balance', 1000, false
from card_products where slug = 'icici-amazon-pay'
  and not exists (select 1 from milestone_rules m where m.card_product_id = card_products.id);

-- >>> Publish gate: verified_at required before status='published' --------
-- Left as 'draft' deliberately (see header comment) — publishing these for
-- real users requires the actual UA-1.1.4 human verification pass.
