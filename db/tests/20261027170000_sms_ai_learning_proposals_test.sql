\set ON_ERROR_STOP on
begin;

do $$
declare
  i integer;
  pid uuid;
  grant_time timestamptz;
begin
  for i in 1..10 loop
    pid := ('20000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.profiles (id, contributions_opt_in) values (pid, true);
    insert into public.user_consents (profile_id, purpose, policy_version, granted)
    values (pid, 'sms_shared_learning', 'sms-shared-learning-v2', true)
    returning granted_at into grant_time;
    insert into public.sms_ai_learning_proposals (
      profile_id, event_id, source_key_hash, sender_fingerprint, user_hash,
      issuer_prefix, sender_pattern, redacted_pattern, template_text,
      synthetic_sample, fact_family, resolved_kind, proposed_fields,
      ai_score, consent_policy_version, consent_granted_at
    ) values (
      pid, gen_random_uuid(), repeat('a', 64), repeat('b', 64),
      lpad(to_hex(i), 64, '0'), 'BANK', 'BANK',
      '{AMOUNT} paid at TEST SHOP', '{AMOUNT} paid at TEST SHOP',
      'Rs. 123.45 paid at TEST SHOP', 'posted_movement', 'transaction',
      '{"merchant":"TEST SHOP","categorySlug":"groceries"}'::jsonb,
      0.95, 'sms-shared-learning-v2', grant_time
    );
  end loop;

  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key = 'TEST SHOP') then
    raise exception 'pending AI proposals must not count as category votes';
  end if;

  update public.sms_ai_learning_proposals
     set status = 'approved', reviewed_at = now()
   where proposed_fields->>'merchant' = 'TEST SHOP';

  if not exists (select 1 from pandapay.sms_shared_category_rules()
                 where merchant_key = 'TEST SHOP' and category_slug = 'groceries'
                   and support_count = 10 and agreement_rate = 1) then
    raise exception 'approved AI proposals did not produce ten distinct votes';
  end if;

  insert into public.user_consents
    (profile_id, purpose, policy_version, granted, granted_at)
  values ('20000000-0000-0000-0000-000000000001', 'sms_shared_learning',
          'sms-shared-learning-v2', false, now() + interval '1 second');

  if exists (select 1 from pandapay.sms_shared_category_rules()
             where merchant_key = 'TEST SHOP') then
    raise exception 'revoked AI proposal still contributes to threshold';
  end if;
  if exists (select 1 from public.sms_ai_learning_proposals
             where profile_id = '20000000-0000-0000-0000-000000000001') then
    raise exception 'revocation did not delete the user AI proposals';
  end if;
  raise notice 'AI proposal approval and revocation gates passed';
end $$;

-- The API uses app_user for admin review. It must see the proposal owner's
-- consent, while a normal user must not see another profile's consent.
insert into public.profiles (id, contributions_opt_in)
values ('20000000-0000-0000-0000-000000000011', true);
insert into public.admin_users (id, email, role, is_active)
values ('20000000-0000-0000-0000-000000000011',
        'sms-learning-admin-fixture@example.invalid', 'operator', true);

set local role app_user;
select set_config('app.user_id', '20000000-0000-0000-0000-000000000002', true);
do $$
begin
  if exists (select 1 from public.user_consents
              where profile_id = '20000000-0000-0000-0000-000000000003'
                and purpose = 'sms_shared_learning') then
    raise exception 'ordinary user read another profile consent';
  end if;
end $$;

select set_config('app.user_id', '20000000-0000-0000-0000-000000000011', true);
do $$
begin
  if not exists (select 1 from public.user_consents
                  where profile_id = '20000000-0000-0000-0000-000000000003'
                    and purpose = 'sms_shared_learning') then
    raise exception 'admin cannot verify AI proposal owner consent';
  end if;
end $$;
reset role;

rollback;
