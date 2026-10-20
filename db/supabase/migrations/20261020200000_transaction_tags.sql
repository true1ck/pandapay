-- Private context, independent of reward/category state. Additive migration.
create table transaction_tags (
  id uuid primary key,
  profile_id uuid not null references profiles(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  normalized_name text not null,
  color text check (color is null or color ~ '^#[0-9a-fA-F]{6}$'),
  archived_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (profile_id,id)
);
create unique index transaction_tags_active_name on transaction_tags(profile_id,normalized_name) where archived_at is null;
alter table transactions add constraint transactions_profile_id_id_key unique(profile_id,id);
create table transaction_tag_links (
  profile_id uuid not null references profiles(id) on delete cascade,
  transaction_id uuid not null,
  tag_id uuid not null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key(profile_id,transaction_id,tag_id),
  foreign key(profile_id,transaction_id) references transactions(profile_id,id) on delete cascade,
  foreign key(profile_id,tag_id) references transaction_tags(profile_id,id) on delete cascade
);
create index transaction_tag_links_lookup on transaction_tag_links(profile_id,tag_id,transaction_id) where deleted_at is null;
create table transaction_tag_mutations (
  profile_id uuid not null references profiles(id) on delete cascade,
  mutation_id uuid not null,
  created_at timestamptz not null default now(),
  primary key(profile_id,mutation_id)
);
-- Keep old identities resolvable after deduplication for offline tag edits.
create table transaction_tag_transaction_aliases (
  profile_id uuid not null references profiles(id) on delete cascade,
  old_id uuid not null,
  transaction_id uuid not null,
  primary key(profile_id,old_id),
  foreign key(profile_id,transaction_id) references transactions(profile_id,id) on delete cascade
);
alter table transaction_tags enable row level security;
alter table transaction_tags force row level security;
create policy transaction_tags_owner on transaction_tags for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());
alter table transaction_tag_links enable row level security;
alter table transaction_tag_links force row level security;
create policy transaction_tag_links_owner on transaction_tag_links for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());
alter table transaction_tag_mutations enable row level security;
alter table transaction_tag_mutations force row level security;
create policy transaction_tag_mutations_owner on transaction_tag_mutations for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());
alter table transaction_tag_transaction_aliases enable row level security;
alter table transaction_tag_transaction_aliases force row level security;
create policy transaction_tag_aliases_owner on transaction_tag_transaction_aliases for all to public using(profile_id=pandapay.uid()) with check(profile_id=pandapay.uid());

alter type budget_scope add value if not exists 'tag';
