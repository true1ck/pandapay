begin;

create table if not exists public.sms_category_rule_approvals (
  merchant_key text primary key,
  category_slug text not null,
  status text not null check (status in ('approved', 'rejected')),
  reviewed_by uuid not null references public.profiles(id),
  reviewed_at timestamptz not null default now(),
  reason text not null,
  support_count_at_review integer not null,
  agreement_rate_at_review numeric not null,
  check (support_count_at_review >= 10),
  check (agreement_rate_at_review >= 0.90)
);

create table if not exists public.sms_parser_candidate_approvals (
  candidate_id text primary key references public.sms_rule_candidates(candidate_id) on delete cascade,
  status text not null check (status in ('approved', 'rejected')),
  reviewed_by uuid not null references public.profiles(id),
  reviewed_at timestamptz not null default now(),
  reason text not null,
  rule_sha256 text not null check (rule_sha256 ~ '^[0-9a-f]{64}$')
);
alter table public.sms_parser_candidate_approvals enable row level security;
alter table public.sms_parser_candidate_approvals force row level security;
grant select, insert, update on public.sms_parser_candidate_approvals to app_user;
create policy sms_parser_candidate_approvals_admin on public.sms_parser_candidate_approvals
  for all to app_user using (pandapay.is_admin()) with check (pandapay.is_admin());
create policy sms_parser_candidate_approvals_device_read on public.sms_parser_candidate_approvals
  for select to app_user using (status = 'approved');

alter table public.sms_category_rule_approvals enable row level security;
alter table public.sms_category_rule_approvals force row level security;
revoke all on public.sms_category_rule_approvals from public, app_user;
grant select, insert, update on public.sms_category_rule_approvals to app_user;
create policy sms_category_rule_approvals_admin on public.sms_category_rule_approvals
  for all to app_user
  using (pandapay.is_admin())
  with check (pandapay.is_admin());

-- Devices receive only mappings that an admin reviewed. A later change in the
-- leading category, or loss of consent/support, removes the rule immediately.
create or replace function pandapay.sms_approved_category_rules()
returns table (
  merchant_key text,
  category_slug text,
  support_count integer,
  agreement_rate numeric
)
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  select c.merchant_key, c.category_slug, c.support_count, c.agreement_rate
    from pandapay.sms_shared_category_rules() c
    join public.sms_category_rule_approvals a
      on a.merchant_key = c.merchant_key
     and a.category_slug = c.category_slug
     and a.status = 'approved'
   order by c.merchant_key, c.category_slug;
$function$;

revoke all on function pandapay.sms_approved_category_rules() from public;
grant execute on function pandapay.sms_approved_category_rules() to app_user;

commit;
