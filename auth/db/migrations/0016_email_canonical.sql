-- One mailbox, one account. jo.hn@gmail.com, john+offer@gmail.com and
-- john@googlemail.com reach the same inbox, so they are the same email to the
-- account system. email_canonical holds that single form and is kept up to date by
-- a trigger, so every way an email is written (sign-up, Google, contact
-- replacement, admin) is covered without each path knowing about it.
--
-- The function MUST match src/utils/emailIdentity.js; both are tested against
-- test/fixtures/email_canonical_corpus.json.
CREATE OR REPLACE FUNCTION auth_canonical_email(p_email text) RETURNS text
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

ALTER TABLE users ADD COLUMN IF NOT EXISTS email_canonical VARCHAR(320);

CREATE OR REPLACE FUNCTION users_set_email_canonical() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.email_canonical := auth_canonical_email(NEW.email);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_users_email_canonical ON users;
CREATE TRIGGER trg_users_email_canonical
    BEFORE INSERT OR UPDATE OF email ON users
    FOR EACH ROW EXECUTE FUNCTION users_set_email_canonical();

-- Fill in every existing row. The trigger writes the same value on later changes.
UPDATE users SET email_canonical = auth_canonical_email(email)
 WHERE email IS NOT NULL AND email_canonical IS DISTINCT FROM auth_canonical_email(email);

-- Two live accounts that are really one mailbox must be resolved by a person before
-- this lock can exist. Count-only, like the earlier contact uniqueness preflight.
DO $email_canonical_preflight$
DECLARE
    duplicate_groups BIGINT;
BEGIN
    SELECT COUNT(*) INTO duplicate_groups FROM (
        SELECT email_canonical FROM users
         WHERE deleted IS FALSE AND email_canonical IS NOT NULL
         GROUP BY email_canonical HAVING COUNT(*) > 1
    ) AS duplicate_mailboxes;
    IF duplicate_groups > 0 THEN
        RAISE EXCEPTION 'email canonical preflight blocked (count-only): duplicate_groups=%', duplicate_groups;
    END IF;
END
$email_canonical_preflight$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_users_live_email_canonical
    ON users (email_canonical)
    WHERE deleted = FALSE AND email_canonical IS NOT NULL;
