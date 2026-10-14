-- Keep catalogue definitions unique by meaning, not by generated UUID.
--
-- Imports used to append identical cap/benefit rows on repeated runs. The
-- client then rendered every row, so one card could show the same cap several
-- times. Keep the oldest definition, merge any user state that points at a
-- duplicate cap, and add semantic unique indexes to prevent recurrence.

begin;

create temporary table _catalogue_cap_rule_duplicates on commit drop as
with ranked as (
  select
    id,
    first_value(id) over (
      partition by card_product_id, reward_rule_id, category_id, benefit_kind,
                   lower(trim(label)), measure, period, cap_value,
                   post_cap_unit, post_cap_rate, resets_on_day
      order by created_at, id
    ) as keep_id,
    row_number() over (
      partition by card_product_id, reward_rule_id, category_id, benefit_kind,
                   lower(trim(label)), measure, period, cap_value,
                   post_cap_unit, post_cap_rate, resets_on_day
      order by created_at, id
    ) as duplicate_rank
  from cap_rules
)
select id as duplicate_id, keep_id
from ranked
where duplicate_rank > 1;

do $$
declare
  mapping record;
begin
  for mapping in
    select duplicate_id, keep_id from _catalogue_cap_rule_duplicates
  loop
    insert into cap_states
      (profile_id, user_card_id, cap_rule_id, period_start, period_end,
       consumed, cap_value_snapshot, state, updated_at)
    select profile_id, user_card_id, mapping.keep_id, period_start, period_end,
           consumed, cap_value_snapshot, state, updated_at
      from cap_states
     where cap_rule_id = mapping.duplicate_id
    on conflict (user_card_id, cap_rule_id, period_start) do update
      set consumed = cap_states.consumed + excluded.consumed,
          cap_value_snapshot = greatest(
            cap_states.cap_value_snapshot,
            excluded.cap_value_snapshot
          ),
          updated_at = greatest(cap_states.updated_at, excluded.updated_at);

    delete from cap_states where cap_rule_id = mapping.duplicate_id;
    delete from cap_rules where id = mapping.duplicate_id;
  end loop;
end $$;

create temporary table _catalogue_benefit_duplicates on commit drop as
with ranked as (
  select
    id,
    first_value(id) over (
      partition by card_product_id, kind, lower(trim(label)), description,
                   quota_count, quota_period, network_program,
                   value_estimate_inr, conditions
      order by created_at, id
    ) as keep_id,
    row_number() over (
      partition by card_product_id, kind, lower(trim(label)), description,
                   quota_count, quota_period, network_program,
                   value_estimate_inr, conditions
      order by created_at, id
    ) as duplicate_rank
  from card_benefits
)
select id as duplicate_id, keep_id
from ranked
where duplicate_rank > 1;

update lounge_usage usage
   set benefit_id = duplicates.keep_id
  from _catalogue_benefit_duplicates duplicates
 where usage.benefit_id = duplicates.duplicate_id;

delete from card_benefits benefit
 using _catalogue_benefit_duplicates duplicates
 where benefit.id = duplicates.duplicate_id;

create unique index if not exists uq_cap_rules_semantic_identity
  on cap_rules (
    card_product_id,
    reward_rule_id,
    category_id,
    benefit_kind,
    label,
    measure,
    period,
    cap_value,
    post_cap_unit,
    post_cap_rate,
    resets_on_day
  ) nulls not distinct;

create unique index if not exists uq_card_benefits_semantic_identity
  on card_benefits (
    card_product_id,
    kind,
    label,
    description,
    quota_count,
    quota_period,
    network_program,
    value_estimate_inr,
    conditions
  ) nulls not distinct;

create unique index if not exists uq_reward_rules_semantic_identity
  on reward_rules (
    card_product_id,
    category_id,
    merchant_pattern,
    rail,
    unit,
    rate,
    min_txn_inr,
    max_txn_inr,
    priority,
    conditions,
    notes,
    effective_from,
    effective_to,
    excluded_categories
  ) nulls not distinct;

create unique index if not exists uq_milestone_rules_semantic_identity
  on milestone_rules (
    card_product_id,
    label,
    period,
    threshold_spend_inr,
    reward_description,
    reward_value_inr,
    is_repeatable,
    max_repeats,
    anchor
  ) nulls not distinct;

create unique index if not exists uq_fee_waiver_rules_semantic_identity
  on fee_waiver_rules (
    card_product_id,
    threshold_spend_inr,
    period,
    waives_fee_inr,
    excluded_categories,
    notes
  ) nulls not distinct;

commit;
