do $$
declare v_prior jsonb;
begin
  select pg_catalog.jsonb_build_object('inherit',m.inherit_option,'set',m.set_option)
    into v_prior from pg_catalog.pg_auth_members m
    where m.roleid = 'account_lifecycle_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.lifecycle_owner_prior_grant', coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.lifecycle_migration_role',current_user,true);
  execute pg_catalog.format('grant account_lifecycle_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant account_lifecycle_owner to %I with set true granted by %I',current_user,current_user);
end $$;

-- External irreversible denial intents must be fsynced to both journal roots
-- before a due-claim transaction commits. Initial identity/head is installed
-- only by the fenced operator after journal/recovery review; never by runtime.
ALTER TABLE account_lifecycle.control
  ADD COLUMN journal_id text,
  ADD COLUMN journal_sequence bigint NOT NULL DEFAULT 0,
  ADD COLUMN journal_head text,
  ADD CONSTRAINT lifecycle_journal_checkpoint_valid CHECK (
    (journal_id IS NULL AND journal_sequence=0 AND journal_head IS NULL)
    OR (journal_id ~ '^[a-f0-9]{64}$' AND journal_head ~ '^[a-f0-9]{64}$'
      AND journal_id IS NOT NULL AND journal_head IS NOT NULL AND journal_sequence BETWEEN 0 AND 4096));
GRANT USAGE,CREATE ON SCHEMA account_lifecycle TO account_lifecycle_owner;
SET LOCAL ROLE account_lifecycle_owner;
CREATE FUNCTION account_lifecycle.journal_checkpoint(p_lock boolean)
RETURNS TABLE(journal_id text,sequence bigint,head text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='5s' SET lock_timeout='1s' AS $$
BEGIN
 IF p_lock IS TRUE THEN
  RETURN QUERY SELECT c.journal_id,c.journal_sequence,c.journal_head FROM account_lifecycle.control c WHERE singleton FOR UPDATE NOWAIT;
 ELSE
  RETURN QUERY SELECT c.journal_id,c.journal_sequence,c.journal_head FROM account_lifecycle.control c WHERE singleton;
 END IF;
END $$;
CREATE FUNCTION account_lifecycle.advance_journal(p_id text,p_sequence bigint,p_head text,p_new_head text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='5s' SET lock_timeout='1s' AS $$
BEGIN
 IF p_id IS NULL OR p_id !~ '^[a-f0-9]{64}$' OR p_sequence IS NULL OR p_sequence NOT BETWEEN 0 AND 4095
    OR p_head IS NULL OR p_head !~ '^[a-f0-9]{64}$' OR p_new_head IS NULL OR p_new_head !~ '^[a-f0-9]{64}$' THEN
  RAISE EXCEPTION 'Invalid journal checkpoint' USING errcode='22023';
 END IF;
 UPDATE account_lifecycle.control SET journal_sequence=p_sequence+1,journal_head=p_new_head
  WHERE singleton AND journal_id=p_id AND journal_sequence=p_sequence AND journal_head=p_head;
 IF NOT FOUND THEN RAISE EXCEPTION 'Journal checkpoint changed' USING errcode='40001'; END IF;
END $$;
-- Once journaled processing is enabled, an expired grace period is an
-- irreversible boundary. This also covers old clients using legacy UPDATE.
CREATE OR REPLACE FUNCTION account_lifecycle.mirror_profile_schedule() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='5s' SET lock_timeout='2s' AS $$
DECLARE r account_lifecycle.requests%rowtype;n bigint;BEGIN
 IF NOT pg_catalog.pg_try_advisory_xact_lock_shared(pg_catalog.hashtextextended(new.id::text,73612)) THEN
  RAISE EXCEPTION 'Account lifecycle schedule must retry' USING errcode='40001';
 END IF;
 IF EXISTS(SELECT 1 FROM account_lifecycle.tombstones WHERE profile_id=new.id) THEN
  RAISE EXCEPTION 'Account access denied' USING errcode='42501';
 END IF;
 SELECT * INTO r FROM account_lifecycle.requests WHERE profile_id=new.id AND status<>'cancelled' FOR UPDATE;
 IF FOUND AND r.due_at<=pg_catalog.now() AND EXISTS(SELECT 1 FROM account_lifecycle.control WHERE singleton AND worker_enabled)
  AND (new.deletion_requested_at IS DISTINCT FROM r.requested_at OR new.deletion_due_at IS DISTINCT FROM r.due_at) THEN
  RAISE EXCEPTION 'Account deletion grace period has ended' USING errcode='55000';
 END IF;
 IF new.deletion_requested_at IS NULL AND new.deletion_due_at IS NULL THEN
  IF FOUND THEN
   IF r.status<>'pending' THEN RAISE EXCEPTION 'Account deletion is already processing' USING errcode='55000';END IF;
   UPDATE account_lifecycle.requests SET status='cancelled',cancelled_at=pg_catalog.now() WHERE request_id=r.request_id;
  END IF;
  RETURN new;
 END IF;
 IF new.deletion_requested_at IS NULL OR new.deletion_due_at IS NULL OR new.deletion_due_at<new.deletion_requested_at THEN
  RAISE EXCEPTION 'Invalid deletion schedule' USING errcode='22023';
 END IF;
 IF FOUND THEN
  IF r.status<>'pending' THEN RAISE EXCEPTION 'Account deletion is already processing' USING errcode='55000';END IF;
  UPDATE account_lifecycle.requests SET requested_at=new.deletion_requested_at,due_at=new.deletion_due_at WHERE request_id=r.request_id;
 ELSE
  SELECT coalesce(max(generation),0)+1 INTO n FROM account_lifecycle.requests WHERE profile_id=new.id;
  INSERT INTO account_lifecycle.requests(profile_id,generation,requested_at,due_at,status)
   VALUES(new.id,n,new.deletion_requested_at,new.deletion_due_at,'pending');
 END IF;
 RETURN new;
END $$;
REVOKE ALL ON FUNCTION account_lifecycle.journal_checkpoint(boolean),account_lifecycle.advance_journal(text,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION account_lifecycle.journal_checkpoint(boolean),account_lifecycle.advance_journal(text,bigint,text,text) TO pandapay_account_lifecycle;
RESET ROLE;
REVOKE CREATE ON SCHEMA account_lifecycle FROM account_lifecycle_owner;
do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.lifecycle_owner_prior_grant')::jsonb;
begin
  if v_prior = 'null'::jsonb then
    execute pg_catalog.format('revoke account_lifecycle_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant account_lifecycle_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant account_lifecycle_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
