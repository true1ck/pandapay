-- Phase 4 (Candidate Synthesis & Scores) & Phase 5 (Autonomous Promotion & Rollback Worker)
-- Database schemas and security definer functions for autonomous SMS rule learning.

begin;

create table if not exists public.sms_learning_examples (
  id                 uuid primary key default gen_random_uuid(),
  sender_fingerprint text not null check (sender_fingerprint ~ '^[0-9a-f]{64}$'),
  issuer_prefix      text,
  fact_family        text not null check (fact_family in (
    'posted_movement', 'pending_or_failed_attempt', 'balance_snapshot',
    'bill_obligation', 'bill_payment', 'mandate_lifecycle',
    'card_identity_hint', 'security_or_service_alert', 'promotion'
  )),
  template_text      text not null,
  sample_body        text not null,
  extracted_fields   jsonb not null default '{}'::jsonb,
  is_negative        boolean not null default false,
  negative_reason    text,
  user_hash          text not null check (user_hash ~ '^[0-9a-f]{64}$'),
  created_at         timestamptz not null default now()
);

comment on table public.sms_learning_examples is
  'Collected training examples and hard negatives for autonomous SMS rule learning.';

create index if not exists idx_sms_learning_examples_cluster
  on public.sms_learning_examples (sender_fingerprint, fact_family, is_negative, created_at desc);

create index if not exists idx_sms_learning_examples_user
  on public.sms_learning_examples (user_hash);

create table if not exists public.sms_rule_candidates (
  candidate_id       text primary key,
  family             text not null check (family in (
    'posted_movement', 'balance_snapshot', 'bill_obligation', 'mandate_lifecycle', 'ignore_noise'
  )),
  issuer             text not null,
  sender_pattern     text not null,
  template           text not null,
  compiled_regex     text not null,
  field_map          jsonb not null,
  default_fields     jsonb not null default '{}'::jsonb,
  confidence         double precision not null default 0.98,
  state              text not null check (state in (
    'proposed', 'evaluated', 'shadow', 'limited', 'expanded', 'active', 'rejected', 'paused', 'rolled_back'
  )),
  stage_metrics      jsonb not null default '{}'::jsonb,
  bundle_version     integer references public.sms_rule_bundles(bundle_version),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.sms_rule_candidates is
  'Synthesized regex candidates advancing through autonomous evaluation and canary stages.';

create index if not exists idx_sms_rule_candidates_state
  on public.sms_rule_candidates (state, created_at desc);

create index if not exists idx_sms_rule_candidates_bundle
  on public.sms_rule_candidates (bundle_version);

-- Enable & force RLS
alter table public.sms_learning_examples enable row level security;
alter table public.sms_learning_examples force row level security;

alter table public.sms_rule_candidates enable row level security;
alter table public.sms_rule_candidates force row level security;

-- Policies for sms_learning_examples
drop policy if exists sms_learning_examples_read on public.sms_learning_examples;
create policy sms_learning_examples_read on public.sms_learning_examples
  for select to public
  using (true);

drop policy if exists sms_learning_examples_insert on public.sms_learning_examples;
create policy sms_learning_examples_insert on public.sms_learning_examples
  for insert to public
  with check (true);

-- Policies for sms_rule_candidates
drop policy if exists sms_rule_candidates_policy on public.sms_rule_candidates;
create policy sms_rule_candidates_policy on public.sms_rule_candidates
  for all to public
  using (true)
  with check (true);

-- Security Definer Functions
create or replace function pandapay.sms_publish_bundle(
  p_bundle_version integer,
  p_rules jsonb,
  p_sha256 text,
  p_min_client_ver text default '1.0.0'
) returns boolean
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare
  v_inserted integer;
begin
  if p_bundle_version is null or p_bundle_version < 1 then
    raise exception 'invalid bundle_version';
  end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then
    raise exception 'rules must be a jsonb array';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid sha256';
  end if;

  insert into public.sms_rule_bundles
    (bundle_version, rules, sha256, is_active, min_client_ver)
  values
    (p_bundle_version, p_rules, p_sha256, true, coalesce(p_min_client_ver, '1.0.0'))
  on conflict (bundle_version) do nothing
  returning bundle_version into v_inserted;

  return v_inserted is not null;
end;
$$;

create or replace function pandapay.sms_rollback_bundle(
  p_bundle_version integer
) returns boolean
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare
  v_updated integer;
begin
  if p_bundle_version is null or p_bundle_version < 1 then
    raise exception 'invalid bundle_version';
  end if;

  update public.sms_rule_bundles
     set is_active = false
   where bundle_version = p_bundle_version
  returning bundle_version into v_updated;

  return v_updated is not null;
end;
$$;

-- Grants
revoke all on function pandapay.sms_publish_bundle(integer, jsonb, text, text) from public;
revoke all on function pandapay.sms_rollback_bundle(integer) from public;
grant execute on function pandapay.sms_publish_bundle(integer, jsonb, text, text) to app_user;
grant execute on function pandapay.sms_rollback_bundle(integer) to app_user;

grant select, insert, update on public.sms_rule_candidates to app_user;
grant select, insert on public.sms_learning_examples to app_user;
grant select on public.sms_rule_bundles to app_user;

commit;
