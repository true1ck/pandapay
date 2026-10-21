-- Run only after the complete migration chain and the final
-- db/setup_app_role.sql pass. This is an assertion script, not a fixture seed.
\set ON_ERROR_STOP on

do $$
declare
  v_role record;
  v_table text;
  v_tables text[] := array[
    'access_settings','campaign_versions','campaign_state','memberships',
    'invitation_codes','referral_attributions','terms_acceptances',
    'inviter_campaign_caps','reward_reservations','engagement_days',
    'reward_entitlements','reward_spins','credit_accounts','credit_ledger',
    'credit_redemptions','eligibility_claims','reward_outbox',
    'invitation_validation_limits','referral_operator_holds','referral_operator_audit'
  ];
  v_oid oid;
  v_has_public_execute boolean;
  v_public_function text;
begin
  select rolcanlogin, rolsuper, rolbypassrls into v_role
    from pg_roles where rolname = 'promotions_owner';
  if not found or v_role.rolcanlogin or v_role.rolsuper or v_role.rolbypassrls then
    raise exception 'promotions_owner must be NOLOGIN, NOSUPERUSER and NOBYPASSRLS';
  end if;

  if has_table_privilege('app_user', 'public.profiles', 'INSERT')
     or has_column_privilege('app_user', 'public.profiles', 'email', 'UPDATE')
     or has_column_privilege('app_user', 'public.profiles', 'phone_number', 'UPDATE') then
    raise exception 'app_user can directly create a profile or alter trusted identity fields';
  end if;
  if not has_column_privilege('app_user', 'public.profiles', 'contributions_opt_in', 'UPDATE') then
    raise exception 'existing owner profile preference updates were accidentally removed';
  end if;
  if has_table_privilege('app_user', 'promotions.credit_accounts', 'SELECT')
     or has_table_privilege('app_user', 'promotions.credit_accounts', 'UPDATE')
     or has_table_privilege('app_user', 'promotions.credit_ledger', 'INSERT')
     or has_table_privilege('app_user', 'promotions.reward_spins', 'UPDATE')
     or has_table_privilege('app_user', 'promotions.referral_operator_audit', 'SELECT')
     or has_table_privilege('rewards_worker', 'promotions.referral_operator_holds', 'SELECT') then
    raise exception 'app_user has direct access to protected promotion/credit tables';
  end if;

  foreach v_table in array v_tables loop
    v_oid := to_regclass(format('promotions.%I', v_table));
    if v_oid is null then raise exception 'missing promotions table: %', v_table; end if;
    if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = v_oid) then
      raise exception 'RLS is not enabled and forced on promotions.%', v_table;
    end if;
  end loop;

  select p.oid into v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'promotions'
     and p.proname = 'activate_current_user';
  if v_oid is null or not has_function_privilege('app_user', v_oid, 'EXECUTE') then
    raise exception 'trusted activation routine is not executable by app_user';
  end if;
  select exists (
    select 1 from aclexplode(coalesce(proacl, acldefault('f', proowner))) acl
     where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
  ) into v_has_public_execute from pg_proc where oid = v_oid;
  if v_has_public_execute then
    raise exception 'activation routine is executable by PUBLIC';
  end if;

  select n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
    into v_public_function
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
   where n.nspname = 'promotions'
     and acl.grantee = 0
     and acl.privilege_type = 'EXECUTE'
   limit 1;
  if v_public_function is not null then
    raise exception 'promotion function is executable by PUBLIC: %', v_public_function;
  end if;

  if not has_function_privilege(
       'app_user',
       'promotions.consume_invitation_validation(text)',
       'EXECUTE'
     ) then
    raise exception 'shared invitation rate limit routine is not executable by app_user';
  end if;

  if not promotions.distribution_is_valid(
    '{"inviter":[{"id":"ten","amountPaise":"1000","weight":70}],'
    '"referee":[{"id":"ten","amountPaise":"1000","weight":70}]}'::jsonb
  ) then
    raise exception 'valid weighted distribution rejected';
  end if;
  if promotions.distribution_is_valid(
    '{"inviter":[{"id":"ten","amountPaise":"1.5","weight":70}],'
    '"referee":[{"id":"ten","amountPaise":"1000","weight":70}]}'::jsonb
  ) then
    raise exception 'fractional paise distribution accepted';
  end if;

  if (select admission_mode <> 'open' or active_campaign_version is not null
        from promotions.access_settings where singleton)
     or exists (select 1 from promotions.campaign_versions) then
    raise exception 'promotion migration must ship with no active campaign and open admission';
  end if;
end
$$;

select 'referral promotion permissions: OK' as result;

begin;
set local role app_user;
do $$
declare
  v_fingerprint text := repeat('a', 64);
  v_allowed boolean;
  v_index integer;
begin
  for v_index in 1..21 loop
    select promotions.consume_invitation_validation(v_fingerprint) into v_allowed;
    if v_allowed is distinct from (v_index <= 20) then
      raise exception 'invitation validation rate limit mismatch at attempt %', v_index;
    end if;
  end loop;
end
$$;
rollback;

select 'shared invitation rate limit: OK' as result;
