-- The operator's completed, version-bound provisioning intent authorizes
-- initial factor enrollment. The browser need not transport a secret grant.
-- No runtime can create/complete that operator intent or enable a principal.
CREATE FUNCTION admin_private.prepare_approved_enrollment(
 p_login uuid,p_cookie text,p_environment text,p_grant text)
 RETURNS TABLE(user_id uuid,slot text,grant_digest text)
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,admin_private,public AS $$
DECLARE actor uuid; factor_slot text;
BEGIN
 IF session_user<>'admin_gateway_runtime' THEN
   RAISE EXCEPTION 'private runtime required' USING ERRCODE='42501';
 END IF;
 IF p_grant IS NULL OR p_grant !~ '^[0-9a-f]{64}$' THEN RETURN; END IF;
 SELECT pr.user_id INTO actor FROM admin_private.email_proofs ep
 JOIN admin_private.principals pr ON pr.user_id=ep.user_id
 JOIN public.users u ON u.id=pr.user_id
 WHERE ep.login_id=p_login AND ep.preauth_cookie_digest=p_cookie
   AND ep.consumed_at IS NULL AND ep.expires_at>now()
   AND pr.state='pending' AND u.is_active AND NOT u.deleted AND u.is_email_verified
   AND EXISTS(SELECT 1 FROM admin_private.provisioning_operations op
     WHERE op.user_id=pr.user_id AND op.operation IN ('grant','reconcile')
       AND op.phase='complete' AND op.expected_principal_version=pr.version
       AND lower(op.email)=lower(u.email) AND op.plan->>'environment'=p_environment)
   AND NOT EXISTS(SELECT 1 FROM admin_private.provisioning_operations op
     WHERE op.user_id=pr.user_id AND op.phase IN ('auth_prepared','product_applied'))
 FOR UPDATE OF ep,pr;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT wanted.slot INTO factor_slot FROM (VALUES('primary',1),('backup',2)) wanted(slot,position)
 WHERE NOT EXISTS(SELECT 1 FROM admin_private.credentials cr
   WHERE cr.user_id=actor AND cr.slot=wanted.slot AND cr.revoked_at IS NULL)
 ORDER BY wanted.position LIMIT 1;
 IF factor_slot IS NULL THEN RETURN; END IF;
 UPDATE admin_private.enrollment_grants g SET consumed_at=now()
   WHERE g.user_id=actor AND g.slot=factor_slot AND g.consumed_at IS NULL;
 INSERT INTO admin_private.enrollment_grants(grant_digest,user_id,environment,origin,rp_id,slot,expires_at)
 VALUES(p_grant,actor,p_environment,'https://localhost:8443','localhost',factor_slot,now()+interval '10 minutes');
 RETURN QUERY SELECT actor,factor_slot,p_grant;
END $$;
REVOKE ALL ON FUNCTION admin_private.prepare_approved_enrollment(uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_private.prepare_approved_enrollment(uuid,text,text,text) TO pandapay_admin_gateway;
