begin;

-- Additive health history for the autonomous SMS learning worker.  The worker
-- writes only bounded, already-redacted status metadata; the admin console
-- reads this table to distinguish a healthy idle worker from a stopped one.
create table if not exists public.sms_learning_worker_runs (
  run_id uuid primary key default gen_random_uuid(),
  status text not null check (status in ('succeeded', 'failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_sms_learning_worker_runs_started
  on public.sms_learning_worker_runs (started_at desc);

-- Keep the worker role separate from app_user while allowing it to read the
-- cross-user evidence it was explicitly granted above.  This policy is
-- intentionally tied to the fixed role used by the compose examples.
drop policy if exists sms_learning_worker_examples on public.sms_learning_examples;
create policy sms_learning_worker_examples on public.sms_learning_examples
  for select to public
  using (current_user = 'sms_learning_worker');

drop policy if exists sms_learning_worker_candidates on public.sms_rule_candidates;
create policy sms_learning_worker_candidates on public.sms_rule_candidates
  for all to public
  using (current_user = 'sms_learning_worker')
  with check (current_user = 'sms_learning_worker');

drop policy if exists sms_learning_worker_exposures on public.sms_rule_candidate_exposures;
create policy sms_learning_worker_exposures on public.sms_rule_candidate_exposures
  for select to public
  using (current_user = 'sms_learning_worker');

-- The worker must see inactive versions when choosing the next immutable
-- version number. Limiting it to the public "active only" policy can make it
-- reuse a rolled-back version and fail publication on the primary key.
drop policy if exists sms_learning_worker_bundles on public.sms_rule_bundles;
create policy sms_learning_worker_bundles on public.sms_rule_bundles
  for select to public
  using (current_user = 'sms_learning_worker');

alter table public.sms_learning_worker_runs enable row level security;
alter table public.sms_learning_worker_runs force row level security;

drop policy if exists sms_learning_worker_runs_ops on public.sms_learning_worker_runs;
create policy sms_learning_worker_runs_ops on public.sms_learning_worker_runs
  for all to public
  using (current_user in ('postgres', 'service_role', 'sms_learning_worker')
         or pandapay.is_admin())
  with check (current_user in ('postgres', 'service_role', 'sms_learning_worker')
              or pandapay.is_admin());

-- The API's app_user can read health through the existing requireAdmin gate;
-- the dedicated worker role can write its own run records.  The conditional
-- grant keeps migration application safe on installations that create the
-- role separately during deployment.
revoke all on public.sms_learning_worker_runs from public;
grant select on public.sms_learning_worker_runs to app_user;
revoke execute on function pandapay.sms_publish_bundle(integer, jsonb, text, text) from app_user;
revoke execute on function pandapay.sms_rollback_bundle(integer) from app_user;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'sms_learning_worker') then
    execute 'grant usage on schema public, pandapay to sms_learning_worker';
    execute 'grant select, insert on public.sms_learning_worker_runs to sms_learning_worker';
    execute 'grant select on public.sms_learning_examples, public.sms_rule_candidate_exposures, public.sms_rule_bundles to sms_learning_worker';
    execute 'grant select, insert, update on public.sms_rule_candidates to sms_learning_worker';
    execute 'grant execute on function pandapay.sms_publish_bundle(integer, jsonb, text, text) to sms_learning_worker';
    execute 'grant execute on function pandapay.sms_rollback_bundle(integer) to sms_learning_worker';
  end if;
end $$;

commit;
