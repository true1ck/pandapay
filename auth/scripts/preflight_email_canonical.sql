-- Run BEFORE deploying migration 0016. Read-only in effect: it makes one temporary
-- function inside a transaction that is always rolled back, and changes no data.
--
-- Migration 0016 gives every email a canonical form (Gmail ignores dots and +tags, and
-- Outlook, iCloud and a few others ignore +tags) and then requires one live account per
-- canonical mailbox. If two live accounts already share one, the migration stops at
-- 0016 (0015 will already have been applied). This lists them first, by domain and
-- account id only, so no email address is printed.
--
--   docker exec -i pandapay-prod-backup-1 sh -c 'psql "$AUTH_DATABASE_URL"' \
--     < auth/scripts/preflight_email_canonical.sql
--
-- Zero rows means the migration will pass. For each group listed, close or merge all but
-- one account before deploying. The function below is copied from 0016; a test keeps the
-- two identical.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.auth_canonical_email(p_email text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v text;
    v_local text;
    v_domain text;
    v_stripped text;
BEGIN
    IF p_email IS NULL THEN RETURN NULL; END IF;
    v := lower(btrim(p_email));
    IF v !~ '^.+@[^@]*$' THEN RETURN NULLIF(v, ''); END IF;
    v_domain := substring(v from '@([^@]*)$');
    v_local := substring(v from '^(.*)@[^@]*$');
    IF v_domain IN ('gmail.com', 'googlemail.com') THEN
        v_stripped := replace(split_part(v_local, '+', 1), '.', '');
        v_domain := 'gmail.com';
    ELSIF v_domain IN ('outlook.com', 'outlook.in', 'hotmail.com', 'hotmail.co.in', 'live.com', 'live.in',
                       'msn.com', 'icloud.com', 'me.com', 'mac.com', 'proton.me', 'protonmail.com',
                       'pm.me', 'fastmail.com') THEN
        v_stripped := split_part(v_local, '+', 1);
    ELSE
        RETURN v;
    END IF;
    IF v_stripped = '' THEN RETURN v; END IF;
    RETURN v_stripped || '@' || v_domain;
END $$;

SELECT split_part(canon, '@', 2) AS mailbox_domain,
       COUNT(*)                  AS live_accounts,
       array_agg(id ORDER BY created_at) AS account_ids
  FROM (SELECT id, created_at, pg_temp.auth_canonical_email(email) AS canon
          FROM users
         WHERE deleted IS FALSE AND email IS NOT NULL) AS live
 WHERE canon IS NOT NULL
 GROUP BY canon
HAVING COUNT(*) > 1
 ORDER BY live_accounts DESC, mailbox_domain;

ROLLBACK;
