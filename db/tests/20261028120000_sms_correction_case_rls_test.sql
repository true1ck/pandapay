\set ON_ERROR_STOP on
-- Admins can review consented correction cases under app_user RLS, while a
-- non-admin sees only their own rows and revoked-consent evidence stays hidden.
begin;

insert into public.profiles (id, contributions_opt_in) values
  ('23000000-0000-0000-0000-000000000001', true),
  ('23000000-0000-0000-0000-000000000002', true),
  ('23000000-0000-0000-0000-000000000003', true);
insert into public.admin_users (id, email, role, is_active)
values ('23000000-0000-0000-0000-000000000001', 'sms-review-test@example.invalid', 'operator', true);
insert into public.user_consents (profile_id, purpose, policy_version, granted) values
  ('23000000-0000-0000-0000-000000000002', 'sms_shared_learning', 'sms-shared-learning-v2', true),
  ('23000000-0000-0000-0000-000000000003', 'sms_shared_learning', 'sms-shared-learning-v2', true);
insert into public.user_consents (profile_id, purpose, policy_version, granted)
values ('23000000-0000-0000-0000-000000000003', 'sms_shared_learning', 'sms-shared-learning-v2', false);

insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug
)
select c.profile_id, gen_random_uuid(),
       case c.profile_id when '23000000-0000-0000-0000-000000000002'::uuid then repeat('2',64) else repeat('3',64) end,
       repeat('f',64), 'category_changed', 'transaction',
       'sms-shared-learning-v2', c.granted_at, 'TEST SHOP', 'dining', 'travel'
  from (select distinct on (profile_id) profile_id, granted_at
          from public.user_consents
         where profile_id in ('23000000-0000-0000-0000-000000000002',
                              '23000000-0000-0000-0000-000000000003')
           and purpose = 'sms_shared_learning'
         order by profile_id, granted_at, id) c;

set local role app_user;
select set_config('app.user_id', '23000000-0000-0000-0000-000000000001', true);
do $$
begin
  if (select count(*) from public.sms_learning_feedback_events) <> 1 then
    raise exception 'admin must see the currently consented correction but not revoked evidence';
  end if;
end $$;

select set_config('app.user_id', '23000000-0000-0000-0000-000000000002', true);
do $$
begin
  if (select count(*) from public.sms_learning_feedback_events) <> 1 then
    raise exception 'non-admin must see only their own correction';
  end if;
  begin
    insert into public.sms_learning_feedback_events (
      profile_id, event_id, source_key_hash, sender_fingerprint, action,
      resolved_kind, consent_policy_version, consent_granted_at,
      decision_origin, decision_rule_id
    ) values (
      '23000000-0000-0000-0000-000000000002', gen_random_uuid(), repeat('4',64),
      repeat('f',64), 'edited', 'transaction', 'sms-shared-learning-v2',
      (select granted_at from public.user_consents
        where profile_id = '23000000-0000-0000-0000-000000000002'
          and purpose = 'sms_shared_learning' and granted),
      'shared_rule', 'invented-rule-id'
    );
    raise exception 'a client attached an unverified rule id';
  exception when insufficient_privilege then
    null;
  end;
end $$;
reset role;

rollback;
