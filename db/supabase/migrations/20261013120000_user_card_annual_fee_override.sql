-- A card product has a catalogue fee, but issuer offers can make the same
-- product lifetime-free for one customer. Keep that fact on user_cards so it
-- does not corrupt the shared catalogue for everybody else.
alter table user_cards
  add column if not exists annual_fee_override_inr numeric(10,2)
  check (annual_fee_override_inr is null or annual_fee_override_inr >= 0);

-- Keep offline edits on the same allowlist as online PATCH edits.
create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','rail','status','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'last4','annual_fee_override_inr'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    else null::text[]
  end;
$$;
