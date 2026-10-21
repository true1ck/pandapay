-- Billing/due learning used to be additive (`WHERE statement_day IS NULL`)
-- because a first write could be garbage — the parser had no printed-date
-- tiers, so any bill-shaped SMS would lock in whichever arrival date won the
-- batch rank. With the parser fixed (printed generation / period-end / due
-- phrases only, due-date mis-captures guarded), stored days can safely HEAL
-- when a newer bill SMS disagrees — that is the whole point for users: cards
-- whose cycle rules changed follow the new SMS automatically.
--
-- A source column separates "user typed this in Edit Card" (never touched)
-- from "learned from an SMS" (overwritten on newer explicit evidence).
--
-- Backfill note: historical `statement_day`/`due_day` values came from either
-- the SMS resolvers or a PATCH /user-cards edit, with no distinguishing
-- marker. They are stamped 'sms' (healable) — the deliberate bias: a stuck,
-- wrong learned day hurting cycle math every month was this project's actual
-- complaint, while a user who wants to lock their value re-saves it once in
-- Edit Card, which stamps 'user' from here on.

alter table user_cards
  add column statement_day_source text check (statement_day_source in ('user', 'sms')),
  add column due_day_source text check (due_day_source in ('user', 'sms'));

update user_cards
   set statement_day_source = 'sms'
 where statement_day is not null
   and statement_day_source is null;

update user_cards
   set due_day_source = 'sms'
 where due_day is not null
   and due_day_source is null;

-- 20261019144500's definition, re-declared in full with the two new
-- syncable fields appended (the learned change must reach every device).
create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','status','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'statement_day_source','due_day_source'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    else null::text[]
  end;
$$;
