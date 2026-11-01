-- A remembered self-transfer is a profile-owned relationship, not a property
-- of one transaction.  Keeping it separate makes undo/reassignment explicit,
-- prevents a correction on one row from silently teaching every future SMS,
-- and gives every device the same source-account + recipient policy.
create table if not exists public.self_transfer_rules (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  source_sender text not null check (source_sender ~ '^[a-z0-9_.-]{2,30}$'),
  source_account_last4 text not null check (source_account_last4 ~ '^[0-9]{4}$'),
  transfer_party text not null check (length(btrim(transfer_party)) between 2 and 160),
  destination_bank text not null check (destination_bank ~ '^[a-z0-9_.-]{2,30}$'),
  destination_account_last4 text not null check (destination_account_last4 ~ '^[0-9]{4}$'),
  is_active boolean not null default true,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_id, source_sender, source_account_last4, transfer_party,
          destination_bank, destination_account_last4)
);

create index if not exists idx_self_transfer_rules_active
  on public.self_transfer_rules(profile_id, is_active)
  where is_active;

-- Promote the first implementation's transaction-attached confirmations into
-- the durable relationship store during rollout. Invalid or incomplete JSON
-- is ignored; it remains visible on the original transaction for audit.
insert into public.self_transfer_rules
  (profile_id, source_sender, source_account_last4, transfer_party,
   destination_bank, destination_account_last4)
select distinct o.profile_id,
       o.metadata->'selfTransferRule'->>'sourceSender',
       o.metadata->'selfTransferRule'->>'sourceAccountLast4',
       o.metadata->'selfTransferRule'->>'party',
       o.metadata->'selfTransferRule'->'destination'->>'bank',
       o.metadata->'selfTransferRule'->'destination'->>'accountLast4'
  from public.transaction_observations o
 where o.metadata->'selfTransferRule' is not null
   and o.metadata->>'selfTransferRemembered' = 'true'
   and o.metadata->'selfTransferRule'->>'sourceSender' ~ '^[a-z0-9_.-]{2,30}$'
   and o.metadata->'selfTransferRule'->>'sourceAccountLast4' ~ '^[0-9]{4}$'
   and length(btrim(o.metadata->'selfTransferRule'->>'party')) between 2 and 160
   and o.metadata->'selfTransferRule'->'destination'->>'bank' ~ '^[a-z0-9_.-]{2,30}$'
   and o.metadata->'selfTransferRule'->'destination'->>'accountLast4' ~ '^[0-9]{4}$'
on conflict (profile_id, source_sender, source_account_last4, transfer_party,
             destination_bank, destination_account_last4) do nothing;

alter table public.self_transfer_rules enable row level security;
alter table public.self_transfer_rules force row level security;
grant select, insert, update, delete on public.self_transfer_rules to app_user;
drop policy if exists self_transfer_rules_owner on public.self_transfer_rules;
create policy self_transfer_rules_owner on public.self_transfer_rules
  for all to public
  using (
    current_user in ('service_role', 'postgres')
    or (pandapay.uid() is not null and profile_id = pandapay.uid())
  )
  with check (
    current_user in ('service_role', 'postgres')
    or (pandapay.uid() is not null and profile_id = pandapay.uid())
  );

comment on table public.self_transfer_rules is
  'Profile-scoped, explicitly confirmed bank-account self-transfer relationships.';
