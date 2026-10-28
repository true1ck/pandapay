\set ON_ERROR_STOP on
-- C9: shared rules must not survive a pattern of user corrections, but one
-- correction (or one angry user) is never proof of a global defect. Runs in a
-- rolled-back transaction. Covers: per-rule negative-evidence rollup from
-- current explicit corrections, the configurable pause threshold, threshold
-- crossing, superseded/cosmetic evidence not counting, single-profile edits
-- not pausing, and the correcting user keeping their override.

begin;

do $$
declare i integer;
begin
  for i in 1..6 loop
    insert into public.profiles (id, contributions_opt_in)
    values (('35000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, true);
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (('35000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
            'sms_shared_learning', 'sms-shared-learning-v2', true);
  end loop;
end $$;

-- Fixture helper: one current explicit correction naming a shared rule.
create function pg_temp.c9_event(
  p_profile uuid, p_source text, p_fact_index integer, p_rule_id text,
  p_kind text default 'misclassified_category'
) returns uuid language sql as $$
  insert into public.sms_learning_feedback_events (
    profile_id, event_id, source_key_hash, sender_fingerprint, action,
    resolved_kind, consent_policy_version, consent_granted_at,
    merchant_key, category_slug, original_category_slug,
    correction_kind, decision_origin, decision_rule_id, fact_key
  ) values (
    p_profile, gen_random_uuid(), p_source, repeat('f', 64), 'category_changed',
    'transaction', 'sms-shared-learning-v2',
    (select granted_at from public.user_consents
      where profile_id = p_profile and purpose = 'sms_shared_learning'
      order by granted_at desc, granted asc, id desc limit 1),
    'C9 SHOP', 'dining', 'travel', p_kind, 'shared_rule', p_rule_id,
    p_source || ':' || p_fact_index::text
  )
  returning event_id
$$;

-- Shipped default threshold.
do $$
begin
  if pandapay.sms_shared_rule_pause_threshold() <> 3 then
    raise exception 'the shipped pause threshold is not 3';
  end if;
  if pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'a rule with no negative evidence is paused';
  end if;
end $$;

-- A single correction is one data point, never proof of a global defect.
do $$
begin
  perform pg_temp.c9_event('35000000-0000-0000-0000-000000000001',
    lpad(to_hex(1), 64, '0'), 0, 'bundle-c9:r1');
  if (select paused from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r1') then
    raise exception 'one correction paused a shared rule';
  end if;
  if (select (negative_evidence_count, distinct_reporting_profiles)
        from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r1')
     is distinct from (1, 1) then
    raise exception 'the negative-evidence rollup miscounted a single correction';
  end if;
end $$;

-- Cosmetic and preference-only edits make no claim about the rule and never
-- count, from any number of profiles.
do $$
declare i integer;
begin
  for i in 1..4 loop
    perform pg_temp.c9_event(('35000000-0000-0000-0000-' || lpad((1 + i)::text, 12, '0'))::uuid,
      lpad(to_hex(9 + i), 64, '0'), 0, 'bundle-c9:r1', 'cosmetic');
  end loop;
  for i in 1..3 loop
    perform pg_temp.c9_event(('35000000-0000-0000-0000-' || lpad((1 + i)::text, 12, '0'))::uuid,
      lpad(to_hex(19 + i), 64, '0'), 1, 'bundle-c9:r1', 'preference_only');
  end loop;
  if (select negative_evidence_count from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r1') <> 1 then
    raise exception 'cosmetic or preference-only edits counted as negative evidence';
  end if;
  if pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'non-correctness corrections paused a shared rule';
  end if;
end $$;

-- Duplicate and already-paid actions are also lifecycle outcomes, not proof
-- that a shared parser rule classified the message incorrectly.
do $$
begin
  perform pg_temp.c9_event('35000000-0000-0000-0000-000000000005',
    lpad(to_hex(25), 64, '0'), 0, 'bundle-c9:r1', 'duplicate');
  perform pg_temp.c9_event('35000000-0000-0000-0000-000000000006',
    lpad(to_hex(26), 64, '0'), 0, 'bundle-c9:r1', 'already_paid');
  if (select negative_evidence_count from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r1') <> 1 then
    raise exception 'duplicate or already-paid feedback counted as negative evidence';
  end if;
  if pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'lifecycle feedback paused a shared rule';
  end if;
end $$;

-- One user editing many facts of one message is still one reporting profile.
do $$
declare i integer;
begin
  for i in 0..4 loop
    perform pg_temp.c9_event('35000000-0000-0000-0000-000000000001',
      lpad(to_hex(40), 64, '0'), i, 'bundle-c9:r2');
  end loop;
  if (select (negative_evidence_count, distinct_reporting_profiles, paused)
        from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r2')
     is distinct from (5, 1, false) then
    raise exception 'a single profile''s many edits paused a shared rule';
  end if;
end $$;

-- Threshold crossing: distinct reporting profiles 2 is below, 3 reaches the
-- shipped threshold of 3 and pauses the rule.
do $$
begin
  perform pg_temp.c9_event('35000000-0000-0000-0000-000000000002',
    lpad(to_hex(30), 64, '0'), 0, 'bundle-c9:r1');
  if pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'two profiles of negative evidence paused a shared rule';
  end if;
  perform pg_temp.c9_event('35000000-0000-0000-0000-000000000003',
    lpad(to_hex(31), 64, '0'), 0, 'bundle-c9:r1');
  if not pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'three profiles of negative evidence did not pause the rule';
  end if;
  if (select (negative_evidence_count, distinct_reporting_profiles, paused)
        from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r1')
     is distinct from (3, 3, true) then
    raise exception 'the rollup did not report the threshold crossing';
  end if;
end $$;

-- The correcting users keep their overrides: a pause is a serving decision and
-- must not modify, supersede, or delete any correction data.
do $$
begin
  if (select count(*) from public.sms_learning_feedback_events
       where fact_key in (lpad(to_hex(1), 64, '0') || ':0',
                          lpad(to_hex(30), 64, '0') || ':0',
                          lpad(to_hex(31), 64, '0') || ':0')
         and profile_id in ('35000000-0000-0000-0000-000000000001',
                            '35000000-0000-0000-0000-000000000002',
                            '35000000-0000-0000-0000-000000000003')
         and decision_rule_id = 'bundle-c9:r1'
         and superseded_at is null
         and superseded_by_event_id is null) <> 3 then
    raise exception 'crossing the threshold changed the users'' correction rows';
  end if;
end $$;

-- Superseded evidence is audit history, not a live vote: correcting the fact
-- withdraws that profile's negative evidence.
do $$
declare
  v_profile uuid := '35000000-0000-0000-0000-000000000003';
  v_source text := lpad(to_hex(31), 64, '0');
  v_replacement uuid;
begin
  v_replacement := gen_random_uuid();
  perform set_config('app.user_id', v_profile::text, true);
  if pandapay.sms_supersede_corrections(v_source, v_source || ':0', v_replacement) <> 1 then
    raise exception 'the retraction supersede touched nothing';
  end if;
  -- A retraction: same fact, but the user now confirms the rule's category was
  -- right, so the new current state is not a correctness claim at all.
  insert into public.sms_learning_feedback_events (
    profile_id, event_id, source_key_hash, sender_fingerprint, action,
    resolved_kind, consent_policy_version, consent_granted_at,
    merchant_key, category_slug, original_category_slug,
    correction_kind, decision_origin, decision_rule_id, fact_key
  ) values (
    v_profile, v_replacement, v_source, repeat('f', 64), 'confirmed',
    'transaction', 'sms-shared-learning-v2', now(),
    'C9 SHOP', 'travel', 'travel', null, 'shared_rule', 'bundle-c9:r1',
    v_source || ':0');
  perform set_config('app.user_id', '', true);

  if (select (distinct_reporting_profiles, paused)
        from pandapay.sms_rule_negative_evidence()
       where decision_rule_id = 'bundle-c9:r1')
     is distinct from (2, false) then
    raise exception 'superseded negative evidence still counted toward the pause';
  end if;
  if pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'the rule stayed paused after a correction was retracted';
  end if;
end $$;

-- The threshold is operator-tunable through the settings row.
do $$
begin
  update public.sms_learning_settings
     set value = '1'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
  if not pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'a threshold of 1 did not pause one profile of evidence';
  end if;
  update public.sms_learning_settings
     set value = '999'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
  if pandapay.sms_shared_rule_paused('bundle-c9:r1') then
    raise exception 'a raised threshold did not un-pause the rule';
  end if;
  update public.sms_learning_settings
     set value = '"not-a-number"'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
  if pandapay.sms_shared_rule_pause_threshold() <> 3 then
    raise exception 'an unparseable threshold did not fall back to the default';
  end if;
  update public.sms_learning_settings
     set value = '0'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
  if pandapay.sms_shared_rule_pause_threshold() <> 3 then
    raise exception 'a zero threshold did not fall back to the default';
  end if;
  update public.sms_learning_settings
     set value = '-2'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
  if pandapay.sms_shared_rule_pause_threshold() <> 3 then
    raise exception 'a negative threshold did not fall back to the default';
  end if;
  update public.sms_learning_settings
     set value = '1001'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
  if pandapay.sms_shared_rule_pause_threshold() <> 3 then
    raise exception 'an out-of-range threshold did not fall back to the default';
  end if;
  update public.sms_learning_settings
     set value = '3'::jsonb, updated_at = now()
   where key = 'sms_shared_rule_negative_pause_threshold';
end $$;

-- The serving-path check is executable by the app role, which runs
-- GET /sms/rules/active.
set local role app_user;
select pandapay.sms_shared_rule_paused('bundle-c9:r1'),
       pandapay.sms_rule_negative_evidence() is not null,
       pandapay.sms_shared_rule_pause_threshold();
reset role;

-- app_user must not read or edit the operator settings row: grants are broad,
-- but forced RLS with no policies filters every row for the app role.
set local role app_user;
do $$
begin
  update public.sms_learning_settings set value = '1'::jsonb
   where key = 'sms_shared_rule_negative_pause_threshold';
  if found then
    raise exception 'app_user modified the pause threshold';
  end if;
exception when insufficient_privilege then
  null;
end $$;
do $$
begin
  begin
    if exists (select 1 from public.sms_learning_settings) then
      raise exception 'app_user can read the settings table';
    end if;
  exception when insufficient_privilege then
    null;
  end;
end $$;
reset role;

do $$
begin
  raise notice 'C9 shared-rule negative evidence and pause tests passed';
end $$;

rollback;
