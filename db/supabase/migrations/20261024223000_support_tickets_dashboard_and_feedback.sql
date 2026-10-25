-- Support tickets queue, dashboard view update, and unauthenticated feedback insert policies.

-- 1. Index support_tickets for fast admin queue lookups
create index if not exists idx_support_tickets_pending on support_tickets (state, created_at desc);
create index if not exists idx_support_tickets_profile on support_tickets (profile_id);

-- 2. Adjust RLS to allow unauthenticated or authenticated submissions for support tickets and data error reports
drop policy if exists tickets_owner on support_tickets;
create policy tickets_owner on support_tickets
  for select to public using (profile_id = pandapay.uid());
create policy tickets_insert on support_tickets
  for insert to public with check (profile_id is null or profile_id = pandapay.uid());
create policy tickets_update on support_tickets
  for update to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

drop policy if exists error_reports_owner on data_error_reports;
create policy error_reports_owner on data_error_reports
  for select to public using (profile_id = pandapay.uid());
create policy error_reports_insert on data_error_reports
  for insert to public with check (profile_id is null or profile_id = pandapay.uid());
create policy error_reports_update on data_error_reports
  for update to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

-- 3. Update v_data_quality_dashboard to include support_tickets_pending
create or replace view v_data_quality_dashboard as
select
  (select count(*) from merchants)                                    as merchants_total,
  (select count(*) from merchants where is_published)                 as merchants_published,
  (select count(*) from merchants where confidence in ('high','operator_verified')) as merchants_high_conf,
  (select count(*) from merchant_locations)                           as locations_total,
  (select count(*) from policy_change_alerts where state='open')       as alerts_open,
  (select count(*) from data_error_reports where state='pending')      as error_reports_pending,
  (select count(*) from card_requests where state='pending')           as card_requests_pending,
  (select count(*) from support_tickets where state='pending')         as support_tickets_pending,
  (select count(*) from merchant_conflicts where state='pending')      as conflicts_pending,
  (select count(*) from scrape_runs where status='failed'
     and started_at > now() - interval '7 days')                       as scrape_failures_7d,
  (select count(*) from card_products where status='published')        as cards_published,
  (select count(*) from card_products where status='published'
     and verified_at < now() - interval '180 days')                    as cards_stale_180d;
