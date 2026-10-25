-- Partner postbacks are service requests, without an end-user RLS context.
-- Keep their authority separate from app_user and from the migration owner.
-- No provider-specific extension or encrypted source data is changed here.
do $$
declare v_role text;
begin
  foreach v_role in array array['partner_webhook_owner', 'pandapay_partner_webhook'] loop
    if not exists (select 1 from pg_catalog.pg_roles where rolname = v_role) then
      execute pg_catalog.format('create role %I nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls', v_role);
    elsif exists (select 1 from pg_catalog.pg_roles where rolname = v_role and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
      raise exception 'Unsafe existing partner webhook role';
    end if;
    if exists (select 1 from pg_catalog.pg_auth_members where member = v_role::regrole) then
      raise exception 'Partner webhook roles must not inherit or SET other roles';
    end if;
  end loop;
end $$;

-- PostgreSQL 16+ managed CREATEROLE users receive ADMIN on roles they create,
-- but not necessarily SET. Temporarily allow only this migration role to SET
-- the definer owner. Save its own grant and restore it below; the bootstrap
-- grantor's ADMIN membership is never revoked or changed. This makes both a
-- first install and a reviewed SQL replay work without SUPERUSER.
do $$
declare v_prior jsonb;
begin
  select pg_catalog.jsonb_build_object('inherit',m.inherit_option,'set',m.set_option)
    into v_prior from pg_catalog.pg_auth_members m
    where m.roleid = 'partner_webhook_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.partner_owner_prior_grant', coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.partner_migration_role',current_user,true);
  execute pg_catalog.format('grant partner_webhook_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant partner_webhook_owner to %I with set true granted by %I',current_user,current_user);
end $$;

create schema if not exists partner_webhook;
revoke all on schema partner_webhook from public;
grant usage, create on schema partner_webhook to partner_webhook_owner;
grant usage on schema public to partner_webhook_owner;

-- The function owner cannot log in and receives only the columns and rows
-- needed for attribution, not general API writes or a BYPASSRLS attribute.
grant select (click_token, partner_program_id) on public.partner_clicks to partner_webhook_owner;
-- ON CONFLICT's EXCLUDED expressions require SELECT on the updated value
-- columns too, even though only canonical RPC arguments supply those values.
grant select (id, click_token, external_ref, status, commission_inr, raw_payload),
      insert (click_token, partner_program_id, status, commission_inr, external_ref, raw_payload),
      update (status, commission_inr, raw_payload, reported_at)
  on public.partner_conversions to partner_webhook_owner;
drop policy if exists partner_clicks_webhook_lookup on public.partner_clicks;
create policy partner_clicks_webhook_lookup on public.partner_clicks
  for select to partner_webhook_owner using (true);
drop policy if exists partner_conversions_webhook_select on public.partner_conversions;
create policy partner_conversions_webhook_select on public.partner_conversions
  for select to partner_webhook_owner using (true);
drop policy if exists partner_conversions_webhook_insert on public.partner_conversions;
create policy partner_conversions_webhook_insert on public.partner_conversions
  for insert to partner_webhook_owner with check (true);
drop policy if exists partner_conversions_webhook_update on public.partner_conversions;
create policy partner_conversions_webhook_update on public.partner_conversions
  for update to partner_webhook_owner using (true) with check (true);

set local role partner_webhook_owner;
create or replace function partner_webhook.ingest_conversion(
  p_click_token text,
  p_status text,
  p_commission_inr numeric,
  p_external_ref text
) returns boolean
language plpgsql security definer
set search_path = ''
set statement_timeout = '5s'
set lock_timeout = '2s'
as $$
declare
  v_program_id uuid;
  v_legacy_id uuid;
  v_external_ref text := nullif(p_external_ref, '');
  v_payload jsonb;
begin
  -- Validate again at the SQL boundary. Database logins cannot bypass the
  -- HTTP shape limits or write arbitrary raw JSON through this capability.
  if p_click_token is null or pg_catalog.octet_length(p_click_token) not between 1 and 256
     or p_click_token ~ '[[:cntrl:]]'
     or p_status is null or p_status not in ('pending', 'approved', 'rejected', 'reversed')
     or (p_commission_inr is not null and
         (p_commission_inr < -9999999999.99 or p_commission_inr > 9999999999.99))
     or (v_external_ref is not null and
         (pg_catalog.octet_length(v_external_ref) > 512 or v_external_ref ~ '[[:cntrl:]]')) then
    raise exception 'Invalid partner conversion' using errcode = '22023';
  end if;

  -- Serialize same-click reports, including the first no-reference insert.
  -- This avoids granting UPDATE on click rows simply to obtain a row lock.
  -- Hash collisions only serialize unrelated requests; they cannot join them.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('partner-webhook:' || p_click_token, 0));
  select c.partner_program_id into v_program_id
    from public.partner_clicks c where c.click_token = p_click_token;
  if not found then return false; end if;

  v_payload := pg_catalog.jsonb_build_object(
    'clickToken', p_click_token, 'status', p_status,
    'commissionInr', p_commission_inr, 'externalRef', v_external_ref);
  if v_external_ref is null then
    -- Historical NULL refs were not unique: SQL UNIQUE treats NULLs as
    -- distinct. Preserve all historical rows, update one stable UUID on retries,
    -- and never create another NULL-ref row for that click after this change.
    select c.id into v_legacy_id from public.partner_conversions c
      where c.click_token = p_click_token and (c.external_ref is null or c.external_ref = '')
      order by c.id limit 1;
    if found then
      update public.partner_conversions set status = p_status,
        commission_inr = p_commission_inr, raw_payload = v_payload,
        reported_at = pg_catalog.now() where id = v_legacy_id;
    else
      insert into public.partner_conversions
        (click_token, partner_program_id, status, commission_inr, external_ref, raw_payload)
      values (p_click_token, v_program_id, p_status, p_commission_inr, null, v_payload);
    end if;
  else
    insert into public.partner_conversions
      (click_token, partner_program_id, status, commission_inr, external_ref, raw_payload)
    values (p_click_token, v_program_id, p_status, p_commission_inr, v_external_ref, v_payload)
    on conflict (click_token, external_ref) do update set
      status = excluded.status, commission_inr = excluded.commission_inr,
      raw_payload = excluded.raw_payload, reported_at = pg_catalog.now();
  end if;
  return true;
end $$;

revoke all on function partner_webhook.ingest_conversion(text,text,numeric,text) from public;
grant execute on function partner_webhook.ingest_conversion(text,text,numeric,text) to pandapay_partner_webhook;

comment on function partner_webhook.ingest_conversion(text,text,numeric,text) is
  'Private service-only affiliate postback capability. Executor role pandapay_partner_webhook is never granted to app_user. NULL/empty references identify one conversion per click; existing duplicate rows are retained.';

select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.partner_migration_role'),true);
-- CREATE was needed only while defining the function, not at runtime. The
-- executor receives no table grants and no owner membership.
revoke create on schema partner_webhook from partner_webhook_owner;
grant usage on schema partner_webhook to pandapay_partner_webhook;
do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.partner_owner_prior_grant')::jsonb;
begin
  if v_prior = 'null'::jsonb then
    execute pg_catalog.format('revoke partner_webhook_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant partner_webhook_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant partner_webhook_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
