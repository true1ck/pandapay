alter table notification_preferences
  add column if not exists category_transactions boolean not null default true;
