\set ON_ERROR_STOP on
-- A category can be shared only for the exact institutional sender and
-- category-discriminating context. Legacy merchant-only approvals are not
-- upgraded by this migration.
begin;

insert into public.profiles (id, contributions_opt_in)
select ('26000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, true
  from generate_series(1, 10) i;
insert into public.user_consents (profile_id, purpose, policy_version, granted)
select ('26000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'sms_shared_learning', 'sms-shared-learning-v2', true
  from generate_series(1, 10) i;

-- The same ten users support two different category labels for one merchant
-- and sender, distinguished by their message context.
insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug,
  correction_kind, redacted_pattern, review_status,
  sender_key, context_key, fact_family
)
select c.profile_id, gen_random_uuid(), lpad(i::text, 64, '0'), repeat('f', 64),
       'category_changed', 'transaction', c.policy_version, c.granted_at,
       'MIXED MERCHANT', 'travel', case when i = 1 then null else 'online' end,
       case when i = 1 then null else 'misclassified_category' end,
       'Flight booking at {MERCHANT}', 'approved',
       'TX-MNTPRO-S', 'FLIGHT|TRAVEL', 'posted_movement'
  from generate_series(1, 10) i
  join public.user_consents c
    on c.profile_id = ('26000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid
   and c.purpose = 'sms_shared_learning' and c.granted;

-- A presentation preference from one of those users must not become a vote,
-- even when it carries a valid scoped context and admin review status.
insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug,
  correction_kind, redacted_pattern, review_status,
  sender_key, context_key, fact_family
)
select c.profile_id, gen_random_uuid(), repeat('c', 64), repeat('f', 64),
       'category_changed', 'transaction', c.policy_version, c.granted_at,
       'MIXED MERCHANT', 'other', 'travel', 'preference_only',
       'Flight at {MERCHANT}', 'approved', 'TX-MNTPRO-S',
       'FLIGHT|TRAVEL', 'posted_movement'
  from public.user_consents c
 where c.profile_id = '26000000-0000-0000-0000-000000000001'
   and c.purpose = 'sms_shared_learning' and c.granted;

-- Legacy/unsupported spend labels remain out of the shared category taxonomy.
insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug,
  correction_kind, redacted_pattern, review_status,
  sender_key, context_key, fact_family
)
select c.profile_id, gen_random_uuid(), repeat('d', 64), repeat('f', 64),
       'category_changed', 'transaction', c.policy_version, c.granted_at,
       'MIXED MERCHANT', 'investments', 'travel', 'misclassified_category',
       'Flight at {MERCHANT}', 'approved', 'TX-MNTPRO-S',
       'FLIGHT|TRAVEL', 'posted_movement'
  from public.user_consents c
 where c.profile_id = '26000000-0000-0000-0000-000000000001'
   and c.purpose = 'sms_shared_learning' and c.granted;

insert into public.sms_learning_feedback_events (
  profile_id, event_id, source_key_hash, sender_fingerprint, action,
  resolved_kind, consent_policy_version, consent_granted_at,
  merchant_key, category_slug, original_category_slug,
  correction_kind, redacted_pattern, review_status,
  sender_key, context_key, fact_family
)
select c.profile_id, gen_random_uuid(), lpad((i + 20)::text, 64, '0'), repeat('f', 64),
       'category_changed', 'transaction', c.policy_version, c.granted_at,
       'MIXED MERCHANT', 'online', 'travel', 'misclassified_category',
       'Subscription renewal at {MERCHANT}', 'approved',
       'TX-MNTPRO-S', 'RENEWAL|SUBSCRIPTION', 'posted_movement'
  from generate_series(1, 10) i
  join public.user_consents c
    on c.profile_id = ('26000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid
   and c.purpose = 'sms_shared_learning' and c.granted;

insert into public.sms_category_rule_v2_approvals (
  merchant_key, sender_key, context_key, fact_family, category_slug,
  status, reviewed_by, reason, support_count_at_review, agreement_rate_at_review
)
values (
  'MIXED MERCHANT', 'TX-MNTPRO-S', 'FLIGHT|TRAVEL', 'posted_movement',
  'travel', 'approved', '26000000-0000-0000-0000-000000000001',
  'isolated category context', 10, 1.0
);

set local role app_user;
do $$
begin
  if pandapay.sms_category_context_key_valid('PERSONALNAME') or
     pandapay.sms_category_context_key_valid('TRAVEL|FLIGHT') or
     pandapay.sms_category_context_key_valid('FLIGHT|FLIGHT') then
    raise exception 'database accepted non-allowlisted or noncanonical context';
  end if;
  if (select count(*) from pandapay.sms_shared_category_rules_v2()
       where merchant_key = 'MIXED MERCHANT'
         and sender_key = 'TX-MNTPRO-S'
         and context_key = 'FLIGHT|TRAVEL'
         and fact_family = 'posted_movement'
         and category_slug = 'travel'
         and support_count = 10) <> 1 then
    raise exception 'flight context aggregate missing or not independently supported';
  end if;
  if exists (select 1 from pandapay.sms_shared_category_rules_v2()
              where category_slug in ('investments', 'income', 'cash')) then
    raise exception 'legacy spend label entered the v2 category vocabulary';
  end if;
  if (select count(*) from pandapay.sms_shared_category_rules_v2()
       where merchant_key = 'MIXED MERCHANT'
         and context_key = 'RENEWAL|SUBSCRIPTION'
         and category_slug = 'online'
         and support_count = 10) <> 1 then
    raise exception 'subscription context aggregate missing or merged with flight context';
  end if;
  if (select count(*) from pandapay.sms_approved_category_rules_v2()
       where merchant_key = 'MIXED MERCHANT') <> 1 then
    raise exception 'only the exact approved tuple should be served';
  end if;
  if (select count(*) from pandapay.sms_approved_category_rules_v2()
       where context_key = 'RENEWAL|SUBSCRIPTION') <> 0 then
    raise exception 'unapproved context was served';
  end if;
end $$;
reset role;

-- Regranting after revocation must not resurrect evidence captured under the
-- earlier consent grant, even if the purpose is currently granted again.
update public.user_consents
   set granted = false
 where profile_id = '26000000-0000-0000-0000-000000000001'
   and purpose = 'sms_shared_learning';
insert into public.user_consents (profile_id, purpose, policy_version, granted, granted_at)
values ('26000000-0000-0000-0000-000000000001', 'sms_shared_learning',
        'sms-shared-learning-v2', true, now() + interval '1 second');
do $$
begin
  if not (select granted
            from public.user_consents
           where profile_id = '26000000-0000-0000-0000-000000000001'
             and purpose = 'sms_shared_learning'
           order by granted_at desc, granted asc, id desc
           limit 1) then
    raise exception 'regrant fixture did not establish a current true consent';
  end if;
end $$;
set local role app_user;
do $$
begin
  if (select count(*) from pandapay.sms_shared_category_rules_v2()
       where merchant_key = 'MIXED MERCHANT'
         and context_key = 'FLIGHT|TRAVEL'
         and category_slug = 'travel') <> 0 then
    raise exception 'stale evidence survived consent revoke and regrant';
  end if;
end $$;
reset role;

rollback;
