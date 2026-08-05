-- >>> MIGRATION 0010 — FUNCTIONS AND VIEWS ====================================

-- Snap a raw coordinate to the ~50m publication grid. Called SERVER-SIDE on
-- ingest as a second line of defence — the client also snaps before upload.
create or replace function pandapay.snap_grid(lat numeric, lng numeric)
returns numeric[] language sql immutable as $$
  select array[round(lat, 4), round(lng, 4)];
$$;

-- §5.8 dedupe key. Date (not timestamp) + rounded amount + normalized merchant.
create or replace function pandapay.dedupe_hash(
  p_card uuid, p_amount numeric, p_merchant text, p_when timestamptz
) returns text language sql immutable as $$
  select encode(digest(
    coalesce(p_card::text,'-') || '|' ||
    to_char(round(p_amount, 0), 'FM9999999999') || '|' ||
    lower(regexp_replace(coalesce(p_merchant,''), '[^a-z0-9]', '', 'gi')) || '|' ||
    to_char(p_when at time zone 'Asia/Kolkata', 'YYYY-MM-DD'),
    'sha256'), 'hex');
$$;

create or replace function pandapay.set_dedupe_hash() returns trigger
language plpgsql as $$
begin
  new.dedupe_hash := pandapay.dedupe_hash(
    new.user_card_id, new.amount_inr, new.merchant_name, new.occurred_at);
  return new;
end $$;

create trigger trg_txn_dedupe before insert or update of
  amount_inr, merchant_name, occurred_at, user_card_id on transactions
  for each row execute function pandapay.set_dedupe_hash();

-- §6.3 publication gate: never publish below N independent agreements.
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

  -- Weighted toward recency, saturating at 5 distinct devices.
  v_score := least(1.0, (v_devices * 0.6 + v_recent * 0.4) / 5.0);

  update merchants
     set distinct_device_count = v_devices,
         confirmation_count    = v_total,
         confidence_score      = v_score,
         confidence = case
           when operator_locked      then 'operator_verified'
           when v_devices >= 5       then 'high'
           when v_devices >= 3       then 'medium'
           when v_devices >= 2       then 'low'
           else 'unverified' end,
         is_published = (v_devices >= 2) or operator_locked,
         last_confirmed_on = current_date,
         updated_at = now()
   where id = p_merchant;
end $$;

-- Source B1 detector. Raises/updates ONE alert row, adding evidence to it.
-- Requires N >= 3 distinct devices before surfacing (admin-console-plan §4.2).
create or replace function pandapay.detect_rate_divergence(p_threshold numeric default 0.15)
returns int language plpgsql as $$
declare r record; v_alert uuid; v_count int := 0;
begin
  for r in
    select * from effective_rate_summary
     where distinct_devices >= 3
       and published_rate is not null
       and abs(coalesce(divergence_pct, 0)) >= p_threshold
       and alert_raised_at is null
  loop
    insert into policy_change_alerts (
      card_product_id, field_path, field_label, current_value, proposed_value,
      signal_count, distinct_signal_kinds, corroboration_score)
    values (
      r.card_product_id,
      'reward_rules.' || coalesce(r.category_id::text, 'all') || '.rate',
      'Empirical rate divergence',
      to_jsonb(r.published_rate), to_jsonb(r.observed_rate_p50),
      1, 1, 0.35)
    on conflict do nothing
    returning id into v_alert;

    if v_alert is null then
      select id into v_alert from policy_change_alerts
       where card_product_id = r.card_product_id
         and field_path = 'reward_rules.' || coalesce(r.category_id::text,'all') || '.rate'
         and state in ('open','needs_more_evidence')
       limit 1;
      update policy_change_alerts
         set signal_count = signal_count + 1,
             corroboration_score = least(1.0, corroboration_score + 0.2),
             last_signal_at = now()
       where id = v_alert;
    end if;

    insert into policy_alert_evidence (alert_id, signal, rate_summary_key, excerpt, weight)
    values (v_alert, 'empirical_divergence',
            jsonb_build_object('card', r.card_product_id, 'category', r.category_id,
                               'month', r.period_month),
            format('%s devices show %s%% vs published %s%%',
                   r.distinct_devices, r.observed_rate_p50, r.published_rate),
            0.35);

    update effective_rate_summary set alert_raised_at = now(), is_divergent = true
     where card_product_id = r.card_product_id
       and coalesce(category_id, '00000000-0000-0000-0000-000000000000')
           = coalesce(r.category_id, '00000000-0000-0000-0000-000000000000')
       and period_month = r.period_month;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- §4.5 PROPAGATION. The ONLY sanctioned path from "alert" to "live for users".
-- Approve -> write catalogue -> bump data_version -> audit -> optional force-sync.
create or replace function pandapay.approve_policy_alert(
  p_alert uuid, p_admin uuid, p_apply jsonb, p_summary text, p_force_sync boolean default false
) returns uuid language plpgsql security definer as $$
declare v_card uuid; v_version bigint; v_change uuid; a record;
begin
  select * into a from policy_change_alerts where id = p_alert for update;
  if a is null then raise exception 'alert % not found', p_alert; end if;
  if a.state <> 'open' and a.state <> 'needs_more_evidence' then
    raise exception 'alert % already decided (%)', p_alert, a.state;
  end if;

  v_card := a.card_product_id;

  -- Caller supplies the concrete UPDATE payload; applied by the console's
  -- typed writer (see adminimplementation_plan AD-5.4). We bump + audit here
  -- so no code path can publish without leaving a record.
  update card_products
     set data_version = data_version + 1,
         verified_at  = now(),
         verified_by  = p_admin,
         updated_at   = now()
   where id = v_card
  returning data_version into v_version;

  insert into card_catalogue_changes (
    card_product_id, data_version_after, field_path, old_value, new_value,
    change_summary, approved_by, policy_alert_id)
  values (v_card, v_version, a.field_path, a.current_value, a.proposed_value,
          p_summary, p_admin, p_alert)
  returning id into v_change;

  update policy_change_alerts
     set state = 'approved', decided_by = p_admin, decided_at = now(),
         published_change_id = v_change, force_sync = p_force_sync
   where id = p_alert;

  insert into admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
  values (p_admin, 'approve_policy_alert', 'card_products', v_card,
          a.current_value, a.proposed_value, p_summary);

  if p_force_sync then
    insert into remote_config (key, value, description)
    values ('force_catalogue_sync_after',
            to_jsonb(extract(epoch from now())::bigint),
            'Set by urgent policy correction')
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;

  return v_change;
end $$;

-- DEVICE SYNC CONTRACT (DB-2.7). The app pulls rows where
-- data_version > catalogue_version_seen. Changing this view's shape is a
-- breaking change and requires an app-version gate.
create or replace view v_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.data_version, c.verified_at,
  c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(to_jsonb(k) - 'card_product_id') from cap_rules k
             where k.card_product_id = c.id), '[]'::jsonb) as cap_rules,
  coalesce((select jsonb_agg(to_jsonb(m) - 'card_product_id') from milestone_rules m
             where m.card_product_id = c.id), '[]'::jsonb) as milestone_rules,
  coalesce((select jsonb_agg(to_jsonb(f) - 'card_product_id') from fee_waiver_rules f
             where f.card_product_id = c.id), '[]'::jsonb) as fee_waiver_rules,
  coalesce((select jsonb_agg(to_jsonb(b) - 'card_product_id') from card_benefits b
             where b.card_product_id = c.id), '[]'::jsonb) as benefits,
  (select to_jsonb(x) - 'card_product_id' from forex_rules x where x.card_product_id = c.id) as forex,
  (select to_jsonb(y) - 'card_product_id' from fuel_surcharge_rules y where y.card_product_id = c.id) as fuel
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;

-- Console: §6.6 Data Quality Dashboard, single query.
create or replace view v_data_quality_dashboard as
select
  (select count(*) from merchants)                                    as merchants_total,
  (select count(*) from merchants where is_published)                 as merchants_published,
  (select count(*) from merchants where confidence in ('high','operator_verified')) as merchants_high_conf,
  (select count(*) from merchant_locations)                           as locations_total,
  (select count(*) from policy_change_alerts where state='open')       as alerts_open,
  (select count(*) from data_error_reports where state='pending')      as error_reports_pending,
  (select count(*) from card_requests where state='pending')           as card_requests_pending,
  (select count(*) from merchant_conflicts where state='pending')      as conflicts_pending,
  (select count(*) from scrape_runs where status='failed'
     and started_at > now() - interval '7 days')                       as scrape_failures_7d,
  (select count(*) from card_products where status='published')        as cards_published,
  (select count(*) from card_products where status='published'
     and verified_at < now() - interval '180 days')                    as cards_stale_180d;

-- §6.7 automated anonymization audit. Runs in CI on every deploy (DB-8.3).
create or replace function pandapay.run_anonymization_audit(p_sha text default null)
returns uuid language plpgsql as $$
declare v_findings jsonb := '[]'::jsonb; v_failed int := 0; v_total int := 0; v_id uuid; v_n int;
begin
  -- Check 1: no crowdsource table may have a column referencing profiles.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchants','merchant_locations','merchant_contributions',
                        'acceptance_reports','acceptance_summary',
                        'effective_rate_samples','effective_rate_summary')
     and column_name in ('profile_id','user_id','email','device_id');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','no_identity_columns','violations',v_n);
  end if;

  -- Check 2: no coordinate finer than the 4dp grid.
  v_total := v_total + 1;
  select count(*) into v_n from merchant_locations
   where grid_lat <> round(grid_lat,4) or grid_lng <> round(grid_lng,4);
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','grid_snapped_coords','violations',v_n);
  end if;

  -- Check 3: no amount columns in crowdsourced merchant tables.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchants','merchant_locations','merchant_contributions','acceptance_reports')
     and (column_name like '%amount%' or column_name like '%_inr');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','no_amount_columns','violations',v_n);
  end if;

  -- Check 4: contribution timestamps must be DATE precision, never timestamptz.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchant_contributions','acceptance_reports','effective_rate_samples')
     and data_type like 'timestamp%';
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','day_precision_only','violations',v_n);
  end if;

  -- Check 5: parser failure telemetry must never contain digits.
  v_total := v_total + 1;
  select count(*) into v_n from parser_failures where redacted_shape ~ '[0-9]';
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','redacted_parser_shapes','violations',v_n);
  end if;

  -- Check 6: RLS enabled on every user-domain table.
  v_total := v_total + 1;
  select count(*) into v_n from pg_tables t
   where t.schemaname='public'
     and t.tablename in ('profiles','user_cards','transactions','card_overrides',
                         'points_ledger','cap_states','milestone_states',
                         'fee_waiver_states','needs_review_items','monthly_reports')
     and not exists (select 1 from pg_class c
                      where c.relname=t.tablename and c.relrowsecurity);
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','rls_enabled','violations',v_n);
  end if;

  insert into anonymization_audit_runs (run_by, checks_total, checks_failed, findings, git_sha)
  values ('ci', v_total, v_failed, v_findings, p_sha)
  returning id into v_id;
  return v_id;
end $$;

-- DPDP §8.2 right to erasure. Hard-deletes user rows; crowdsourced rows are
-- untouched because they never contained identity in the first place (R2).
create or replace function pandapay.execute_account_deletion(p_profile uuid)
returns void language plpgsql security definer as $$
begin
  delete from change_log         where profile_id = p_profile;
  delete from inbound_emails     where profile_id = p_profile;
  delete from forwarding_addresses where profile_id = p_profile;
  delete from transactions       where profile_id = p_profile;
  delete from user_cards         where profile_id = p_profile;
  delete from profiles           where id = p_profile;
  -- The identity row itself lives in the auth service's database (auth/), not
  -- here — the app backend must also call DELETE /users/:id (or equivalent)
  -- against the auth service in the same erasure workflow.
  -- Backups purge on their own retention schedule; the stated window in the
  -- privacy policy MUST be >= that retention. See adminimplementation_plan AD-8.
end $$;


