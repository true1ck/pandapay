alter table recurring_series
  add column if not exists user_edited boolean not null default false;
