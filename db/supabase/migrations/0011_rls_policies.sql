-- >>> MIGRATION 0011 — ROW LEVEL SECURITY =====================================
-- Default deny. A user can only ever read/write their own rows.
--
-- No Supabase auth.uid() here — identity is verified by the PandaPay auth
-- service (auth/) via JWT, not by Postgres itself. The app backend, after
-- verifying a request's JWT, MUST run `select set_config('app.user_id', $1, true)`
-- with the verified user id at the start of every transaction/request before
-- touching any RLS-protected table below. pandapay.uid() reads that setting;
-- if it was never set, it returns null and every owner policy denies by
-- construction (null = anything is never true).

create or replace function pandapay.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('app.user_id', true), '')::uuid;
$$;

create or replace function pandapay.is_admin() returns boolean
language sql stable as $$
  select exists (select 1 from admin_users a where a.id = pandapay.uid() and a.is_active);
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_consents','user_devices','user_cards','card_overrides',
    'transactions','transaction_splits','points_ledger','cap_states',
    'milestone_states','fee_waiver_states','lounge_usage','needs_review_items',
    'duplicate_candidates','monthly_reports','change_log','sync_cursors',
    'sync_conflicts','forwarding_addresses','inbound_emails','statement_imports',
    'sms_import_batches','support_tickets','card_requests','data_error_reports'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
  end loop;
end $$;

-- Owner policies for every table carrying profile_id.
do $$
declare t text;
begin
  foreach t in array array[
    'user_consents','user_devices','user_cards','card_overrides','transactions',
    'points_ledger','cap_states','milestone_states','fee_waiver_states',
    'lounge_usage','needs_review_items','duplicate_candidates','monthly_reports',
    'change_log','sync_cursors','sync_conflicts','forwarding_addresses',
    'inbound_emails','statement_imports','sms_import_batches'
  ] loop
    execute format($f$
      create policy %1$s_owner on %1$I
        for all to public
        using (profile_id = pandapay.uid())
        with check (profile_id = pandapay.uid())
    $f$, t);
  end loop;
end $$;

create policy profiles_owner on profiles
  for all to public using (id = pandapay.uid()) with check (id = pandapay.uid());

create policy splits_owner on transaction_splits
  for all to public
  using (exists (select 1 from transactions t
                  where t.id = transaction_id and t.profile_id = pandapay.uid()))
  with check (exists (select 1 from transactions t
                  where t.id = transaction_id and t.profile_id = pandapay.uid()));

-- Users may CREATE reports/requests and read their own; the console reads all.
create policy tickets_owner on support_tickets
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
create policy card_requests_owner on card_requests
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
create policy error_reports_owner on data_error_reports
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

-- Catalogue: world-readable when published (local-only users need it too).
do $$
declare t text;
begin
  foreach t in array array[
    'issuers','issuer_emergency_contacts','spend_categories','mcc_categories',
    'card_products','reward_rules','cap_rules','milestone_rules','fee_waiver_rules',
    'card_benefits','forex_rules','fuel_surcharge_rules','billing_cycle_rules',
    'redemption_options','parser_patterns','feature_flags','remote_config',
    'app_versions','kill_switches','changelog_entries','card_catalogue_changes'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy %1$s_public_read on %1$I for select to public using (true)', t);
    execute format('create policy %1$s_admin_write on %1$I for all to public using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;

-- Crowdsource: WRITE-ONLY for users (via SECURITY DEFINER RPC), read for admin.
-- No user may read the merchant graph directly — that is a scraping surface.
do $$
declare t text;
begin
  foreach t in array array[
    'merchants','merchant_locations','merchant_contributions','acceptance_reports',
    'acceptance_summary','effective_rate_samples','effective_rate_summary',
    'contribution_quotas','abuse_signals','merchant_conflicts'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('create policy %1$s_admin_all on %1$I for all to public using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;

-- Published merchant lookup is served through this view only (rate-limited at
-- the edge), never through direct table select.
create or replace view v_published_merchants as
  select m.vpa, m.display_name, m.mcc, m.category_id, m.confidence,
         l.geohash6, l.grid_lat, l.grid_lng
    from merchants m
    left join merchant_locations l on l.merchant_id = m.id
   where m.is_published;

-- Admin-only tables: default deny + admin policy.
do $$
declare t text;
begin
  foreach t in array array[
    'admin_users','admin_audit_log','sources','source_pages','scrape_runs',
    'page_snapshots','extraction_proposals','policy_change_alerts',
    'policy_alert_evidence','anonymization_audit_runs','backup_runs',
    'restore_drills','parser_failures'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('create policy %1$s_admin_only on %1$I for all to public using (pandapay.is_admin()) with check (pandapay.is_admin())', t);
  end loop;
end $$;


