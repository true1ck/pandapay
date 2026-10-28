\set ON_ERROR_STOP on
-- Category approval evidence must match the exact category and current
-- consented/admin-approved correction, never a different merchant context.
begin;

insert into public.profiles (id, contributions_opt_in) values
  ('24000000-0000-0000-0000-000000000001', true),
  ('24000000-0000-0000-0000-000000000002', true);
insert into public.admin_users (id, email, role, is_active)
values ('24000000-0000-0000-0000-000000000001', 'category-evidence@example.invalid', 'operator', true);
insert into public.user_consents (profile_id, purpose, policy_version, granted) values
  ('24000000-0000-0000-0000-000000000002', 'sms_shared_learning', 'sms-shared-learning-v2', true);

insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug,
  correction_kind, redacted_pattern, review_status
)
select '24000000-0000-0000-0000-000000000002', gen_random_uuid(),
       repeat('a', 64), repeat('f', 64), 'category_changed', 'transaction',
       'sms-shared-learning-v2', c.granted_at,
       'MIXED MERCHANT', 'travel', 'online', 'misclassified_category',
       'Booking at {MERCHANT} for INR {AMOUNT}', 'approved'
  from public.user_consents c
 where c.profile_id = '24000000-0000-0000-0000-000000000002'
   and c.purpose = 'sms_shared_learning' and c.granted;

insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug,
  correction_kind, redacted_pattern, review_status
)
select '24000000-0000-0000-0000-000000000002', gen_random_uuid(),
       repeat('b', 64), repeat('f', 64), 'category_changed', 'transaction',
       'sms-shared-learning-v2', c.granted_at,
       'MIXED MERCHANT', 'online', 'travel', 'misclassified_category',
       'Shopping at {MERCHANT} for INR {AMOUNT}', 'approved'
  from public.user_consents c
 where c.profile_id = '24000000-0000-0000-0000-000000000002'
   and c.purpose = 'sms_shared_learning' and c.granted;

set local role app_user;
select set_config('app.user_id', '24000000-0000-0000-0000-000000000001', true);
do $$
begin
  if (select count(*) from pandapay.sms_admin_category_evidence()
       where merchant_key = 'MIXED MERCHANT' and category_slug = 'travel'
         and redacted_pattern = 'Booking at {MERCHANT} for INR {AMOUNT}') <> 1 then
    raise exception 'admin category evidence did not return the exact travel pattern';
  end if;
  if (select count(*) from pandapay.sms_admin_category_evidence()
       where merchant_key = 'MIXED MERCHANT' and category_slug = 'dining') <> 0 then
    raise exception 'category evidence leaked across a different category';
  end if;
end $$;
reset role;

rollback;
