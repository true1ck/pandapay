-- Regression test for migration 0029 (crowdsource ingest) and 0030/0031.
--
-- This file exists because of how two real bugs were found. Both migrations
-- applied cleanly — `psql -f` reported success — and both functions failed on
-- the first actual call:
--
--   1. `submit_acceptance_report()`'s OUT parameter `merchant_id` shadowed the
--      column of the same name, making its `ON CONFLICT (merchant_id, ...)`
--      ambiguous at runtime.
--   2. `recompute_merchant_confidence()` (from 0010, untouched since) assigns
--      an untyped `case` expression to a `record_confidence` enum column,
--      which Postgres refuses. That function is the merchant publication gate
--      and had never once succeeded — nothing had ever called it.
--
-- plpgsql resolves function bodies at call time, so "the migration applied"
-- proves almost nothing about whether a function works. Applying migrations
-- in CI was never going to catch either of these. Calling them will.
--
-- Run with `psql -v ON_ERROR_STOP=1`: every check below raises an exception on
-- failure, so a non-zero exit is the assertion mechanism.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into profiles (id, contributions_opt_in) values
  ('11111111-1111-1111-1111-111111111111', true),
  ('22222222-2222-2222-2222-222222222222', true),
  ('33333333-3333-3333-3333-333333333333', false);

insert into issuers (id, slug, name)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'test-bank', 'Test Bank');
insert into card_products (id, issuer_id, slug, name, network, card_type, status, verified_at)
  values ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
          'test-card', 'Test Card', 'visa', 'credit', 'published', now());

do $$
declare
  v_ok boolean;
  v_reason text;
  v_count int;
  v_lat numeric;
begin
  -- -------------------------------------------------------------------------
  -- Opt-in is enforced inside the function, not at the API boundary
  -- -------------------------------------------------------------------------
  select out_accepted, out_reason into v_ok, v_reason
    from pandapay.submit_acceptance_report(
      '33333333-3333-3333-3333-333333333333', 'chai@okaxis', 'Chai Point',
      'visa', 'upi_qr', 'declined');
  if v_ok or v_reason <> 'not_opted_in' then
    raise exception 'opted-out profile was not refused (accepted=%, reason=%)', v_ok, v_reason;
  end if;

  select count(*) into v_count from acceptance_reports;
  if v_count <> 0 then
    raise exception 'a refused submission still wrote % acceptance_reports row(s)', v_count;
  end if;

  -- -------------------------------------------------------------------------
  -- Two opted-in contributors: the call must succeed (bugs 1 and 2 above both
  -- surfaced right here) and the publication gate must fire at N >= 2.
  -- -------------------------------------------------------------------------
  select out_accepted into v_ok from pandapay.submit_acceptance_report(
    '11111111-1111-1111-1111-111111111111', 'chai@okaxis', 'Chai Point',
    'visa', 'upi_qr', 'declined', 12.97123456, 77.59456789, '1.2.0');
  if not v_ok then raise exception 'first contribution was refused'; end if;

  select count(*) into v_count from merchants where is_published;
  if v_count <> 0 then
    raise exception 'merchant published on a single contribution — gate is N >= 2';
  end if;

  select out_accepted into v_ok from pandapay.submit_acceptance_report(
    '22222222-2222-2222-2222-222222222222', 'chai@okaxis', null,
    'visa', 'upi_qr', 'declined', 12.97119999, 77.59451111, '1.2.0');
  if not v_ok then raise exception 'second contribution was refused'; end if;

  select count(*) into v_count from merchants where is_published and confidence = 'low';
  if v_count <> 1 then
    raise exception 'publication gate did not fire at 2 distinct devices (published+low = %)', v_count;
  end if;

  -- -------------------------------------------------------------------------
  -- Pseudonymity: distinct contributors, and no raw profile id anywhere
  -- -------------------------------------------------------------------------
  select count(distinct device_hash) into v_count from acceptance_reports;
  if v_count <> 2 then
    raise exception 'expected 2 distinct device hashes, got %', v_count;
  end if;

  select count(*) into v_count from acceptance_reports
   where device_hash in ('11111111-1111-1111-1111-111111111111',
                         '22222222-2222-2222-2222-222222222222');
  if v_count <> 0 then
    raise exception 'a raw profile id was stored as a device_hash';
  end if;

  select count(*) into v_count from merchant_contributions
   where device_hash in ('11111111-1111-1111-1111-111111111111',
                         '22222222-2222-2222-2222-222222222222');
  if v_count <> 0 then
    raise exception 'a raw profile id leaked into merchant_contributions';
  end if;

  -- -------------------------------------------------------------------------
  -- Coordinates are grid-snapped server-side, whatever the client sent
  -- -------------------------------------------------------------------------
  select max(grid_lat) into v_lat from merchant_locations;
  if v_lat <> round(v_lat, 4) then
    raise exception 'coordinate finer than the 4dp grid was stored: %', v_lat;
  end if;

  -- -------------------------------------------------------------------------
  -- 'unknown' must not count as evidence either way
  -- -------------------------------------------------------------------------
  perform pandapay.submit_acceptance_report(
    '11111111-1111-1111-1111-111111111111', 'chai@okaxis', null,
    'visa', 'upi_qr', 'unknown');
  select accepted_count + declined_count into v_count from acceptance_summary
   where network = 'visa' and rail = 'upi_qr';
  if v_count <> 2 then
    raise exception 'an ''unknown'' result was counted as evidence (total = %)', v_count;
  end if;

  -- -------------------------------------------------------------------------
  -- Effective-rate samples: confirmed only, bucketed, idempotent
  -- -------------------------------------------------------------------------
  insert into user_cards (id, profile_id, card_product_id) values
    ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
     'bbbbbbbb-0000-0000-0000-000000000001');
  insert into transactions
    (profile_id, user_card_id, amount_inr, occurred_at, source, reward_state, confirmed_value_inr)
  values
    ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001',
     20000.00, date_trunc('month', now() - interval '1 month') + interval '3 days',
     'statement', 'confirmed', 1000.00),
    -- Estimated is the app's OWN prediction. Feeding it back would measure
    -- the ranking engine against itself and detect divergence never.
    ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001',
     99999.00, date_trunc('month', now() - interval '1 month') + interval '4 days',
     'manual', 'estimated', null);

  if pandapay.build_effective_rate_samples() <> 1 then
    raise exception 'estimated transactions were not excluded from effective-rate samples';
  end if;

  select count(*) into v_count from effective_rate_samples where observed_rate = 0.0500;
  if v_count <> 1 then
    raise exception 'effective rate was not computed as confirmed_value / spend';
  end if;

  -- Re-running a month must replace, not double.
  perform pandapay.build_effective_rate_samples();
  select count(*) into v_count from effective_rate_samples;
  if v_count <> 1 then
    raise exception 'build_effective_rate_samples is not idempotent (% rows after re-run)', v_count;
  end if;

  -- -------------------------------------------------------------------------
  -- 0030: attribution stamps a per-click token onto the issuer URL
  -- -------------------------------------------------------------------------
  update card_products set apply_url = 'https://bank.example/apply?ref=web'
   where id = 'bbbbbbbb-0000-0000-0000-000000000001';
  insert into partner_programs (issuer_id, partner_name, affiliate_id, token_param, is_active)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'TestAffiliate', 'PP123', 'subid', true);

  perform pandapay.record_partner_click(
    '11111111-1111-1111-1111-111111111111', 'bbbbbbbb-0000-0000-0000-000000000001', 'test');
  select count(*) into v_count from partner_clicks where placement = 'test';
  if v_count <> 1 then raise exception 'partner click was not recorded'; end if;

  -- A card with no apply_url must yield no row, so the API can 404 rather
  -- than invent a destination.
  select count(*) into v_count from pandapay.record_partner_click(
    '11111111-1111-1111-1111-111111111111', gen_random_uuid(), 'test');
  if v_count <> 0 then raise exception 'a click was recorded for a card with no apply_url'; end if;

  raise notice 'crowdsource + attribution ingest: all checks passed';
end $$;

-- ---------------------------------------------------------------------------
-- 0031: consent purposes are constrained
-- ---------------------------------------------------------------------------
do $$
begin
  insert into user_consents (profile_id, purpose, granted, policy_version)
       values ('11111111-1111-1111-1111-111111111111', 'crowdsourse', true, 'v1');
  raise exception 'a misspelled consent purpose was accepted';
exception when check_violation then
  raise notice 'consent purpose constraint: ok';
end $$;

-- ---------------------------------------------------------------------------
-- The anonymization gate must still pass with real crowdsource rows present.
-- Running it on an empty database, which is all CI did before, could not fail.
-- ---------------------------------------------------------------------------
do $$
declare v_failed int;
begin
  perform pandapay.run_anonymization_audit('ingest-test');
  select checks_failed into v_failed from anonymization_audit_runs
   order by ran_at desc limit 1;
  if v_failed <> 0 then
    raise exception 'anonymization audit failed with real ingested data: % check(s)', v_failed;
  end if;
  raise notice 'anonymization audit with real data: ok';
end $$;

rollback;
