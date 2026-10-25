-- Preserve historical four-digit challenges as protocol 1. Protocol 2 is
-- explicit, six-digit and bound to both its random UUID and stable device.
ALTER TABLE public.otp_requests
  ADD COLUMN protocol_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN device_binding_hash text;
ALTER TABLE public.otp_requests ADD CONSTRAINT otp_requests_protocol_binding
  CHECK ((protocol_version=1 AND device_binding_hash IS NULL)
    OR (protocol_version=2 AND device_binding_hash ~ '^[a-f0-9]{64}$' AND device_binding_hash IS NOT NULL));
