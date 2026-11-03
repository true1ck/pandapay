-- setup_app_role grants table-wide DML during role reconciliation. Enforce the
-- customer retry invariant independently of column grants, without changing
-- the already applied migration. Trusted security-definer consent cleanup
-- runs as its owner and remains able to erase shared evidence.
CREATE FUNCTION pandapay.sms_v2_guard_customer_correction_update() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
  IF current_user='app_user' AND
     (to_jsonb(NEW)-'request_hash') IS DISTINCT FROM (to_jsonb(OLD)-'request_hash') THEN
    RAISE EXCEPTION 'customer correction update is limited to retry identity' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_guard_customer_correction_update() FROM PUBLIC;
CREATE TRIGGER sms_v2_guard_customer_correction_update BEFORE UPDATE ON public.sms_v2_correction_cases
 FOR EACH ROW EXECUTE FUNCTION pandapay.sms_v2_guard_customer_correction_update();
