\set ON_ERROR_STOP on
begin;

do $$
declare
  i integer;
  v_users integer;
  v_category text;
  v_rate numeric;
begin
  -- Alpha has 11/12 distinct current contributors agreeing. The one user
  -- who changes their vote later must count only once, using the latest vote.
  for i in 1..12 loop
    insert into public.profiles (id, contributions_opt_in)
    values (('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, true)
    on conflict (id) do update set contributions_opt_in = true;
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'sms_shared_learning', 'test-v1', true);
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, merchant_key, category_slug,
      original_category_slug, created_at
    ) values (
      ('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, gen_random_uuid(),
      repeat(lpad(to_hex(i), 2, '0'), 32), repeat(lpad(to_hex(i + 16), 2, '0'), 32),
      'category_changed', 'transaction', 'test-v1', 'ALPHA MARKET',
      case when i = 12 then 'dining' else 'groceries' end, 'dining', now()
    );
  end loop;
  -- Later correction from user 12 replaces the older vote for this merchant.
  insert into public.sms_learning_feedback_events (
    profile_id, event_id, source_key_hash, sender_fingerprint, action,
    resolved_kind, consent_policy_version, merchant_key, category_slug,
    original_category_slug, created_at
  ) values (
    '10000000-0000-0000-0000-000000000012', gen_random_uuid(), repeat('a', 64), repeat('b', 64),
    'category_changed', 'transaction', 'test-v1', 'ALPHA MARKET', 'groceries', 'dining', now() + interval '1 second'
  );

  for i in 21..32 loop
    insert into public.profiles (id, contributions_opt_in)
    values (('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, true)
    on conflict (id) do update set contributions_opt_in = true;
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'sms_shared_learning', 'test-v1', true);
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, merchant_key, category_slug,
      created_at
    ) values (
      ('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, gen_random_uuid(),
      repeat(lpad(to_hex(i), 2, '0'), 32), repeat(lpad(to_hex(i + 16), 2, '0'), 32),
      'category_changed', 'transaction', 'test-v1', 'CONTESTED STORE',
      case when i <= 30 then 'groceries' else 'dining' end, now()
    );
  end loop;

  select support_count, category_slug, agreement_rate
    into v_users, v_category, v_rate
    from pandapay.sms_shared_category_rules()
   where merchant_key = 'ALPHA MARKET';
  if v_users <> 12 or v_category <> 'groceries' or v_rate <> 1 then
    raise exception 'latest correction aggregation was wrong: %, %, %', v_users, v_category, v_rate;
  end if;

  if exists (select 1 from pandapay.sms_shared_category_rules() where merchant_key = 'CONTESTED STORE') then
    raise exception 'contested merchant category should abstain';
  end if;

  -- Missing or revoked consent must stop contributing immediately.
  for i in 41..50 loop
    insert into public.profiles (id, contributions_opt_in)
    values (('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, true)
    on conflict (id) do update set contributions_opt_in = true;
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'sms_shared_learning', 'test-v1', true);
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, merchant_key, category_slug, created_at
    ) values (
      ('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, gen_random_uuid(),
      repeat(lpad(to_hex(i), 2, '0'), 32), repeat(lpad(to_hex(i + 16), 2, '0'), 32),
      'category_changed', 'transaction', 'test-v1', 'CONSENT TEST', 'fuel', now()
    );
  end loop;
  insert into public.user_consents (profile_id, purpose, policy_version, granted)
  values ('10000000-0000-0000-0000-000000000041', 'sms_shared_learning', 'test-v2', false);
  if exists (select 1 from pandapay.sms_shared_category_rules() where merchant_key = 'CONSENT TEST') then
    raise exception 'latest revoked consent was counted in shared category support';
  end if;

  raise notice 'shared SMS category rules: threshold, consensus, latest correction, and consent checks passed';
end $$;

rollback;
