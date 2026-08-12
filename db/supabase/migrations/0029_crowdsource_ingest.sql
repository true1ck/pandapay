-- >>> MIGRATION 0029 — CROWDSOURCE INGEST =====================================
--
-- Plan Phase 2.1. `merchant_contributions`, `acceptance_reports`, and
-- `effective_rate_samples` — the three tables 0007_crowdsource.sql calls "the
-- dataset nobody else has" — have never had a single write path. Not one
-- INSERT existed anywhere in the repo, seeds included: the console reads
-- them, `GET /my-contributions` aggregates over them, `recompute_merchant_
-- confidence()` and `detect_rate_divergence()` are written against them, and
-- all of it has been operating on permanently empty tables. This migration is
-- the missing producer.
--
-- ============================================================================
-- THE IDENTITY PROBLEM, AND HOW THIS SOLVES IT
-- ============================================================================
-- 0011_rls_policies.sql makes every crowdsource table admin-only for direct
-- access, with the comment "WRITE-ONLY for users (via SECURITY DEFINER RPC)".
-- So the write path was always intended to be an RPC — this supplies it, in
-- the same shape as `pandapay.ingest_inbound_email()` (0021).
--
-- The harder constraint is `run_anonymization_audit()`, a DEPLOY-BLOCKING CI
-- gate which fails the build if any of these tables gains a `profile_id`,
-- `user_id`, `email`, or `device_id` column, any amount column, or any
-- timestamp finer than a date. The schema wants a `device_hash` that is, in
-- 0007's own words, "a salted, ROTATING hash used only for rate limiting".
-- Nothing ever defined how that hash gets produced. This does:
--
--   device_hash = sha256(profile_id || monthly_salt)
--
-- with the salt regenerated per calendar month and stored in a table the
-- crowdsource RPCs read but never expose. Three consequences worth being
-- explicit about, because they are the whole privacy argument:
--
--   1. The hash is computed INSIDE the SECURITY DEFINER function. The profile
--      id is an argument; it is never stored, and the API layer never
--      computes or sees a hash it could correlate with a user.
--   2. Because the salt rotates monthly, contributions from the same person
--      in different months carry different hashes and cannot be chained into
--      a longitudinal profile of where one individual shops. Within a month
--      they share a hash — which is exactly what the N-distinct-devices
--      publication gate and the daily quota need in order to work at all.
--   3. It is a pseudonym, not anonymity. Anyone with both the salt table and
--      the profile list could re-identify a month's contributions. That is a
--      real, bounded residual risk and it must be reviewed with counsel under
--      plan Phase 3.3 before any of this data is used commercially or shared
--      with a partner. It is stated here rather than buried so that review
--      starts from an accurate description.
--
-- Old salts are deleted rather than kept (see the sweep at the bottom), which
-- makes re-identification of past months impossible rather than merely
-- against policy.

-- ---------------------------------------------------------------------------
-- Rotating salt
-- ---------------------------------------------------------------------------
create table if not exists contribution_salts (
  period_month        date primary key,     -- always the 1st of the month
  salt                text not null,
  created_at          timestamptz not null default now()
);

alter table contribution_salts enable row level security;
alter table contribution_salts force row level security;
-- No policy for anyone, not even admins. The SECURITY DEFINER functions below
-- run as the migration owner and bypass RLS; every other role — including the
-- console's admin path — is denied by the absence of any policy. An admin
-- being able to read the salt is precisely the capability that would turn
-- these pseudonyms back into identities.
comment on table contribution_salts is
  'Monthly rotating salt for crowdsource device_hash pseudonyms. Deliberately '
  'has NO RLS policy: readable only by the SECURITY DEFINER ingest functions, '
  'never by an admin or the app role. Old rows are swept so past months '
  'cannot be re-identified even with database access.';

create or replace function pandapay.current_contribution_salt()
returns text language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  v_month date := date_trunc('month', current_date)::date;
  v_salt text;
begin
  select salt into v_salt from contribution_salts where period_month = v_month;
  if v_salt is null then
    -- 32 bytes from pgcrypto's CSPRNG. `on conflict do nothing` + re-select
    -- rather than a plain insert: two concurrent first-of-the-month
    -- contributions would otherwise race and one would fail on the primary
    -- key, turning a successful user action into a 500 once a month.
    insert into contribution_salts (period_month, salt)
         values (v_month, encode(gen_random_bytes(32), 'hex'))
    on conflict (period_month) do nothing;
    select salt into v_salt from contribution_salts where period_month = v_month;
  end if;
  return v_salt;
end $$;

create or replace function pandapay.device_hash_for(p_profile uuid)
returns text language plpgsql security definer
set search_path = public, pandapay
as $$
begin
  return encode(
    digest(p_profile::text || '|' || pandapay.current_contribution_salt(), 'sha256'),
    'hex');
end $$;

-- ---------------------------------------------------------------------------
-- Daily quota — §6.3 abuse resistance
-- ---------------------------------------------------------------------------
-- A poisoned merchant database gives wrong financial advice, which is the
-- worst failure this product has. `contribution_quotas` already existed with
-- no enforcement anywhere; this is that enforcement.
create or replace function pandapay.claim_contribution_quota(
  p_device_hash text, p_limit int default 50
) returns boolean language plpgsql security definer
set search_path = public, pandapay
as $$
declare v_count int;
begin
  insert into contribution_quotas (device_hash, quota_date, submission_count)
       values (p_device_hash, current_date, 1)
  on conflict (device_hash, quota_date) do update
          set submission_count = contribution_quotas.submission_count + 1
    returning submission_count into v_count;

  if v_count > p_limit then
    update contribution_quotas
       set rejected_count = rejected_count + 1
     where device_hash = p_device_hash and quota_date = current_date;
    return false;
  end if;
  return true;
end $$;

-- geohash6 is referenced by merchant_locations but was never defined — the
-- column is `not null`, so any insert would have failed on it. A 1.2km bucket
-- key for map queries; implemented as a plain truncated grid label rather than
-- true base-32 geohash because every consumer of it (the nearby-merchant
-- lookup) only ever uses it for equality bucketing, and a real geohash would
-- imply prefix-proximity semantics that nothing here relies on.
create or replace function pandapay.geohash6(lat numeric, lng numeric)
returns text language sql immutable as $$
  select to_char(round(lat, 2), 'FM90.00') || ',' || to_char(round(lng, 2), 'FM990.00');
$$;

-- ---------------------------------------------------------------------------
-- Fix forward: recompute_merchant_confidence() has never actually run
-- ---------------------------------------------------------------------------
-- 0010_functions_and_views.sql's version of this function is broken and always
-- has been: the `case ... end` assigned to `merchants.confidence` produces
-- untyped text, and Postgres will not implicitly cast text to the
-- `record_confidence` enum, so the UPDATE raises
--   column "confidence" is of type record_confidence but expression is of type text
-- every single time.
--
-- It went unnoticed for the same reason this whole migration exists: nothing
-- ever called it. It is the publication gate for the merchant graph — the
-- function that decides `is_published` — and it could not have succeeded once.
-- Found by executing it against a real database rather than by reading it.
--
-- Replaced here rather than edited in 0010, following 0015_card_products_rls_
-- fix.sql's precedent: applied history stays an accurate record of what ran.
-- The logic and thresholds are unchanged; only the enum cast is added.
create or replace function pandapay.recompute_merchant_confidence(p_merchant uuid)
returns void language plpgsql as $$
declare
  v_devices int; v_total int; v_score numeric; v_recent int;
begin
  select count(distinct device_hash), count(*)
    into v_devices, v_total
    from merchant_contributions
   where merchant_id = p_merchant and is_counted;

  select count(distinct device_hash) into v_recent
    from merchant_contributions
   where merchant_id = p_merchant and is_counted
     and submitted_on > current_date - 180;

  v_score := least(1.0, (v_devices * 0.6 + v_recent * 0.4) / 5.0);

  update merchants
     set distinct_device_count = v_devices,
         confirmation_count    = v_total,
         confidence_score      = v_score,
         confidence = (case
           when operator_locked      then 'operator_verified'
           when v_devices >= 5       then 'high'
           when v_devices >= 3       then 'medium'
           when v_devices >= 2       then 'low'
           else 'unverified' end)::record_confidence,
         is_published = (v_devices >= 2) or operator_locked,
         last_confirmed_on = current_date,
         updated_at = now()
   where id = p_merchant;
end $$;

-- ---------------------------------------------------------------------------
-- Acceptance reports — "did this card actually work here?"
-- ---------------------------------------------------------------------------
-- The genuinely proprietary signal. Nobody publishes which cards are declined
-- at which merchant, because nobody else is standing next to the user at the
-- till. It cannot be scraped, only observed.
--
-- Takes a VPA rather than a merchant id: the client knows the VPA (it scanned
-- the QR) and generally does not know whether that merchant exists in our
-- graph yet. Resolving-or-creating server-side also keeps merchant creation
-- inside the privileged function, so the merchants table never needs to be
-- writable by the app role.
create or replace function pandapay.submit_acceptance_report(
  p_profile        uuid,
  p_vpa            citext,
  p_display_name   text,
  p_network        card_network,
  p_rail           txn_rail,
  p_result         acceptance_result,
  p_grid_lat       numeric default null,
  p_grid_lng       numeric default null,
  p_app_version    text default null
)
-- OUT parameters are prefixed `out_` rather than named `merchant_id`/
-- `accepted`/`reason`. plpgsql resolves a bare identifier to an OUT parameter
-- before a column, so a plain `merchant_id` here makes the
-- `on conflict (merchant_id, grid_lat, grid_lng)` clause below ambiguous and
-- the function fails at runtime, not at creation time — which is exactly how
-- this was found: the migration applied cleanly and the first real call blew
-- up. The alternative, `#variable_conflict use_column`, would fix this one
-- site by changing name resolution for the whole body, which is a much
-- broader change than the problem warrants.
returns table(out_merchant_id uuid, out_accepted boolean, out_reason text)
language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  v_hash text;
  v_merchant uuid;
  v_lat numeric;
  v_lng numeric;
begin
  if p_profile is null or p_vpa is null then
    return query select null::uuid, false, 'missing_arguments'::text; return;
  end if;

  -- Opt-in is checked HERE, not in the API layer, and that is deliberate:
  -- this function is the only way data reaches these tables, so putting the
  -- consent check at the boundary makes it impossible for a future caller to
  -- forget it. profiles.contributions_opt_in defaults to false, so silence
  -- means no.
  if not exists (select 1 from profiles where id = p_profile and contributions_opt_in) then
    return query select null::uuid, false, 'not_opted_in'::text; return;
  end if;

  v_hash := pandapay.device_hash_for(p_profile);

  if not pandapay.claim_contribution_quota(v_hash) then
    return query select null::uuid, false, 'quota_exceeded'::text; return;
  end if;

  -- Resolve or create the merchant.
  select id into v_merchant from merchants where vpa = p_vpa;
  if v_merchant is null then
    insert into merchants (vpa, display_name)
         values (p_vpa, nullif(trim(coalesce(p_display_name, '')), ''))
      returning id into v_merchant;
  elsif p_display_name is not null and trim(p_display_name) <> '' then
    update merchants set display_name = coalesce(display_name, trim(p_display_name))
     where id = v_merchant;
  end if;

  -- Location, only if the client sent one. Snapped server-side even though
  -- the client is also expected to snap — 0010's snap_grid() calls itself "a
  -- second line of defence", and a check constraint that rejects finer
  -- coordinates would otherwise turn a client bug into a failed submission
  -- instead of a coarsened one.
  if p_grid_lat is not null and p_grid_lng is not null then
    v_lat := round(p_grid_lat, 4);
    v_lng := round(p_grid_lng, 4);
    if v_lat between 6.0 and 37.5 and v_lng between 68.0 and 97.5 then
      insert into merchant_locations (merchant_id, grid_lat, grid_lng, geohash6)
           values (v_merchant, v_lat, v_lng, pandapay.geohash6(v_lat, v_lng))
      on conflict (merchant_id, grid_lat, grid_lng) do update
              set confirmation_count = merchant_locations.confirmation_count + 1,
                  last_confirmed_on  = current_date;
    end if;
  end if;

  -- The contribution row (drives the publication gate) …
  insert into merchant_contributions (
    kind, vpa, merchant_id, reported_name, grid_lat, grid_lng, device_hash, app_version
  ) values (
    'acceptance', p_vpa, v_merchant, nullif(trim(coalesce(p_display_name, '')), ''),
    v_lat, v_lng, v_hash, p_app_version
  );

  -- … and the acceptance observation itself.
  insert into acceptance_reports (merchant_id, network, rail, result, device_hash)
       values (v_merchant, p_network, p_rail, p_result, v_hash);

  -- Keep the pre-aggregated summary in step. 'unknown' deliberately counts
  -- toward neither side: it means the user couldn't tell, which is not
  -- evidence either way and must not drag a merchant's acceptance rate.
  insert into acceptance_summary (merchant_id, network, rail, accepted_count, declined_count)
       values (
         v_merchant, p_network, p_rail,
         case when p_result = 'accepted' then 1 else 0 end,
         case when p_result in ('declined','not_supported') then 1 else 0 end
       )
  on conflict (merchant_id, network, rail) do update
          set accepted_count  = acceptance_summary.accepted_count
                                + case when p_result = 'accepted' then 1 else 0 end,
              declined_count  = acceptance_summary.declined_count
                                + case when p_result in ('declined','not_supported') then 1 else 0 end,
              last_updated_on = current_date;

  -- Publication gate: N >= 2 distinct devices, computed by the function that
  -- has always existed for it.
  perform pandapay.recompute_merchant_confidence(v_merchant);

  update acceptance_summary s
     set confidence_score = least(1.0,
           (s.accepted_count + s.declined_count)::numeric / 5.0),
         is_published = (s.accepted_count + s.declined_count) >= 2
   where s.merchant_id = v_merchant and s.network = p_network and s.rail = p_rail;

  return query select v_merchant, true, null::text;
end $$;

-- ---------------------------------------------------------------------------
-- Effective-rate samples — empirical "what did this card really pay?"
-- ---------------------------------------------------------------------------
-- Source B1 in admin-console-plan §4.2, and the input `detect_rate_divergence()`
-- has been waiting on. Aggregated from RECONCILED transactions only
-- (reward_state = 'confirmed'), because an estimated reward is this app's own
-- prediction — feeding it back in would measure the ranking engine against
-- itself and detect divergence never.
--
-- Runs as a monthly batch rather than per-transaction: a sample is a
-- month-card-category aggregate by definition, and computing it incrementally
-- would mean either rewriting rows or storing exact per-transaction amounts,
-- the second of which the anonymization gate forbids outright.
create or replace function pandapay.build_effective_rate_samples(p_month date default null)
returns int language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  v_month date := coalesce(date_trunc('month', p_month)::date,
                           date_trunc('month', current_date - interval '1 month')::date);
  v_inserted int := 0;
begin
  -- Idempotent: re-running for a month replaces that month's samples rather
  -- than doubling them. The summary is rebuilt from the samples afterwards,
  -- so this is safe to re-run after a fix.
  delete from effective_rate_samples where period_month = v_month;

  insert into effective_rate_samples (
    card_product_id, category_id, period_month,
    spend_bucket_inr, observed_reward_inr, observed_rate, device_hash
  )
  select
    uc.card_product_id,
    t.category_id,
    v_month,
    -- Bucketed, never exact, per the column's own comment. Round to the
    -- nearest ₹5,000 so a distinctive total ("₹47,312.55 at this merchant")
    -- can't act as a quasi-identifier.
    round(sum(t.amount_inr) / 5000) * 5000,
    round(sum(t.confirmed_value_inr), 2),
    -- Guarded division: a month whose confirmed transactions net to zero
    -- spend would otherwise raise division_by_zero and abort the whole batch.
    case when sum(t.amount_inr) > 0
         then round(sum(t.confirmed_value_inr) / sum(t.amount_inr), 4)
         else 0 end,
    pandapay.device_hash_for(t.profile_id)
  from transactions t
  join user_cards uc on uc.id = t.user_card_id
  join profiles p on p.id = t.profile_id
  where t.status = 'active'
    and t.reward_state = 'confirmed'
    and t.confirmed_value_inr is not null
    and date_trunc('month', t.occurred_at at time zone 'Asia/Kolkata')::date = v_month
    -- Same opt-in gate as acceptance reports, for the same reason.
    and p.contributions_opt_in
  group by uc.card_product_id, t.category_id, t.profile_id;

  get diagnostics v_inserted = row_count;

  -- Rebuild the summary this month's samples feed.
  --
  -- `category_id is not null` is required, not optional: effective_rate_summary's
  -- primary key is (card_product_id, category_id, period_month), and a primary
  -- key column cannot be null, so an uncategorised sample cannot be summarised
  -- at all. Found by running this against real rows — the samples inserted
  -- fine and then the summary insert aborted the whole batch.
  --
  -- Uncategorised samples are still STORED (effective_rate_samples.category_id
  -- is nullable) rather than dropped on the floor: they are real observations,
  -- they will summarise correctly once the transaction is categorised and the
  -- month is rebuilt, and discarding them would quietly bias the dataset
  -- toward whatever spend the categoriser happens to recognise today.
  delete from effective_rate_summary where period_month = v_month;
  insert into effective_rate_summary (
    card_product_id, category_id, period_month,
    sample_count, distinct_devices, observed_rate_mean, observed_rate_p50
  )
  select card_product_id, category_id, v_month,
         count(*), count(distinct device_hash),
         round(avg(observed_rate), 4),
         round(percentile_cont(0.5) within group (order by observed_rate)::numeric, 4)
    from effective_rate_samples
   where period_month = v_month
     and category_id is not null
   group by card_product_id, category_id;

  return v_inserted;
end $$;

-- ---------------------------------------------------------------------------
-- Scheduled jobs
-- ---------------------------------------------------------------------------
-- Same pg_cron pattern as 0013_cron_jobs.sql. Guarded so the migration still
-- applies on a database without the extension (CI's throwaway Postgres has no
-- pg_cron, and the anonymization-audit workflow runs these migrations).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- 4th of the month: late enough that the previous month's statements have
    -- been imported and reconciled, which is what makes the samples real.
    perform cron.schedule('effective-rate-samples', '0 3 4 * *',
      $cron$select pandapay.build_effective_rate_samples();$cron$);
    -- Salt sweep. Keeping 3 months covers a late reconciliation batch still
    -- needing to match a recent month's hashes; past that, deleting the salt
    -- makes those months' pseudonyms irreversible rather than merely
    -- policy-protected.
    perform cron.schedule('contribution-salt-sweep', '0 4 1 * *',
      $cron$delete from contribution_salts
             where period_month < date_trunc('month', current_date)::date - interval '3 months';$cron$);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Execute grants
-- ---------------------------------------------------------------------------
-- Postgres grants EXECUTE on a new function to PUBLIC by default. For a
-- SECURITY DEFINER function that returns the pseudonymisation salt, that
-- default is a hole big enough to undo the entire privacy design above: any
-- role that can reach the database — including `app_user`, which the API
-- connects as — could call `current_contribution_salt()`, get the month's
-- salt, and then recompute every contributor's device_hash from a list of
-- profile ids. The `contribution_salts` table having no RLS policy would
-- protect nothing, because the function bypasses RLS on purpose.
--
-- So both helpers are revoked from PUBLIC. Neither is called from outside the
-- database: `submit_acceptance_report()` and `build_effective_rate_samples()`
-- are themselves SECURITY DEFINER, so they execute as the function owner and
-- can still call them.
revoke execute on function pandapay.current_contribution_salt() from public;
revoke execute on function pandapay.device_hash_for(uuid) from public;
revoke execute on function pandapay.claim_contribution_quota(text, int) from public;

-- The two entry points the API is meant to call, granted explicitly rather
-- than left to the PUBLIC default, so the intended surface is stated rather
-- than inherited.
grant execute on function pandapay.submit_acceptance_report(
  uuid, citext, text, card_network, txn_rail, acceptance_result, numeric, numeric, text
) to public;
grant execute on function pandapay.build_effective_rate_samples(date) to public;
