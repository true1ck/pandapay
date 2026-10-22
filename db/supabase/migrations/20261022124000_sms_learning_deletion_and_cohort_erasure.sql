begin;

-- Complete the user erasure contract after the cohort tables are present.
-- This replaces the earlier examples-only helper so opt-out/deletion removes
-- every learning artifact that could identify or influence a profile.
create or replace function pandapay.sms_delete_learning_examples_for_user(
  p_user_id uuid, p_hmac_key text default null
) returns integer
language plpgsql security definer
set search_path = pg_catalog, public, pandapay, extensions
as $$
declare
  v_user_hash text;
  v_deleted integer := 0;
  v_count integer;
  v_key text;
begin
  if p_user_id is null then return 0; end if;
  if session_user not in ('postgres', 'service_role')
     and pandapay.uid() is distinct from p_user_id then
    raise exception 'cannot erase another profile';
  end if;
  v_key := coalesce(nullif(p_hmac_key, ''),
    nullif(current_setting('app.sms_learning_hmac_key', true), ''));
  if v_key is not null and length(v_key) >= 32 then
    v_user_hash := encode(hmac(p_user_id::text, v_key, 'sha256'), 'hex');
  end if;

  delete from public.sms_learning_examples
   where profile_id = p_user_id
      or (v_user_hash is not null and user_hash = v_user_hash);
  get diagnostics v_count = row_count;
  v_deleted := v_deleted + v_count;

  delete from public.sms_learning_feedback where profile_id = p_user_id;
  get diagnostics v_count = row_count;
  v_deleted := v_deleted + v_count;

  delete from public.sms_rule_candidate_exposures where profile_id = p_user_id;
  get diagnostics v_count = row_count;
  v_deleted := v_deleted + v_count;

  delete from public.sms_rule_candidate_assignments where profile_id = p_user_id;
  get diagnostics v_count = row_count;
  v_deleted := v_deleted + v_count;

  return v_deleted;
end;
$$;

commit;
