-- >>> MIGRATION 0037 — PROFILE ID LOOKUP BY FORWARDING ADDRESS ====================

-- For Phase 1 Email Ingestion (Card Discovery Only):
-- We need to look up a user's profile_id based on the inbound email's 
-- local_part (e.g. u7f3k9@in.pandapay.app). 
-- This is SECURITY DEFINER because the webhook caller has no user JWT.

create or replace function pandapay.get_profile_by_forwarding_address(p_local_part text) 
returns uuid
language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  v_profile_id uuid;
begin
  select profile_id into v_profile_id 
  from forwarding_addresses
  where local_part = p_local_part and is_active
  limit 1;

  return v_profile_id;
end;
$$;
