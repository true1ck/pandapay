-- >>> MIGRATION 0032 — PRODUCT ANALYTICS =====================================
--
-- Plan Phase 2.2. The app has no analytics of any kind: no Firebase,
-- Amplitude, Mixpanel, PostHog or Segment in `app/pubspec.yaml`, no events
-- table in any migration, no screen-view or funnel instrumentation anywhere.
-- Today nobody can answer "how many users add a second card", "where does
-- onboarding drop off", or "did the recommendation engine change behaviour" —
-- which are the first three questions any investor, partner, or product
-- decision will need answered.
--
-- ============================================================================
-- WHY SELF-HOSTED RATHER THAN AN SDK
-- ============================================================================
-- Dropping in a vendor SDK would have been a fraction of this work. It is the
-- wrong call for this product specifically:
--
--   * Every mainstream mobile analytics SDK auto-collects an advertising or
--     vendor device id and ships it to a third-party processor abroad. For an
--     app holding someone's complete credit-card spending history, that is a
--     cross-border transfer of personal data under DPDP that would have to be
--     disclosed, justified, and consented to — for telemetry.
--   * The SDKs also auto-instrument screen names. In this app screen names
--     leak content ("Card detail — HDFC Millennia"), so the default
--     configuration is a data-flow nobody reviewed.
--   * Self-hosting keeps the data inside the same Postgres the anonymisation
--     gate already polices, and makes the event schema reviewable in the repo.
--
-- ============================================================================
-- WHAT IS AND IS NOT COLLECTED
-- ============================================================================
-- `profile_id` IS stored, and that is a deliberate, different choice from the
-- crowdsource tables in 0029. Retention/activation questions are inherently
-- about whether *the same person* came back, which a rotating pseudonym
-- cannot answer. So this is honest first-party product telemetry about a
-- signed-in user's use of the app they signed into — not the anonymous
-- dataset, and it lives under RLS and the erasure cascade accordingly.
--
-- What is structurally impossible to collect here, by design:
--
--   * No free-text. `props` is jsonb but the CHECK below caps its size, and
--     the client's event registry is a closed enum (see analytics.dart).
--   * No money amounts, merchant names, VPAs, or card product names. The
--     funnel needs to know THAT a card was added, never which one. Enforced
--     by the key allowlist below rather than by client discipline alone.
--   * No raw IP or user agent columns exist to write them into.

create table if not exists analytics_events (
  id                  bigserial primary key,
  profile_id          uuid references profiles(id) on delete cascade,
  -- Closed vocabulary, checked below. A typo'd event name is a funnel step
  -- that silently reports zero forever, which is worse than an error.
  event               text not null,
  props               jsonb not null default '{}'::jsonb,
  app_version         text,
  platform            text check (platform in ('android', 'ios', 'web', 'macos', 'other')),
  -- Coarse to the hour. Product questions are answered at day/week grain; a
  -- millisecond timestamp on "opened the app" is a movement log nobody needs.
  occurred_at         timestamptz not null default date_trunc('hour', now()),
  created_at          timestamptz not null default now(),

  constraint analytics_props_are_small check (pg_column_size(props) <= 2048)
);

-- Nullable profile_id: pre-sign-in funnel steps (app opened, onboarding
-- started) are exactly the ones you most need in order to measure activation,
-- and they happen before there is an account. Those rows are unattributed and
-- stay that way — they are never back-filled once the user signs up, because
-- doing so would retroactively attach pre-consent activity to an identity.

create index if not exists idx_analytics_event_time on analytics_events (event, occurred_at desc);
create index if not exists idx_analytics_profile on analytics_events (profile_id, occurred_at desc);

alter table analytics_events enable row level security;
alter table analytics_events force row level security;

-- Insert-only for the owner; readable only by an admin. A user cannot read
-- back their own event stream through this policy, and that is intentional:
-- the aggregate is a business artefact, and the DPDP access right is served
-- by `GET /export`, which is a considered export rather than a raw log dump.
drop policy if exists analytics_owner_insert on analytics_events;
create policy analytics_owner_insert on analytics_events
  for insert to public
  with check (profile_id = pandapay.uid());

drop policy if exists analytics_admin_read on analytics_events;
create policy analytics_admin_read on analytics_events
  for select to public
  using (pandapay.is_admin());

comment on table analytics_events is
  'First-party product telemetry (plan Phase 2.2). Deliberately NOT anonymous '
  'and deliberately not part of the crowdsource dataset: retention and '
  'activation are questions about whether the same person returned. No '
  'amounts, merchant names, or card names — see 0032''s header and the key '
  'allowlist in pandapay.record_analytics_event().';

-- ---------------------------------------------------------------------------
-- Ingest
-- ---------------------------------------------------------------------------
-- The event-name vocabulary. Adding a funnel step means adding it here AND to
-- the client registry, which is the point: an event that exists in only one of
-- the two places is a measurement nobody can interpret.
create or replace function pandapay.is_known_analytics_event(p_event text)
returns boolean language sql immutable as $$
  select p_event in (
    -- Activation funnel, in order.
    'app_opened',
    'onboarding_started',
    'onboarding_completed',
    'account_created',
    'first_card_added',
    'second_card_added',
    -- Core loop.
    'recommendation_viewed',
    'scan_started',
    'scan_completed',
    'transaction_logged',
    'comparison_viewed',
    -- Value-realisation moments worth measuring separately from the loop.
    'cap_warning_shown',
    'insight_viewed',
    'import_completed',
    -- Phase 2 features, so their adoption is answerable.
    'acceptance_report_submitted',
    'partner_apply_tapped',
    'guest_wallet_migrated',
    'device_revoked'
  );
$$;

-- The only `props` keys that may be stored. Everything else is dropped
-- silently rather than rejected: a newer client sending a key this build
-- doesn't know must not have its whole event discarded, and an older server
-- must never become the reason a rollout loses a week of funnel data.
--
-- Every allowed key is a bounded, low-cardinality dimension. None of them can
-- carry a merchant name, an amount, or a card product name — that is the
-- property being enforced, not merely requested.
create or replace function pandapay.filter_analytics_props(p_props jsonb)
returns jsonb language sql immutable as $$
  select coalesce(
    jsonb_object_agg(key, value) filter (
      where key in ('source', 'placement', 'step', 'result', 'count_bucket', 'surface')
        and jsonb_typeof(value) in ('string', 'number', 'boolean')
        and length(value::text) <= 64
    ),
    '{}'::jsonb)
  from jsonb_each(coalesce(p_props, '{}'::jsonb));
$$;

-- SECURITY DEFINER so a pre-sign-in event (profile_id null) can be recorded:
-- the owner-insert RLS policy requires `profile_id = pandapay.uid()`, which a
-- null profile can never satisfy, and those anonymous funnel rows are the ones
-- activation measurement most depends on.
create or replace function pandapay.record_analytics_event(
  p_profile     uuid,
  p_event       text,
  p_props       jsonb default '{}'::jsonb,
  p_app_version text default null,
  p_platform    text default null
) returns boolean language plpgsql security definer
set search_path = public, pandapay
as $$
begin
  if not pandapay.is_known_analytics_event(p_event) then
    return false;
  end if;

  insert into analytics_events (profile_id, event, props, app_version, platform)
       values (
         p_profile,
         p_event,
         pandapay.filter_analytics_props(p_props),
         p_app_version,
         case when p_platform in ('android','ios','web','macos') then p_platform else 'other' end
       );
  return true;
end $$;

grant execute on function pandapay.record_analytics_event(uuid, text, jsonb, text, text) to public;

-- ---------------------------------------------------------------------------
-- The questions this exists to answer (plan Phase 3.4's BI layer, in miniature)
-- ---------------------------------------------------------------------------
-- Admin-only through the underlying table's RLS. Deliberately a view rather
-- than a materialised one: at any plausible near-term event volume this is a
-- sub-second scan, and a stale funnel silently reporting last week's numbers
-- is a worse failure than a slow one.
create or replace view v_activation_funnel as
select
  date_trunc('week', occurred_at)::date as week,
  count(*) filter (where event = 'app_opened')            as app_opened,
  count(*) filter (where event = 'onboarding_completed')  as onboarding_completed,
  count(*) filter (where event = 'account_created')       as account_created,
  count(*) filter (where event = 'first_card_added')      as first_card_added,
  count(*) filter (where event = 'second_card_added')     as second_card_added,
  count(*) filter (where event = 'transaction_logged')    as transaction_logged,
  count(distinct profile_id)                              as distinct_profiles
from analytics_events
group by 1
order by 1 desc;

-- Retention by signup cohort. `profile_id is not null` because an
-- unattributed pre-sign-in row cannot belong to a cohort by construction.
create or replace view v_weekly_retention as
with first_seen as (
  select profile_id, min(date_trunc('week', occurred_at))::date as cohort_week
    from analytics_events
   where profile_id is not null
   group by profile_id
)
select f.cohort_week,
       date_trunc('week', e.occurred_at)::date as active_week,
       count(distinct e.profile_id) as active_profiles
  from analytics_events e
  join first_seen f on f.profile_id = e.profile_id
 where e.profile_id is not null
 group by 1, 2
 order by 1 desc, 2 desc;
