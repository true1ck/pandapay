\set ON_ERROR_STOP on
-- C6: aggregation hardening for the shared category vote. Every scenario runs
-- in a rolled-back transaction, so no fixture row survives. Covers: repeated
-- edits by the same user (latest wins, history retained), multiple SMS from one
-- user (votes are per profile/merchant, never per source message), consent
-- withdrawal, explicit-vs-AI conflict per source_key_hash, mixed categories
-- from different users, false dismissal events, and source spoofing.

begin;

do $$
declare i integer;
begin
  for i in 1..40 loop
    insert into public.profiles (id, contributions_opt_in)
    values (('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, true);
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
            'sms_shared_learning', 'sms-shared-learning-v2', true);
  end loop;
end $$;

-- Fixture helper: one current explicit correction from p_profile for
-- (p_source, p_fact_index) against p_merchant.
create function pg_temp.c6_event(
  p_profile uuid, p_source text, p_fact_index integer,
  p_merchant text, p_slug text, p_original text,
  p_kind text default 'misclassified_category',
  p_action text default 'category_changed',
  p_resolved text default 'transaction',
  p_event_id uuid default gen_random_uuid()
) returns uuid language sql as $$
  insert into public.sms_learning_feedback_events (
    profile_id, event_id, source_key_hash, sender_fingerprint, action,
    resolved_kind, consent_policy_version, consent_granted_at,
    merchant_key, category_slug, original_category_slug,
    correction_kind, decision_origin, fact_key
  ) values (
    p_profile, p_event_id, p_source, repeat('c', 64), p_action,
    p_resolved, 'sms-shared-learning-v2',
    (select granted_at from public.user_consents
      where profile_id = p_profile and purpose = 'sms_shared_learning'
      order by granted_at desc, id desc limit 1),
    p_merchant, p_slug, p_original, p_kind, 'ai',
    p_source || ':' || p_fact_index::text
  )
  returning event_id
$$;

-- Fixture helper: one approved AI-only category proposal from p_profile.
create function pg_temp.c6_ai_proposal(
  p_profile uuid, p_source text, p_merchant text, p_slug text
) returns uuid language sql as $$
  insert into public.sms_ai_learning_proposals (
    profile_id, event_id, source_key_hash, sender_fingerprint, user_hash,
    sender_pattern, redacted_pattern, fact_family, resolved_kind,
    proposed_fields, consent_policy_version, consent_granted_at, status
  ) values (
    p_profile, gen_random_uuid(), p_source, repeat('d', 64), repeat('e', 64),
    'AD-BANK {n} {AMOUNT}', 'AD-BANK {n}', 'posted_movement', 'transaction',
    jsonb_build_object('merchant', p_merchant, 'categorySlug', p_slug),
    'sms-shared-learning-v2',
    (select granted_at from public.user_consents
      where profile_id = p_profile and purpose = 'sms_shared_learning'
      order by granted_at desc, id desc limit 1),
    'approved'
  )
  returning proposal_id
$$;

-- ---------------------------------------------------------------- repeated edits
-- The same user edits one fact three times. The newest correction is the only
-- current vote; the two older ones are retained as superseded audit history.
do $$
declare
  v_profile uuid := '33000000-0000-0000-0000-000000000001';
  v_source text := lpad(to_hex(1), 64, '0');
  v_first uuid; v_second uuid; v_third uuid;
begin
  -- Mirror the route's order: supersede the older fact first, then insert the
  -- newer correction as the single current row.
  v_first := pg_temp.c6_event(v_profile, v_source, 0, 'REPEAT SHOP', 'groceries', 'travel');
  v_second := gen_random_uuid();
  v_third := gen_random_uuid();

  perform set_config('app.user_id', v_profile::text, true);
  if pandapay.sms_supersede_corrections(v_source, v_source || ':0', v_second) <> 1 then
    raise exception 'first edit did not supersede the original correction';
  end if;
  perform pg_temp.c6_event(v_profile, v_source, 0, 'REPEAT SHOP', 'health', 'travel',
    'misclassified_category', 'category_changed', 'transaction', v_second);
  if pandapay.sms_supersede_corrections(v_source, v_source || ':0', v_third) <> 1 then
    raise exception 'second edit did not supersede the first edit';
  end if;
  perform pg_temp.c6_event(v_profile, v_source, 0, 'REPEAT SHOP', 'dining', 'travel',
    'misclassified_category', 'category_changed', 'transaction', v_third);
  perform set_config('app.user_id', '', true);

  if (select count(*) from public.sms_learning_feedback_events
       where profile_id = v_profile and fact_key = v_source || ':0') <> 3 then
    raise exception 'repeated edits did not retain all three audit rows';
  end if;
  if (select count(*) from public.sms_learning_feedback_events
       where profile_id = v_profile and fact_key = v_source || ':0'
         and superseded_at is null) <> 1 then
    raise exception 'repeated edits left more than one current correction';
  end if;
  if not exists (select 1 from public.sms_learning_feedback_events
       where event_id = v_third and superseded_at is null and category_slug = 'dining') then
    raise exception 'the newest correction is not the current vote';
  end if;
  if exists (select 1 from public.sms_learning_feedback_events
       where event_id in (v_first, v_second) and superseded_at is null) then
    raise exception 'an older edit is still a current correction';
  end if;
  -- One user, one fact, three edits: a single vote can never mint a rule.
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'REPEAT SHOP') then
    raise exception 'one user''s repeated edits minted a shared rule';
  end if;
end $$;

-- ------------------------------------------------- multiple SMS from one user
-- Ten corrections from profile 1 (ten different source_key_hash values) are
-- ONE vote, not ten: the aggregate counts per profile/merchant. Profiles 2-10
-- each add one SMS, so the rule must show exactly support_count = 10.
do $$
declare
  v_profile uuid;
  v_seq integer;
  i integer;
begin
  for i in 1..10 loop
    v_seq := 9 + i;
    perform pg_temp.c6_event('33000000-0000-0000-0000-000000000001',
      lpad(to_hex(v_seq), 64, '0'), 0, 'DEDUPE SHOP', 'dining', 'travel');
  end loop;
  for i in 2..10 loop
    v_profile := ('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    v_seq := 19 + i;
    perform pg_temp.c6_event(v_profile, lpad(to_hex(v_seq), 64, '0'), 0,
      'DEDUPE SHOP', 'dining', 'travel');
  end loop;
  -- One dissenting user, so the expected aggregate is dining 10 of 11.
  perform pg_temp.c6_event('33000000-0000-0000-0000-000000000011',
    lpad(to_hex(29), 64, '0'), 0, 'DEDUPE SHOP', 'groceries', 'travel');
end $$;

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'DEDUPE SHOP' and category_slug = 'dining'
                    and support_count = 10) then
    raise exception 'multiple SMS from one user did not collapse to a single per-user vote';
  end if;
end $$;

-- Ten source messages from a single user alone must never reach the ten-user bar.
do $$
declare i integer;
begin
  for i in 1..10 loop
    perform pg_temp.c6_event('33000000-0000-0000-0000-000000000001',
      lpad(to_hex(29 + i), 64, '0'), 0, 'SOLO SHOP', 'dining', 'travel');
  end loop;
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'SOLO SHOP') then
    raise exception 'one user voting across ten SMS sources minted a shared rule';
  end if;
end $$;

-- ---------------------------------------------------------- consent withdrawal
do $$
declare i integer;
begin
  for i in 1..10 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(39 + i), 64, '0'), 0, 'WITHDRAW SHOP', 'dining', 'travel');
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'WITHDRAW SHOP' and support_count = 10) then
    raise exception 'the ten-user withdrawal fixture did not build a rule';
  end if;
end $$;

-- Withdrawal erases the user's attributed events and removes their influence.
set local role app_user;
select set_config('app.user_id', '33000000-0000-0000-0000-000000000010', true);
select pandapay.sms_delete_learning_examples_for_user(
  '33000000-0000-0000-0000-000000000010');
reset role;

do $$
begin
  if exists (select 1 from public.sms_learning_feedback_events
              where profile_id = '33000000-0000-0000-0000-000000000010'
                and merchant_key = 'WITHDRAW SHOP') then
    raise exception 'consent withdrawal left the user''s correction rows behind';
  end if;
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'WITHDRAW SHOP') then
    raise exception 'a withdrawn user still influences the aggregate';
  end if;
end $$;

-- A latest-consent=false row alone (without deletion) also removes influence.
-- Dedicated profiles keep the revoked state from leaking into later fixtures.
do $$
declare i integer;
begin
  for i in 1..10 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad((30 + i)::text, 12, '0'))::uuid,
      lpad(to_hex(49 + i), 64, '0'), 0, 'FLIP SHOP', 'dining', 'travel');
  end loop;
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'FLIP SHOP' and support_count = 10) then
    raise exception 'the consent-flip fixture did not build a rule';
  end if;
  insert into public.user_consents (profile_id, purpose, policy_version, granted)
  values ('33000000-0000-0000-0000-000000000040', 'sms_shared_learning',
          'sms-shared-learning-v2', false);
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'FLIP SHOP') then
    raise exception 'a revoked consent still contributed a vote';
  end if;
  if (select count(*) from public.sms_learning_feedback_events
       where profile_id = '33000000-0000-0000-0000-000000000040'
         and merchant_key = 'FLIP SHOP') <> 1 then
    raise exception 'consent flip must gate eligibility, not delete audit rows';
  end if;
end $$;

-- ------------------------------------------- explicit feedback vs AI, per source
do $$
declare i integer;
begin
  for i in 1..10 loop
    perform pg_temp.c6_ai_proposal(
      ('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(59 + i), 64, '0'), 'AI CONFLICT SHOP', 'travel');
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'AI CONFLICT SHOP' and category_slug = 'travel'
                    and support_count = 10) then
    raise exception 'the approved-AI fixture did not build a rule';
  end if;
end $$;

-- The user's explicit correction for the SAME source outranks their AI-only
-- evidence: the proposal is demoted, the explicit vote replaces the AI vote,
-- and travel no longer holds 10 of 10.
do $$
declare
  v_profile uuid := '33000000-0000-0000-0000-000000000001';
  v_source text := lpad(to_hex(60), 64, '0');
  v_event uuid;
  v_resurrected uuid;
begin
  perform set_config('app.user_id', v_profile::text, true);
  v_event := pg_temp.c6_event(v_profile, v_source, 0, 'AI CONFLICT SHOP', 'dining', 'travel');
  if pandapay.sms_supersede_ai_proposals(v_source, v_event) <> 1 then
    raise exception 'explicit feedback did not supersede the AI proposal for its source';
  end if;

  -- A delayed or retried AI upload for the corrected source must not resurrect
  -- the demoted evidence: the before-insert trigger silently drops the row.
  v_resurrected := pg_temp.c6_ai_proposal(v_profile, v_source, 'AI CONFLICT SHOP', 'travel');
  if v_resurrected is not null then
    raise exception 'a superseded source accepted a new AI proposal';
  end if;
  perform set_config('app.user_id', '', true);

  if exists (select 1 from public.sms_ai_learning_proposals
              where profile_id = v_profile and source_key_hash = v_source
                and status <> 'superseded') then
    raise exception 'the AI proposal for the corrected source is still live';
  end if;
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'AI CONFLICT SHOP') then
    raise exception 'superseded AI evidence still voted for the AI category';
  end if;
end $$;

-- Per source_key_hash, not per user: the same user's AI proposal for a
-- DIFFERENT source of the same merchant stays live after a correction to one
-- source. The explicit correction wins their vote, the untouched AI proposal
-- keeps voting travel for nobody else.
do $$
declare i integer;
begin
  for i in 1..10 loop
    perform pg_temp.c6_ai_proposal(
      ('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(79 + i), 64, '0'), 'AI OTHER SOURCE SHOP', 'travel');
  end loop;
  -- Profile 1 corrects the merchant from a different source.
  perform pg_temp.c6_event('33000000-0000-0000-0000-000000000001',
    lpad(to_hex(71), 64, '0'), 0, 'AI OTHER SOURCE SHOP', 'dining', 'travel');
end $$;

do $$
begin
  if not exists (select 1 from public.sms_ai_learning_proposals
                  where profile_id = '33000000-0000-0000-0000-000000000001'
                    and source_key_hash = lpad(to_hex(80), 64, '0')
                    and status = 'approved') then
    raise exception 'superseding one source demoted the same user''s other-source proposal';
  end if;
  -- Explicit (priority 1) beats the AI vote (priority 0) for profile 1:
  -- travel 9, dining 1 must not produce a rule.
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'AI OTHER SOURCE SHOP') then
    raise exception 'an explicit correction did not outrank the same user''s AI-only vote';
  end if;
end $$;

-- -------------------------------------------------- mixed categories, no majority
do $$
declare i integer;
begin
  for i in 1..6 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(89 + i), 64, '0'), 0, 'SPLIT SHOP', 'groceries', 'travel');
  end loop;
  for i in 7..10 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(89 + i), 64, '0'), 0, 'SPLIT SHOP', 'dining', 'travel');
  end loop;
  for i in 1..5 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(99 + i), 64, '0'), 0, 'TIE SHOP', 'groceries', 'travel');
  end loop;
  for i in 6..10 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(99 + i), 64, '0'), 0, 'TIE SHOP', 'dining', 'travel');
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key in ('SPLIT SHOP', 'TIE SHOP')) then
    raise exception 'a mixed-category user base produced a shared rule';
  end if;
end $$;

-- --------------------------------------------------------- false dismissal events
-- A false_dismissal correction makes a correctness claim about a suppressed
-- message but never a category claim: it must abstain from the category vote
-- without blocking the user's real category correction on another fact.
do $$
declare
  v_profile uuid := '33000000-0000-0000-0000-000000000010';
  i integer;
begin
  for i in 1..9 loop
    perform pg_temp.c6_event(('33000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      lpad(to_hex(109 + i), 64, '0'), 0, 'DISMISSAL SHOP', 'dining', 'travel');
  end loop;
  perform pg_temp.c6_event(v_profile, lpad(to_hex(119), 64, '0'), 0,
    'DISMISSAL SHOP', null, null, 'false_dismissal', 'dismissed', 'dismissed');
end $$;

do $$
begin
  if exists (select 1 from pandapay.sms_shared_category_rules()
              where merchant_key = 'DISMISSAL SHOP') then
    raise exception 'a false dismissal event voted in the category aggregate';
  end if;
end $$;

-- The same user's genuine category correction on a different fact still counts.
do $$
begin
  perform pg_temp.c6_event('33000000-0000-0000-0000-000000000010',
    lpad(to_hex(120), 64, '0'), 0, 'DISMISSAL SHOP', 'dining', 'travel');
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'DISMISSAL SHOP' and category_slug = 'dining'
                    and support_count = 10) then
    raise exception 'a false dismissal blocked the user''s real category vote';
  end if;
end $$;

-- ------------------------------------------------------------- source spoofing
-- Under the app role, a user cannot insert events or AI proposals for another
-- profile, cannot demote another profile's rows through the helper, and has no
-- direct UPDATE path at all.
create temp table c6_foreign_fact on commit drop as
  select source_key_hash, fact_key, event_id
    from public.sms_learning_feedback_events
   where profile_id = '33000000-0000-0000-0000-000000000004'
     and merchant_key = 'DEDUPE SHOP';

grant select on c6_foreign_fact to app_user;

set local role app_user;
select set_config('app.user_id', '33000000-0000-0000-0000-000000000003', true);

do $$
declare
  v_source text; v_fact text; v_event uuid; v_touched integer; v_spoofed uuid;
begin
  select source_key_hash, fact_key, event_id into v_source, v_fact, v_event
    from c6_foreign_fact;

  -- Insert for another profile is blocked by RLS.
  begin
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at,
      merchant_key, category_slug, original_category_slug, fact_key
    ) values (
      '33000000-0000-0000-0000-000000000004', gen_random_uuid(), v_source,
      repeat('c', 64), 'category_changed', 'transaction',
      'sms-shared-learning-v2', now(), 'DEDUPE SHOP', 'health', 'travel',
      v_source || ':1');
    raise exception 'a user inserted a correction for another profile';
  exception when insufficient_privilege then
    null;
  end;

  -- The supersede helper is scoped to pandapay.uid(): it must touch nothing.
  select pandapay.sms_supersede_corrections(v_source, v_fact, gen_random_uuid())
    into v_touched;
  if v_touched <> 0 then
    raise exception 'a user superseded another profile''s correction (% rows)', v_touched;
  end if;

  -- Direct UPDATE is denied either by a missing grant or, when setup_app_role
  -- grants table privileges, by forced RLS filtering the foreign row to zero.
  begin
    update public.sms_learning_feedback_events
       set superseded_at = now()
     where event_id = v_event;
    if found then
      raise exception 'a user directly updated another profile''s correction';
    end if;
  exception when insufficient_privilege then
    null;
  end;

  -- AI proposals are owner-scoped: RLS rejects a foreign profile_id, and the
  -- before-insert resurrection guard silently drops a proposal whose source
  -- already carries that profile's explicit feedback. Either outcome is safe.
  begin
    v_spoofed := pg_temp.c6_ai_proposal('33000000-0000-0000-0000-000000000004',
      v_source, 'DEDUPE SHOP', 'travel');
    if v_spoofed is not null then
      raise exception 'a user inserted an AI proposal for another profile';
    end if;
  exception when insufficient_privilege then
    null;
  end;
end $$;

reset role;

do $$
begin
  if exists (select 1 from public.sms_learning_feedback_events
              where profile_id = '33000000-0000-0000-0000-000000000004'
                and merchant_key = 'DEDUPE SHOP'
                and superseded_at is not null) then
    raise exception 'spoofing changed another profile''s correction state';
  end if;
end $$;

do $$
begin
  raise notice 'C6 aggregation hardening tests passed';
end $$;

rollback;
