-- Pending original-currency evidence is deliberately separate from the INR
-- ledger. Reference estimates cannot affect spending/rewards/card state.
create table if not exists public.foreign_payments (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  source_key text not null check (source_key ~ '^[a-f0-9]{64}$'),
  original_currency text check (original_currency is null or (original_currency ~ '^[A-Z]{3}$' and original_currency <> 'INR')),
  original_amount numeric(26,4) check (original_amount is null or original_amount > 0),
  occurred_at timestamptz not null,
  merchant_name text check (merchant_name is null or length(merchant_name) between 1 and 200),
  card_last4 text check (card_last4 is null or card_last4 ~ '^[0-9]{4}$'),
  account_last4 text check (account_last4 is null or account_last4 ~ '^[0-9]{4}$'),
  instrument text not null default 'other' check (instrument in ('credit_card','debit_card','upi_bank','wallet','cash','other')),
  user_card_id uuid references public.user_cards(id) on delete set null,
  category_id uuid references public.spend_categories(id) on delete set null,
  user_category_id uuid references public.user_categories(id) on delete set null,
  category_name text check (category_name is null or length(category_name) between 1 and 100),
  valuation_status text not null check (valuation_status in ('awaiting_amount','awaiting_rate','estimated','confirmed','ignored')),
  estimated_inr numeric(12,2) check (estimated_inr is null or estimated_inr > 0),
  billed_inr numeric(12,2) check (billed_inr is null or billed_inr > 0),
  rate numeric(34,14) check (rate is null or rate > 0),
  rate_date date,
  rate_source text,
  transaction_id uuid,
  confirmation_source text check (confirmation_source is null or confirmation_source in ('user','sms','statement')),
  direction text not null default 'spend' check (direction in ('spend','refund')),
  reference text check (reference is null or reference ~ '^[A-Za-z0-9-]{6,40}$'),
  refund_of_id uuid,
  user_modified boolean not null default false,
  revision integer not null default 1 check (revision > 0),
  last_refreshed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(profile_id,source_key),
  unique(profile_id,id),
  foreign key(profile_id,transaction_id) references public.transactions(profile_id,id) on delete set null (transaction_id),
  foreign key(profile_id,refund_of_id) references public.foreign_payments(profile_id,id) on delete set null (refund_of_id) deferrable initially deferred,
  check (valuation_status <> 'estimated' or (original_amount is not null and original_currency is not null and estimated_inr is not null and rate is not null and rate_date is not null)),
  check (valuation_status <> 'confirmed' or (billed_inr is not null and transaction_id is not null and confirmation_source is not null))
);
create unique index if not exists foreign_payments_confirmed_transaction on public.foreign_payments(profile_id,transaction_id) where transaction_id is not null;
create index if not exists foreign_payments_activity on public.foreign_payments(profile_id,occurred_at desc,id desc);
create index if not exists foreign_payments_reference on public.foreign_payments(profile_id,reference) where reference is not null;

create table if not exists public.foreign_payment_sources (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  source_key text not null check (source_key ~ '^[a-f0-9]{64}$'),
  foreign_payment_id uuid not null,
  created_at timestamptz not null default now(),
  primary key(profile_id,source_key),
  foreign key(profile_id,foreign_payment_id) references public.foreign_payments(profile_id,id) on delete cascade
);
create table if not exists public.foreign_payment_events (
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  foreign_payment_id uuid not null,
  event_kind text not null check (event_kind in ('created','edited','estimated','confirmed','ignored','restored','reconciled')),
  previous_state jsonb,
  next_state jsonb not null,
  created_at timestamptz not null default now(),
  foreign key(profile_id,foreign_payment_id) references public.foreign_payments(profile_id,id) on delete cascade
);
-- Currency/date only; immutable snapshots contain no personal data.
create table if not exists public.foreign_exchange_rates (
  currency text not null check (currency ~ '^[A-Z]{3}$' and currency <> 'INR'),
  requested_date date not null,
  rate_date date not null,
  rate numeric(34,14) not null check (rate > 0),
  rate_source text not null,
  fetched_at timestamptz not null default now(),
  primary key(currency,requested_date),
  check (rate_date <= requested_date and rate_date >= requested_date - 31)
);
grant select,insert,update on public.foreign_exchange_rates to app_user;
grant select,insert,update,delete on public.foreign_payments,public.foreign_payment_sources,public.foreign_payment_events to app_user;
grant usage,select on sequence public.foreign_payment_events_id_seq to app_user;
alter table public.foreign_payments enable row level security;
alter table public.foreign_payments force row level security;
alter table public.foreign_payment_sources enable row level security;
alter table public.foreign_payment_sources force row level security;
alter table public.foreign_payment_events enable row level security;
alter table public.foreign_payment_events force row level security;
drop policy if exists foreign_payments_owner on public.foreign_payments;
create policy foreign_payments_owner on public.foreign_payments for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());
drop policy if exists foreign_payment_sources_owner on public.foreign_payment_sources;
create policy foreign_payment_sources_owner on public.foreign_payment_sources for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());
drop policy if exists foreign_payment_events_owner on public.foreign_payment_events;
create policy foreign_payment_events_owner on public.foreign_payment_events for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());

-- Later ledger edits/deletion/restore must not leave a stale confirmed FX
-- summary behind. Invoker rights retain exactly the writer's owner context.
create or replace function pandapay.sync_foreign_payment_ledger_state()
returns trigger language plpgsql set search_path = public, pandapay as $$
declare
  v_before public.foreign_payments;
  v_after public.foreign_payments;
begin
  for v_before in select * from public.foreign_payments
      where profile_id=old.profile_id and transaction_id=old.id for update
  loop
    if tg_op='DELETE' then
      update public.foreign_payments set transaction_id=null,valuation_status='ignored',
          revision=revision+1,updated_at=now()
        where profile_id=v_before.profile_id and id=v_before.id returning * into v_after;
    else
      update public.foreign_payments set
          valuation_status=case when new.status='active' then 'confirmed' else 'ignored' end,
          billed_inr=new.amount_inr, category_id=new.category_id,
          category_name=case when new.user_category_id is not null
            then (select name from public.user_categories where profile_id=new.profile_id and id=new.user_category_id)
            else (select name from public.spend_categories where id=new.category_id) end,
          user_category_id=new.user_category_id,user_card_id=new.user_card_id,
          merchant_name=coalesce(new.merchant_name,merchant_name),occurred_at=new.occurred_at,
          revision=revision+1,updated_at=now()
        where profile_id=v_before.profile_id and id=v_before.id returning * into v_after;
    end if;
    insert into public.foreign_payment_events(profile_id,foreign_payment_id,event_kind,previous_state,next_state)
      values(v_before.profile_id,v_before.id,'reconciled',to_jsonb(v_before)-'profile_id',to_jsonb(v_after)-'profile_id');
  end loop;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function pandapay.sync_foreign_payment_ledger_state() from public;
grant execute on function pandapay.sync_foreign_payment_ledger_state() to app_user;
drop trigger if exists sync_foreign_payment_after_ledger_edit on public.transactions;
create trigger sync_foreign_payment_after_ledger_edit
  after update of status,amount_inr,category_id,user_category_id,user_card_id,merchant_name,occurred_at
  on public.transactions for each row execute function pandapay.sync_foreign_payment_ledger_state();
drop trigger if exists sync_foreign_payment_before_ledger_delete on public.transactions;
create trigger sync_foreign_payment_before_ledger_delete before delete on public.transactions
  for each row execute function pandapay.sync_foreign_payment_ledger_state();
