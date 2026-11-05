-- Learning loop B8: a private AI rule goes only to the phones whose submission
-- of the layout was attested. A phone that sent the layout without a valid App
-- Check token (stored as held, never drafted) gets nothing back.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_template_results(p_revision bigint) RETURNS TABLE(template_hash text,ai_status text,ai_draft jsonb,revision bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT t.template_hash,t.ai_status,t.ai_draft,greatest(t.result_revision,s.result_revision)
    FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING(template_hash)
   WHERE s.profile_id=pandapay.uid() AND greatest(t.result_revision,s.result_revision)>p_revision
     AND s.eligible AND pandapay.sms_shared_learning_granted(s.profile_id)
   ORDER BY greatest(t.result_revision,s.result_revision),t.template_hash LIMIT 500
$$;
