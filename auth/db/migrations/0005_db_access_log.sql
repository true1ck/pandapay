-- Optional database-access audit storage. Runtime query paths must never
-- create or alter their own audit schema.
-- Earlier optional logger versions created the same table at runtime.
-- Adopt compatible installations without dropping their audit history.
CREATE TABLE IF NOT EXISTS public.db_access_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query_type VARCHAR(20) NOT NULL,
    tables_accessed JSONB,
    query_text TEXT NOT NULL,
    params_sanitized JSONB,
    user_id UUID,
    ip_address VARCHAR(45),
    user_agent TEXT,
    duration_ms INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_db_access_log_created_at ON public.db_access_log (created_at);
CREATE INDEX IF NOT EXISTS idx_db_access_log_user_id ON public.db_access_log (user_id);
CREATE INDEX IF NOT EXISTS idx_db_access_log_tables ON public.db_access_log USING GIN (tables_accessed);
CREATE INDEX IF NOT EXISTS idx_db_access_log_query_type ON public.db_access_log (query_type);

REVOKE ALL ON TABLE public.db_access_log FROM PUBLIC;
