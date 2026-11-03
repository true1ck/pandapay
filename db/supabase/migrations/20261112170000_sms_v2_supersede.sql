-- WP-16 history rollout: preserve original SMS rows for support rollback.
ALTER TYPE txn_status ADD VALUE IF NOT EXISTS 'superseded';
ALTER TABLE transactions ADD COLUMN superseded_by_event_id text
  REFERENCES sms_v2_events(event_id);
CREATE INDEX transactions_sms_v2_superseded_event ON transactions(profile_id,superseded_by_event_id)
  WHERE superseded_by_event_id IS NOT NULL;

-- A stale legacy sync must not make a hidden row active again. Public GUCs do
-- not grant this exemption: admin_has_permission authenticates session_user.
CREATE FUNCTION pandapay.sms_v2_protect_superseded_transaction() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
  IF OLD.status::text='superseded' AND
     (NEW.status IS DISTINCT FROM OLD.status OR
      NEW.superseded_by_event_id IS DISTINCT FROM OLD.superseded_by_event_id) AND
     (NOT pandapay.admin_has_permission('learning.publish') OR
      current_setting('pandapay.admin_permission',true) IS DISTINCT FROM 'learning.publish') THEN
    RAISE EXCEPTION 'superseded legacy transaction is read only' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_protect_superseded_transaction() FROM PUBLIC,app_user,pandapay_admin_api;
CREATE TRIGGER sms_v2_protect_superseded_transaction BEFORE UPDATE OF status,superseded_by_event_id ON transactions
  FOR EACH ROW EXECUTE FUNCTION pandapay.sms_v2_protect_superseded_transaction();

-- Invoke only through an authenticated private runtime with learning.publish,
-- after disabling the v2 rollout. This changes visibility, never reward state.
CREATE FUNCTION pandapay.sms_v2_unsupersede(p_profile_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n integer; hidden integer; mapped text[]; actor uuid;
BEGIN
  IF NOT pandapay.admin_has_permission('learning.publish') OR
     current_setting('pandapay.admin_permission',true) IS DISTINCT FROM 'learning.publish' THEN
    RAISE EXCEPTION 'private learning.publish permission required' USING ERRCODE='42501';
  END IF;
  IF p_profile_id IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('transaction-ingest:'||p_profile_id::text,0));
  SELECT array_agg(DISTINCT superseded_by_event_id) INTO mapped FROM transactions
   WHERE profile_id=p_profile_id AND pipeline_version=1 AND status::text='superseded';
  UPDATE transactions SET status='ignored'
   WHERE profile_id=p_profile_id AND pipeline_version=2 AND event_id=ANY(mapped) AND status::text='active';
  GET DIAGNOSTICS hidden=ROW_COUNT;
  UPDATE transactions SET status='active',superseded_by_event_id=NULL
   WHERE profile_id=p_profile_id AND pipeline_version=1 AND status::text='superseded';
  GET DIAGNOSTICS n=ROW_COUNT;
  actor:=nullif(current_setting('pandapay.admin_actor',true),'')::uuid;
  INSERT INTO admin_audit_log(admin_id,action,entity,entity_id,after_value,reason)
   VALUES(actor,'sms_v2_unsupersede','profiles',p_profile_id,
          jsonb_build_object('legacyRestored',n,'v2Hidden',hidden),
          'Operator restored retained legacy SMS visibility after rollout rollback');
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_unsupersede(uuid) FROM PUBLIC,app_user,pandapay_admin_api;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_unsupersede(uuid) TO pandapay_admin_api;
