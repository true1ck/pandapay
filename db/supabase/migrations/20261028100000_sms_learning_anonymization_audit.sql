-- DB audit extension: the deploy-blocking anonymization gate
-- (`pandapay.run_anonymization_audit`, CI job `anonymization-audit`) predates
-- SMS shared learning. Its six checks cover the crowdsourced merchant tables
-- and `parser_failures` only, so every privacy invariant added by the L13-L15
-- and C1-C9 work is enforced solely in application code. This re-create keeps
-- the six original checks byte-for-byte and adds six DB-level checks over the
-- shared-learning surfaces.

begin;

create or replace function pandapay.run_anonymization_audit(p_sha text default null)
returns uuid language plpgsql as $$
declare v_findings jsonb := '[]'::jsonb; v_failed int := 0; v_total int := 0; v_id uuid; v_n int;
begin
  -- Check 1: no crowdsource table may have a column referencing profiles.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchants','merchant_locations','merchant_contributions',
                        'acceptance_reports','acceptance_summary',
                        'effective_rate_samples','effective_rate_summary')
     and column_name in ('profile_id','user_id','email','device_id');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','no_identity_columns','violations',v_n);
  end if;

  -- Check 2: no coordinate finer than the 4dp grid.
  v_total := v_total + 1;
  select count(*) into v_n from merchant_locations
   where grid_lat <> round(grid_lat,4) or grid_lng <> round(grid_lng,4);
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','grid_snapped_coords','violations',v_n);
  end if;

  -- Check 3: no amount columns in crowdsourced merchant tables.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchants','merchant_locations','merchant_contributions','acceptance_reports')
     and (column_name like '%amount%' or column_name like '%_inr');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','no_amount_columns','violations',v_n);
  end if;

  -- Check 4: contribution timestamps must be DATE precision, never timestamptz.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('merchant_contributions','acceptance_reports','effective_rate_samples')
     and data_type like 'timestamp%';
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','day_precision_only','violations',v_n);
  end if;

  -- Check 5: parser failure telemetry must never contain digits.
  v_total := v_total + 1;
  select count(*) into v_n from parser_failures where redacted_shape ~ '[0-9]';
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','redacted_parser_shapes','violations',v_n);
  end if;

  -- Check 6: RLS enabled on every user-domain table.
  v_total := v_total + 1;
  select count(*) into v_n from pg_tables t
   where t.schemaname='public'
     and t.tablename in ('profiles','user_cards','transactions','card_overrides',
                         'points_ledger','cap_states','milestone_states',
                         'fee_waiver_states','needs_review_items','monthly_reports')
     and not exists (select 1 from pg_class c
                      where c.relname=t.tablename and c.relrowsecurity);
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','rls_enabled','violations',v_n);
  end if;

  -- Check 7: shared learning may only ever hold pseudonymous, redacted text.
  -- sms_learning_examples/sms_ai_learning_proposals feed worker-synthesized
  -- rules and admin review, and sms_learning_feedback_events is the durable
  -- correction case an operator reads. A raw-message or direct-identity column
  -- on any of them would put PII on the aggregation path by schema alone.
  v_total := v_total + 1;
  select count(*) into v_n
    from information_schema.columns
   where table_schema='public'
     and table_name in ('sms_learning_examples','sms_ai_learning_proposals',
                        'sms_learning_feedback_events')
     and column_name in ('email','phone','mobile','device_id','full_name',
                         'account_number','raw_body','sms_body','message_body',
                         'original_body','sender_name');
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','shared_learning_no_identity_columns','violations',v_n);
  end if;

  -- Check 8: an OTP/security-alert message must never become shared evidence.
  -- recordLearningExample refuses the write and the AI queue excludes these
  -- families; this catches any path that reaches the tables without that gate.
  v_total := v_total + 1;
  select count(*) into v_n from (
    select 1 from public.sms_learning_examples
     where template_text ~* '\m(otp|one[ -]?time[ -]?password|cvv|cvn|verification code)\M'
    union all
    select 1 from public.sms_ai_learning_proposals
     where coalesce(redacted_pattern,'') ~* '\m(otp|one[ -]?time[ -]?password|cvv|cvn|verification code)\M'
        or coalesce(template_text,'')   ~* '\m(otp|one[ -]?time[ -]?password|cvv|cvn|verification code)\M'
    union all
    select 1 from public.sms_learning_feedback_events
     where coalesce(redacted_pattern,'') ~* '\m(otp|one[ -]?time[ -]?password|cvv|cvn|verification code)\M'
  ) sensitive;
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','shared_learning_no_otp_evidence','violations',v_n);
  end if;

  -- Check 9: no primary account number may survive redaction. redactBody
  -- collapses runs of 11-19 digits to XXXX plus the last four, so a full PAN
  -- in stored evidence means the write bypassed the redactor.
  v_total := v_total + 1;
  select count(*) into v_n from (
    select 1 from public.sms_learning_examples where template_text ~ '\d{15,16}'
    union all
    select 1 from public.sms_ai_learning_proposals
     where coalesce(redacted_pattern,'') ~ '\d{15,16}'
        or coalesce(template_text,'') ~ '\d{15,16}'
    union all
    select 1 from public.sms_learning_feedback_events
     where coalesce(redacted_pattern,'') ~ '\d{15,16}'
  ) pan;
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','shared_learning_no_pan_evidence','violations',v_n);
  end if;

  -- Check 10: shared evidence may only exist for a profile that currently
  -- consents. Consent is checked on write and withdrawn evidence is purged by
  -- sms_delete_learning_examples_for_user / sms_purge_ai_proposals_on_opt_out;
  -- a row surviving revocation is exactly the leak that gate describes.
  v_total := v_total + 1;
  with latest_consent as (
    select distinct on (profile_id)
           profile_id, granted, policy_version, granted_at
      from public.user_consents
     where purpose = 'sms_shared_learning'
     order by profile_id, granted_at desc, granted asc, id desc
  )
  select count(*) into v_n from (
    select e.profile_id from public.sms_learning_examples e
      left join latest_consent c on c.profile_id = e.profile_id
     where e.profile_id is not null
       and (c.granted is distinct from true
         or e.created_at < c.granted_at)
    union all
    select p.profile_id from public.sms_ai_learning_proposals p
      left join latest_consent c on c.profile_id = p.profile_id
     where p.profile_id is not null
       and (c.granted is distinct from true
         or p.consent_policy_version is distinct from c.policy_version
         or p.consent_granted_at is distinct from c.granted_at)
    union all
    select e.profile_id from public.sms_learning_feedback_events e
      left join latest_consent c on c.profile_id = e.profile_id
     where e.profile_id is not null
       and (c.granted is distinct from true
         or e.consent_policy_version is distinct from c.policy_version
         or e.consent_granted_at is distinct from c.granted_at)
  ) unconsented;
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','shared_learning_consent_gated','violations',v_n);
  end if;

  -- Check 11: an approved merchant category must be a canonical app/API spend
  -- slug. The delivery aggregate re-derives the pair and filters to this list,
  -- so an out-of-taxonomy approval is already withheld from devices; it still
  -- must not be recorded, because 'subscription' and friends are commitment
  -- kinds, not spend categories.
  v_total := v_total + 1;
  select count(*) into v_n from public.sms_category_rule_approvals
   where status = 'approved'
     and category_slug not in (
       'groceries','fuel','dining','online','travel','bills','rent',
       'insurance','education','government','wallet','entertainment',
       'health','emi','other'
     );
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','category_approvals_canonical_taxonomy','violations',v_n);
  end if;

  -- Check 12: only an operator may leave a rule bundle active for devices.
  -- Worker-authored bundles predate the admin publication gate and are
  -- withdrawn by 20261027160000; an active NULL published_by row means one
  -- became live again without a review record.
  v_total := v_total + 1;
  select count(*) into v_n from public.sms_rule_bundles
   where is_active and published_by is null;
  if v_n > 0 then
    v_failed := v_failed + 1;
    v_findings := v_findings || jsonb_build_object('check','active_bundles_admin_published','violations',v_n);
  end if;

  insert into anonymization_audit_runs (run_by, checks_total, checks_failed, findings, git_sha)
  values ('ci', v_total, v_failed, v_findings, p_sha)
  returning id into v_id;
  return v_id;
end $$;

comment on function pandapay.run_anonymization_audit(text) is
  'Deploy-blocking privacy audit. Checks 1-6 cover the crowdsourced merchant '
  'surface; checks 7-12 cover SMS shared learning: no identity or raw-message '
  'columns, no OTP or PAN evidence, consent required for shared evidence, '
  'canonical category taxonomy, admin-only active rule bundles.';

commit;
