-- Latest purpose-specific withdrawal erases contributed correction evidence.
-- Minimal source/trace/kind and the fact of the decision remain private to
-- the account and the administrative review boundary.
CREATE FUNCTION pandapay.sms_v2_revoke_correction_evidence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE current_granted boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || NEW.profile_id::text,0));
  SELECT granted INTO current_granted FROM public.user_consents
    WHERE profile_id=NEW.profile_id AND purpose='sms_shared_learning'
    ORDER BY granted_at DESC,granted ASC,id DESC LIMIT 1;
  IF current_granted IS FALSE THEN
    UPDATE public.sms_v2_correction_cases
      SET corrected='{}',redacted_template=NULL,template_hash=NULL,sender_brand=NULL,
          shared_learning_eligible=false,output=NULL,
          reason=CASE WHEN status='decided' THEN 'Contributed evidence erased after consent withdrawal' ELSE NULL END,
          updated_at=clock_timestamp(),change_seq=nextval('public.sms_v2_correction_change_seq')
      WHERE profile_id=NEW.profile_id AND
        (redacted_template IS NOT NULL OR corrected<>'{}'::jsonb OR output IS NOT NULL OR shared_learning_eligible);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_revoke_correction_evidence() FROM PUBLIC;
CREATE TRIGGER sms_v2_correction_consent_withdrawal
AFTER INSERT OR UPDATE OF granted,granted_at ON public.user_consents
FOR EACH ROW WHEN (NEW.purpose='sms_shared_learning')
EXECUTE FUNCTION pandapay.sms_v2_revoke_correction_evidence();
