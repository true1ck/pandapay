-- Private IMAP worker capability; no public or app_user execution rights.
do $$
declare v_role text;
begin
  foreach v_role in array array['imap_worker_owner', 'pandapay_imap_worker'] loop
    if not exists (select 1 from pg_catalog.pg_roles where rolname = v_role) then
      execute pg_catalog.format('create role %I nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls', v_role);
    elsif exists (select 1 from pg_catalog.pg_roles where rolname = v_role and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
      raise exception 'Unsafe existing IMAP worker role';
    end if;
    if exists (select 1 from pg_catalog.pg_auth_members where member = v_role::regrole) then
      raise exception 'IMAP worker roles must not inherit or SET other roles';
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
    where m.roleid = 'imap_worker_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.imap_owner_prior_grant', coalesce(v_prior::text,'null'),true);
  perform pg_catalog.set_config('pandapay.imap_migration_role',current_user,true);
  execute pg_catalog.format('grant imap_worker_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant imap_worker_owner to %I with set true granted by %I',current_user,current_user);
end $$;

create schema if not exists imap_worker;
revoke all on schema imap_worker from public;
grant usage, create on schema imap_worker to imap_worker_owner;
grant usage on schema public to imap_worker_owner;

-- Private cursor: one bounded batch per tick, durable across lock owners.
-- It advances before provider work. Failed mailboxes retain last_poll_at and
-- are retried after the next full rotation; they do not hold up other users.
create table if not exists imap_worker.poll_state (
  singleton boolean primary key default true check (singleton),
  last_connection_id uuid,
  updated_at timestamptz not null default pg_catalog.now()
);
insert into imap_worker.poll_state (singleton) values (true) on conflict do nothing;
revoke all on table imap_worker.poll_state from public;
alter table imap_worker.poll_state enable row level security;
grant select (singleton,last_connection_id), update (last_connection_id,updated_at)
  on imap_worker.poll_state to imap_worker_owner;
drop policy if exists imap_worker_cursor_select on imap_worker.poll_state;
create policy imap_worker_cursor_select on imap_worker.poll_state
  for select to imap_worker_owner using (singleton);
drop policy if exists imap_worker_cursor_update on imap_worker.poll_state;
create policy imap_worker_cursor_update on imap_worker.poll_state
  for update to imap_worker_owner using (singleton) with check (singleton);

-- The owner has only the columns and active rows this enumeration needs.
-- It cannot log in, bypass RLS, alter ownership, or import user transactions.
grant select (id,profile_id,email,imap_host,imap_port,sender_filter,last_poll_at,is_active,app_password_encrypted)
  on public.imap_connections to imap_worker_owner;
drop policy if exists imap_connections_worker_read on public.imap_connections;
create policy imap_connections_worker_read on public.imap_connections
  for select to imap_worker_owner using (is_active);

-- pgcrypto is in extensions on Supabase and public on some portable targets.
-- Resolve its trusted extension namespace rather than trusting search_path.
do $$
declare v_crypto_schema text;
begin
  select n.nspname into v_crypto_schema from pg_catalog.pg_extension e
    join pg_catalog.pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto';
  if v_crypto_schema is null then raise exception 'IMAP worker requires pgcrypto'; end if;
  if not pg_catalog.has_schema_privilege('imap_worker_owner',v_crypto_schema,'USAGE') then
    execute pg_catalog.format('grant usage on schema %I to imap_worker_owner',v_crypto_schema);
  end if;
  if not pg_catalog.has_function_privilege('imap_worker_owner',
      pg_catalog.format('%I.pgp_sym_decrypt(bytea,text)',v_crypto_schema),'EXECUTE') then
    execute pg_catalog.format('grant execute on function %I.pgp_sym_decrypt(bytea,text) to imap_worker_owner',v_crypto_schema);
  end if;
end $$;

set local role imap_worker_owner;
create or replace function imap_worker.next_connections(p_encryption_key text, p_limit integer)
returns table (
  id uuid, profile_id uuid, email text, imap_host text, imap_port integer,
  sender_filter text, last_poll_at timestamptz, app_password text,
  credential_error boolean
)
language plpgsql security definer
set search_path = ''
set statement_timeout = '5s'
set lock_timeout = '2s'
as $$
declare
  v_cursor uuid;
  v_last uuid;
  v_count integer := 0;
  v_connection record;
  v_crypto_schema text;
begin
  if p_encryption_key is null or pg_catalog.octet_length(p_encryption_key) not between 1 and 4096
     or p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Invalid IMAP worker arguments' using errcode='22023';
  end if;
  select n.nspname into v_crypto_schema from pg_catalog.pg_extension e
    join pg_catalog.pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto';
  if v_crypto_schema is null then raise exception 'IMAP worker unavailable'; end if;

  select s.last_connection_id into v_cursor from imap_worker.poll_state s
    where s.singleton for update;
  if not found then raise exception 'IMAP worker cursor unavailable'; end if;

  for v_connection in
    select c.id,c.profile_id,c.email::text as email,c.imap_host,c.imap_port,
           c.sender_filter,c.last_poll_at,c.app_password_encrypted
      from public.imap_connections c
     where c.is_active and (v_cursor is null or c.id > v_cursor)
     order by c.id limit p_limit
  loop
    id := v_connection.id;
    profile_id := v_connection.profile_id;
    email := v_connection.email;
    imap_host := v_connection.imap_host;
    imap_port := v_connection.imap_port;
    sender_filter := v_connection.sender_filter;
    last_poll_at := v_connection.last_poll_at;
    app_password := null;
    credential_error := false;
    begin
      execute pg_catalog.format('select %I.pgp_sym_decrypt($1,$2)',v_crypto_schema)
        into app_password using v_connection.app_password_encrypted,p_encryption_key;
    exception when external_routine_invocation_exception or data_exception then
      -- Wrong key/corrupt ciphertext must not reveal values or starve a batch.
      credential_error := true;
      app_password := null;
    end;
    v_last := v_connection.id;
    v_count := v_count + 1;
    return next;
  end loop;
  update imap_worker.poll_state set
    last_connection_id=case when v_count < p_limit then null else v_last end,
    updated_at=pg_catalog.now() where singleton;
end $$;

revoke all on function imap_worker.next_connections(text,integer) from public;
grant execute on function imap_worker.next_connections(text,integer) to pandapay_imap_worker;
comment on function imap_worker.next_connections(text,integer) is
  'Private worker-only IMAP enumeration/decryption, max100 active rows per call. Durable UUID cursor advances before provider work; failed rows retry after rotation. Per-user import/status writes remain RLS-scoped app work. Direct/session pooling required for the caller advisory lock.';

-- A bounded cycle may stop before processing its whole claimed batch. Move
-- the cursor back to the last attempted UUID before releasing the session
-- advisory lock so deferred rows lead the next tick (including short batches).
create or replace function imap_worker.defer_connections(p_last_attempted_id uuid)
returns void language plpgsql security definer
set search_path = ''
set statement_timeout = '5s'
set lock_timeout = '2s'
as $$
begin
  update imap_worker.poll_state set last_connection_id=p_last_attempted_id,
    updated_at=pg_catalog.now() where singleton;
  if not found then raise exception 'IMAP worker cursor unavailable'; end if;
end $$;
revoke all on function imap_worker.defer_connections(uuid) from public;
grant execute on function imap_worker.defer_connections(uuid) to pandapay_imap_worker;

select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.imap_migration_role'),true);
-- CREATE was needed only while defining the function, not at runtime. The
-- executor receives no table grants and no owner membership.
revoke create on schema imap_worker from imap_worker_owner;
grant usage on schema imap_worker to pandapay_imap_worker;
do $$
declare v_prior jsonb := pg_catalog.current_setting('pandapay.imap_owner_prior_grant')::jsonb;
begin
  if v_prior = 'null'::jsonb then
    execute pg_catalog.format('revoke imap_worker_owner from %I granted by %I',current_user,current_user);
  else
    execute pg_catalog.format('grant imap_worker_owner to %I with inherit %s granted by %I',
      current_user,v_prior->>'inherit',current_user);
    execute pg_catalog.format('grant imap_worker_owner to %I with set %s granted by %I',
      current_user,v_prior->>'set',current_user);
  end if;
end $$;
