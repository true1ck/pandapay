-- Disposable fully-migrated local PG fixture. Synthetic account only; rollback.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as profile_id \gset
select set_config('test.profile_id', :'profile_id', true);
insert into public.profiles(id) values(:'profile_id'::uuid);
insert into public.statement_imports(profile_id,statement_from,statement_to,txn_count,reconciled_count,
  import_request_hash,import_response_summary)
values(:'profile_id'::uuid,'2026-10-01','2026-10-31',1,1,repeat('a',64),
  '{"imported":1,"pendingDuplicates":0,"exactRetries":0}'::jsonb);

do $$ begin
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='statement_imports' and column_name='import_request_hash' and is_nullable='YES')
     or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='statement_imports' and column_name='import_response_summary' and is_nullable='YES') then
    raise exception 'receipt columns must be nullable and additive';
  end if;
  begin
    insert into public.statement_imports(profile_id,statement_from,statement_to,import_request_hash)
    values(current_setting('test.profile_id',true)::uuid,'2026-10-01','2026-10-31','raw financial request');
    raise exception 'malformed request digest accepted';
  exception when check_violation then null; end;
  begin
    insert into public.statement_imports(profile_id,statement_from,statement_to,import_request_hash,import_response_summary)
    values(current_setting('test.profile_id',true)::uuid,'2026-10-01','2026-10-31',repeat('b',64),
      '{"imported":1,"pendingDuplicates":-1,"exactRetries":0}'::jsonb);
    raise exception 'unbounded or negative summary accepted';
  exception when check_violation then null; end;
end $$;

set local role app_user;
select set_config('app.user_id', :'profile_id', true);
do $$ begin
  if not exists(select 1 from public.statement_imports where profile_id=pandapay.uid()
      and import_request_hash=repeat('a',64)
      and import_response_summary->>'imported'='1') then
    raise exception 'owner cannot read stored import receipt';
  end if;
end $$;
reset role;
rollback;
