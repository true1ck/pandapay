-- Disposable fully-migrated PostgreSQL fixture. No customer data or external
-- service calls; all generated status rows are rolled back at the end.
\set ON_ERROR_STOP on
begin;
select set_config('test.notification_health_worker', 'health-fixture', true);

do $$
declare
  i integer;
  accepted boolean;
begin
  if not has_function_privilege('notification_worker',
      'notification_delivery.report_worker_status(text,boolean,boolean,integer,integer,integer,text)', 'execute') then
    raise exception 'notification worker lacks status RPC';
  end if;
  if has_function_privilege('notification_worker','notification_delivery.health()', 'execute') then
    raise exception 'notification worker must not read monitor health';
  end if;
  if not has_function_privilege('notification_monitor','notification_delivery.health()', 'execute') then
    raise exception 'monitor capability lacks health RPC';
  end if;
  if has_table_privilege('notification_monitor','notification_delivery.worker_status','select')
     or has_table_privilege('notification_monitor','notification_delivery.outbox','select') then
    raise exception 'monitor must use aggregate RPC, not table access';
  end if;
  if has_table_privilege('notification_worker','notification_delivery.worker_status','select')
     or has_table_privilege('notification_worker','notification_delivery.worker_status','insert') then
    raise exception 'worker must report through function only';
  end if;

  begin
    perform notification_delivery.report_worker_status('bad worker id',true,false,0,0,0,null);
    raise exception 'unsafe worker id accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform notification_delivery.report_worker_status('health-fixture',true,false,2,0,0,null);
    raise exception 'unbounded status counts accepted';
  exception when invalid_parameter_value then null; end;
end $$;

set local role notification_worker;
do $$ declare ok boolean; begin
  ok:=notification_delivery.report_worker_status('health-fixture',true,false,1,1,0,null);
  if not ok then raise exception 'first status report was refused'; end if;
end $$;
reset role;

-- Fill the bounded status ledger to capacity. A 129th live worker is declined
-- without blocking delivery work; one bounded stale prune admits a replacement.
set local role notification_worker;
do $$ declare i integer; ok boolean; begin
  for i in 1..127 loop
    ok:=notification_delivery.report_worker_status('health-fixture-'||i,true,false,0,0,0,null);
    if not ok then raise exception 'worker status capacity filled early at %',i; end if;
  end loop;
  ok:=notification_delivery.report_worker_status('health-fixture-overflow',true,false,0,0,0,null);
  if ok then raise exception 'worker status capacity exceeded 128'; end if;
end $$;
reset role;

set local role notification_outbox_owner;
update notification_delivery.worker_status set heartbeat_at=now()-interval '2 days';
reset role;
set local role notification_worker;
select notification_delivery.report_worker_status('health-fixture-replacement',false,false,0,0,0,'db_unavailable');
reset role;

set local role notification_monitor;
do $$
declare h jsonb;
begin
  h:=notification_delivery.health();
  if h->'enabled'<>'null'::jsonb then raise exception 'health must not guess deployment enablement'; end if;
  if jsonb_typeof(h->'queued')<>'number' or jsonb_typeof(h->'retained')<>'number'
     or jsonb_typeof(h->'oldest_pending_seconds') not in ('number','null')
     or jsonb_typeof(h->'expired_leased')<>'number' or jsonb_typeof(h->'dead')<>'number'
     or jsonb_typeof(h->'new_terminal_24h')<>'number'
     or jsonb_typeof(h->'heartbeat_age_seconds') not in ('number','null')
     or jsonb_typeof(h->'missing_worker')<>'boolean'
     or jsonb_typeof(h->'blocked_workers')<>'number'
     or jsonb_typeof(h->'unavailable_workers')<>'number' then
    raise exception 'health output has invalid field types: %',h;
  end if;
  if (select count(*) from jsonb_object_keys(h))<>14 then raise exception 'health output contains unexpected fields: %',h; end if;
  if (h->>'worker_rows')::integer<>97 then raise exception 'bounded stale cleanup did not prune 32 statuses: %',h; end if;
  if h->>'missing_worker'='true' or (h->>'unavailable_workers')::integer<1 then
    raise exception 'fresh unavailable worker status missing from health'; end if;
end $$;
reset role;
rollback;
