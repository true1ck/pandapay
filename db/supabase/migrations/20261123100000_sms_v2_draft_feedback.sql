-- AI draft feedback loop (docs/implementation/draft-feedback/DESIGN.md).
-- A phone checks a delivered draft against its own original SMS and may report it as wrong. The report
-- carries only the draft id and a reason code. Enough rejections replace the draft (twice at most).

ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN IF NOT EXISTS ai_draft_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_user_replacements integer NOT NULL DEFAULT 0;

-- A different non-null draft is a new revision; no worker code has to know.
CREATE OR REPLACE FUNCTION pandapay.sms_v2_bump_draft_revision() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  NEW.ai_draft_revision := OLD.ai_draft_revision + 1;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_bump_draft_revision() FROM PUBLIC;
DROP TRIGGER IF EXISTS sms_v2_bump_draft_revision ON public.sms_v2_unknown_templates;
CREATE TRIGGER sms_v2_bump_draft_revision BEFORE UPDATE ON public.sms_v2_unknown_templates
  FOR EACH ROW WHEN (NEW.ai_draft IS NOT NULL AND NEW.ai_draft IS DISTINCT FROM OLD.ai_draft)
  EXECUTE FUNCTION pandapay.sms_v2_bump_draft_revision();

-- Which draft revision went to which person. The opaque draft_id is what the phone reports back.
CREATE TABLE public.sms_v2_draft_deliveries (
  profile_id uuid NOT NULL REFERENCES public.profiles ON DELETE CASCADE,
  template_hash text NOT NULL REFERENCES public.sms_v2_unknown_templates ON DELETE CASCADE,
  draft_revision bigint NOT NULL,
  draft_id uuid NOT NULL DEFAULT gen_random_uuid(),
  delivered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (profile_id, template_hash, draft_revision),
  UNIQUE (draft_id)
);
CREATE TABLE public.sms_v2_draft_rejections (
  profile_id uuid NOT NULL REFERENCES public.profiles ON DELETE CASCADE,
  template_hash text NOT NULL REFERENCES public.sms_v2_unknown_templates ON DELETE CASCADE,
  draft_revision bigint NOT NULL,
  reason text NOT NULL CHECK (reason IN ('no_match', 'invalid_facts', 'unsafe_rule')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (profile_id, template_hash, draft_revision)
);
CREATE INDEX sms_v2_draft_rejections_layout ON public.sms_v2_draft_rejections (template_hash, draft_revision);

-- Like sms_v2_template_submitters: row security is forced and no policy admits app_user, so phones
-- reach these tables only through the SECURITY DEFINER functions below.
ALTER TABLE public.sms_v2_draft_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_draft_deliveries FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_draft_rejections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_v2_draft_rejections FORCE ROW LEVEL SECURITY;

-- Results now record deliveries, so the function writes (VOLATILE) and its return type grows.
-- p_deliver is false for a phone that cannot report drafts (older build): no delivery row, no draft_id.
DROP FUNCTION pandapay.sms_v2_template_results(bigint);
CREATE FUNCTION pandapay.sms_v2_template_results(p_revision bigint, p_deliver boolean DEFAULT true)
RETURNS TABLE(template_hash text, ai_status text, ai_draft jsonb, revision bigint, draft_id uuid, rejected boolean)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE me uuid;
BEGIN
  me := pandapay.uid();
  -- Same-person syncs run one after another, so a repeated sync always finds the first delivery.
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-v2-draft-deliveries:' || coalesce(me::text, ''), 0));
  RETURN QUERY
  WITH picked AS (
    SELECT t.template_hash AS h, t.ai_status AS st, t.ai_draft AS dr, t.ai_draft_revision AS rev,
           greatest(t.result_revision, s.result_revision) AS r,
           EXISTS (SELECT 1 FROM sms_v2_draft_rejections j
                    WHERE j.profile_id = me AND j.template_hash = t.template_hash
                      AND j.draft_revision = t.ai_draft_revision) AS rej
      FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING (template_hash)
     WHERE s.profile_id = me AND greatest(t.result_revision, s.result_revision) > p_revision
       AND s.eligible AND pandapay.sms_shared_learning_granted(s.profile_id)
     ORDER BY greatest(t.result_revision, s.result_revision), t.template_hash LIMIT 500
  ), made AS (
    INSERT INTO sms_v2_draft_deliveries AS nd (profile_id, template_hash, draft_revision)
    SELECT me, pk.h, pk.rev FROM picked pk WHERE p_deliver AND pk.st = 'ready' AND pk.dr IS NOT NULL AND NOT pk.rej
    ON CONFLICT DO NOTHING
    RETURNING nd.template_hash AS h, nd.draft_revision AS rev, nd.draft_id AS id
  )
  SELECT p.h, p.st, CASE WHEN p.rej THEN NULL ELSE p.dr END, p.r,
         CASE WHEN p_deliver AND p.st = 'ready' AND p.dr IS NOT NULL AND NOT p.rej
              THEN coalesce(m.id, d.draft_id) END,
         p.rej
    FROM picked p
    LEFT JOIN made m ON m.h = p.h AND m.rev = p.rev
    LEFT JOIN sms_v2_draft_deliveries d
      ON d.profile_id = me AND d.template_hash = p.h AND d.draft_revision = p.rev
   ORDER BY p.r, p.h;
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_template_results(bigint, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_template_results(bigint, boolean) TO app_user;

-- The whole report in one transaction. SQLSTATEs: 42501 no consent, P0404 draft not delivered to the
-- caller (unknown id and someone else's id look the same), 22023 bad reason.
CREATE FUNCTION pandapay.sms_v2_report_draft_rejection(p_draft_id uuid, p_reason text) RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE me uuid; dl sms_v2_draft_deliveries; t sms_v2_unknown_templates; added integer; n integer; d integer;
BEGIN
  me := pandapay.uid();
  IF me IS NULL THEN RAISE EXCEPTION 'profile required' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('no_match', 'invalid_facts', 'unsafe_rule') THEN
    RAISE EXCEPTION 'draft rejection reason invalid' USING ERRCODE = '22023';
  END IF;
  -- The consent-change lock, so a concurrent revocation wins in order (as in sms_v2_submit_templates).
  PERFORM pg_advisory_xact_lock(hashtextextended('sms-shared-learning-consent:' || me::text, 0));
  IF NOT pandapay.sms_shared_learning_granted(me) THEN
    RAISE EXCEPTION 'consent required' USING ERRCODE = '42501';
  END IF;
  -- Revision allocation lock before anything touches the layout row (the rejection insert takes a key share
  -- on it), then the row itself: two reports for one layout run one after another and cannot deadlock.
  PERFORM pg_advisory_xact_lock(hashtext('sms_v2_template_results'));
  SELECT * INTO dl FROM sms_v2_draft_deliveries WHERE draft_id = p_draft_id AND profile_id = me;
  IF NOT FOUND THEN RAISE EXCEPTION 'draft not delivered' USING ERRCODE = 'P0404'; END IF;

  INSERT INTO sms_v2_draft_rejections (profile_id, template_hash, draft_revision, reason)
    VALUES (me, dl.template_hash, dl.draft_revision, p_reason) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS added = ROW_COUNT;
  IF added = 0 THEN RETURN 'already_recorded'; END IF;

  SELECT * INTO t FROM sms_v2_unknown_templates WHERE template_hash = dl.template_hash FOR UPDATE;
  -- Stale report: recorded above, nothing else moves.
  IF NOT FOUND OR t.ai_status <> 'ready' OR t.ai_draft_revision <> dl.draft_revision THEN RETURN 'recorded'; END IF;

  -- The reporter's own phone learns of its rejection through its own revision.
  UPDATE sms_v2_template_submitters SET result_revision = nextval('sms_v2_template_revision')
   WHERE template_hash = dl.template_hash AND profile_id = me;

  SELECT count(*) INTO n FROM sms_v2_draft_rejections
   WHERE template_hash = dl.template_hash AND draft_revision = dl.draft_revision;
  SELECT count(*) INTO d FROM sms_v2_template_submitters s
   WHERE s.template_hash = dl.template_hash AND s.eligible AND pandapay.sms_shared_learning_granted(s.profile_id);
  -- An admin decision (approved or rejected) is never overridden by phones: evidence only.
  IF t.admin_decision IS NULL AND n >= least(3, greatest(d, 1)) THEN
    IF t.ai_user_replacements >= 2 THEN
      UPDATE sms_v2_unknown_templates SET ai_status = 'failed', failure_code = 'draft_rejected_by_users',
             ai_draft = NULL, lease_id = NULL, lease_expires_at = NULL,
             result_revision = nextval('sms_v2_template_revision')
       WHERE template_hash = dl.template_hash;
    ELSE
      UPDATE sms_v2_unknown_templates SET ai_status = 'queued', ai_draft = NULL, failure_code = NULL,
             failure_detail = NULL, ai_user_replacements = ai_user_replacements + 1,
             queued_at = clock_timestamp(), lease_id = NULL, lease_expires_at = NULL,
             result_revision = nextval('sms_v2_template_revision')
       WHERE template_hash = dl.template_hash;
    END IF;
  END IF;
  RETURN 'recorded';
END $$;
REVOKE ALL ON FUNCTION pandapay.sms_v2_report_draft_rejection(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pandapay.sms_v2_report_draft_rejection(uuid, text) TO app_user;
