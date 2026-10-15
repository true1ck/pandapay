begin;

-- Keep a masked source-account suffix separate from physical-card last four
-- digits. This lets Spending group bank debits without attaching them to a
-- saved card that happens to share the same suffix.
alter table public.transactions
  add column if not exists source_account_last4 text;

alter table public.transactions
  drop constraint if exists transactions_source_account_last4_format;

alter table public.transactions
  add constraint transactions_source_account_last4_format
  check (
    source_account_last4 is null
    or source_account_last4 ~ '^[0-9]{4}$'
  );

create index if not exists idx_transactions_profile_source_account_time
  on public.transactions(profile_id, source_account_last4, occurred_at desc)
  where source_account_last4 is not null;

comment on column public.transactions.source_account_last4 is
  'Masked last four digits of the source bank account for cardless debits; never a physical-card identifier.';

commit;
