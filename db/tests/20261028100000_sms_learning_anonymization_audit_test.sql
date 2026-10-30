\set ON_ERROR_STOP on
-- DB audit extension: checks 7-12 must fire on the shared-learning surfaces
-- and stay silent on a clean database. Runs in a rolled-back transaction.
-- Covers the schema guard, OTP and PAN redaction leaks, the consent gate for
-- shared evidence, the canonical category taxonomy, and admin-only bundle
-- publication -- each violation is inserted, proven to be detected, then
-- removed so the next scenario starts from a clean finding set.

begin;

-- One consenting profile is the baseline every shared-learning row needs.
insert into public.profiles (id, contributions_opt_in)
values ('36000000-0000-0000-0000-000000000001'::uuid, true);
insert into public.user_consents (profile_id, purpose, policy_version, granted)
values ('36000000-0000-0000-0000-000000000001'::uuid,
        'sms_shared_learning', 'sms-shared-learning-v2', true);

create function pg_temp.audit_findings() returns jsonb language plpgsql as $$
declare v_id uuid; v jsonb;
begin
  -- Two statements, not one: the audit row is this function's own side effect,
  -- and a single statement cannot see it (same reason the CI job splits them).
  v_id := pandapay.run_anonymization_audit('db-audit-test');
  select findings into v from anonymization_audit_runs where id = v_id;
  return v;
end $$;

create function pg_temp.audit_failed() returns integer language plpgsql as $$
declare v_id uuid; v integer;
begin
  v_id := pandapay.run_anonymization_audit('db-audit-test');
  select checks_failed into v from anonymization_audit_runs where id = v_id;
  return v;
end $$;

-- Clean database: the twelve checks all pass, and the six new shared-learning
-- checks are present in the total rather than silently missing.
do $$
declare v_total integer; v_failed integer;
begin
  v_failed := pg_temp.audit_failed();
  select checks_total into v_total from anonymization_audit_runs
   where run_by = 'ci' order by ran_at desc limit 1;
  if v_total <> 12 then
    raise exception 'expected 12 audit checks, got %', v_total;
  end if;
  if v_failed <> 0 then
    raise exception 'a clean shared-learning database failed the audit: % check(s)', v_failed;
  end if;
end $$;

-- Check 7: a raw-message or direct-identity column on a shared-learning table.
alter table public.sms_learning_examples add column raw_body text;
do $$
begin
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_no_identity_columns"}]'::jsonb) then
    raise exception 'a raw_body column on sms_learning_examples went undetected';
  end if;
end $$;
alter table public.sms_learning_examples drop column raw_body;

-- Check 8: an OTP message recorded as shared training evidence.
insert into public.sms_learning_examples
  (profile_id, sender_fingerprint, fact_family, template_text, sample_body, user_hash)
values ('36000000-0000-0000-0000-000000000001'::uuid, repeat('a', 64),
        'posted_movement', 'Your OTP is {REF} and never share it',
        'Your OTP is TESTREF123456 and never share it', repeat('b', 64));
do $$
begin
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_no_otp_evidence"}]'::jsonb) then
    raise exception 'an OTP example escaped the shared-learning audit';
  end if;
  delete from public.sms_learning_examples
   where template_text = 'Your OTP is {REF} and never share it';
  if (pg_temp.audit_findings() @> '[{"check":"shared_learning_no_otp_evidence"}]'::jsonb) then
    raise exception 'the OTP finding survived its removal';
  end if;
end $$;

-- Check 9: a full card number left unredacted in stored evidence.
insert into public.sms_learning_feedback_events
  (profile_id, event_id, source_key_hash, sender_fingerprint, action,
   resolved_kind, consent_policy_version, consent_granted_at,
   correction_kind, decision_origin, redacted_pattern)
values ('36000000-0000-0000-0000-000000000001'::uuid, gen_random_uuid(),
        repeat('c', 64), repeat('a', 64), 'edited', 'transaction',
        'sms-shared-learning-v2', now(), 'wrong_amount', 'manual',
        'Spent Rs. 500 on card 4111111111111111 at SHOP');
do $$
begin
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_no_pan_evidence"}]'::jsonb) then
    raise exception 'an unredacted card number escaped the shared-learning audit';
  end if;
  delete from public.sms_learning_feedback_events
   where redacted_pattern = 'Spent Rs. 500 on card 4111111111111111 at SHOP';
end $$;

-- Check 10: shared evidence for a profile that no longer consents. The purge
-- helpers are what normally remove these rows; a surviving row is the leak.
insert into public.profiles (id, contributions_opt_in)
values ('36000000-0000-0000-0000-000000000002'::uuid, true);
insert into public.user_consents (profile_id, purpose, policy_version, granted)
values ('36000000-0000-0000-0000-000000000002'::uuid,
        'sms_shared_learning', 'sms-shared-learning-v2', true);
insert into public.user_consents
  (profile_id, purpose, policy_version, granted, granted_at)
values ('36000000-0000-0000-0000-000000000002'::uuid,
        'sms_shared_learning', 'sms-shared-learning-v2', false,
        now() + interval '1 second');
insert into public.sms_learning_examples
  (profile_id, sender_fingerprint, fact_family, template_text, sample_body, user_hash)
values ('36000000-0000-0000-0000-000000000002'::uuid, repeat('a', 64),
        'posted_movement', 'INR {AMOUNT} spent at {MERCHANT}',
        'INR Rs. 123.45 spent at MerchantTest', repeat('d', 64));
insert into public.sms_learning_feedback_events
  (profile_id, event_id, source_key_hash, sender_fingerprint, action,
   resolved_kind, consent_policy_version, consent_granted_at)
select '36000000-0000-0000-0000-000000000002'::uuid, gen_random_uuid(),
       repeat('9', 64), repeat('a', 64), 'edited', 'transaction',
       'sms-shared-learning-v2', min(granted_at)
  from public.user_consents
 where profile_id = '36000000-0000-0000-0000-000000000002'::uuid
   and purpose = 'sms_shared_learning' and granted;
do $$
begin
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_consent_gated"}]'::jsonb) then
    raise exception 'evidence for a withdrawn consent went undetected';
  end if;
  delete from public.sms_learning_examples
   where template_text = 'INR {AMOUNT} spent at {MERCHANT}';
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_consent_gated"}]'::jsonb) then
    raise exception 'feedback event surviving opt-out escaped the consent audit';
  end if;
  delete from public.sms_learning_feedback_events
   where source_key_hash = repeat('9', 64);
  -- A new grant must not make evidence from an earlier grant appear current.
  insert into public.user_consents
    (profile_id, purpose, policy_version, granted, granted_at)
  values ('36000000-0000-0000-0000-000000000002'::uuid,
          'sms_shared_learning', 'sms-shared-learning-v3', true,
          now() + interval '2 seconds');
  insert into public.sms_learning_feedback_events
    (profile_id, event_id, source_key_hash, sender_fingerprint, action,
     resolved_kind, consent_policy_version, consent_granted_at)
  select '36000000-0000-0000-0000-000000000002'::uuid, gen_random_uuid(),
         repeat('8', 64), repeat('a', 64), 'edited', 'transaction',
         'sms-shared-learning-v2', min(granted_at)
    from public.user_consents
   where profile_id = '36000000-0000-0000-0000-000000000002'::uuid
     and purpose = 'sms_shared_learning' and granted
     and policy_version = 'sms-shared-learning-v2';
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_consent_gated"}]'::jsonb) then
    raise exception 'old grant evidence passed after consent was re-granted';
  end if;
  delete from public.sms_learning_feedback_events
   where source_key_hash = repeat('8', 64);
  -- No consent row at all is the same violation.
  insert into public.sms_learning_examples
    (profile_id, sender_fingerprint, fact_family, template_text, sample_body, user_hash)
    select '36000000-0000-0000-0000-000000000002'::uuid, repeat('a', 64),
           'posted_movement', 'INR {AMOUNT} paid to {MERCHANT}',
           'INR Rs. 123.45 paid to MerchantTest', repeat('e', 64);
  delete from public.user_consents
   where profile_id = '36000000-0000-0000-0000-000000000002'::uuid;
  if not (pg_temp.audit_findings() @> '[{"check":"shared_learning_consent_gated"}]'::jsonb) then
    raise exception 'evidence for a profile with no consent went undetected';
  end if;
  delete from public.sms_learning_examples
   where template_text = 'INR {AMOUNT} paid to {MERCHANT}';
end $$;

-- Check 11: a commitment kind approved as if it were a spend category.
insert into public.sms_category_rule_approvals
  (merchant_key, category_slug, status, reviewed_by, reason,
   support_count_at_review, agreement_rate_at_review)
values ('NETFLIX.COM', 'subscription', 'approved',
        '36000000-0000-0000-0000-000000000001'::uuid,
        'Operator approved an out-of-taxonomy slug', 12, 0.95);
do $$
begin
  if not (pg_temp.audit_findings() @> '[{"check":"category_approvals_canonical_taxonomy"}]'::jsonb) then
    raise exception 'an out-of-taxonomy approved category went undetected';
  end if;
  delete from public.sms_category_rule_approvals where category_slug = 'subscription';
  -- The canonical slugs stay clean.
  insert into public.sms_category_rule_approvals
    (merchant_key, category_slug, status, reviewed_by, reason,
     support_count_at_review, agreement_rate_at_review)
  values ('NETFLIX.COM', 'entertainment', 'approved',
          '36000000-0000-0000-0000-000000000001'::uuid,
          'Operator approved a canonical category', 12, 0.95);
  if (pg_temp.audit_findings() @> '[{"check":"category_approvals_canonical_taxonomy"}]'::jsonb) then
    raise exception 'a canonical approved category was reported as a violation';
  end if;
  -- A rejection records no shared rule, so its slug is not a delivery claim.
  delete from public.sms_category_rule_approvals;
  insert into public.sms_category_rule_approvals
    (merchant_key, category_slug, status, reviewed_by, reason,
     support_count_at_review, agreement_rate_at_review)
  values ('NETFLIX.COM', 'subscription', 'rejected',
          '36000000-0000-0000-0000-000000000001'::uuid,
          'Operator rejected an out-of-taxonomy slug', 12, 0.95);
  if (pg_temp.audit_findings() @> '[{"check":"category_approvals_canonical_taxonomy"}]'::jsonb) then
    raise exception 'a rejected category was reported as a violation';
  end if;
  delete from public.sms_category_rule_approvals;
end $$;

-- Check 12: a worker-authored bundle active for devices again.
insert into public.sms_rule_bundles (bundle_version, rules, sha256, published_by, is_active)
values (987654, '[{"id":"db-audit-rule"}]'::jsonb, repeat('f', 64), null, true);
do $$
begin
  if not (pg_temp.audit_findings() @> '[{"check":"active_bundles_admin_published"}]'::jsonb) then
    raise exception 'an active bundle with no publishing operator went undetected';
  end if;
  delete from public.sms_rule_bundles where bundle_version = 987654;
  -- Withdrawing the same bundle is not a violation: only active rows are served.
  insert into public.sms_rule_bundles (bundle_version, rules, sha256, published_by, is_active)
  values (987655, '[{"id":"db-audit-rule"}]'::jsonb, repeat('f', 64), null, false);
  if (pg_temp.audit_findings() @> '[{"check":"active_bundles_admin_published"}]'::jsonb) then
    raise exception 'an inactive legacy bundle was reported as a violation';
  end if;
  delete from public.sms_rule_bundles where bundle_version = 987655;
end $$;

-- Everything removed: the audit is clean again, so no scenario leaked into the
-- next one.
do $$
begin
  if pg_temp.audit_failed() <> 0 then
    raise exception 'the audit did not return to a clean state after the fixtures were removed';
  end if;
end $$;

-- POST /admin/anonymization-audit-runs/run executes the audit on the app role's
-- connection, so EXECUTE must survive the re-create. Checked through the
-- privilege catalog rather than by running it: the function is not SECURITY
-- DEFINER, so a real insert also needs is_admin(), which needs app.user_id.
set local role app_user;
do $$
begin
  if not has_function_privilege('app_user', 'pandapay.run_anonymization_audit(text)', 'execute') then
    raise exception 'app_user lost EXECUTE on the re-created audit function';
  end if;
end $$;
reset role;

do $$
begin
  raise notice 'DB audit shared-learning checks 7-12 passed';
end $$;

rollback;
