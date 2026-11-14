-- Regression test for migration 20261123060000 (user_local_state).
-- Run with `psql -v ON_ERROR_STOP=1` against a fully migrated scratch database.
\set ON_ERROR_STOP on
begin;

insert into profiles (id) values
  ('11110000-0000-0000-0000-00000000aaaa'),
  ('22220000-0000-0000-0000-00000000bbbb');

do $$
declare
  a uuid := '11110000-0000-0000-0000-00000000aaaa';
  b uuid := '22220000-0000-0000-0000-00000000bbbb';
  v_n int; v_seq1 bigint; v_seq2 bigint;
begin
  -- Rows are written as the owner so RLS (with check) is exercised for app_user.
  if exists(select 1 from pg_roles where rolname = 'app_user') then
    set local role app_user;
  end if;

  perform set_config('app.user_id', a::text, true);
  insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
    values (a, 'subscription_override', 'netflix', '{"hidden":true}', '2026-11-01T10:00:00Z');
  insert into user_local_state(profile_id, kind, state_key, payload_enc, client_edited_at)
    values (a, 'bank_balance', 'hdfc-savings', 'v1:k1:AAAA', '2026-11-01T10:00:00Z');

  -- Isolation: B sees nothing, cannot insert for A, cannot update or delete A's rows.
  perform set_config('app.user_id', b::text, true);
  select count(*) into v_n from user_local_state;
  if v_n <> 0 then raise exception 'B can read A rows (%)', v_n; end if;
  begin
    insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
      values (a, 'subscription_override', 'spoof', '{}', now());
    raise exception 'B inserted a row for A';
  exception when insufficient_privilege or check_violation then null; end;
  update user_local_state set deleted = true;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'B updated A rows'; end if;
  delete from user_local_state;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'B deleted A rows'; end if;

  -- Owner view, tombstone, server_seq moves forward on update.
  perform set_config('app.user_id', a::text, true);
  select server_seq into v_seq1 from user_local_state where state_key = 'netflix';
  update user_local_state set deleted = true, payload = null, client_edited_at = '2026-11-02T10:00:00Z',
         server_seq = nextval('user_local_state_seq')
   where state_key = 'netflix';
  select server_seq into v_seq2 from user_local_state where state_key = 'netflix';
  if v_seq2 <= v_seq1 then raise exception 'server_seq did not advance'; end if;
  select count(*) into v_n from user_local_state where deleted;
  if v_n <> 1 then raise exception 'tombstone missing'; end if;

  -- LWW is enforced by the API's conditional upsert; assert the same statement shape here.
  insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
    values (a, 'subscription_override', 'netflix', '{"hidden":false}', '2026-11-01T11:00:00Z')
    on conflict (profile_id, kind, state_key) do update
      set payload = excluded.payload, client_edited_at = excluded.client_edited_at
      where user_local_state.client_edited_at <= excluded.client_edited_at;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'older write overwrote newer row'; end if;

  -- Check constraints.
  begin
    insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
      values (a, 'nonsense', 'k', '{}', now());
    raise exception 'bad kind accepted';
  exception when check_violation then null; end;
  begin
    insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
      values (a, 'bank_balance', 'plain', '{"amount":1}', now());
    raise exception 'plaintext bank_balance accepted';
  exception when check_violation then null; end;
  begin
    insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
      values (a, 'subscription_override', '', '{}', now());
    raise exception 'empty key accepted';
  exception when check_violation then null; end;
  begin
    insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
      values (a, 'subscription_override', 'big', jsonb_build_object('x', repeat('y', 5000)), now());
    raise exception 'oversize payload accepted';
  exception when check_violation then null; end;
  begin
    insert into user_local_state(profile_id, kind, state_key, payload, client_edited_at)
      values (a, 'subscription_override', 'arr', '[]', now());
    raise exception 'non-object payload accepted';
  exception when check_violation then null; end;
end $$;

rollback;
\echo user_local_state: ok
