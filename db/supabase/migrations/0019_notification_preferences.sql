-- >>> MIGRATION 0019 — NOTIFICATION PREFERENCES (Group H, Task H3) ============
-- H3 Notification Settings. Per docs/superpowers/plans/
-- 2026-08-07-group-h-settings-and-group-a-completion.md's own audit: no
-- per-user notification preference storage exists anywhere in the schema —
-- remote_config only carries global defaults (notification_daily_cap,
-- geofence_notifications), not a per-profile row. This is the one genuine
-- schema gap that plan found; everything else it needed already existed.

create table notification_preferences (
  profile_id              uuid primary key references profiles(id) on delete cascade,
  -- Conservative defaults per the spec's own mandate: location and the
  -- monthly report are opt-in (off), everything actionable-to-the-user's-
  -- money is on by default, mirroring 0014_seed_reference.sql's existing
  -- geofence_notifications=false seed.
  category_location       boolean not null default false,
  category_caps           boolean not null default true,
  category_milestones     boolean not null default true,
  category_fee_waivers    boolean not null default true,
  category_bills          boolean not null default true,
  category_expiry         boolean not null default true,
  category_monthly_report boolean not null default false,
  category_needs_review   boolean not null default true,
  quiet_hours_start       time,                 -- null = no quiet hours set
  quiet_hours_end         time,
  daily_cap               int not null default 3 check (daily_cap between 0 and 20),
  updated_at              timestamptz not null default now()
);
create trigger trg_notification_preferences_touch before update on notification_preferences
  for each row execute function pandapay.touch_updated_at();

create table notification_muted_merchants (
  profile_id          uuid not null references profiles(id) on delete cascade,
  merchant_id         uuid not null references merchants(id) on delete cascade,
  muted_at            timestamptz not null default now(),
  primary key (profile_id, merchant_id)
);

alter table notification_preferences enable row level security;
alter table notification_preferences force row level security;
create policy notification_preferences_owner on notification_preferences
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

alter table notification_muted_merchants enable row level security;
alter table notification_muted_merchants force row level security;
create policy notification_muted_merchants_owner on notification_muted_merchants
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
