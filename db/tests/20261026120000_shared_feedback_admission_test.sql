-- Run after migration 20261026120000_shared_feedback_admission.sql.
begin;
do $$
declare r record; i integer;
begin
  if has_table_privilege('pandapay_feedback_admission','feedback_admission.buckets','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'runtime role has direct bucket table privileges';
  end if;
  if not has_function_privilege('pandapay_feedback_admission',
    'feedback_admission.consume(text,text,boolean)','EXECUTE') then
    raise exception 'runtime role cannot execute admission capability';
  end if;
  if has_schema_privilege('pandapay_feedback_admission','feedback_admission','CREATE') then
    raise exception 'runtime role can create objects in capability schema';
  end if;
  if (select rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolreplication or rolbypassrls
      from pg_roles where rolname='pandapay_feedback_admission') then
    raise exception 'capability role has login or elevated role attributes';
  end if;
end $$;

-- Model a nearly full store without allocating 250,000 fixture rows. The
-- target expired identity sorts after 500 older rows and must renew in place.
do $$
declare r record; i integer; v_capacity integer; v_denied boolean := false;
begin
  insert into feedback_admission.buckets(route_bucket,identity_digest,authenticated,hit_count,window_started_at,expires_at)
  select 'support_tickets', lpad(to_hex(seed.k),64,'0'), false, 1,
         now()-interval '3 hours', now()-interval '2 hours'
    from generate_series(1,500) AS seed(k);
  insert into feedback_admission.buckets(route_bucket,identity_digest,authenticated,hit_count,window_started_at,expires_at)
  values ('support_tickets',repeat('f',64),false,1,now()-interval '2 hours',now()-interval '1 hour');
  update feedback_admission.capacity set used_rows=250000 where singleton;
  select * into r from feedback_admission.consume('support_tickets',repeat('f',64),false);
  if not r.allowed then raise exception 'expired identity did not renew at capacity'; end if;
  select used_rows into v_capacity from feedback_admission.capacity where singleton;
  if v_capacity <> 249500 then raise exception 'renewal changed capacity counter unexpectedly: %',v_capacity; end if;
  update feedback_admission.capacity set used_rows=250000 where singleton;
  begin
    perform * from feedback_admission.consume('support_tickets',repeat('e',64),false);
  exception when sqlstate 'P0001' then v_denied := true; end;
  if not v_denied then raise exception using errcode='P0002', message='new identity bypassed full capacity'; end if;
  update feedback_admission.capacity set used_rows=(select count(*) from feedback_admission.buckets)::integer where singleton;
end $$;

create role pandapay_feedback_fixture_login login nosuperuser nocreatedb nocreaterole inherit nobypassrls;
grant pandapay_feedback_admission to pandapay_feedback_fixture_login;
do $$
begin
  if not has_function_privilege('pandapay_feedback_fixture_login',
    'feedback_admission.consume(text,text,boolean)','EXECUTE') then
    raise exception 'independent login cannot execute narrow capability';
  end if;
  if has_table_privilege('pandapay_feedback_fixture_login','feedback_admission.buckets','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'independent login inherited direct bucket privileges';
  end if;
end $$;
set local role pandapay_feedback_fixture_login;
do $$
declare r record; i integer;
begin
  for i in 1..30 loop
    select * into r from feedback_admission.consume('support_tickets', repeat('a',64), false);
    if not r.allowed then raise exception 'anonymous quota limited early at %',i; end if;
  end loop;
  select * into r from feedback_admission.consume('support_tickets', repeat('a',64), false);
  if r.allowed is distinct from false or r.retry_after_seconds < 1 then raise exception 'anonymous cap not enforced'; end if;
  select * into r from feedback_admission.consume('data_error_reports', repeat('a',64), false);
  if r.allowed is distinct from true then raise exception 'route buckets are not independent'; end if;
  for i in 1..5 loop
    select * into r from feedback_admission.consume('data_error_reports', repeat('b',64), true);
    if not r.allowed then raise exception 'profile quota limited early at %',i; end if;
  end loop;
  select * into r from feedback_admission.consume('data_error_reports', repeat('b',64), true);
  if r.allowed is distinct from false then raise exception 'profile cap not enforced'; end if;
  begin
    perform * from feedback_admission.consume('arbitrary_bucket', repeat('c',64), false);
    raise exception 'unexpected bucket accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform * from feedback_admission.consume('support_tickets', 'raw-ip', false);
    raise exception 'invalid digest accepted';
  exception when invalid_parameter_value then null; end;
  begin
    execute 'select count(*) from feedback_admission.buckets';
    raise exception 'runtime role can read internal table';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
