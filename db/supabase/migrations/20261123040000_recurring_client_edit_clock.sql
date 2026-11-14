-- WP-S4: the device's edit time for a subscription, so a replayed older
-- edit cannot clobber a newer one. NULL = no client clock supplied.
alter table public.recurring_series add column if not exists client_edited_at timestamptz;
