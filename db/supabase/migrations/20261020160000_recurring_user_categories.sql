-- Keep recurring/subscription records connected to a user's private
-- category taxonomy. The built-in category remains on category_id for
-- reward/report compatibility; user_category_id preserves the optional
-- private category or subcategory chosen by the user/import resolver.
alter table recurring_series
  add column if not exists user_category_id uuid references user_categories(id) on delete set null;

create index if not exists idx_recurring_series_user_category
  on recurring_series (profile_id, user_category_id);
