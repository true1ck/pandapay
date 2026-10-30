\set ON_ERROR_STOP on
-- C2/C4: one typed, current correction per profile/fact, and a spend category
-- allowlist that matches the app and API. Runs in a rolled-back transaction, so
-- no fixture row survives.

begin;

insert into public.admin_users (id, email, role, is_active)
values ('22000000-0000-0000-0000-000000000099',
        'c2-admin-fixture@example.invalid', 'operator', true);

do $$
declare
  i integer;
  pid uuid;
  grant_time timestamptz;
  seq integer := 0;
begin
  for i in 1..10 loop
    pid := ('22000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.profiles (id, contributions_opt_in) values (pid, true);
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (pid, 'sms_shared_learning', 'sms-shared-learning-v2', true)
    returning granted_at into grant_time;

    -- Each event needs its own live fact: (profile_id, fact_key) is unique.
    seq := seq + 1;
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at,
      merchant_key, category_slug, original_category_slug,
      correction_kind, decision_origin, fact_key, learned, learning_reason,
      review_status
    ) values (
      pid, gen_random_uuid(), lpad(to_hex(seq), 64, '0'), repeat('b', 64),
      'category_changed', 'transaction', 'sms-shared-learning-v2', grant_time,
      'CONTRACT TEST SHOP', 'groceries', 'travel',
      'misclassified_category', 'ai', lpad(to_hex(seq), 64, '0') || ':0',
      false, 'category_feedback_stored', 'approved'
    );
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'CONTRACT TEST SHOP' and support_count = 10) then
    raise exception 'baseline ten-user category rule was not built';
  end if;
end $$;

-- A second correction for the same fact replaces the first as the current vote.
-- The older row is retained as superseded audit history.
do $$
declare
  v_profile uuid := '22000000-0000-0000-0000-000000000001';
  v_source text;
  v_fact text;
  v_event uuid := gen_random_uuid();
  v_superseded integer;
begin
  select source_key_hash, fact_key into v_source, v_fact
    from public.sms_learning_feedback_events
   where profile_id = v_profile and merchant_key = 'CONTRACT TEST SHOP';

  perform set_config('app.user_id', v_profile::text, true);
  select pandapay.sms_supersede_corrections(v_source, v_fact, v_event) into v_superseded;
  if v_superseded <> 1 then
    raise exception 'expected exactly one current correction to be superseded, got %', v_superseded;
  end if;

  insert into public.sms_learning_feedback_events (
    profile_id, event_id, source_key_hash, sender_fingerprint, action,
    resolved_kind, consent_policy_version, consent_granted_at,
    merchant_key, category_slug, original_category_slug,
    correction_kind, decision_origin, fact_key, learned, learning_reason,
    review_status
  ) values (
    v_profile, v_event, v_source, repeat('b', 64), 'category_changed', 'transaction',
    'sms-shared-learning-v2', now(), 'CONTRACT TEST SHOP', 'dining', 'travel',
    'misclassified_category', 'ai', v_fact, false, 'category_feedback_stored',
    'approved'
  );

  if not exists (select 1 from public.sms_learning_feedback_events
                  where profile_id = v_profile and event_id = v_event
                    and superseded_at is null) then
    raise exception 'the newer correction is not the current row';
  end if;
  if (select count(*) from public.sms_learning_feedback_events
       where profile_id = v_profile and merchant_key = 'CONTRACT TEST SHOP'
         and superseded_at is not null) <> 1 then
    raise exception 'the older correction was not kept as superseded audit history';
  end if;
end $$;

-- One user moved, so groceries no longer holds 10 of 10: the rule must vanish.
do $$
begin
  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key = 'CONTRACT TEST SHOP') then
    raise exception 'a superseded correction still votes for its old category';
  end if;
end $$;

-- The partial unique index rejects a second current correction for one fact.
do $$
declare
  v_profile uuid := '22000000-0000-0000-0000-000000000002';
  v_source text;
  v_fact text;
begin
  select source_key_hash, fact_key into v_source, v_fact
    from public.sms_learning_feedback_events
   where profile_id = v_profile and merchant_key = 'CONTRACT TEST SHOP';
  begin
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at,
      merchant_key, category_slug, correction_kind, fact_key
    ) values (
      v_profile, gen_random_uuid(), v_source, repeat('b', 64), 'category_changed',
      'transaction', 'sms-shared-learning-v2', now(), 'CONTRACT TEST SHOP',
      'health', 'misclassified_category', v_fact
    );
    raise exception 'a second current correction for one fact was accepted';
  exception when unique_violation then
    null;
  end;
end $$;

-- Under the owner role the supersede helper must not reach another profile.
-- The fact identity is captured first because RLS hides that row from the
-- app role entirely.
create temp table c2_foreign_fact on commit drop as
  select source_key_hash, fact_key
    from public.sms_learning_feedback_events
   where profile_id = '22000000-0000-0000-0000-000000000004';

grant select on c2_foreign_fact to app_user;

set local role app_user;
select set_config('app.user_id', '22000000-0000-0000-0000-000000000003', true);
do $$
declare
  v_source text;
  v_fact text;
  v_touched integer;
begin
  select source_key_hash, fact_key into v_source, v_fact from c2_foreign_fact;
  select pandapay.sms_supersede_corrections(v_source, v_fact, gen_random_uuid())
    into v_touched;
  if v_touched <> 0 then
    raise exception 'owner role superseded another profile''s row (% rows)', v_touched;
  end if;
end $$;
reset role;

do $$
begin
  if not exists (select 1 from public.sms_learning_feedback_events
                  where profile_id = '22000000-0000-0000-0000-000000000004'
                    and superseded_at is null) then
    raise exception 'another profile''s current correction was demoted';
  end if;
end $$;

-- Preference-only, cosmetic, duplicate and already-paid never train a category
-- rule, even when the category changed.
do $$
declare
  i integer;
  pid uuid;
  grant_time timestamptz;
  seq integer := 100;
  kind text;
begin
  foreach kind in array array['preference_only', 'cosmetic', 'duplicate', 'already_paid'] loop
    for i in 1..10 loop
      pid := ('22000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
      select granted_at into grant_time from public.user_consents
       where profile_id = pid and purpose = 'sms_shared_learning'
       order by granted_at desc, id desc limit 1;
      seq := seq + 1;
      insert into public.sms_learning_feedback_events (
        profile_id, event_id, source_key_hash, sender_fingerprint, action,
        resolved_kind, consent_policy_version, consent_granted_at,
        merchant_key, category_slug, original_category_slug,
        correction_kind, fact_key, review_status
      ) values (
        pid, gen_random_uuid(), lpad(to_hex(seq), 64, '0'), repeat('b', 64),
        'edited', 'transaction', 'sms-shared-learning-v2', grant_time,
        upper(kind) || ' TEST SHOP', 'groceries', 'travel',
        kind, lpad(to_hex(seq), 64, '0') || ':0', 'approved'
      );
    end loop;
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key like '% TEST SHOP'
               and merchant_key in ('PREFERENCE_ONLY TEST SHOP', 'COSMETIC TEST SHOP',
                                    'DUPLICATE TEST SHOP', 'ALREADY_PAID TEST SHOP')) then
    raise exception 'a non-training correction kind contributed a category vote';
  end if;
end $$;

-- A manual review save recorded as 'edited' still counts when the category
-- changed, which is what the aggregate previously missed.
do $$
declare
  i integer;
  pid uuid;
  grant_time timestamptz;
  seq integer := 200;
begin
  for i in 1..10 loop
    pid := ('22000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    select granted_at into grant_time from public.user_consents
     where profile_id = pid and purpose = 'sms_shared_learning'
     order by granted_at desc, id desc limit 1;
    seq := seq + 1;
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at,
      merchant_key, category_slug, original_category_slug, correction_kind,
      fact_key, review_status
    ) values (
      pid, gen_random_uuid(), lpad(to_hex(seq), 64, '0'), repeat('b', 64),
      'edited', 'transaction', 'sms-shared-learning-v2', grant_time,
      'MANUAL SAVE SHOP', 'dining', 'travel', 'misclassified_category',
      lpad(to_hex(seq), 64, '0') || ':0', 'approved'
    );
    -- A confirmation that keeps the same category must not vote.
    seq := seq + 1;
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at,
      merchant_key, category_slug, original_category_slug, correction_kind,
      fact_key, review_status
    ) values (
      pid, gen_random_uuid(), lpad(to_hex(seq), 64, '0'), repeat('b', 64),
      'confirmed', 'transaction', 'sms-shared-learning-v2', grant_time,
      'UNCHANGED SHOP', 'groceries', 'groceries', 'misclassified_category',
      lpad(to_hex(seq), 64, '0') || ':0', 'approved'
    );
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'MANUAL SAVE SHOP' and category_slug = 'dining'
                    and support_count = 10) then
    raise exception 'a category corrected during a manual save did not vote';
  end if;
  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key = 'UNCHANGED SHOP') then
    raise exception 'a confirmation with an unchanged category voted';
  end if;
end $$;

-- The spend allowlist matches the app and API: government/other are canonical,
-- and cash/investments/income/subscription are not spend categories.
do $$
declare
  i integer;
  pid uuid;
  grant_time timestamptz;
  seq integer := 300;
  slug text;
begin
  foreach slug in array array['government', 'other', 'cash', 'investments', 'income', 'subscription'] loop
    for i in 1..10 loop
      pid := ('22000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
      select granted_at into grant_time from public.user_consents
       where profile_id = pid and purpose = 'sms_shared_learning'
       order by granted_at desc, id desc limit 1;
      seq := seq + 1;
      insert into public.sms_learning_feedback_events (
        profile_id, event_id, source_key_hash, sender_fingerprint, action,
        resolved_kind, consent_policy_version, consent_granted_at,
      merchant_key, category_slug, original_category_slug, correction_kind,
      fact_key, review_status
      ) values (
        pid, gen_random_uuid(), lpad(to_hex(seq), 64, '0'), repeat('b', 64),
        'category_changed', 'transaction', 'sms-shared-learning-v2', grant_time,
        upper(slug) || ' SLUG SHOP', slug, 'travel', 'misclassified_category',
        lpad(to_hex(seq), 64, '0') || ':0', 'approved'
      );
    end loop;
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'GOVERNMENT SLUG SHOP' and category_slug = 'government') then
    raise exception 'a canonical spend category the SQL allowlist was missing is still rejected';
  end if;
  if not exists (select 1 from pandapay.sms_shared_category_rules()
                  where merchant_key = 'OTHER SLUG SHOP' and category_slug = 'other') then
    raise exception 'the "other" spend category is not accepted';
  end if;
  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key in ('CASH SLUG SHOP', 'INVESTMENTS SLUG SHOP',
                                    'INCOME SLUG SHOP', 'SUBSCRIPTION SLUG SHOP')) then
    raise exception 'a non-canonical spend slug reached the category aggregate';
  end if;
end $$;

-- Column contracts.
do $$
begin
  begin
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at, fact_key
    ) values ('22000000-0000-0000-0000-000000000001', gen_random_uuid(),
              repeat('f', 64), repeat('b', 64), 'edited', 'transaction',
              'sms-shared-learning-v2', now(), 'not-a-fact-key');
    raise exception 'a malformed fact_key was accepted';
  exception when check_violation then null;
  end;
end $$;

do $$
begin
  begin
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at, correction_kind
    ) values ('22000000-0000-0000-0000-000000000001', gen_random_uuid(),
              repeat('f', 64), repeat('b', 64), 'edited', 'transaction',
              'sms-shared-learning-v2', now(), 'not_a_kind');
    raise exception 'an unknown correction_kind was accepted';
  exception when check_violation then null;
  end;

  begin
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at, commitment_category
    ) values ('22000000-0000-0000-0000-000000000001', gen_random_uuid(),
              repeat('f', 64), repeat('b', 64), 'edited', 'bill',
              'sms-shared-learning-v2', now(), 'government');
    raise exception 'a spend category was accepted as a commitment category';
  exception when check_violation then null;
  end;
end $$;

-- Consent withdrawal removes the vote even when the correction is current.
set local role app_user;
select set_config('app.user_id', '22000000-0000-0000-0000-000000000010', true);
select pandapay.sms_delete_learning_examples_for_user(
  '22000000-0000-0000-0000-000000000010');
reset role;

do $$
begin
  if exists (select 1 from public.sms_learning_feedback_events
             where profile_id = '22000000-0000-0000-0000-000000000010') then
    raise exception 'consent withdrawal left event rows behind';
  end if;
end $$;

do $$
begin
  raise notice 'C2 correction envelope, taxonomy and aggregate gates passed';
end $$;

rollback;
