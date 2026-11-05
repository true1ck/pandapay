-- Regression test for migration 20261115010000 (hand-entered bills sync).
-- Run with `psql -v ON_ERROR_STOP=1` against a fully migrated scratch database.

\set ON_ERROR_STOP on

begin;

select set_config('app.user_id', '11110000-0000-0000-0000-00000000aaaa', true);

insert into profiles (id) values
  ('11110000-0000-0000-0000-00000000aaaa'),
  ('22220000-0000-0000-0000-00000000bbbb');

do $$
declare
  v_a uuid; v_b uuid; v_other uuid;
  v_bill uuid := '77770000-0000-0000-0000-000000000001';
  v_applied boolean; v_reason text; v_count int; v_payload jsonb; v_op text;
begin
  v_a := pandapay.register_sync_device('11110000-0000-0000-0000-00000000aaaa', 'android', 'Phone A');
  v_b := pandapay.register_sync_device('11110000-0000-0000-0000-00000000aaaa', 'ios', 'Phone B');

  -- Insert from phone A.
  select out_applied, out_reason into v_applied, v_reason
    from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa', v_a, v_bill,
         'insert', '{"id":"manual-1","title":"Rent","amount_paise":1500000}'::jsonb, 1);
  if not v_applied then raise exception 'insert not applied: %', v_reason; end if;

  -- Phone B pulls it from the start of the log.
  select count(*) into v_count
    from pandapay.sync_pull('11110000-0000-0000-0000-00000000aaaa', v_b, 0, 500)
   where entity = 'user_commitments' and entity_id = v_bill and op = 'insert'
     and payload ->> 'title' = 'Rent';
  if v_count <> 1 then raise exception 'phone B did not receive the bill (%).', v_count; end if;

  -- Phone A does not receive its own change back.
  select count(*) into v_count
    from pandapay.sync_pull('11110000-0000-0000-0000-00000000aaaa', v_a, 0, 500)
   where entity = 'user_commitments';
  if v_count <> 0 then raise exception 'phone A received its own change'; end if;

  -- Update replaces the document and is logged as an update.
  select out_applied into v_applied
    from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa', v_a, v_bill,
         'update', '{"id":"manual-1","title":"Rent","amount_paise":1600000}'::jsonb, 2);
  select payload, op::text into v_payload, v_op
    from pandapay.sync_pull('11110000-0000-0000-0000-00000000aaaa', v_b, 0, 500)
   where entity = 'user_commitments' order by server_seq desc limit 1;
  if v_op <> 'update' or (v_payload ->> 'amount_paise')::int <> 1600000 then
    raise exception 'update was not logged';
  end if;
  if (select payload ->> 'amount_paise' from public.user_commitments where id = v_bill) <> '1600000' then
    raise exception 'row was not replaced';
  end if;

  -- Malformed documents are refused.
  select out_applied, out_reason into v_applied, v_reason
    from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa', v_a,
         '77770000-0000-0000-0000-000000000002', 'insert', '{"title":"no id"}'::jsonb, 3);
  if v_applied or v_reason <> 'malformed' then raise exception 'malformed document accepted'; end if;
  select out_applied, out_reason into v_applied, v_reason
    from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa', v_a,
         '77770000-0000-0000-0000-000000000002', 'insert',
         jsonb_build_object('id','x','pad',repeat('a',17000)), 4);
  if v_applied or v_reason <> 'malformed' then raise exception 'oversized document accepted'; end if;

  -- Delete leaves a tombstone; a late update cannot resurrect the bill.
  select out_applied into v_applied
    from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa', v_a, v_bill,
         'delete', '{}'::jsonb, 5);
  if not v_applied then raise exception 'delete not applied'; end if;
  select out_applied, out_reason into v_applied, v_reason
    from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa', v_a, v_bill,
         'update', '{"id":"manual-1","title":"Rent"}'::jsonb, 6);
  if not v_applied then raise exception 'late update after delete should drain the queue'; end if;
  if (select deleted_at from public.user_commitments where id = v_bill) is null
     or (select payload from public.user_commitments where id = v_bill) <> '{}'::jsonb then
    raise exception 'deleted bill was resurrected or has no tombstone';
  end if;

  -- A device that is not the caller's is refused.
  begin
    perform * from pandapay.sync_apply_user_commitment('11110000-0000-0000-0000-00000000aaaa',
      '99990000-0000-0000-0000-000000000009', v_bill, 'update', '{"id":"x"}'::jsonb, 7);
    raise exception 'unknown device accepted';
  exception when insufficient_privilege then null;
  end;

  -- Another account cannot touch this row (RLS context is the other profile).
  perform set_config('app.user_id', '22220000-0000-0000-0000-00000000bbbb', true);
  v_other := pandapay.register_sync_device('22220000-0000-0000-0000-00000000bbbb', 'android', 'Other');
  select out_applied, out_reason into v_applied, v_reason
    from pandapay.sync_apply_user_commitment('22220000-0000-0000-0000-00000000bbbb', v_other, v_bill,
         'update', '{"id":"x","title":"stolen"}'::jsonb, 1);
  if v_applied then raise exception 'cross-account write accepted'; end if;
  select out_applied into v_applied
    from pandapay.sync_apply_user_commitment('22220000-0000-0000-0000-00000000bbbb', v_other, v_bill,
         'delete', '{}'::jsonb, 2);
  if v_applied then raise exception 'cross-account delete accepted'; end if;
  perform set_config('app.user_id', '11110000-0000-0000-0000-00000000aaaa', true);
end $$;

rollback;
\echo user_commitments sync: ok
