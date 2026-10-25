-- Google identity is the provider subject, never an email address. Retain
-- optional legacy google_id columns/values; never merge/delete user UUIDs.
CREATE TABLE IF NOT EXISTS public.oauth_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    provider VARCHAR(50) NOT NULL,
    provider_user_id VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider, provider_user_id)
);

LOCK TABLE public.users, public.oauth_accounts IN SHARE ROW EXCLUSIVE MODE;

-- Adopt the base schema's existing index; also establish provider uniqueness
-- for compatible older installations that created the table without it.
CREATE UNIQUE INDEX IF NOT EXISTS oauth_accounts_provider_provider_user_id_key
    ON public.oauth_accounts (provider, provider_user_id);

DO $google_identity_index$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_index i
         WHERE i.indexrelid = 'public.oauth_accounts_provider_provider_user_id_key'::regclass
           AND i.indrelid = 'public.oauth_accounts'::regclass
           AND i.indisunique AND i.indisvalid AND i.indnkeyatts = 2
           AND i.indpred IS NULL AND i.indexprs IS NULL
           AND pg_get_indexdef(i.indexrelid, 1, TRUE) = 'provider'
           AND pg_get_indexdef(i.indexrelid, 2, TRUE) = 'provider_user_id'
    ) THEN
        RAISE EXCEPTION 'Google identity migration blocked: incompatible provider subject uniqueness index';
    END IF;
END
$google_identity_index$;

DO $google_legacy_identity$
DECLARE
    ambiguous BIGINT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'google_id'
    ) THEN
        EXECUTE $query$
            SELECT count(*) FROM public.users
             WHERE google_id IS NOT NULL
               AND google_id::text !~ '^[A-Za-z0-9_-]{1,255}$'
        $query$ INTO ambiguous;
        IF ambiguous > 0 THEN
            RAISE EXCEPTION 'Google identity migration blocked: malformed legacy identity count=%', ambiguous;
        END IF;
        EXECUTE $query$
            SELECT count(*) FROM (
                SELECT google_id::text FROM public.users WHERE google_id IS NOT NULL
                 GROUP BY google_id::text HAVING count(*) > 1
            ) AS conflicts
        $query$ INTO ambiguous;
        IF ambiguous > 0 THEN
            RAISE EXCEPTION 'Google identity migration blocked: duplicate legacy subject groups=%', ambiguous;
        END IF;
        EXECUTE $query$
            SELECT count(*) FROM public.users u JOIN public.oauth_accounts o
              ON o.provider = 'google' AND o.provider_user_id = u.google_id::text
             WHERE u.google_id IS NOT NULL AND o.user_id <> u.id
        $query$ INTO ambiguous;
        IF ambiguous > 0 THEN
            RAISE EXCEPTION 'Google identity migration blocked: conflicting legacy ownership count=%', ambiguous;
        END IF;
        EXECUTE $query$
            INSERT INTO public.oauth_accounts (user_id, provider, provider_user_id)
            SELECT u.id, 'google', u.google_id::text FROM public.users u
             WHERE u.google_id IS NOT NULL AND NOT EXISTS (
                 SELECT 1 FROM public.oauth_accounts o
                  WHERE o.provider = 'google' AND o.provider_user_id = u.google_id::text
             )
        $query$;
    END IF;
END
$google_legacy_identity$;

CREATE INDEX IF NOT EXISTS idx_oauth_accounts_user ON public.oauth_accounts (user_id);
REVOKE ALL ON TABLE public.oauth_accounts FROM PUBLIC;
