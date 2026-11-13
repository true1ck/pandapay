-- WP-S3: the device's edit time, so a replayed (older) budget write can never
-- override a newer one. NULL = written by a client that sends no edit clock.
alter table public.budgets add column if not exists client_edited_at timestamptz;
