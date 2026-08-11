-- >>> MIGRATION 0024 — NOTIFICATION INBOX ====================================
--
-- Design 19 is an inbox: a reverse-chronological list of things that already
-- happened, grouped Today / Earlier, each individually read or unread.
--
-- notification_preferences (0019) says which categories a user *wants* to be
-- told about, and notification_muted_merchants which ones to stay quiet on,
-- but nothing in the schema ever recorded that a notification was actually
-- delivered — so there was no inbox to read, only settings for one. This is
-- that missing table.
--
-- `category` deliberately reuses the same vocabulary as
-- notification_preferences' own `category_*` columns so a delivery can be
-- checked against the user's stated preference by name rather than by a
-- second mapping table.
--
-- `dedupe_key` makes delivery idempotent: a nightly job that re-evaluates
-- "SBI Cashback is due in 4 days" every run should update the existing row,
-- not stack four copies of it in the inbox.

create table if not exists notifications (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references profiles(id) on delete cascade,
  category      text not null check (category in (
                  'location', 'caps', 'milestones', 'fee_waivers',
                  'bills', 'expiry', 'monthly_report', 'needs_review',
                  'streak', 'card_added'
                )),
  severity      text not null default 'info' check (severity in ('info', 'good', 'urgent')),
  title         text not null,
  body          text,
  -- Where tapping it should land, as an in-app route path. Null means the
  -- notification is purely informational and taps do nothing, which the UI
  -- renders without a chevron rather than as a dead tap target.
  deep_link     text,
  dedupe_key    text,
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

create unique index if not exists notifications_dedupe
  on notifications (profile_id, dedupe_key) where dedupe_key is not null;

create index if not exists idx_notifications_profile_created
  on notifications (profile_id, created_at desc);

-- Unread badge counts hit this constantly; a partial index keeps that a
-- lookup rather than a scan of the user's whole history.
create index if not exists idx_notifications_unread
  on notifications (profile_id) where read_at is null;

alter table notifications enable row level security;

-- Same owner-only shape as every other per-user table in 0011, via that
-- migration's own pandapay.uid() helper rather than reading the session
-- GUC directly — the GUC is named `app.user_id`, and hand-rolling the
-- current_setting() call here is exactly how that name gets typo'd into a
-- policy that silently matches nothing.
drop policy if exists notifications_owner on notifications;
create policy notifications_owner on notifications
  for all
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

grant select, insert, update, delete on notifications to app_user;
