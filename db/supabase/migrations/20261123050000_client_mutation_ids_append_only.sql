-- WP-S5: client-generated mutation ids make append-only inserts idempotent.
-- NULL (old clients) is exempt from the partial unique index, so behaviour
-- without an id is unchanged.
alter table public.notifications add column if not exists client_mutation_id uuid;
alter table public.user_consents add column if not exists client_mutation_id uuid;
alter table public.sms_import_batches add column if not exists client_mutation_id uuid;

create unique index if not exists idx_notifications_client_mutation
  on public.notifications (profile_id, client_mutation_id) where client_mutation_id is not null;
create unique index if not exists idx_user_consents_client_mutation
  on public.user_consents (profile_id, client_mutation_id) where client_mutation_id is not null;
create unique index if not exists idx_sms_import_batches_client_mutation
  on public.sms_import_batches (profile_id, client_mutation_id) where client_mutation_id is not null;
