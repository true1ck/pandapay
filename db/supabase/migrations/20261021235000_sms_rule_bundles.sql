-- Versioned rule bundle store for restricted, evaluated, cross-platform
-- regex rules executed on mobile devices.
begin;

create table if not exists public.sms_rule_bundles (
  bundle_version    integer primary key,
  rules             jsonb not null,
  sha256            text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  published_at      timestamptz not null default now(),
  published_by      uuid references public.profiles(id),
  is_active         boolean not null default true,
  min_client_ver    text not null default '1.0.0'
);

comment on table public.sms_rule_bundles is
  'Versioned, evaluated rule bundles containing restricted, cross-platform regex rules for device execution.';

alter table public.sms_rule_bundles enable row level security;
alter table public.sms_rule_bundles force row level security;

-- Authenticated users (app_user) can read active bundles
drop policy if exists sms_rule_bundles_read on public.sms_rule_bundles;
create policy sms_rule_bundles_read on public.sms_rule_bundles
  for select to public
  using (is_active = true or pandapay.is_admin());

-- Only admins can insert or update bundles
drop policy if exists sms_rule_bundles_admin_write on public.sms_rule_bundles;
create policy sms_rule_bundles_admin_write on public.sms_rule_bundles
  for all to public
  using (pandapay.is_admin())
  with check (pandapay.is_admin());

revoke all on public.sms_rule_bundles from public;
grant select, insert, update on public.sms_rule_bundles to app_user;

commit;
