-- Invite-only admission, immutable referral attribution and campaign ledger.
-- No campaign is activated here. New behavior ships in open-access mode with
-- enrollment, fulfillment and redemption disabled until an operator creates
-- an approved campaign version and deliberately changes the switches.

do $$
declare
  v_can_login boolean;
  v_is_superuser boolean;
  v_bypass_rls boolean;
begin
  if not exists (select 1 from pg_roles where rolname = 'promotions_owner') then
    create role promotions_owner nologin nosuperuser nobypassrls;
  end if;
  select rolcanlogin, rolsuper, rolbypassrls
    into v_can_login, v_is_superuser, v_bypass_rls
    from pg_roles where rolname = 'promotions_owner';
  if v_can_login or v_is_superuser or v_bypass_rls then
    raise exception 'promotions_owner must remain NOLOGIN, NOSUPERUSER and NOBYPASSRLS';
  end if;
end
$$;

create schema if not exists promotions authorization promotions_owner;
alter schema promotions owner to promotions_owner;
grant usage on schema public, pandapay to promotions_owner;
grant select, insert, update on public.profiles to promotions_owner;
grant select, insert, update on public.referral_codes to promotions_owner;
grant select, insert, update on public.referrals to promotions_owner;
grant select, insert on public.user_consents to promotions_owner;
grant usage, select on all sequences in schema public to promotions_owner;

set role promotions_owner;

create table promotions.access_settings (
  singleton boolean primary key default true check (singleton),
  admission_mode text not null default 'open'
    check (admission_mode in ('open', 'invite_only', 'paused_new')),
  minimum_client_capability text,
  active_campaign_version text,
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now()
);

insert into promotions.access_settings (singleton, admission_mode)
values (true, 'open')
on conflict (singleton) do nothing;

create table promotions.campaign_versions (
  version_key text primary key check (length(version_key) between 1 and 80),
  calendar_zone text not null check (calendar_zone = 'Asia/Kolkata'),
  required_consecutive_days smallint not null check (required_consecutive_days between 1 and 30),
  qualification_window_days smallint not null check (qualification_window_days between 1 and 180),
  receipt_lifetime_seconds smallint not null check (receipt_lifetime_seconds between 30 and 900),
  terms_version text not null check (length(terms_version) between 1 and 120),
  inviter_cap_enrollments integer check (inviter_cap_enrollments is null or inviter_cap_enrollments > 0),
  prize_distribution jsonb not null check (jsonb_typeof(prize_distribution) = 'object'),
  created_at timestamptz not null default now(),
  created_by uuid
);

create table promotions.campaign_state (
  version_key text primary key references promotions.campaign_versions(version_key) on delete restrict,
  enrollment_open boolean not null default false,
  fulfillment_paused boolean not null default true,
  redemption_paused boolean not null default true,
  platform_benefit_available boolean not null default false,
  total_budget_paise bigint not null default 0 check (total_budget_paise >= 0),
  issued_paise bigint not null default 0 check (issued_paise >= 0),
  reserved_paise bigint not null default 0 check (reserved_paise >= 0),
  enrollment_cap integer check (enrollment_cap is null or enrollment_cap >= 0),
  enrollment_count integer not null default 0 check (enrollment_count >= 0),
  updated_at timestamptz not null default now(),
  check (issued_paise + reserved_paise <= total_budget_paise)
);

alter table promotions.access_settings
  add constraint access_settings_campaign_version_fk
  foreign key (active_campaign_version) references promotions.campaign_versions(version_key)
  on delete restrict;

create table promotions.memberships (
  profile_id uuid primary key,
  state text not null check (state in ('active', 'suspended')),
  admission_source text not null
    check (admission_source in ('legacy', 'invite', 'open', 'operator')),
  activated_at timestamptz not null default now(),
  suspended_at timestamptz,
  suspension_reason text,
  created_at timestamptz not null default now(),
  check ((state = 'suspended') = (suspended_at is not null))
);

create table promotions.invitation_codes (
  code text primary key check (code = upper(code) and length(code) between 6 and 32),
  owner_profile_id uuid not null,
  active boolean not null default true,
  issued_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (active = (revoked_at is null))
);
create index invitation_codes_owner_idx
  on promotions.invitation_codes (owner_profile_id) where active;

create table promotions.referral_attributions (
  id uuid primary key default gen_random_uuid(),
  inviter_id uuid not null,
  referee_id uuid not null unique,
  invitation_code text not null references promotions.invitation_codes(code) on delete restrict,
  joined_at timestamptz not null default now(),
  campaign_version text references promotions.campaign_versions(version_key) on delete restrict,
  reward_eligible boolean not null default false,
  ineligible_reason text,
  deadline_at timestamptz,
  current_streak_days smallint not null default 0 check (current_streak_days >= 0),
  best_streak_days smallint not null default 0 check (best_streak_days >= 0),
  qualified_at timestamptz,
  disqualified_at timestamptz,
  disqualification_reason text,
  created_at timestamptz not null default now(),
  check (inviter_id <> referee_id),
  check (reward_eligible = (campaign_version is not null and deadline_at is not null)),
  check ((disqualified_at is null) = (disqualification_reason is null))
);
create index referral_attributions_inviter_joined_idx
  on promotions.referral_attributions (inviter_id, joined_at desc, id desc);
create index referral_attributions_referee_joined_idx
  on promotions.referral_attributions (referee_id, joined_at desc);

create table promotions.terms_acceptances (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null,
  purpose text not null check (purpose in ('product_terms', 'referral_terms')),
  policy_version text not null,
  granted_at timestamptz not null default now(),
  source text not null,
  unique (profile_id, purpose, policy_version)
);

create table promotions.inviter_campaign_caps (
  campaign_version text not null references promotions.campaign_versions(version_key) on delete restrict,
  inviter_id uuid not null,
  enrolled_count integer not null default 0 check (enrolled_count >= 0),
  primary key (campaign_version, inviter_id)
);

create table promotions.reward_reservations (
  id uuid primary key default gen_random_uuid(),
  attribution_id uuid not null references promotions.referral_attributions(id) on delete restrict,
  beneficiary_id uuid not null,
  beneficiary_role text not null check (beneficiary_role in ('inviter', 'referee')),
  campaign_version text not null references promotions.campaign_versions(version_key) on delete restrict,
  reserved_paise bigint not null check (reserved_paise >= 0),
  awarded_paise bigint check (awarded_paise is null or awarded_paise >= 0),
  state text not null default 'reserved' check (state in ('reserved', 'settled', 'released')),
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  unique (attribution_id, beneficiary_role),
  check ((state = 'reserved' and settled_at is null and awarded_paise is null)
      or (state = 'settled' and settled_at is not null and awarded_paise is not null)
      or (state = 'released' and settled_at is not null and awarded_paise is null))
);

create table promotions.engagement_days (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null,
  campaign_version text not null references promotions.campaign_versions(version_key) on delete restrict,
  local_date date not null,
  server_activity_at timestamptz not null,
  source_action text not null,
  receipt_id text not null unique,
  created_at timestamptz not null default now(),
  unique (profile_id, campaign_version, local_date)
);
create index engagement_days_profile_date_idx
  on promotions.engagement_days (profile_id, campaign_version, local_date);

create table promotions.reward_entitlements (
  id uuid primary key default gen_random_uuid(),
  attribution_id uuid not null references promotions.referral_attributions(id) on delete restrict,
  beneficiary_id uuid not null,
  beneficiary_role text not null check (beneficiary_role in ('inviter', 'referee')),
  campaign_version text not null references promotions.campaign_versions(version_key) on delete restrict,
  state text not null default 'ready'
    check (state in ('ready', 'claimed', 'held', 'revoked', 'expired')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (attribution_id, beneficiary_role),
  check ((state = 'claimed') = (claimed_at is not null))
);
create index reward_entitlements_owner_idx
  on promotions.reward_entitlements (beneficiary_id, created_at desc, id desc);

create table promotions.reward_spins (
  id uuid primary key default gen_random_uuid(),
  entitlement_id uuid not null unique references promotions.reward_entitlements(id) on delete restrict,
  beneficiary_id uuid not null,
  outcome_id text not null,
  amount_paise bigint not null check (amount_paise >= 0),
  campaign_version text not null references promotions.campaign_versions(version_key) on delete restrict,
  committed_at timestamptz not null default now()
);

create table promotions.credit_accounts (
  profile_id uuid primary key,
  currency text not null default 'INR' check (currency = 'INR'),
  available_paise bigint not null default 0 check (available_paise >= 0),
  reserved_paise bigint not null default 0 check (reserved_paise >= 0),
  version bigint not null default 0 check (version >= 0),
  updated_at timestamptz not null default now()
);

create table promotions.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null,
  event_type text not null
    check (event_type in ('award', 'reserve', 'release', 'redeem', 'expiry', 'reversal', 'adjustment')),
  available_delta_paise bigint not null default 0,
  reserved_delta_paise bigint not null default 0,
  source_type text not null,
  source_id uuid not null,
  idempotency_key text not null unique,
  actor_profile_id uuid,
  reason text,
  occurred_at timestamptz not null default now(),
  check (available_delta_paise <> 0 or reserved_delta_paise <> 0)
);
create index credit_ledger_owner_page_idx
  on promotions.credit_ledger (profile_id, occurred_at desc, id desc);

create table promotions.credit_redemptions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null,
  quote_id uuid not null,
  platform text not null check (platform in ('android', 'ios')),
  benefit_id text not null,
  credit_cost_paise bigint not null check (credit_cost_paise > 0),
  state text not null check (state in ('reserved', 'external_pending', 'committed', 'released', 'failed')),
  terms_snapshot jsonb not null,
  provider_transaction_id text,
  created_at timestamptz not null default now(),
  finalized_at timestamptz
);
create unique index credit_redemptions_provider_txn_unique
  on promotions.credit_redemptions (platform, provider_transaction_id)
  where provider_transaction_id is not null;

create table promotions.eligibility_claims (
  campaign_version text not null references promotions.campaign_versions(version_key) on delete restrict,
  identity_kind text not null check (identity_kind in ('email', 'phone')),
  fingerprint_key_version text not null,
  fingerprint text not null,
  profile_id uuid not null,
  retained_until timestamptz,
  created_at timestamptz not null default now(),
  primary key (campaign_version, identity_kind, fingerprint_key_version, fingerprint)
);

create table promotions.reward_outbox (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  event_type text not null,
  beneficiary_id uuid,
  payload jsonb not null default '{}'::jsonb,
  state text not null default 'pending' check (state in ('pending', 'leased', 'delivered', 'dead')),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default now(),
  lease_until timestamptz,
  delivered_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now()
);
create index reward_outbox_pending_idx
  on promotions.reward_outbox (available_at, created_at)
  where state in ('pending', 'leased');

-- The API role receives no table privileges. SECURITY DEFINER routines are
-- the only path to these records and always bind user operations to uid().
do $$
declare t text;
begin
  foreach t in array array[
    'access_settings','campaign_versions','campaign_state','memberships',
    'invitation_codes','referral_attributions','terms_acceptances',
    'inviter_campaign_caps','reward_reservations','engagement_days',
    'reward_entitlements','reward_spins','credit_accounts','credit_ledger',
    'credit_redemptions','eligibility_claims','reward_outbox'
  ] loop
    execute format('alter table promotions.%I enable row level security', t);
    execute format('alter table promotions.%I force row level security', t);
    execute format(
      'create policy promotions_owner_all on promotions.%I for all to promotions_owner using (true) with check (true)',
      t
    );
  end loop;
end
$$;

reset role;

-- Keep existing codes usable. Run the copy with the migration role so the
-- legacy owner-only RLS policy does not hide other people's codes. Legacy
-- referral rows themselves are intentionally not copied or funded.
insert into promotions.invitation_codes (code, owner_profile_id)
select upper(code), profile_id
  from public.referral_codes
 where length(code) between 6 and 32
on conflict (code) do nothing;

-- SECURITY DEFINER reads of legacy product rows are constrained to the
-- request's uid except the safe referral projection, whose owner role only
-- receives SELECT access to friend display names and referral records.
drop policy if exists profiles_promotions_service_read on public.profiles;
create policy profiles_promotions_service_read on public.profiles
  for select to promotions_owner using (true);
drop policy if exists referrals_promotions_service on public.referrals;
create policy referrals_promotions_service on public.referrals
  for all to promotions_owner using (true) with check (true);
drop policy if exists referral_codes_promotions_service on public.referral_codes;
create policy referral_codes_promotions_service on public.referral_codes
  for all to promotions_owner using (true) with check (true);

alter default privileges for role promotions_owner in schema promotions
  revoke all on tables from public;
alter default privileges for role promotions_owner in schema promotions
  revoke execute on functions from public;

comment on schema promotions is
  'Invite admission, referral qualification and subscription-credit ledger. app_user has no direct table access.';
comment on table promotions.referral_attributions is
  'Immutable first successful product activation attribution; legacy qualified rows are not copied or funded.';
comment on table promotions.credit_ledger is
  'Append-only integer-paise accounting; never use the separate card points ledger for these credits.';

-- Make the restriction effective immediately after this migration as well as
-- after the repository's role setup script is rerun by local/production jobs.
revoke insert, update, delete on table public.profiles from app_user;
grant update (contributions_opt_in, deletion_requested_at, deletion_due_at)
  on table public.profiles to app_user;
revoke insert, update, delete on table public.referral_codes from app_user;
grant select on table public.referral_codes to app_user;
revoke insert, update, delete on table public.referrals from app_user;
grant select on table public.referrals to app_user;
revoke insert, update, delete on table public.referral_program from app_user;
grant select on table public.referral_program to app_user;
