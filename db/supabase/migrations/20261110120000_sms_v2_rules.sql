-- SMS pipeline v2 / WP-09: rule service tables.
-- Rule tables are admin-only (pandapay.is_admin()). Phones never read them
-- directly: they go through the security-definer functions at the bottom.

create table sms_v2_rules (
  rule_id     text        not null,
  version     integer     not null check (version >= 1),
  status      text        not null check (status in ('draft','active','provisional','paused','retired')),
  family      text        not null,
  senders     text[]      not null default '{}',
  body        jsonb       not null,
  created_by  text        not null,
  created_at  timestamptz not null default now(),
  primary key (rule_id, version)
);

create table sms_v2_rule_cohorts (
  rule_id      text        not null,
  version      integer     not null,
  cohort       text        not null check (cohort in ('testers','pct5','pct25','all')),
  started_at   timestamptz not null default now(),
  paused_at    timestamptz,
  pause_reason text,
  primary key (rule_id, version, cohort),
  foreign key (rule_id, version) references sms_v2_rules (rule_id, version)
);

create table sms_v2_bundles (
  bundle_version integer     primary key,
  manifest       jsonb       not null,
  sha256         text        not null,
  signature      text        not null,
  key_id         text        not null,
  cohort         text        not null check (cohort in ('testers','pct5','pct25','all')),
  golden_report  jsonb,
  status         text        not null check (status in ('active','superseded','rolled_back')),
  published_by   text,
  created_at     timestamptz not null default now(),
  body           jsonb       not null  -- unsigned bundle content at mint time
);
create index sms_v2_bundles_cohort_active_idx on sms_v2_bundles (cohort) where status = 'active';

-- Non-rule bundle content (senders, ignore/link/category rules, ...) imported
-- from the CLI build output. One row per bundle part.
create table sms_v2_bundle_parts (
  part       text        primary key,
  body       jsonb       not null,
  updated_at timestamptz not null default now()
);

create table sms_v2_testers (
  profile_id uuid primary key references profiles (id) on delete cascade
);

create table sms_v2_rule_stats_daily (
  day          date    not null,
  rule_id      text    not null,
  rule_version integer not null,
  app_version  text    not null,
  hits         bigint  not null default 0,
  to_review    bigint  not null default 0,
  corrected    bigint  not null default 0,
  devices      integer not null default 0,
  primary key (day, rule_id, rule_version, app_version)
);

-- Profile-level counters, kept 48 hours and then rolled up.
create table sms_v2_rule_stats_profile_daily (
  day          date    not null,
  profile_id   uuid    not null,
  rule_id      text    not null,
  rule_version integer not null,
  app_version  text    not null,
  hits         bigint  not null default 0,
  to_review    bigint  not null default 0,
  corrected    bigint  not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (day, profile_id, rule_id, rule_version, app_version)
);

do $$
declare t text;
begin
  foreach t in array array[
    'sms_v2_rules','sms_v2_rule_cohorts','sms_v2_bundles','sms_v2_bundle_parts',
    'sms_v2_testers','sms_v2_rule_stats_daily','sms_v2_rule_stats_profile_daily'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('create policy %1$s_admin_only on %1$I for all to public using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;

-- Phone-facing access ------------------------------------------------------

create or replace function pandapay.sms_v2_is_tester() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from sms_v2_testers t where t.profile_id = pandapay.uid());
$$;

create or replace function pandapay.sms_v2_latest_bundle(p_cohort text)
returns table (bundle_version integer, body jsonb, sha256 text)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.bundle_version, b.body, b.sha256
    from sms_v2_bundles b
   where b.cohort = p_cohort and b.status = 'active'
   order by b.bundle_version desc
   limit 1;
$$;

-- Stats are written only through this function; the profile is always the caller.
create or replace function pandapay.sms_v2_record_rule_stats(p_day date, p_app_version text, p_stats jsonb)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  if pandapay.uid() is null then raise exception 'not authenticated'; end if;
  -- Only days still inside the 48 hour retention window are accepted.
  if p_day < (now() at time zone 'utc')::date - 2 or p_day > (now() at time zone 'utc')::date + 1 then
    return 0;
  end if;
  insert into sms_v2_rule_stats_profile_daily
    (day, profile_id, rule_id, rule_version, app_version, hits, to_review, corrected, updated_at)
  select p_day, pandapay.uid(), s.rule_id, s.rule_version, p_app_version,
         s.hits, s.to_review, s.corrected, now()
    from jsonb_to_recordset(p_stats) as s(rule_id text, rule_version integer, hits bigint, to_review bigint, corrected bigint)
  on conflict (day, profile_id, rule_id, rule_version, app_version) do update
     set hits = excluded.hits, to_review = excluded.to_review,
         corrected = excluded.corrected, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Folds profile rows into the daily table (distinct profiles = devices) and
-- deletes profile rows older than 48 hours. Run hourly by the rule jobs.
create or replace function pandapay.sms_v2_rollup_rule_stats() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  if not pandapay.is_admin() then raise exception 'admin only'; end if;
  insert into sms_v2_rule_stats_daily (day, rule_id, rule_version, app_version, hits, to_review, corrected, devices)
  select day, rule_id, rule_version, app_version,
         sum(hits), sum(to_review), sum(corrected), count(distinct profile_id)
    from sms_v2_rule_stats_profile_daily
   group by day, rule_id, rule_version, app_version
  on conflict (day, rule_id, rule_version, app_version) do update
     set hits = excluded.hits, to_review = excluded.to_review,
         corrected = excluded.corrected, devices = excluded.devices;
  get diagnostics n = row_count;
  delete from sms_v2_rule_stats_profile_daily where day < (now() at time zone 'utc')::date - 2;
  return n;
end $$;

revoke all on function pandapay.sms_v2_is_tester() from public;
revoke all on function pandapay.sms_v2_latest_bundle(text) from public;
revoke all on function pandapay.sms_v2_record_rule_stats(date, text, jsonb) from public;
revoke all on function pandapay.sms_v2_rollup_rule_stats() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'app_user') then
    -- Table access is still gated by the admin-only RLS policies above.
    grant select, insert, update, delete on sms_v2_rules, sms_v2_rule_cohorts, sms_v2_bundles,
      sms_v2_bundle_parts, sms_v2_testers, sms_v2_rule_stats_daily, sms_v2_rule_stats_profile_daily to app_user;
    grant execute on function pandapay.sms_v2_is_tester() to app_user;
    grant execute on function pandapay.sms_v2_latest_bundle(text) to app_user;
    grant execute on function pandapay.sms_v2_record_rule_stats(date, text, jsonb) to app_user;
    grant execute on function pandapay.sms_v2_rollup_rule_stats() to app_user;  -- checks is_admin() itself
  end if;
  if exists (select 1 from pg_roles where rolname = 'pandapay_admin_api') then
    grant execute on function pandapay.sms_v2_rollup_rule_stats() to pandapay_admin_api;
  end if;
end $$;
