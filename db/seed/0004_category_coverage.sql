-- Chunk: category coverage across the demo catalogue.
--
-- Same honesty contract as 0001/0002's headers: real issuers, real product
-- names, real reward/cap SHAPES, with rates that are approximate
-- publicly-known figures for development and demo use — NOT verified
-- against current bank T&C, and every card here is still status='draft'
-- until UA-1.1.4's human verification pass sets verified_at.
--
-- Why this exists: 0001+0002 gave most cards exactly ONE category rule, so
-- picking any other category on Home produced a flat ranking where every
-- card fell back to its base rate and the "best card for THIS purchase"
-- question had no interesting answer. The engine was fine; the data was
-- one-dimensional. This fills in the second and third rules real Indian
-- cards actually carry (a fuel surcharge waiver, a dining tier, a travel
-- portal rate) plus the caps that make them interesting — a card that
-- looks great at ₹500 and mediocre at ₹50,000 is the whole point of the
-- product.
--
-- Idempotent: every insert is guarded on (card, category), so re-running
-- adds nothing and overwrites nothing.

-- Helper shape used throughout:
--   insert into reward_rules (...) select cp.id, sc.id, ...
--   from card_products cp, spend_categories sc
--   where cp.slug = ? and sc.slug = ?
--     and not exists (... same card+category ...);

-- >>> Axis Ace — 5% bills (existing), 4% online, 2% dining (existing) -------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 4.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'axis-ace' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 4.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'axis-ace' and sc.slug = 'groceries'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> HDFC Millennia — 5% online (existing), 2.5% dining, 1% groceries -----
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 2.5, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-millennia' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 2.5, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-millennia' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> SBI Cashback — 5% online (existing), 1% everywhere else is its base --
--     Its real differentiator is that online is uncapped-ish but bills are
--     excluded; model the exclusion as an explicit 0% rule so the engine
--     shows "₹0 back" with a reason rather than silently paying base rate.
insert into reward_rules (card_product_id, category_id, unit, rate, priority, notes)
select cp.id, sc.id, 'cashback_percent', 0.0, 5, 'Utility and rent spends are excluded from cashback'
from card_products cp, spend_categories sc
where cp.slug = 'sbi-cashback' and sc.slug = 'bills'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority, notes)
select cp.id, sc.id, 'cashback_percent', 0.0, 5, 'Rent is excluded from cashback'
from card_products cp, spend_categories sc
where cp.slug = 'sbi-cashback' and sc.slug = 'rent'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> AU LIT — 5% on the ONE chosen category (existing: entertainment) -----
--     Plus the fuel and dining packs its LIT toggles actually offer.
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 2.0, 20
from card_products cp, spend_categories sc
where cp.slug = 'au-lit' and sc.slug = 'fuel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 2.0, 20
from card_products cp, spend_categories sc
where cp.slug = 'au-lit' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> ICICI Amazon Pay — 5% online (existing), 2% bills, 1% base ----------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 2.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-amazon-pay' and sc.slug = 'bills'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 2.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-amazon-pay' and sc.slug = 'groceries'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> HDFC Swiggy — 10% dining (existing), 5% groceries, 5% online --------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-swiggy' and sc.slug = 'groceries'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-swiggy' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> HDFC Regalia Gold — 8x dining (existing), 8x travel, 8x groceries ----
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_150', 8.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-regalia-gold' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_150', 8.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'hdfc-regalia-gold' and sc.slug = 'groceries'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> IDFC FIRST Select — 10x dining (existing), 10x online above ₹20k/mo --
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_150', 10.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'idfc-first-select' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_150', 6.0, 20
from card_products cp, spend_categories sc
where cp.slug = 'idfc-first-select' and sc.slug = 'health'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> ICICI Coral RuPay — 2x groceries (existing), 2x bills, 2x dining -----
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 2.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-coral-rupay' and sc.slug = 'bills'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 2.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-coral-rupay' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> ICICI Sapphiro — 4x dining (existing), 4x travel -------------------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 4.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'icici-sapphiro' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> Kotak Myntra — 7.5% online (existing), 5% dining -------------------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'kotak-myntra' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> Axis Flipkart — 5% online (existing), 4% travel, 1.5% base ----------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 4.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'axis-flipkart' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> SBI SimplyCLICK — 10x online (existing), 5x dining ------------------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'sbi-simplyclick' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> RBL World Safari — 5x travel (existing), 5x dining ------------------
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'rbl-world-safari' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> The five cards 0002 left with NO category rules at all --------------
--     Each gets the one or two categories it's actually known for. Without
--     these they only ever showed their flat base rate, which for Amex's
--     `flat_points` base meant they were excluded from every ranking.

-- Amex Membership Rewards: 1 point per ₹50, with accelerated dining/travel.
update card_products
   set base_reward_unit = 'points_per_100', base_reward_rate = 2.0
 where slug = 'amex-membership-rewards' and base_reward_unit = 'flat_points';

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 4.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'amex-membership-rewards' and sc.slug in ('dining', 'travel')
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- Axis Magnus: travel-first, 12x on the Travel Edge portal.
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_200', 60.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'axis-magnus' and sc.slug = 'travel'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_200', 12.0, 20
from card_products cp, spend_categories sc
where cp.slug = 'axis-magnus' and sc.slug = 'dining'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- IndusInd Tiger: fuel and groceries.
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 3.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'indusind-tiger' and sc.slug in ('fuel', 'groceries')
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- SBI ELITE: dining/entertainment, 5x.
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'points_per_100', 5.0, 10
from card_products cp, spend_categories sc
where cp.slug = 'sbi-elite' and sc.slug in ('dining', 'entertainment')
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- Yes Bank PaisaSave: 1.5% online, 1% everything else.
insert into reward_rules (card_product_id, category_id, unit, rate, priority)
select cp.id, sc.id, 'cashback_percent', 1.5, 10
from card_products cp, spend_categories sc
where cp.slug = 'yes-paisasave' and sc.slug = 'online'
  and not exists (select 1 from reward_rules r where r.card_product_id = cp.id and r.category_id = sc.id);

-- >>> Caps on the new accelerated rules ------------------------------------
--     Without a cap, a 10% dining rule pays 10% on a ₹2,00,000 dinner,
--     which is what made large-amount rankings read as obviously wrong.
--     Each cap is monthly, measured in reward value, and drops to the
--     card's own base rate afterwards — the shape real cards use.
insert into cap_rules (
  card_product_id, reward_rule_id, category_id, label, measure, period,
  cap_value, post_cap_unit, post_cap_rate
)
select r.card_product_id,
       r.id,
       r.category_id,
       format('%s on %s — capped at %s reward value/month',
              case r.unit
                when 'cashback_percent' then r.rate::text || '%'
                else r.rate::text || 'x points'
              end,
              sc.name,
              '₹' || (case when r.rate >= 5 then 750 else 1500 end)::text),
       'reward_value',
       'calendar_month',
       case when r.rate >= 5 then 750 else 1500 end,
       cp.base_reward_unit,
       cp.base_reward_rate
from reward_rules r
join card_products cp on cp.id = r.card_product_id
join spend_categories sc on sc.id = r.category_id
where r.rate > 0
  and cp.base_reward_unit is not null
  and not exists (select 1 from cap_rules k where k.reward_rule_id = r.id);
