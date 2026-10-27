\set ON_ERROR_STOP on
-- L13: explicit user feedback outranks AI-only evidence for the same SMS.
-- Runs entirely inside a rolled-back transaction; no fixture row survives.
begin;

-- Ten opted-in users, each with an admin-approved AI-only proposal for the
-- same merchant. That is exactly the 10-user/90% category threshold, so the
-- rule is live until one user corrects their own message.
do $$
declare
  i integer;
  pid uuid;
  grant_time timestamptz;
begin
  for i in 1..10 loop
    pid := ('21000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.profiles (id, contributions_opt_in) values (pid, true);
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (pid, 'sms_shared_learning', 'sms-shared-learning-v2', true)
    returning granted_at into grant_time;
    insert into public.sms_ai_learning_proposals (
      proposal_id, profile_id, event_id, source_key_hash, sender_fingerprint,
      user_hash, issuer_prefix, sender_pattern, redacted_pattern, template_text,
      synthetic_sample, fact_family, resolved_kind, proposed_fields, ai_score,
      consent_policy_version, consent_granted_at, status, reviewed_at
    ) values (
      ('31000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
      pid, gen_random_uuid(), repeat('a', 64), repeat('b', 64),
      lpad(to_hex(i), 64, '0'), 'HDFC', 'HDFC',
      '{AMOUNT} paid at SUPERSEDE TEST SHOP', '{AMOUNT} paid at SUPERSEDE TEST SHOP',
      'Rs. 123.45 paid at SUPERSEDE TEST SHOP', 'posted_movement', 'transaction',
      '{"merchant":"SUPERSEDE TEST SHOP","categorySlug":"groceries"}'::jsonb,
      0.95, 'sms-shared-learning-v2', grant_time, 'approved', now()
    );
  end loop;
end $$;

insert into public.profiles (id, contributions_opt_in)
values ('21000000-0000-0000-0000-000000000099', true);
insert into public.admin_users (id, email, role, is_active)
values ('21000000-0000-0000-0000-000000000099',
        'l13-admin-fixture@example.invalid', 'operator', true);

insert into public.sms_category_rule_approvals
  (merchant_key, category_slug, status, reviewed_by, reason,
   support_count_at_review, agreement_rate_at_review)
values ('SUPERSEDE TEST SHOP', 'groceries', 'approved',
        '21000000-0000-0000-0000-000000000099',
        'l13 fixture approval', 10, 1.0);

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                 where merchant_key = 'SUPERSEDE TEST SHOP' and support_count = 10) then
    raise exception 'fixture did not reach the ten-user category threshold';
  end if;
  if not exists (select 1 from pandapay.sms_approved_category_rules()
                 where merchant_key = 'SUPERSEDE TEST SHOP') then
    raise exception 'approved AI evidence is not reaching approved-only delivery';
  end if;
end $$;

-- An approved AI proposal is still only evidence. The worker candidate query
-- counts it; once superseded it must disappear from the same query.
do $$
declare
  v_before integer;
begin
  select count(distinct user_hash) into v_before
    from public.sms_ai_learning_proposals p
   where p.status = 'approved' and p.template_text is not null
     and p.proposed_fields->>'merchant' = 'SUPERSEDE TEST SHOP';
  if v_before <> 10 then
    raise exception 'worker candidate query saw % approved proposals, expected 10', v_before;
  end if;
end $$;

-- User 1 edits the transaction. Under app_user, with only the owner update
-- policy available, the SECURITY DEFINER helper must still demote their row.
set local role app_user;
select set_config('app.user_id', '21000000-0000-0000-0000-000000000001', true);

insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action, resolved_kind,
  consent_policy_version, consent_granted_at, corrected_fields, learned, learning_reason
) values (
  '21000000-0000-0000-0000-000000000001', gen_random_uuid(), repeat('a', 64),
  repeat('b', 64), 'edited', 'transaction', 'sms-shared-learning-v2', now(),
  '{"amountInr":750}'::jsonb, true, 'recorded'
);

do $$
declare
  v_demoted integer;
begin
  select pandapay.sms_supersede_ai_proposals(repeat('a', 64), gen_random_uuid())
    into v_demoted;
  if v_demoted <> 1 then
    raise exception 'app_user could not supersede its own approved AI proposal (demoted %)', v_demoted;
  end if;
end $$;

-- The corrected facts survive; only the AI-only evidence is demoted.
do $$
begin
  if not exists (select 1 from public.sms_learning_feedback_events
                  where profile_id = '21000000-0000-0000-0000-000000000001'
                    and action = 'edited'
                    and (corrected_fields->>'amountInr')::numeric = 750) then
    raise exception 'the user correction was not retained';
  end if;
  if not exists (select 1 from public.sms_ai_learning_proposals
                  where profile_id = '21000000-0000-0000-0000-000000000001'
                    and status = 'superseded'
                    and superseded_reason = 'explicit_user_feedback') then
    raise exception 'approved AI proposal was not demoted to superseded';
  end if;
  if not exists (select 1 from public.sms_ai_learning_proposals
                  where profile_id = '21000000-0000-0000-0000-000000000001') then
    raise exception 'audit history was deleted instead of superseded';
  end if;
end $$;

-- A delayed or retried ai_auto_resolved upload must not resurrect the evidence.
-- The before-insert trigger drops the row, so the device outbox stops retrying.
insert into public.sms_ai_learning_proposals (
  profile_id, event_id, source_key_hash, sender_fingerprint, user_hash,
  issuer_prefix, sender_pattern, redacted_pattern, fact_family, resolved_kind,
  proposed_fields, consent_policy_version, consent_granted_at
) values (
  '21000000-0000-0000-0000-000000000001', gen_random_uuid(), repeat('a', 64),
  repeat('b', 64), repeat('c', 64), 'HDFC', 'HDFC',
  '{AMOUNT} paid at SUPERSEDE TEST SHOP', 'posted_movement', 'transaction',
  '{"merchant":"SUPERSEDE TEST SHOP","categorySlug":"groceries"}'::jsonb,
  'sms-shared-learning-v2', now()
);

do $$
declare
  v_active integer;
  v_total integer;
begin
  select count(*) filter (where status in ('pending', 'approved')), count(*)
    into v_active, v_total
    from public.sms_ai_learning_proposals
   where profile_id = '21000000-0000-0000-0000-000000000001';
  if v_active <> 0 then
    raise exception 'a delayed AI upload recreated eligible evidence (% active)', v_active;
  end if;
  if v_total <> 1 then
    raise exception 'delayed AI upload was not dropped by the trigger (% rows)', v_total;
  end if;
end $$;

-- A superseded proposal cannot be re-approved through the owner role either.
do $$
declare
  v_still_superseded integer;
begin
  update public.sms_ai_learning_proposals
     set status = 'approved'
   where profile_id = '21000000-0000-0000-0000-000000000001';
  get diagnostics v_still_superseded = row_count;
  if v_still_superseded <> 0 then
    raise exception 'the owner role updated a proposal directly (% rows)', v_still_superseded;
  end if;
end $$;

reset role;

-- Support dropped below the threshold, so the pair leaves eligible aggregation
-- and approved-only device delivery in the same step.
do $$
declare
  v_worker integer;
begin
  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key = 'SUPERSEDE TEST SHOP') then
    raise exception 'a superseded AI proposal still contributes a category vote';
  end if;
  if exists (select 1 from pandapay.sms_approved_category_rules()
             where merchant_key = 'SUPERSEDE TEST SHOP') then
    raise exception 'a superseded AI proposal still reaches approved-only delivery';
  end if;
  select count(distinct user_hash) into v_worker
    from public.sms_ai_learning_proposals p
   where p.status = 'approved' and p.template_text is not null
     and p.proposed_fields->>'merchant' = 'SUPERSEDE TEST SHOP';
  if v_worker <> 9 then
    raise exception 'worker candidate query still counts the superseded proposal (%)', v_worker;
  end if;
end $$;

-- Rows written before the migration are demoted by the same rule: an accepted
-- explicit event for the source makes the AI-only proposal ineligible. User 2
-- is staged as that pre-migration state (approved proposal, matching explicit
-- event, status never demoted), then the backfill statement runs.
insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action, resolved_kind,
  consent_policy_version, consent_granted_at, learned, learning_reason
) values (
  '21000000-0000-0000-0000-000000000002', gen_random_uuid(), repeat('d', 64),
  repeat('b', 64), 'edited', 'transaction', 'sms-shared-learning-v2', now(),
  true, 'recorded'
);
update public.sms_ai_learning_proposals
   set source_key_hash = repeat('d', 64), status = 'approved', superseded_at = null
 where profile_id = '21000000-0000-0000-0000-000000000002';
update public.sms_ai_learning_proposals p
   set status = 'superseded', superseded_reason = 'explicit_user_feedback_backfill'
  where p.status in ('pending', 'approved')
    and exists (select 1 from public.sms_learning_feedback_events e
                 where e.profile_id = p.profile_id
                   and e.source_key_hash = p.source_key_hash);
do $$
begin
  if not exists (select 1 from public.sms_ai_learning_proposals
                  where profile_id = '21000000-0000-0000-0000-000000000002'
                    and status = 'superseded'
                    and superseded_reason = 'explicit_user_feedback_backfill') then
    raise exception 'backfill did not demote a pre-migration approved proposal';
  end if;
end $$;

-- Opt-out removes AI evidence regardless of how far review had progressed.
update public.sms_ai_learning_proposals
   set status = case when profile_id = '21000000-0000-0000-0000-000000000003'
                     then 'pending' else 'approved' end,
       source_key_hash = repeat('e', 64)
 where profile_id in ('21000000-0000-0000-0000-000000000003',
                      '21000000-0000-0000-0000-000000000004');

insert into public.user_consents (profile_id, purpose, policy_version, granted, granted_at)
values ('21000000-0000-0000-0000-000000000003', 'sms_shared_learning',
        'sms-shared-learning-v2', false, now() + interval '1 second');
insert into public.user_consents (profile_id, purpose, policy_version, granted, granted_at)
values ('21000000-0000-0000-0000-000000000004', 'sms_shared_learning',
        'sms-shared-learning-v2', false, now() + interval '1 second');

do $$
begin
  if exists (select 1 from public.sms_ai_learning_proposals
             where profile_id in ('21000000-0000-0000-0000-000000000003',
                                  '21000000-0000-0000-0000-000000000004')) then
    raise exception 'opt-out did not remove both pending and approved AI evidence';
  end if;
end $$;

-- Admin review must read the proposal owner's current consent; an ordinary user
-- must not be able to read anyone else's.
set local role app_user;
select set_config('app.user_id', '21000000-0000-0000-0000-000000000005', true);
do $$
begin
  if exists (select 1 from public.user_consents
              where profile_id = '21000000-0000-0000-0000-000000000006'
                and purpose = 'sms_shared_learning') then
    raise exception 'ordinary user read another profile consent';
  end if;
end $$;

select set_config('app.user_id', '21000000-0000-0000-0000-000000000099', true);
do $$
begin
  if not exists (select 1 from public.user_consents
                  where profile_id = '21000000-0000-0000-0000-000000000006'
                    and purpose = 'sms_shared_learning') then
    raise exception 'admin cannot verify AI proposal owner consent';
  end if;
  -- An admin must not be able to read a superseded proposal back into scope by
  -- pretending the owner's consent is the only gate.
  if not exists (select 1 from public.sms_ai_learning_proposals p
                  where p.profile_id = '21000000-0000-0000-0000-000000000001'
                    and p.status = 'superseded') then
    raise exception 'admin lost visibility of superseded audit history';
  end if;
end $$;
reset role;

do $$
begin
  raise notice 'L13 supersede, delayed-AI, aggregation, delivery, opt-out and RLS gates passed';
end $$;

rollback;
