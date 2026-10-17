-- Axis Flipkart cap data requested for the recommendation and tracking flows.
-- The cap is expressed in rupees of reward value, not raw points, so the
-- ranking engine can compare it directly with cashback and other cards.

begin;

update card_products
set base_reward_unit = 'cashback_percent',
    base_reward_rate = coalesce(base_reward_rate, 1.5),
    point_value_inr = coalesce(point_value_inr, 1.0)
where slug = 'axis-flipkart';

insert into cap_rules (
  card_product_id,
  reward_rule_id,
  category_id,
  label,
  measure,
  period,
  cap_value,
  post_cap_unit,
  post_cap_rate
)
select cp.id,
       rr.id,
       sc.id,
       '5% online cashback — capped at ₹4,000/quarter',
       'reward_value',
       'quarter',
       4000,
       'cashback_percent',
       1.5
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where cp.slug = 'axis-flipkart'
  and not exists (
    select 1
    from cap_rules existing
    where existing.card_product_id = cp.id
      and existing.reward_rule_id = rr.id
      and existing.category_id = sc.id
  );

update cap_rules existing
set label = '5% online cashback — capped at ₹4,000/quarter',
    measure = 'reward_value',
    period = 'quarter',
    cap_value = 4000,
    post_cap_unit = 'cashback_percent',
    post_cap_rate = 1.5
from card_products cp
join reward_rules rr on rr.card_product_id = cp.id
join spend_categories sc on sc.id = rr.category_id and sc.slug = 'online'
where existing.card_product_id = cp.id
  and existing.reward_rule_id = rr.id
  and existing.category_id = sc.id
  and cp.slug = 'axis-flipkart';

insert into fuel_surcharge_rules (
  card_product_id,
  surcharge_percent,
  waiver_percent,
  min_txn_inr,
  max_txn_inr
)
select cp.id, 1.0, 1.0, 400, 4000
from card_products cp
where cp.slug = 'axis-flipkart'
  and not exists (
    select 1 from fuel_surcharge_rules existing
    where existing.card_product_id = cp.id
  );

update fuel_surcharge_rules fuel
set surcharge_percent = 1.0,
    waiver_percent = 1.0,
    min_txn_inr = 400,
    max_txn_inr = 4000
from card_products cp
where fuel.card_product_id = cp.id
  and cp.slug = 'axis-flipkart';

commit;
