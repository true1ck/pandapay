begin;

-- One row per candidate/user/source/stage. The unique key makes retries from
-- the inbox listener, first-install scan, and sync converge to one exposure.
create table if not exists public.sms_rule_candidate_exposures (
  candidate_id text not null references public.sms_rule_candidates(candidate_id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  source_key text not null check (source_key ~ '^[0-9a-f]{64}$'),
  stage text not null check (stage in ('shadow', 'limited', 'expanded', 'active')),
  stage_version integer not null default 1 check (stage_version > 0),
  assignment_id uuid,
  assigned boolean not null default true,
  matched boolean not null default false,
  applied boolean not null default false,
  outcome text not null default 'unresolved' check (outcome in ('accepted', 'review', 'ignored', 'unresolved')),
  delta_outcome text,
  baseline_family text,
  candidate_family text,
  baseline_disposition text,
  candidate_disposition text,
  exact_fields_equal boolean,
  fact_valid boolean,
  invariant_breach boolean not null default false,
  correction boolean not null default false,
  false_discard boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (candidate_id, profile_id, source_key, stage, stage_version)
);

-- The table may already exist on databases that applied the first cohort
-- migration before stage epochs were introduced.  Make the upgrade explicit
-- so the new epoch is part of the identity instead of silently retaining the
-- old four-column primary key.
alter table public.sms_rule_candidate_exposures
  add column if not exists stage_version integer not null default 1;
alter table public.sms_rule_candidate_exposures
  add column if not exists assignment_id uuid;
alter table public.sms_rule_candidate_exposures
  add column if not exists delta_outcome text;
alter table public.sms_rule_candidate_exposures
  add column if not exists baseline_family text;
alter table public.sms_rule_candidate_exposures
  add column if not exists candidate_family text;
alter table public.sms_rule_candidate_exposures
  add column if not exists baseline_disposition text;
alter table public.sms_rule_candidate_exposures
  add column if not exists candidate_disposition text;
alter table public.sms_rule_candidate_exposures
  add column if not exists exact_fields_equal boolean;
alter table public.sms_rule_candidate_exposures
  add column if not exists fact_valid boolean;
alter table public.sms_rule_candidate_exposures
  add column if not exists invariant_breach boolean not null default false;
alter table public.sms_rule_candidate_exposures
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.sms_rule_candidate_exposures'::regclass
       and conname = 'sms_rule_candidate_exposures_stage_version_check'
  ) then
    alter table public.sms_rule_candidate_exposures
      add constraint sms_rule_candidate_exposures_stage_version_check
      check (stage_version > 0);
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.sms_rule_candidate_exposures'::regclass
       and conname = 'sms_rule_candidate_exposures_delta_outcome_check'
  ) then
    alter table public.sms_rule_candidate_exposures
      add constraint sms_rule_candidate_exposures_delta_outcome_check
      check (delta_outcome is null or delta_outcome in (
        'unresolved', 'agreement_unresolved', 'candidate_miss', 'candidate_extra_financial',
        'agreement', 'wrong_family', 'disposition_mismatch', 'field_mismatch', 'wrong_amount', 'wrong_date',
        'invalid_fact', 'duplicate_risk', 'projection_mismatch',
        'candidate_worse', 'baseline_better', 'regression', 'same', 'improved', 'regressed', 'unknown'
      ));
  end if;
end $$;

do $$
begin
  if exists (
    select 1 from pg_constraint
     where conrelid = 'public.sms_rule_candidate_exposures'::regclass
       and conname = 'sms_rule_candidate_exposures_pkey'
  ) then
    alter table public.sms_rule_candidate_exposures
      drop constraint sms_rule_candidate_exposures_pkey;
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.sms_rule_candidate_exposures'::regclass
       and conname = 'sms_rule_candidate_exposures_pkey'
  ) then
    alter table public.sms_rule_candidate_exposures
      add constraint sms_rule_candidate_exposures_pkey
      primary key (candidate_id, profile_id, source_key, stage, stage_version);
  end if;
end $$;

-- A stage assignment is issued to one profile and remains verifiable after
-- the candidate advances. This allows delayed offline events to be accepted
-- without trusting a client-supplied historical stage.
create table if not exists public.sms_rule_candidate_assignments (
  assignment_id uuid primary key default gen_random_uuid(),
  candidate_id text not null references public.sms_rule_candidates(candidate_id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  stage text not null check (stage in ('shadow', 'limited', 'expanded', 'active')),
  stage_version integer not null check (stage_version > 0),
  mode text not null check (mode in ('shadow', 'apply')),
  bundle_version integer,
  min_client_version text not null default '1.0.0',
  rule_sha256 text not null check (rule_sha256 ~ '^[0-9a-f]{64}$'),
  issued_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  unique (candidate_id, profile_id, stage_version)
);

create index if not exists idx_sms_rule_candidate_assignments_profile
  on public.sms_rule_candidate_assignments(profile_id, issued_at desc);
create index if not exists idx_sms_rule_candidate_assignments_candidate
  on public.sms_rule_candidate_assignments(candidate_id, stage_version, revoked_at);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.sms_rule_candidate_exposures'::regclass
       and conname = 'sms_rule_candidate_exposures_assignment_fk'
  ) then
    alter table public.sms_rule_candidate_exposures
      add constraint sms_rule_candidate_exposures_assignment_fk
      foreign key (assignment_id) references public.sms_rule_candidate_assignments(assignment_id)
      on delete set null;
  end if;
end $$;

create unique index if not exists uq_sms_rule_candidate_exposure_assignment_source
  on public.sms_rule_candidate_exposures(assignment_id, source_key)
  where assignment_id is not null;

create index if not exists idx_sms_rule_candidate_exposure_metrics
  on public.sms_rule_candidate_exposures(candidate_id, stage, created_at desc);
create index if not exists idx_sms_rule_candidate_exposure_source
  on public.sms_rule_candidate_exposures(profile_id, source_key);

alter table public.sms_rule_candidate_exposures enable row level security;
alter table public.sms_rule_candidate_exposures force row level security;

alter table public.sms_rule_candidate_assignments enable row level security;
alter table public.sms_rule_candidate_assignments force row level security;

drop policy if exists sms_rule_candidate_exposures_service on public.sms_rule_candidate_exposures;
create policy sms_rule_candidate_exposures_service on public.sms_rule_candidate_exposures
  for all to public
  using (current_user in ('service_role', 'postgres') or pandapay.is_admin()
         or (pandapay.uid() is not null and profile_id = pandapay.uid()
             and exists (select 1 from public.profiles p
                           where p.id = pandapay.uid() and p.contributions_opt_in)))
  with check (current_user in ('service_role', 'postgres') or pandapay.is_admin()
         or (pandapay.uid() is not null and profile_id = pandapay.uid()
             and exists (select 1 from public.profiles p
                           where p.id = pandapay.uid() and p.contributions_opt_in)));

drop policy if exists sms_rule_candidate_assignments_owner on public.sms_rule_candidate_assignments;
create policy sms_rule_candidate_assignments_owner on public.sms_rule_candidate_assignments
  for all to public
  using (current_user in ('service_role', 'postgres') or pandapay.is_admin()
         or (pandapay.uid() is not null and profile_id = pandapay.uid()))
  with check (current_user in ('service_role', 'postgres') or pandapay.is_admin()
         or (pandapay.uid() is not null and profile_id = pandapay.uid()
             and exists (select 1 from public.profiles p
                           where p.id = pandapay.uid() and p.contributions_opt_in)));

revoke all on public.sms_rule_candidate_exposures from public;
grant select, insert, update on public.sms_rule_candidate_exposures to app_user;
revoke all on public.sms_rule_candidate_assignments from public;
grant select, insert, update on public.sms_rule_candidate_assignments to app_user;

-- Candidates are safe, compiled rule metadata. Devices may read only rules
-- that are in delivery stages; proposed/evaluated/paused evidence remains
-- worker/admin-only.
drop policy if exists sms_rule_candidates_delivery_read on public.sms_rule_candidates;
create policy sms_rule_candidates_delivery_read on public.sms_rule_candidates
  for select to app_user
  using (state in ('shadow', 'limited', 'expanded', 'active'));

-- New candidate revisions can advertise a minimum app version without
-- changing the original candidate table definition on older databases.
alter table public.sms_rule_candidates
  add column if not exists min_client_ver text not null default '1.0.0';

-- Every stage transition gets a monotonically increasing epoch.  Devices send
-- the epoch they were assigned, so delayed offline telemetry remains tied to
-- the exact rule revision that produced it.
alter table public.sms_rule_candidates
  add column if not exists stage_version integer not null default 1;
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.sms_rule_candidates'::regclass
       and conname = 'sms_rule_candidates_stage_version_check'
  ) then
    alter table public.sms_rule_candidates
      add constraint sms_rule_candidates_stage_version_check
      check (stage_version > 0);
  end if;
end $$;

commit;
