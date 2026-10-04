-- >>> MIGRATION 0045 — REMOVE UNENFORCEABLE REWARD TRIGGERS =============
--
-- CardPipeline preserves welcome, activation, transaction-count, birthday,
-- and other event benefits. The spend recommendation engine does not carry
-- the lifecycle state needed to decide whether those events occurred.
--
-- The old importer nevertheless projected two unsafe shapes:
--   * a fixed conditional bonus such as 1,000 points after six transactions
--     became 1,000 points per spend block on every transaction;
--   * birthday/activation/first-transaction benefits became normal spend
--     milestones and were added to unrelated purchases.
--
-- This migration repairs existing imported catalogue rows. The complete rows
-- being removed are retained in admin_audit_log, and transform v5 preserves
-- the exact CardPipeline source objects in card_products.extended_data on
-- subsequent imports. Child-table delete triggers bump data_version, causing
-- devices to replace their stale catalogue entries on the next sync.

begin;

create temporary table bad_reward_rules on commit drop as
select rr.id, rr.card_product_id
from reward_rules rr
join card_products cp on cp.id = rr.card_product_id
where cp.import_source_hash is not null
  and rr.rate > 0
  and (
    lower(coalesce(rr.conditions->>'source_local_id', '')) ~ '(welcome|activation)'
    or lower(coalesce((rr.conditions->'source_conditions')::text, '')) ~
      '"(transaction_count|transaction_sequence|first_transaction|first_spend|within_days_of_card_receipt|within_days_of_card_issuance|days_from_card_issuance|days_from_card_receipt|deadline_days_from_receipt|deadline_days_from_issuance|trigger)"[[:space:]]*:'
    or lower(coalesce((rr.conditions->'source_conditions')::text, '')) ~
      '"field"[[:space:]]*:[[:space:]]*"(first_transaction|first_spend|days_from_card_issuance|days_from_card_receipt)"'
  );

create temporary table bad_milestone_rules on commit drop as
select mr.id, mr.card_product_id
from milestone_rules mr
join card_products cp on cp.id = mr.card_product_id
where cp.import_source_hash is not null
  and lower(mr.label) ~
    '(birthday|welcome|activation|upgrade|joining[- ]fee|fee (waiver|reversal)|first[- ](transaction|spend|purchase|fuel|hpcl|emi|year|60|90)|within [0-9]+ days)';

insert into admin_audit_log
  (admin_id, action, entity, entity_id, before_value, after_value, reason)
select
  null,
  'repair_unenforceable_reward_triggers',
  'card_products',
  cp.id,
  jsonb_build_object(
    'slug', cp.slug,
    'reward_rules', coalesce(
      (select jsonb_agg(to_jsonb(rr) order by rr.id)
       from bad_reward_rules b
       join reward_rules rr on rr.id = b.id
       where b.card_product_id = cp.id),
      '[]'::jsonb
    ),
    'milestone_rules', coalesce(
      (select jsonb_agg(to_jsonb(mr) order by mr.id)
       from bad_milestone_rules b
       join milestone_rules mr on mr.id = b.id
       where b.card_product_id = cp.id),
      '[]'::jsonb
    )
  ),
  jsonb_build_object(
    'slug', cp.slug,
    'reward_rules', '[]'::jsonb,
    'milestone_rules', '[]'::jsonb
  ),
  'Removed conditional rewards that the recommendation context cannot evaluate; complete removed rows retained in this audit entry.'
from card_products cp
where exists (select 1 from bad_reward_rules b where b.card_product_id = cp.id)
   or exists (select 1 from bad_milestone_rules b where b.card_product_id = cp.id);

delete from reward_rules rr
using bad_reward_rules bad
where rr.id = bad.id;

delete from milestone_rules mr
using bad_milestone_rules bad
where mr.id = bad.id;

-- The migration applies the same projection semantics as importer transform
-- v5, including to protected reviewed/published rows that the importer would
-- otherwise leave untouched without --force.
update card_products
set import_transform_version = '5'
where import_source_hash is not null
  and import_transform_version in ('1', '2', '3', '4');

commit;
