begin;

-- SMS examples can contain transaction amounts and timing. Existing
-- crowdsource consent covers merchant/MCC/rough-location signals, so shared
-- SMS learning needs its own explicit, default-off consent purpose.
alter table user_consents
  drop constraint if exists user_consents_purpose_check;
alter table user_consents
  add constraint user_consents_purpose_check
  check (purpose in (
    'terms', 'crowdsource', 'marketing', 'aggregate_insights',
    'partner_sharing', 'sms_shared_learning'
  ));

create table if not exists public.sms_learning_feedback_events (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  event_id uuid not null,
  source_key_hash text not null check (source_key_hash ~ '^[0-9a-f]{64}$'),
  sender_fingerprint text not null check (sender_fingerprint ~ '^[0-9a-f]{64}$'),
  action text not null check (action in (
    'confirmed', 'edited', 'category_changed', 'moved_to_review', 'dismissed'
  )),
  resolved_kind text not null check (resolved_kind in (
    'transaction', 'bill', 'mandate', 'dismissed', 'unresolved'
  )),
  consent_purpose text not null default 'sms_shared_learning'
    check (consent_purpose = 'sms_shared_learning'),
  consent_policy_version text not null,
  consent_granted_at timestamptz not null,
  merchant_key text,
  category_slug text,
  original_category_slug text,
  original_decision jsonb not null default '{}'::jsonb,
  corrected_fields jsonb not null default '{}'::jsonb,
  occurred_at timestamptz,
  learned boolean not null default false,
  learning_reason text,
  created_at timestamptz not null default now(),
  primary key (profile_id, event_id)
);

create index if not exists idx_sms_learning_feedback_category
  on public.sms_learning_feedback_events (merchant_key, category_slug, created_at desc)
  where action = 'category_changed';

comment on table public.sms_learning_feedback_events is
  'Idempotent, privacy-minimized user feedback for SMS decisions. No raw SMS body or sender is stored here; shared examples are separately redacted and consent-gated.';

alter table public.sms_learning_feedback_events enable row level security;
alter table public.sms_learning_feedback_events force row level security;
drop policy if exists sms_learning_feedback_events_read on public.sms_learning_feedback_events;
create policy sms_learning_feedback_events_read on public.sms_learning_feedback_events
  for select to public
  using (current_user in ('service_role', 'postgres') or profile_id = pandapay.uid());
drop policy if exists sms_learning_feedback_events_insert on public.sms_learning_feedback_events;
create policy sms_learning_feedback_events_insert on public.sms_learning_feedback_events
  for insert to public
  with check (
    (current_user in ('service_role', 'postgres') or profile_id = pandapay.uid())
    and exists (
      select 1 from public.user_consents c
       where c.profile_id = sms_learning_feedback_events.profile_id
         and c.purpose = 'sms_shared_learning' and c.granted
         and not exists (
           select 1 from public.user_consents newer
            where newer.profile_id = c.profile_id
              and newer.purpose = c.purpose
              and (newer.granted_at, newer.id) > (c.granted_at, c.id)
         )
    )
  );
grant select, insert on public.sms_learning_feedback_events to app_user;

-- Replace historical crowdsource-consent gates on all shared SMS learning
-- surfaces. The merchant graph remains governed by contributions_opt_in;
-- numeric SMS examples and experiment telemetry require this dedicated purpose.
drop policy if exists sms_learning_examples_insert on public.sms_learning_examples;
create policy sms_learning_examples_insert on public.sms_learning_examples
  for insert to public
  with check (
    current_user in ('service_role', 'postgres')
    or (
      pandapay.uid() is not null
      and profile_id = pandapay.uid()
      and exists (
        select 1 from public.user_consents c
         where c.profile_id = pandapay.uid()
           and c.purpose = 'sms_shared_learning' and c.granted
           and not exists (
             select 1 from public.user_consents newer
              where newer.profile_id = c.profile_id and newer.purpose = c.purpose
                and (newer.granted_at, newer.id) > (c.granted_at, c.id)
           )
      )
      and nullif(current_setting('app.sms_learning_hmac_key', true), '') is not null
      and user_hash = encode(hmac(pandapay.uid()::text,
        current_setting('app.sms_learning_hmac_key', true), 'sha256'), 'hex')
    )
  );

drop policy if exists sms_learning_feedback_owner on public.sms_learning_feedback;
create policy sms_learning_feedback_owner on public.sms_learning_feedback
  for insert to public
  with check (
    profile_id = pandapay.uid()
    and exists (
      select 1 from public.user_consents c
       where c.profile_id = pandapay.uid()
         and c.purpose = 'sms_shared_learning' and c.granted
         and not exists (
           select 1 from public.user_consents newer
            where newer.profile_id = c.profile_id and newer.purpose = c.purpose
              and (newer.granted_at, newer.id) > (c.granted_at, c.id)
         )
    )
  );

drop policy if exists sms_rule_candidate_exposures_service on public.sms_rule_candidate_exposures;
create policy sms_rule_candidate_exposures_service on public.sms_rule_candidate_exposures
  for all to public
  using (
    current_user in ('service_role', 'postgres') or pandapay.is_admin()
    or (pandapay.uid() is not null and profile_id = pandapay.uid()
        and exists (
          select 1 from public.user_consents c
           where c.profile_id = pandapay.uid()
             and c.purpose = 'sms_shared_learning' and c.granted
             and not exists (
               select 1 from public.user_consents newer
                where newer.profile_id = c.profile_id and newer.purpose = c.purpose
                  and (newer.granted_at, newer.id) > (c.granted_at, c.id)
             )
        ))
  )
  with check (
    current_user in ('service_role', 'postgres') or pandapay.is_admin()
    or (pandapay.uid() is not null and profile_id = pandapay.uid()
        and exists (
          select 1 from public.user_consents c
           where c.profile_id = pandapay.uid()
             and c.purpose = 'sms_shared_learning' and c.granted
             and not exists (
               select 1 from public.user_consents newer
                where newer.profile_id = c.profile_id and newer.purpose = c.purpose
                  and (newer.granted_at, newer.id) > (c.granted_at, c.id)
             )
        ))
  );

drop policy if exists sms_rule_candidate_assignments_owner on public.sms_rule_candidate_assignments;
create policy sms_rule_candidate_assignments_owner on public.sms_rule_candidate_assignments
  for all to public
  using (current_user in ('service_role', 'postgres') or pandapay.is_admin()
         or (pandapay.uid() is not null and profile_id = pandapay.uid()))
  with check (current_user in ('service_role', 'postgres') or pandapay.is_admin()
         or (pandapay.uid() is not null and profile_id = pandapay.uid()
             and exists (
               select 1 from public.user_consents c
                where c.profile_id = pandapay.uid()
                  and c.purpose = 'sms_shared_learning' and c.granted
                  and not exists (
                    select 1 from public.user_consents newer
                     where newer.profile_id = c.profile_id and newer.purpose = c.purpose
                       and (newer.granted_at, newer.id) > (c.granted_at, c.id)
                  )
             )));

-- Consent withdrawal erases attributed examples, event metadata, exposures,
-- and staged assignments. Published immutable rule snapshots may still carry
-- aggregate rules; they are handled through their global safety/rollback gate.
create or replace function pandapay.sms_delete_learning_examples_for_user(
  p_user_id uuid, p_hmac_key text default null
) returns integer
language plpgsql security definer
set search_path = pg_catalog, public, pandapay, extensions
as $$
declare
  v_user_hash text;
  v_deleted integer := 0;
  v_count integer;
  v_key text;
begin
  if p_user_id is null then return 0; end if;
  if session_user not in ('postgres', 'service_role')
     and pandapay.uid() is distinct from p_user_id then
    raise exception 'cannot erase another profile';
  end if;
  v_key := coalesce(nullif(p_hmac_key, ''),
    nullif(current_setting('app.sms_learning_hmac_key', true), ''));
  if v_key is not null and length(v_key) >= 32 then
    v_user_hash := encode(hmac(p_user_id::text, v_key, 'sha256'), 'hex');
  end if;

  delete from public.sms_learning_examples
   where profile_id = p_user_id
      or (v_user_hash is not null and user_hash = v_user_hash);
  get diagnostics v_count = row_count; v_deleted := v_deleted + v_count;
  delete from public.sms_learning_feedback where profile_id = p_user_id;
  get diagnostics v_count = row_count; v_deleted := v_deleted + v_count;
  delete from public.sms_learning_feedback_events where profile_id = p_user_id;
  get diagnostics v_count = row_count; v_deleted := v_deleted + v_count;
  delete from public.sms_rule_candidate_exposures where profile_id = p_user_id;
  get diagnostics v_count = row_count; v_deleted := v_deleted + v_count;
  delete from public.sms_rule_candidate_assignments where profile_id = p_user_id;
  get diagnostics v_count = row_count; v_deleted := v_deleted + v_count;
  return v_deleted;
end;
$$;

commit;
