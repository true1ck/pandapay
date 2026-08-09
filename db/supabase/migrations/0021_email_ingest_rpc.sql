-- >>> MIGRATION 0021 — EMAIL INGEST RPC ========================================
--
-- Closes the gap 0006_ingest.sql's own comment flagged: "no real inbound-
-- email receiver... wired up to write inbound_emails and update this row."
-- api/src/index.js's POST /inbound-emails/webhook is that receiver, but it
-- runs with NO user/admin JWT — it's called by a mail-forwarding provider
-- (SendGrid/Mailgun inbound parse, or a Cloudflare Email Worker forwarding
-- the parsed message as JSON), authenticated only by a shared secret, not
-- by any profile's identity. There is no app.user_id to SET LOCAL, so the
-- normal withUserClient() RLS path can't be used for the initial
-- local_part -> profile_id lookup (forwarding_addresses/inbound_emails are
-- both owner-only RLS per 0011, with no admin bypass — correctly so, an
-- admin has no legitimate reason to browse a user's raw forwarded email).
--
-- This mirrors the existing pattern for exactly this situation: a
-- SECURITY DEFINER RPC that does the minimum privileged work (look up the
-- address, insert the email, bump the counters) and nothing else — same
-- shape as pandapay.approve_policy_alert()/execute_account_deletion() in
-- 0010_functions_and_views.sql. The actual field-extraction regex matching
-- happens in plain JS beforehand (against parser_patterns, which is
-- already public-read — no privilege needed there) so this function only
-- ever receives an already-computed parsed:boolean/pattern_id, never raw
-- regex logic to duplicate in plpgsql.
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
    return; -- unknown/inactive address: caller (webhook route) treats as a no-op, not an error
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

  -- Same telemetry convention as POST /transactions/from-sms: a winning
  -- pattern's success_count is bumped in the same transaction as the row
  -- that used it; a miss is logged as a redacted shape only, never raw
  -- content (parser_failures.redacted_shape_has_no_digits enforces this at
  -- the DB level regardless of what this function passes in).
  if p_parsed_ok and p_parser_pattern_id is not null then
    update parser_patterns set success_count = success_count + 1, updated_at = now()
     where id = p_parser_pattern_id;
  elsif not p_parsed_ok and p_redacted_shape is not null then
    insert into parser_failures (channel, sender_pattern, redacted_shape, occurrences)
    values ('email', p_sender, p_redacted_shape, 1);
  end if;

  return query select v_email_id, v_addr.profile_id;
end $$;
