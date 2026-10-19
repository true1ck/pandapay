-- A transaction keeps the public catalogue category and a private user
-- category in separate nullable columns. Both are editable sync fields.
create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','status','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    else null::text[]
  end;
$$;

create or replace function pandapay.validate_transaction_user_category()
returns trigger language plpgsql security definer
set search_path = public, pandapay
as $$
begin
  if new.user_category_id is not null and not exists (
    select 1 from user_categories
     where id = new.user_category_id and profile_id = new.profile_id
  ) then
    raise exception 'user category does not belong to transaction profile';
  end if;
  return new;
end $$;

drop trigger if exists trg_transactions_user_category on transactions;
create trigger trg_transactions_user_category
  before insert or update of user_category_id, profile_id on transactions
  for each row execute function pandapay.validate_transaction_user_category();
