-- Keep one active row per physical card identity.
--
-- The old add/import paths deduplicated only by card_product_id. That made a
-- retry capable of producing several visually identical wallet cards, while
-- spend rows remained attached to only one user_card_id. This migration keeps
-- the oldest active row as the canonical row, moves all references to it, and
-- archives the redundant rows. Archiving is reversible and preserves history.

begin;

create temporary table _user_card_dedupe_map on commit drop as
with ranked as (
  select
    uc.id,
    first_value(uc.id) over (
      partition by uc.profile_id, uc.card_product_id, btrim(coalesce(uc.last4, ''))
      order by uc.created_at, uc.id
    ) as keep_id,
    row_number() over (
      partition by uc.profile_id, uc.card_product_id, btrim(coalesce(uc.last4, ''))
      order by uc.created_at, uc.id
    ) as duplicate_rank
  from user_cards uc
  where uc.is_archived = false
)
select id as duplicate_id, keep_id
from ranked
where duplicate_rank > 1;

do $$
declare
  mapping record;
begin
  for mapping in select duplicate_id, keep_id from _user_card_dedupe_map loop
    -- Preserve user-entered metadata from either row without overwriting the
    -- canonical row's values.
    update user_cards keep
       set nickname = coalesce(keep.nickname, duplicate.nickname),
           credit_limit_inr = coalesce(keep.credit_limit_inr, duplicate.credit_limit_inr),
           statement_day = coalesce(keep.statement_day, duplicate.statement_day),
           due_day = coalesce(keep.due_day, duplicate.due_day),
           opened_on = coalesce(keep.opened_on, duplicate.opened_on),
           anniversary_on = coalesce(keep.anniversary_on, duplicate.anniversary_on),
           points_balance = greatest(keep.points_balance, duplicate.points_balance),
           is_default = keep.is_default or duplicate.is_default,
           updated_at = now()
      from user_cards duplicate
     where keep.id = mapping.keep_id and duplicate.id = mapping.duplicate_id;

    update transactions set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update transactions set recommended_card_id = mapping.keep_id
      where recommended_card_id = mapping.duplicate_id;
    update transaction_splits set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update card_overrides set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update points_ledger set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update lounge_usage set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update statement_imports set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update recurring_series set user_card_id = mapping.keep_id
      where user_card_id = mapping.duplicate_id;
    update needs_review_items set suggested_card_id = mapping.keep_id
      where suggested_card_id = mapping.duplicate_id;

    -- These tables are unique per card/rule/period. Merge their progress
    -- before removing the duplicate row so no cap or milestone disappears.
    insert into cap_states
      (profile_id, user_card_id, cap_rule_id, period_start, period_end,
       consumed, cap_value_snapshot, state, updated_at)
    select profile_id, mapping.keep_id, cap_rule_id, period_start, period_end,
           consumed, cap_value_snapshot, state, updated_at
      from cap_states
     where user_card_id = mapping.duplicate_id
    on conflict (user_card_id, cap_rule_id, period_start) do update
      set consumed = cap_states.consumed + excluded.consumed,
          cap_value_snapshot = greatest(cap_states.cap_value_snapshot, excluded.cap_value_snapshot),
          updated_at = greatest(cap_states.updated_at, excluded.updated_at);
    delete from cap_states where user_card_id = mapping.duplicate_id;

    insert into milestone_states
      (profile_id, user_card_id, milestone_rule_id, period_start, period_end,
       qualified_spend, achieved_at, updated_at)
    select profile_id, mapping.keep_id, milestone_rule_id, period_start, period_end,
           qualified_spend, achieved_at, updated_at
      from milestone_states
     where user_card_id = mapping.duplicate_id
    on conflict (user_card_id, milestone_rule_id, period_start) do update
      set qualified_spend = milestone_states.qualified_spend + excluded.qualified_spend,
          achieved_at = coalesce(milestone_states.achieved_at, excluded.achieved_at),
          updated_at = greatest(milestone_states.updated_at, excluded.updated_at);
    delete from milestone_states where user_card_id = mapping.duplicate_id;

    insert into fee_waiver_states
      (profile_id, user_card_id, fee_waiver_rule_id, period_start, period_end,
       qualified_spend, waived_at, updated_at)
    select profile_id, mapping.keep_id, fee_waiver_rule_id, period_start, period_end,
           qualified_spend, waived_at, updated_at
      from fee_waiver_states
     where user_card_id = mapping.duplicate_id
    on conflict (user_card_id, fee_waiver_rule_id, period_start) do update
      set qualified_spend = fee_waiver_states.qualified_spend + excluded.qualified_spend,
          waived_at = coalesce(fee_waiver_states.waived_at, excluded.waived_at),
          updated_at = greatest(fee_waiver_states.updated_at, excluded.updated_at);
    delete from fee_waiver_states where user_card_id = mapping.duplicate_id;

    update user_cards
       set is_archived = true, archived_at = now(), updated_at = now()
     where id = mapping.duplicate_id;
  end loop;
end $$;

create unique index if not exists uq_user_cards_active_identity
  on user_cards (profile_id, card_product_id, btrim(coalesce(last4, '')))
  where is_archived = false;

comment on index uq_user_cards_active_identity is
  'One active wallet row per profile, catalogue card product/type, and last four; '
  'a missing last four is one unlinked placeholder.';

commit;
