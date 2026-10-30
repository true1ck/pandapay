-- Reset personal product data while retaining the login identity and profile.
-- Clears user-owned records across FK-backed and profile_id-scoped tables,
-- keeps the profile/login identity, and resets user-level profile settings.
-- Shared catalogue/reference rows have no profile_id and remain untouched.

-- Promotions tables are owned by promotions_owner and use FORCE ROW LEVEL
-- SECURITY. Keep their purge/anonymization work in narrowly scoped definer
-- functions owned by that role; the migration/admin role does not own those
-- tables on every deployment target.
-- PostgreSQL 16 gives a CREATEROLE login ADMIN membership in a role it
-- creates, but its initial membership has SET FALSE. The earlier promotions
-- migration created promotions_owner through that login, so enable its
-- existing membership before assuming the role. A migration login without
-- either SET or ADMIN rights still fails closed here.
do $$
begin
  if not pg_has_role(current_user, 'promotions_owner', 'SET') then
    execute 'grant promotions_owner to current_user with set true';
  end if;
end
$$;
set role promotions_owner;

create or replace function promotions.reset_account_profile_data(p_profile uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, promotions, pg_temp
as $$
declare
  v_table record;
  v_deleted bigint;
  v_total bigint;
  v_pass integer := 0;
begin
  loop
    v_total := 0;
    v_pass := v_pass + 1;
    for v_table in
      select distinct c.table_name
        from information_schema.columns c
        join information_schema.tables t
          on t.table_schema = c.table_schema and t.table_name = c.table_name
       where c.table_schema = 'promotions'
         and t.table_type = 'BASE TABLE'
         and c.column_name = 'profile_id'
       order by c.table_name
    loop
      begin
        execute format('delete from promotions.%I where profile_id = $1',
                       v_table.table_name)
          using p_profile;
        get diagnostics v_deleted = row_count;
        v_total := v_total + v_deleted;
      exception when foreign_key_violation then
        -- Retry this parent after its profile-owned children are removed.
        null;
      end;
    end loop;
    exit when v_total = 0 or v_pass >= 32;
  end loop;

  for v_table in
    select distinct c.table_name
      from information_schema.columns c
      join information_schema.tables t
        on t.table_schema = c.table_schema and t.table_name = c.table_name
     where c.table_schema = 'promotions'
       and t.table_type = 'BASE TABLE'
       and c.column_name = 'profile_id'
  loop
    execute format('select count(*) from promotions.%I where profile_id = $1',
                   v_table.table_name)
      into v_deleted using p_profile;
    if v_deleted > 0 then
      raise exception 'account_data_reset_incomplete: promotions.%',
        v_table.table_name;
    end if;
  end loop;
end;
$$;

create or replace function promotions.anonymize_account_profile_references(p_profile uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, promotions, pg_temp
as $$
declare
  v_fk record;
begin
  for v_fk in
    select distinct rel.relname as table_name,
                    att.attname as column_name
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
      join unnest(con.conkey) with ordinality fk_col(attnum, ord) on true
      join pg_attribute att on att.attrelid = rel.oid and att.attnum = fk_col.attnum
     where con.contype = 'f'
       and con.confrelid = 'public.profiles'::regclass
       and ns.nspname = 'promotions'
       and not att.attnotnull
       and att.attname <> 'profile_id'
  loop
    execute format('update promotions.%I set %I = null where %I = $1',
                   v_fk.table_name, v_fk.column_name, v_fk.column_name)
      using p_profile;
  end loop;
end;
$$;

revoke all on function promotions.reset_account_profile_data(uuid) from public;
revoke all on function promotions.anonymize_account_profile_references(uuid) from public;
reset role;

grant usage on schema promotions to current_user;
grant execute on function promotions.reset_account_profile_data(uuid) to current_user;
grant execute on function promotions.anonymize_account_profile_references(uuid) to current_user;

create or replace function pandapay.reset_account_data(p_profile uuid)
returns void
language plpgsql
security definer
set search_path = public, pandapay, pg_temp
as $$
declare
  v_profile profiles%rowtype;
  v_table record;
  v_deleted bigint;
  v_total bigint;
  v_pass integer := 0;
begin
  select * into v_profile from profiles where id = p_profile for update;
  if not found then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  perform promotions.reset_account_profile_data(p_profile);

  -- Delete every profile-owned table in dependency-aware passes. A table
  -- blocked by a child row is retried after that child has been cleared.
  loop
    v_total := 0;
    v_pass := v_pass + 1;
    for v_table in
      select distinct c.table_schema, c.table_name
        from information_schema.columns c
        join information_schema.tables t
          on t.table_schema = c.table_schema and t.table_name = c.table_name
       where c.table_schema = 'public'
         and t.table_type = 'BASE TABLE'
         and c.column_name = 'profile_id'
         and c.table_name <> 'profiles'
       order by c.table_name
    loop
      begin
        execute format('delete from %I.%I where profile_id = $1',
                       v_table.table_schema, v_table.table_name)
          using p_profile;
        get diagnostics v_deleted = row_count;
        v_total := v_total + v_deleted;
      exception when foreign_key_violation then
        -- The referenced user-owned row will be removed on a later pass.
        null;
      end;
    end loop;
    exit when v_total = 0 or v_pass >= 32;
  end loop;

  -- Surface an incomplete purge and roll the whole reset back atomically.
  for v_table in
    select distinct c.table_schema, c.table_name
      from information_schema.columns c
      join information_schema.tables t
        on t.table_schema = c.table_schema and t.table_name = c.table_name
     where c.table_schema = 'public'
       and t.table_type = 'BASE TABLE'
       and c.column_name = 'profile_id'
       and c.table_name <> 'profiles'
  loop
    execute format('select count(*) from %I.%I where profile_id = $1',
                   v_table.table_schema, v_table.table_name)
      into v_deleted using p_profile;
    if v_deleted > 0 then
      raise exception 'account_data_reset_incomplete: %.%',
        v_table.table_schema, v_table.table_name;
    end if;
  end loop;

  update profiles
     set travel_mode_active = false,
         contributions_opt_in = false,
         onboarding_completed_at = null,
         deletion_requested_at = null,
         deletion_due_at = null
   where id = p_profile;
end;
$$;

revoke all on function pandapay.reset_account_data(uuid) from public;
grant execute on function pandapay.reset_account_data(uuid) to app_user;

-- Shared learning/audit records retain decisions but no longer retain the
-- identity of the reviewer when that account is erased.
alter table public.sms_category_rule_approvals
  alter column reviewed_by drop not null;
alter table public.sms_parser_candidate_approvals
  alter column reviewed_by drop not null;
alter table public.sms_category_rule_v2_approvals
  alter column reviewed_by drop not null;
alter table public.sms_learning_candidate_decisions
  alter column decided_by drop not null;

set role promotions_owner;
alter table promotions.referral_operator_holds
  alter column changed_by drop not null;
alter table promotions.referral_operator_audit
  alter column actor_profile_id drop not null;
reset role;

create or replace function pandapay.execute_account_deletion(p_profile uuid)
returns void
language plpgsql
security definer
set search_path = public, pandapay, pg_temp
as $$
declare
  v_fk record;
begin
  if not exists (select 1 from profiles where id = p_profile) then
    return; -- idempotent retry after partial cross-service completion
  end if;

  perform pandapay.reset_account_data(p_profile);
  perform promotions.anonymize_account_profile_references(p_profile);

  -- Anonymize nullable reviewer/actor references in shared audit data. Any
  -- non-nullable references must be handled explicitly in a reviewed schema
  -- migration instead of silently blocking or deleting another user's data.
  for v_fk in
    select distinct ns.nspname as schema_name,
                    rel.relname as table_name,
                    att.attname as column_name
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
      join unnest(con.conkey) with ordinality fk_col(attnum, ord) on true
      join pg_attribute att on att.attrelid = rel.oid and att.attnum = fk_col.attnum
     where con.contype = 'f'
       and con.confrelid = 'public.profiles'::regclass
       and rel.oid <> 'public.profiles'::regclass
       and ns.nspname <> 'promotions'
       and not att.attnotnull
       and att.attname <> 'profile_id'
  loop
    execute format('update %I.%I set %I = null where %I = $1',
                   v_fk.schema_name, v_fk.table_name,
                   v_fk.column_name, v_fk.column_name)
      using p_profile;
  end loop;

  delete from profiles where id = p_profile;
end;
$$;

revoke all on function pandapay.execute_account_deletion(uuid) from public;
grant execute on function pandapay.execute_account_deletion(uuid) to app_user;
