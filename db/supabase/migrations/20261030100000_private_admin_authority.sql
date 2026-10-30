-- Private API database authority. Public runtime GUCs can never satisfy this
-- check: only a connection authenticated as the separately provisioned
-- admin_api_runtime may assert transaction-local actor/permission context.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pandapay_admin_api') THEN
    CREATE ROLE pandapay_admin_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pandapay_admin_api' AND
    (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR rolinherit)) THEN
    RAISE EXCEPTION 'Unsafe private admin API capability';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member='pandapay_admin_api'::regrole) THEN
    RAISE EXCEPTION 'Private admin API capability must not inherit roles';
  END IF;
END $$;

ALTER TABLE public.admin_users ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
-- Preserve inactive/orphan rows for FK and audit attribution. Only active email
-- membership must be unique so a replacement verified UUID can be reconciled.
CREATE UNIQUE INDEX IF NOT EXISTS admin_users_active_email_uq ON public.admin_users(email) WHERE is_active;
DO $$ DECLARE c record; BEGIN
  FOR c IN SELECT conname FROM pg_constraint
    WHERE conrelid='public.admin_users'::regclass AND contype='u'
      AND pg_get_constraintdef(oid) ILIKE '%(email)%'
  LOOP EXECUTE format('ALTER TABLE public.admin_users DROP CONSTRAINT %I',c.conname); END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS admin_users_active_actor ON public.admin_users(id) WHERE is_active;

CREATE TABLE IF NOT EXISTS public.admin_role_permissions (
  role text NOT NULL CHECK(role IN ('owner','operator','reviewer','readonly')),
  permission text NOT NULL CHECK(permission ~ '^[a-z][a-z0-9_.-]{1,100}$'),
  PRIMARY KEY(role,permission)
);
REVOKE ALL ON public.admin_role_permissions FROM PUBLIC;
ALTER TABLE public.admin_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_role_permissions FORCE ROW LEVEL SECURITY;
CREATE POLICY private_admin_permissions_read ON public.admin_role_permissions FOR SELECT TO pandapay_admin_api USING(true);
INSERT INTO public.admin_role_permissions(role,permission) VALUES
 ('readonly','catalogue.read'),('readonly','reference.read'),('readonly','operations.read'),
 ('reviewer','catalogue.read'),('reviewer','reference.read'),('reviewer','operations.read'),('reviewer','review.write'),
 ('operator','catalogue.read'),('operator','reference.read'),('operator','operations.read'),('operator','review.write'),('operator','catalogue.edit'),('operator','support.resolve'),('operator','scraper.configure'),('operator','scraper.run'),('operator','ai.queue.read'),('operator','learning.read'),
 ('owner','catalogue.read'),('owner','reference.read'),('owner','operations.read'),('owner','review.write'),('owner','catalogue.edit'),('owner','support.resolve'),('owner','scraper.configure'),('owner','scraper.run'),('owner','ai.queue.read'),('owner','learning.read'),('owner','catalogue.publish'),('owner','learning.publish'),('owner','referrals.control'),('owner','admin.audit.read'),('owner','admin.audit.run'),('owner','support.evidence.read'),('owner','financial.evidence.read'),('owner','referrals.read'),('owner','ai.queue.run'),('owner','learning.cycle'),('owner','notifications.broadcast')
ON CONFLICT DO NOTHING;
INSERT INTO public.admin_role_permissions(role,permission) VALUES
 ('operator','support.evidence.read') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pandapay.admin_has_permission(p_permission text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE actor uuid; allowed boolean;
BEGIN
  IF session_user <> 'admin_api_runtime' THEN RETURN false; END IF;
  BEGIN actor := nullif(current_setting('pandapay.admin_actor',true),'')::uuid;
  EXCEPTION WHEN OTHERS THEN RETURN false; END;
  IF actor IS NULL OR p_permission IS NULL THEN RETURN false; END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.admin_users u JOIN public.admin_role_permissions rp ON rp.role=u.role
    WHERE u.id=actor AND u.is_active AND rp.permission=p_permission
  ) INTO allowed;
  RETURN coalesce(allowed,false);
END $$;
REVOKE ALL ON FUNCTION pandapay.admin_has_permission(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.admin_has_permission(text) TO pandapay_admin_api;

-- Legacy boolean policy callers remain compatible only inside the private
-- runtime and only when the authority supplied at least one permission.
CREATE OR REPLACE FUNCTION pandapay.is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT session_user='admin_api_runtime'
    AND EXISTS (SELECT 1 FROM public.admin_users u
      WHERE u.id = nullif(current_setting('pandapay.admin_actor',true),'')::uuid AND u.is_active)
$$;
-- Existing customer RLS policies invoke this safe predicate; execution must
-- remain available to public roles, which receive false unless authenticated
-- as the dedicated private login.
GRANT EXECUTE ON FUNCTION pandapay.is_admin() TO PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.is_admin() TO pandapay_admin_api;

-- Restrict the separately authenticated runtime per operation. These policies
-- do not apply to customer logins; their owner/public read rules are preserved.
DO $$ DECLARE r record; read_permission text; write_permissions text[]; cmd text; guard text; BEGIN
  FOR r IN SELECT DISTINCT schemaname,tablename FROM pg_policies
    WHERE schemaname='public' AND (coalesce(qual,'') ILIKE '%is_admin%' OR coalesce(with_check,'') ILIKE '%is_admin%')
  LOOP
    read_permission := CASE
      WHEN r.tablename IN ('admin_users','admin_role_permissions') THEN 'reference.read'
      WHEN r.tablename LIKE 'sms_%' OR r.tablename LIKE 'ai_%' THEN 'learning.read'
      WHEN r.tablename IN ('support_tickets','data_error_reports','abuse_signals') THEN 'support.evidence.read'
      WHEN r.tablename LIKE 'effective_rate%' THEN 'financial.evidence.read'
      WHEN r.tablename IN ('admin_audit_log','anonymization_audit_runs','backup_runs','restore_drills') THEN 'admin.audit.read'
      WHEN r.tablename IN ('sources','source_pages','scrape_runs','page_snapshots','extraction_proposals','policy_change_alerts','policy_alert_evidence','card_requests','merchant_conflicts','parser_failures') THEN 'operations.read'
      ELSE 'catalogue.read' END;
    write_permissions := CASE
      WHEN r.tablename IN ('admin_users','admin_role_permissions') THEN ARRAY[]::text[]
      WHEN r.tablename LIKE 'sms_%' OR r.tablename LIKE 'ai_%' THEN ARRAY['learning.publish','ai.queue.run','learning.cycle','review.write']
      WHEN r.tablename LIKE 'referral%' THEN ARRAY['referrals.control']
      WHEN r.tablename IN ('support_tickets') THEN ARRAY['support.resolve']
      WHEN r.tablename IN ('feature_flags') THEN ARRAY['learning.publish']
      WHEN r.tablename IN ('abuse_signals','merchant_contributions') THEN ARRAY['referrals.control','catalogue.edit','catalogue.publish']
      WHEN r.tablename IN ('sources','source_pages') THEN ARRAY['scraper.configure','scraper.run']
      WHEN r.tablename IN ('scrape_runs','card_requests') THEN ARRAY['scraper.run']
      WHEN r.tablename IN ('policy_change_alerts','policy_alert_evidence') THEN ARRAY['review.write','catalogue.publish']
      WHEN r.tablename IN ('anonymization_audit_runs') THEN ARRAY['admin.audit.run']
      WHEN r.tablename IN ('data_error_reports') THEN ARRAY['review.write','catalogue.publish']
      WHEN r.tablename IN ('admin_audit_log') THEN ARRAY['catalogue.edit','catalogue.publish','review.write','support.resolve','scraper.configure','scraper.run','learning.publish','referrals.control','notifications.broadcast','admin.audit.run']
      ELSE ARRAY['catalogue.edit','catalogue.publish'] END;
    EXECUTE format('CREATE POLICY private_admin_read_guard ON %I.%I AS RESTRICTIVE FOR SELECT TO pandapay_admin_api USING (pandapay.admin_has_permission(%L))',r.schemaname,r.tablename,read_permission);
    guard := format('pandapay.admin_has_permission(current_setting(''pandapay.admin_permission'',true)) AND current_setting(''pandapay.admin_permission'',true)=ANY(%L::text[])',write_permissions);
    EXECUTE format('CREATE POLICY private_admin_insert_guard ON %I.%I AS RESTRICTIVE FOR INSERT TO pandapay_admin_api WITH CHECK (%s)',r.schemaname,r.tablename,guard);
    EXECUTE format('CREATE POLICY private_admin_update_guard ON %I.%I AS RESTRICTIVE FOR UPDATE TO pandapay_admin_api USING (%s) WITH CHECK (%s)',r.schemaname,r.tablename,guard,guard);
    EXECUTE format('CREATE POLICY private_admin_delete_guard ON %I.%I AS RESTRICTIVE FOR DELETE TO pandapay_admin_api USING (%s)',r.schemaname,r.tablename,guard);
    EXECUTE format('GRANT SELECT ON %I.%I TO pandapay_admin_api',r.schemaname,r.tablename);
    IF cardinality(write_permissions)>0 THEN
      EXECUTE format('GRANT INSERT,UPDATE,DELETE ON %I.%I TO pandapay_admin_api',r.schemaname,r.tablename);
    END IF;
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA public,pandapay TO pandapay_admin_api;
GRANT SELECT ON public.admin_role_permissions TO pandapay_admin_api;
GRANT SELECT ON public.v_admin_card_catalogue_export TO pandapay_admin_api;
-- Support queues may join only the user-facing identity columns they display.
-- The customer profile has no legacy is_admin policy, so it is intentionally
-- excluded from the catalogue-table loop above.
DO $$ BEGIN
  IF to_regclass('public.profiles') IS NOT NULL THEN
    GRANT SELECT(id,email,display_name) ON public.profiles TO pandapay_admin_api;
    CREATE POLICY private_admin_support_identity ON public.profiles FOR SELECT TO pandapay_admin_api
      USING (pandapay.admin_has_permission('support.evidence.read')
        AND current_setting('pandapay.admin_permission',true)='support.evidence.read');
  END IF;
END $$;
-- Explicit legacy read interfaces; no blanket function/schema grants. These
-- interfaces remain behind the route permission checks in the private API.
DO $$ DECLARE signature text; BEGIN
  IF to_regclass('public.v_data_quality_dashboard') IS NOT NULL THEN
    GRANT SELECT ON public.v_data_quality_dashboard TO pandapay_admin_api;
  END IF;
  IF to_regnamespace('promotions') IS NOT NULL THEN
    GRANT USAGE ON SCHEMA promotions TO pandapay_admin_api;
  END IF;
  FOREACH signature IN ARRAY ARRAY[
    'promotions.get_admin_referral_operations()',
    'promotions.set_admin_referral_hold(text,boolean,text)',
    'pandapay.ai_admin_summary()', 'pandapay.ai_admin_jobs(text,integer)',
    'pandapay.ai_admin_events(uuid)', 'pandapay.ai_admin_quota()',
    'pandapay.ai_provider_admin_summary(integer,integer)',
    'pandapay.sms_learning_candidates(integer)',
    'pandapay.sms_rule_negative_evidence()', 'pandapay.sms_shared_rule_pause_threshold()',
    'pandapay.sms_shared_category_rules_v2()', 'pandapay.sms_admin_category_evidence_v2()',
    'pandapay.sms_review_correction_case(uuid,text,uuid,text)',
    'pandapay.sms_learning_decide(uuid,text,uuid)', 'pandapay.run_anonymization_audit(text)'
  ] LOOP
    IF to_regprocedure(signature) IS NOT NULL THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pandapay_admin_api',to_regprocedure(signature));
    END IF;
  END LOOP;
END $$;
-- Sequences carry no table DML authority and are required by existing audited writes.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO pandapay_admin_api;

COMMENT ON TABLE public.admin_role_permissions IS 'Reviewed private-admin capability map; runtime is read-only, provisioning owns changes.';
COMMENT ON FUNCTION pandapay.admin_has_permission(text) IS 'True only for active membership under the authenticated private API database login and transaction-local actor context.';
