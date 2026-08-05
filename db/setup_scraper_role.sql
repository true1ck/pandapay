-- The scraper (scraper/) writes to sources/source_pages/scrape_runs/
-- page_snapshots — all in the "admin-only" RLS block (0011's
-- admin_users_admin_only-style policies: `using (pandapay.is_admin())`),
-- because a human operator reaches them through the console as an
-- authenticated admin. The scraper is a background service with no admin
-- session to impersonate.
--
-- Two ways to give it access: (a) BYPASSRLS, or (b) SET LOCAL app.user_id to
-- a real admin's id before every write, the same way api/ does per-request
-- impersonation. (a) is chosen here, deliberately, NOT by accident the way
-- Chunk 7 found `postgres` accidentally bypassing everything: this role can
-- ONLY log in and touch tables explicitly granted below (no superuser
-- privileges, no DDL, nothing outside the admin-console content tables) —
-- a narrow, documented, single-purpose bypass for a trusted first-party
-- background job, not an accidental blanket one.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'scraper_role') then
    create role scraper_role login password 'scraper_dev_pw' nosuperuser bypassrls;
  end if;
end $$;

grant usage on schema public to scraper_role;
grant select, update on sources to scraper_role;
grant select, update on source_pages to scraper_role;
grant select, insert, update on scrape_runs to scraper_role;
grant select, insert on page_snapshots to scraper_role;
grant select, insert, update on policy_change_alerts to scraper_role;
grant select, insert on policy_alert_evidence to scraper_role;
grant select, insert on extraction_proposals to scraper_role;

-- Production: use a real generated password via your secrets manager, never
-- this literal. This file is for local/dev reproducibility only.
