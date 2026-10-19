alter table transactions
  add column if not exists user_category_id uuid references user_categories(id) on delete set null;

create index if not exists idx_transactions_user_category
  on transactions(profile_id, user_category_id, occurred_at desc)
  where status = 'active';

alter table transaction_splits
  add column if not exists user_category_id uuid references user_categories(id) on delete set null;
