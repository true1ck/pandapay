-- Run after the account-data-reset migration and db/setup_app_role.sql.
-- Fixtures are inside a transaction and rolled back; no real profile data is touched.
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_profile uuid := gen_random_uuid();
  v_target_key text := 'migration-account-erasure-' || gen_random_uuid()::text;
  v_count bigint;
begin
  if has_function_privilege(
       'app_user',
       'promotions.reset_account_profile_data(uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'app_user',
       'promotions.anonymize_account_profile_references(uuid)',
       'EXECUTE'
     ) then
    raise exception 'app_user must not call the promotions cleanup helpers directly';
  end if;

  insert into public.profiles (id) values (v_profile);
  insert into promotions.referral_operator_holds
    (scope, target_key, original_state, changed_by, reason)
  values
    ('redemption', v_target_key, '{}'::jsonb, v_profile, 'migration reset test');
  insert into promotions.referral_operator_audit
    (actor_profile_id, action, scope, target_key, reason, before_state, after_state)
  values
    (v_profile, 'hold_applied', 'redemption', v_target_key,
     'migration deletion test', '{}'::jsonb, '{}'::jsonb);

  perform pandapay.reset_account_data(v_profile);
  if not exists (select 1 from public.profiles where id = v_profile) then
    raise exception 'data reset removed the login profile';
  end if;
  if not exists (
    select 1 from promotions.referral_operator_holds
     where target_key = v_target_key and changed_by = v_profile
  ) or not exists (
    select 1 from promotions.referral_operator_audit
     where target_key = v_target_key and actor_profile_id = v_profile
  ) then
    raise exception 'data reset changed shared operator audit history';
  end if;

  perform pandapay.execute_account_deletion(v_profile);
  if exists (select 1 from public.profiles where id = v_profile) then
    raise exception 'permanent deletion left the profile behind';
  end if;
  select count(*) into v_count
    from promotions.referral_operator_holds
   where target_key = v_target_key and changed_by is null;
  if v_count <> 1 then
    raise exception 'permanent deletion did not anonymize the operator hold actor';
  end if;
  select count(*) into v_count
    from promotions.referral_operator_audit
   where target_key = v_target_key and actor_profile_id is null;
  if v_count <> 1 then
    raise exception 'permanent deletion did not anonymize the operator audit actor';
  end if;
end
$$;

rollback;

select 'account data reset and permanent erasure: OK' as result;
