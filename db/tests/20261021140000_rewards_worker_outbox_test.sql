-- Exercises the isolated worker role, lease fencing, retry history and
-- heartbeat on a disposable, fully migrated database. All fixtures roll back.
\set ON_ERROR_STOP on

begin;
select gen_random_uuid()::text as event_id,
       gen_random_uuid()::text as beneficiary_id,
       'worker-test-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) as event_key
\gset
select set_config('test.worker_event_id', :'event_id', true);

set local role promotions_owner;
insert into promotions.reward_outbox
  (id, event_key, event_type, beneficiary_id, payload)
values
  (:'event_id'::uuid, :'event_key', 'referral.joined', :'beneficiary_id'::uuid,
   '{"source":"worker-test"}'::jsonb);
reset role;

set local role app_user;
do $$
begin
  if pg_has_role('app_user', 'rewards_worker', 'member') then
    raise exception 'the API app_user must not inherit or assume the worker role';
  end if;
  if has_function_privilege('app_user',
       'promotions.claim_reward_outbox(text,integer,integer)', 'execute') then
    raise exception 'app_user must not execute reward worker routines';
  end if;
end
$$;

set local role rewards_worker;
do $$
declare
  v_claim record;
  v_result jsonb;
begin
  if has_table_privilege('rewards_worker', 'promotions.reward_outbox', 'select')
     or has_table_privilege('rewards_worker', 'promotions.reward_outbox', 'update') then
    raise exception 'worker role must use routines, not direct outbox table access';
  end if;

  select * into v_claim
    from promotions.claim_reward_outbox('worker-test-1', 5, 90)
   where id = current_setting('test.worker_event_id')::uuid;
  if v_claim.id is null or v_claim.attempt_number <> 1 then
    raise exception 'first event claim/attempt was not created';
  end if;

  v_result := promotions.finalize_reward_outbox(
    v_claim.id, v_claim.lease_token, false, null, 'temporary_failure', false
  );
  if v_result->>'state' <> 'pending' then
    raise exception 'transient failure did not schedule a retry: %', v_result;
  end if;
end
$$;
reset role;

set local role promotions_owner;
update promotions.reward_outbox
   set available_at = now()
 where id = current_setting('test.worker_event_id')::uuid;
reset role;

set local role app_user;
set local role rewards_worker;
do $$
declare
  v_claim record;
  v_result jsonb;
begin
  select * into v_claim
    from promotions.claim_reward_outbox('worker-test-1', 5, 90)
   where id = current_setting('test.worker_event_id')::uuid;
  if v_claim.id is null or v_claim.attempt_number <> 2 then
    raise exception 'retry claim did not increment the attempt number';
  end if;

  v_result := promotions.finalize_reward_outbox(
    v_claim.id, gen_random_uuid(), true, '{"status":"wrong-lease"}'::jsonb, null, false
  );
  if v_result->>'accepted' <> 'false' or v_result->>'state' <> 'lease_lost' then
    raise exception 'stale lease token was accepted: %', v_result;
  end if;

  v_result := promotions.finalize_reward_outbox(
    v_claim.id, v_claim.lease_token, true, '{"status":"inbox_committed"}'::jsonb, null, false
  );
  if v_result->>'state' <> 'delivered' then
    raise exception 'current lease could not be completed: %', v_result;
  end if;

  perform promotions.record_reward_worker_heartbeat('worker-test-1', 2, 1, null);
end
$$;
reset role;

do $$
begin
  if (select state from promotions.reward_outbox
       where id = current_setting('test.worker_event_id')::uuid) <> 'delivered' then
    raise exception 'outbox event is not terminal delivered';
  end if;
  if (select count(*) from promotions.reward_outbox_attempts
       where outbox_id = current_setting('test.worker_event_id')::uuid) <> 2 then
    raise exception 'attempt audit did not retain both lease attempts';
  end if;
  if (select count(*) from promotions.reward_outbox_attempts
       where outbox_id = current_setting('test.worker_event_id')::uuid
         and status in ('retry', 'delivered')) <> 2 then
    raise exception 'retry/delivery attempt statuses are incorrect';
  end if;
  if (select polls from promotions.reward_worker_heartbeats
       where worker_id = 'worker-test-1') <> 1 then
    raise exception 'worker heartbeat was not persisted';
  end if;
end
$$;

rollback;
select 'reward worker outbox: OK (rolled back fixtures)' as result;
