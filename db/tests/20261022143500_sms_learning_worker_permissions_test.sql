-- Verifies that the autonomous learner has a dedicated, non-bypass login and
-- only the cross-user capabilities its cycle actually needs.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_role record;
begin
  select rolcanlogin, rolinherit, rolsuper, rolcreaterole, rolcreatedb, rolreplication,
         rolbypassrls
    into v_role
    from pg_roles
   where rolname = 'sms_learning_worker';

  if not found then
    raise exception 'sms_learning_worker role was not bootstrapped';
  end if;
  if not v_role.rolcanlogin or v_role.rolinherit or v_role.rolsuper or v_role.rolcreaterole
     or v_role.rolcreatedb or v_role.rolreplication or v_role.rolbypassrls then
    raise exception 'sms_learning_worker has unsafe role attributes';
  end if;

  if pg_has_role('app_user', 'sms_learning_worker', 'member') then
    raise exception 'app_user must not inherit or assume the SMS learning worker role';
  end if;
  if has_function_privilege(
       'app_user',
       'pandapay.sms_publish_bundle(integer,jsonb,text,text)',
       'EXECUTE'
     ) or has_function_privilege(
       'app_user',
       'pandapay.sms_rollback_bundle(integer)',
       'EXECUTE'
     ) then
    raise exception 'app_user must not execute autonomous publish/rollback routines';
  end if;
  if has_table_privilege('app_user', 'public.sms_learning_worker_runs', 'INSERT') then
    raise exception 'app_user must not write worker health history';
  end if;

  if not has_schema_privilege('sms_learning_worker', 'public', 'USAGE')
     or not has_schema_privilege('sms_learning_worker', 'pandapay', 'USAGE')
     or not has_table_privilege('sms_learning_worker', 'public.sms_learning_examples', 'SELECT')
     or not has_table_privilege('sms_learning_worker', 'public.sms_rule_candidates', 'SELECT')
     or not has_table_privilege('sms_learning_worker', 'public.sms_rule_candidates', 'INSERT')
     or not has_table_privilege('sms_learning_worker', 'public.sms_rule_candidates', 'UPDATE')
     or not has_table_privilege('sms_learning_worker', 'public.sms_rule_candidate_exposures', 'SELECT')
     or not has_table_privilege('sms_learning_worker', 'public.sms_rule_bundles', 'SELECT')
     or not has_table_privilege('sms_learning_worker', 'public.sms_learning_worker_runs', 'SELECT')
     or not has_table_privilege('sms_learning_worker', 'public.sms_learning_worker_runs', 'INSERT')
     then
    raise exception 'sms_learning_worker is missing a required cycle capability';
  end if;

  -- Global publication and autonomous rollback belong to the authenticated
  -- admin API, not to the cross-user learning cycle. 20261027160000_sms_
  -- category_rule_approval.sql revokes both, and sms_autonomous_worker.js
  -- refuses to start unless they are absent, so holding them is a privilege
  -- beyond the cycle rather than a required capability.
  if has_table_privilege('sms_learning_worker', 'public.profiles', 'SELECT')
     or has_table_privilege('sms_learning_worker', 'public.sms_learning_examples', 'INSERT')
     or has_table_privilege('sms_learning_worker', 'public.sms_learning_examples', 'UPDATE')
     or has_table_privilege('sms_learning_worker', 'public.sms_learning_examples', 'DELETE')
     or has_table_privilege('sms_learning_worker', 'public.sms_rule_candidate_exposures', 'INSERT')
     or has_table_privilege('sms_learning_worker', 'public.sms_rule_candidate_exposures', 'UPDATE')
     or has_table_privilege('sms_learning_worker', 'public.sms_rule_candidate_exposures', 'DELETE')
     or has_table_privilege('sms_learning_worker', 'public.sms_rule_bundles', 'INSERT')
     or has_table_privilege('sms_learning_worker', 'public.sms_rule_bundles', 'UPDATE')
     or has_table_privilege('sms_learning_worker', 'public.sms_rule_bundles', 'DELETE')
     or has_table_privilege('sms_learning_worker', 'public.sms_learning_worker_runs', 'UPDATE')
     or has_table_privilege('sms_learning_worker', 'public.sms_learning_worker_runs', 'DELETE')
     or has_function_privilege(
       'sms_learning_worker',
       'pandapay.sms_publish_bundle(integer,jsonb,text,text)',
       'EXECUTE'
     )
     or has_function_privilege(
       'sms_learning_worker',
       'pandapay.sms_rollback_bundle(integer)',
       'EXECUTE'
     ) then
    raise exception 'sms_learning_worker has privileges beyond the autonomous cycle';
  end if;
end $$;

rollback;
