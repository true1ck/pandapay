-- >>> MIGRATION 0033 — PARSER FAILURE INGEST ==================================
--
-- Plan Phase 2.4, and a live bug fix.
--
-- ============================================================================
-- THE BUG
-- ============================================================================
-- `POST /transactions/from-sms` inserts a `parser_failures` row when a bank
-- SMS matches no active pattern. That insert runs inside
-- `withUserClient(req.userId, …)`, but `parser_failures` is in
-- 0011_rls_policies.sql's ADMIN-ONLY list. So for every real (non-admin) user
-- the insert raises
--
--   new row violates row-level security policy for table "parser_failures"
--
-- which aborts the surrounding transaction and turns the route's documented
-- `200 { parsed: false }` into a 500. Two consequences, both silent:
--
--   1. A user whose bank SMS doesn't match a pattern — which is the ENTIRE
--      point of the failure branch, and common for any issuer not yet
--      covered — gets a server error rather than "couldn't read this one".
--   2. `parser_failures` has never received a single SMS row, so the triage
--      loop that is supposed to tell operators which issuers need a new
--      pattern has never had any input. Parser coverage cannot improve from
--      data that is never collected.
--
-- The email channel was never affected: it writes through
-- `pandapay.ingest_inbound_email()` (0021), which is SECURITY DEFINER and so
-- bypasses the policy. That asymmetry is exactly why this went unnoticed —
-- one of the two writers happened to be built the right way.
--
-- Found by executing the insert as a real non-admin role. Reading the route
-- would not have revealed it; the SQL is correct, the permission is not.
--
-- ============================================================================
-- THE FIX, AND THE DEDUPE THE COLUMNS WERE ALWAYS ASKING FOR
-- ============================================================================
-- A SECURITY DEFINER writer, same shape as 0021 and 0029.
--
-- It also upserts rather than inserting. `parser_failures` has carried
-- `occurrences`, `first_seen_at` and `last_seen_at` since 0006 and nothing has
-- ever incremented `occurrences` — every writer inserted a fresh row with
-- occurrences = 1. Those three columns only make sense if identical shapes
-- collapse, and that collapsing is what makes the table useful: "this exact
-- unparsed shape from HDFCBK has now been seen 4,000 times" is an operator's
-- work queue, whereas 4,000 near-identical rows is a haystack.

-- ---------------------------------------------------------------------------
-- Collapse any duplicates left by the old insert-per-occurrence writers.
-- ---------------------------------------------------------------------------
-- Must run BEFORE the unique index below, or `create unique index` fails on
-- the very rows it exists to prevent. No-op on a database that never received
-- any — which, per the header, is every database as far as the SMS channel is
-- concerned, but the email channel has been writing one row per miss since
-- 0021 and those are real.
-- `(array_agg(id order by …))[1]` rather than `min(id)`: Postgres has no
-- `min(uuid)` aggregate, and picking the oldest row by `first_seen_at` is the
-- correct survivor anyway — it is the one whose first_seen_at is already right.
with collapsed as (
  select channel, coalesce(sender_pattern, '') as sender_key, redacted_shape,
         (array_agg(id order by first_seen_at, id))[1] as keep_id,
         sum(occurrences) as total,
         min(first_seen_at) as first_at, max(last_seen_at) as last_at
    from parser_failures
   group by 1, 2, 3
  having count(*) > 1
)
update parser_failures p
   set occurrences   = c.total,
       first_seen_at = c.first_at,
       last_seen_at  = c.last_at
  from collapsed c
 where p.id = c.keep_id;

delete from parser_failures p
 using (
   select (array_agg(id order by first_seen_at, id))[1] as keep_id,
          channel, coalesce(sender_pattern, '') as sender_key, redacted_shape
     from parser_failures group by 2, 3, 4
 ) k
 where p.channel = k.channel
   and coalesce(p.sender_pattern, '') = k.sender_key
   and p.redacted_shape = k.redacted_shape
   and p.id <> k.keep_id;

-- Required for the ON CONFLICT below. `coalesce` on the nullable sender so
-- rows with no sender still deduplicate against each other rather than each
-- being unique-by-null.
create unique index if not exists uq_parser_failure_shape
  on parser_failures (channel, coalesce(sender_pattern, ''), redacted_shape);

create or replace function pandapay.record_parser_failure(
  p_channel        txn_source,
  p_sender_pattern text,
  p_redacted_shape text,
  p_app_version    text default null,
  p_issuer_id      uuid default null
) returns uuid
language plpgsql security definer
set search_path = public, pandapay
as $$
declare v_id uuid;
begin
  -- A shape that is empty, or that still contains digits, is dropped rather
  -- than raising. The table's `redacted_shape_has_no_digits` CHECK is the real
  -- guarantee that no raw statement content lands here, and it must stay that
  -- way — but a caller that fails to redact should lose its telemetry, not
  -- break the user-facing import it was attached to. Silent on purpose: this
  -- is the failure path of a failure path.
  if p_redacted_shape is null or p_redacted_shape = '' or p_redacted_shape ~ '[0-9]' then
    return null;
  end if;

  insert into parser_failures (
    channel, sender_pattern, redacted_shape, app_version, issuer_id, occurrences
  ) values (
    p_channel, p_sender_pattern, p_redacted_shape, p_app_version, p_issuer_id, 1
  )
  on conflict (channel, coalesce(sender_pattern, ''), redacted_shape) do update
     set occurrences  = parser_failures.occurrences + 1,
         last_seen_at = now(),
         -- Keep the newest app version that still hits this shape: it answers
         -- "is this still happening on current builds, or did we already fix
         -- it?" without a second column.
         app_version  = coalesce(excluded.app_version, parser_failures.app_version)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function pandapay.record_parser_failure(txn_source, text, text, text, uuid) to public;

-- Route the email path through the same writer, so both channels dedupe
-- identically. Everything else about this function is unchanged from 0021 —
-- only the parser_failures branch differs.
create or replace function pandapay.ingest_inbound_email(
  p_local_part           text,
  p_sender               text,
  p_subject              text,
  p_body                 text,
  p_is_known_bank_sender boolean,
  p_parsed_ok            boolean,
  p_parser_pattern_id    uuid,
  p_policy_keyword_hit   boolean,
  p_redacted_shape       text
) returns table(inbound_email_id uuid, profile_id uuid)
language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  v_addr forwarding_addresses%rowtype;
  v_email_id uuid;
begin
  select * into v_addr from forwarding_addresses
   where local_part = p_local_part and is_active
   limit 1;

  if v_addr.id is null then
    return; -- unknown/inactive address: caller treats as a no-op, not an error
  end if;

  insert into inbound_emails (
    forwarding_address_id, profile_id, sender, subject, body_text,
    is_known_bank_sender, parsed_ok, parser_pattern_id, policy_keyword_hit
  ) values (
    v_addr.id, v_addr.profile_id, p_sender, p_subject, p_body,
    coalesce(p_is_known_bank_sender, false), p_parsed_ok, p_parser_pattern_id,
    coalesce(p_policy_keyword_hit, false)
  ) returning id into v_email_id;

  update forwarding_addresses
     set first_email_at = coalesce(first_email_at, now()),
         email_count = email_count + 1
   where id = v_addr.id;

  if p_parsed_ok and p_parser_pattern_id is not null then
    update parser_patterns set success_count = success_count + 1, updated_at = now()
     where id = p_parser_pattern_id;
  elsif not p_parsed_ok then
    perform pandapay.record_parser_failure('email', p_sender, p_redacted_shape);
  end if;

  return query select v_email_id, v_addr.profile_id;
end $$;
