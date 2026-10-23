-- Merchant related category review/apply snapshots. The snapshot is owned by
-- the profile and short lived; it prevents a client from changing the
-- merchant scope or row versions between preview and approval.
create table if not exists transaction_category_bulk_previews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  source_transaction_id uuid not null,
  target_category_id uuid references spend_categories(id),
  target_user_category_id uuid,
  match_basis text not null check (match_basis in ('vpa', 'strict_name')),
  match_value text not null,
  match_policy_version text not null,
  source_version bigint not null,
  candidates jsonb not null check (jsonb_typeof(candidates) = 'array'),
  candidate_count integer not null check (candidate_count >= 0),
  selectable_count integer not null check (selectable_count >= 0),
  overflow boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending', 'applied', 'expired')),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  created_at timestamptz not null default now(),
  applied_at timestamptz,
  foreign key (profile_id, source_transaction_id)
    references transactions(profile_id, id) on delete cascade
);

create index if not exists idx_transaction_category_bulk_preview_expiry
  on transaction_category_bulk_previews(expires_at) where status = 'pending';
create index if not exists idx_transaction_category_bulk_preview_owner
  on transaction_category_bulk_previews(profile_id, created_at desc);

create table if not exists transaction_category_bulk_operations (
  profile_id uuid not null references profiles(id) on delete cascade,
  operation_id uuid not null default gen_random_uuid(),
  idempotency_key text not null check (length(btrim(idempotency_key)) between 8 and 200),
  preview_id uuid not null,
  request_hash text not null,
  target_category_id uuid references spend_categories(id),
  target_user_category_id uuid,
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (profile_id, operation_id),
  unique (profile_id, idempotency_key),
  foreign key (preview_id) references transaction_category_bulk_previews(id) on delete restrict
);

create table if not exists transaction_category_bulk_operation_items (
  profile_id uuid not null references profiles(id) on delete cascade,
  operation_id uuid not null,
  transaction_id uuid not null,
  old_category_id uuid references spend_categories(id),
  old_user_category_id uuid,
  new_category_id uuid references spend_categories(id),
  new_user_category_id uuid,
  created_at timestamptz not null default now(),
  primary key (profile_id, operation_id, transaction_id),
  foreign key (profile_id, operation_id)
    references transaction_category_bulk_operations(profile_id, operation_id) on delete cascade,
  foreign key (profile_id, transaction_id)
    references transactions(profile_id, id) on delete cascade
);

alter table transaction_category_bulk_previews enable row level security;
alter table transaction_category_bulk_previews force row level security;
alter table transaction_category_bulk_operations enable row level security;
alter table transaction_category_bulk_operations force row level security;
alter table transaction_category_bulk_operation_items enable row level security;
alter table transaction_category_bulk_operation_items force row level security;

create policy transaction_category_bulk_previews_owner
  on transaction_category_bulk_previews for all to public
  using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
create policy transaction_category_bulk_operations_owner
  on transaction_category_bulk_operations for all to public
  using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
create policy transaction_category_bulk_operation_items_owner
  on transaction_category_bulk_operation_items for all to public
  using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

create index if not exists idx_transactions_bulk_vpa_date
  on transactions(profile_id, merchant_vpa, occurred_at desc)
  where status = 'active';
create index if not exists idx_transactions_bulk_name_date
  on transactions(profile_id, (lower(regexp_replace(btrim(merchant_name), '\s+', ' ', 'g'))), occurred_at desc)
  where status = 'active' and merchant_vpa is null;
