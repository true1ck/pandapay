-- Chunk 8 finding: card_requests and data_error_reports (0011) only got an
-- owner policy (`profile_id = pandapay.uid()`) — there was no admin policy
-- at all. An admin querying these tables through RLS saw zero rows unless
-- they happened to be the reporting user, which defeats the entire purpose
-- of AD-2's queues. Same class of bug as 0015 (a table needing dual
-- visibility only got one half of it), found by actually hitting the new
-- /admin/card-requests and /admin/error-reports endpoints with a real
-- admin token and getting an empty list back against non-empty tables.

create policy card_requests_admin_all on card_requests
  for all to public using (pandapay.is_admin()) with check (pandapay.is_admin());

create policy error_reports_admin_all on data_error_reports
  for all to public using (pandapay.is_admin()) with check (pandapay.is_admin());

-- Same gap, found by inspection while fixing the two above: support_tickets
-- (C7's sibling table, not yet wired to any console screen) has the exact
-- same owner-only shape. Fixed pre-emptively rather than waiting for a
-- console feature to hit it and report empty results again.
create policy tickets_admin_all on support_tickets
  for all to public using (pandapay.is_admin()) with check (pandapay.is_admin());
