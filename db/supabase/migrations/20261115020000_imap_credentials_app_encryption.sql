-- Email import: mailbox app passwords are sealed in the API process with
-- AES-256-GCM (api/src/imap_credentials.js). The key never reaches PostgreSQL,
-- so pgp_sym_encrypt/pgp_sym_decrypt and the key-as-query-parameter path go.
-- Sealed values are bound to the profile, the connection and the key id.
--
-- Fresh-start release: the product database starts empty, so no existing
-- credential is re-encrypted. Any row from the old scheme cannot be opened by
-- the new code and is removed, which makes that user reconnect.
-- This file runs inside the migration runner's transaction.

truncate table public.imap_connections;

alter table public.imap_connections
  drop column app_password_encrypted,
  add column app_password_ciphertext bytea not null,
  add column app_password_key_id text not null
    check (app_password_key_id ~ '^[A-Za-z0-9._-]{1,32}$'),
  alter column sender_filter set not null;

comment on column public.imap_connections.app_password_ciphertext is
  'nonce(12) || GCM tag(16) || ciphertext. AES-256-GCM sealed by the API; AAD binds profile, connection and key id.';
comment on column public.imap_connections.sender_filter is
  'Comma-separated bank sender addresses. Required: polling never reads the whole mailbox.';

-- Let the private worker owner read only what the new enumeration needs.
-- (Dropping app_password_encrypted removed its column grant.)
grant select (app_password_ciphertext, app_password_key_id)
  on public.imap_connections to imap_worker_owner;

-- PostgreSQL 16+ managed CREATEROLE users receive ADMIN on roles they create,
-- but not necessarily SET. Temporarily allow only this migration role to SET
-- the definer owner, restoring its prior grant at the end (same method as
-- 20261023190128_imap_worker_capability.sql).
do $$
declare v_prior jsonb;
begin
  select pg_catalog.jsonb_build_object('inherit',m.inherit_option,'set',m.set_option)
    into v_prior from pg_catalog.pg_auth_members m
    where m.roleid = 'imap_worker_owner'::regrole
      and m.member = current_user::regrole and m.grantor = current_user::regrole;
  perform pg_catalog.set_config('pandapay.imap_owner_prior_grant',coalesce(v_prior::text,'null'),false);
  perform pg_catalog.set_config('pandapay.imap_migration_role',current_user,false);
  execute pg_catalog.format('grant imap_worker_owner to %I with inherit false granted by %I',current_user,current_user);
  execute pg_catalog.format('grant imap_worker_owner to %I with set true granted by %I',current_user,current_user);
end $$;

grant create on schema imap_worker to imap_worker_owner;

set local role imap_worker_owner;

drop function if exists imap_worker.next_connections(text, integer);

-- Same durable-cursor behaviour as before; it now returns the sealed value
-- and key id instead of decrypting in SQL.
create function imap_worker.next_connections(p_limit integer)
returns table (
  id uuid, profile_id uuid, email text, imap_host text, imap_port integer,
  sender_filter text, last_poll_at timestamptz,
  app_password_ciphertext bytea, app_password_key_id text
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
begin
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Invalid IMAP worker arguments' using errcode='22023';
  end if;
  select s.last_connection_id into v_cursor from imap_worker.poll_state s
    where s.singleton for update;
  if not found then raise exception 'IMAP worker cursor unavailable'; end if;

  for v_connection in
    select c.id,c.profile_id,c.email::text as email,c.imap_host,c.imap_port,
           c.sender_filter,c.last_poll_at,c.app_password_ciphertext,c.app_password_key_id
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
    app_password_ciphertext := v_connection.app_password_ciphertext;
    app_password_key_id := v_connection.app_password_key_id;
    v_last := v_connection.id;
    v_count := v_count + 1;
    return next;
  end loop;
  update imap_worker.poll_state set
    last_connection_id=case when v_count < p_limit then null else v_last end,
    updated_at=pg_catalog.now() where singleton;
end $$;

revoke all on function imap_worker.next_connections(integer) from public;
grant execute on function imap_worker.next_connections(integer) to pandapay_imap_worker;
comment on function imap_worker.next_connections(integer) is
  'Private worker-only IMAP enumeration, max 100 active rows per call. Returns the sealed credential; the API opens it. Durable UUID cursor advances before provider work; failed rows retry after rotation. Direct/session pooling required for the caller advisory lock.';

select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.imap_migration_role'),true);
revoke create on schema imap_worker from imap_worker_owner;
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
