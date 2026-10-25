-- Adopt both legacy installations without risk_level and installations where
-- the older request logger added it. Retain every existing audit row/value.
-- Request handlers and loggers must not create or alter their own schema.
ALTER TABLE public.auth_audit ADD COLUMN IF NOT EXISTS risk_level VARCHAR(20) DEFAULT 'INFO';
CREATE INDEX IF NOT EXISTS idx_auth_audit_risk_level ON public.auth_audit (risk_level);
REVOKE ALL ON TABLE public.auth_audit FROM PUBLIC;
