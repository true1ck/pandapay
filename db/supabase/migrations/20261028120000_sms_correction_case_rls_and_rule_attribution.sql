begin;

-- Admin correction review runs through app_user. Allow admins to see cases
-- only while the submitting profile still has the exact current consent grant.
drop policy if exists sms_learning_feedback_events_read
  on public.sms_learning_feedback_events;
create policy sms_learning_feedback_events_read
  on public.sms_learning_feedback_events
  for select to public
  using (
    current_user in ('service_role', 'postgres')
    or profile_id = pandapay.uid()
    or (
      pandapay.is_admin()
      and exists (
        select 1
          from public.user_consents c
         where c.profile_id = sms_learning_feedback_events.profile_id
           and c.purpose = 'sms_shared_learning'
           and c.granted
           and c.policy_version = sms_learning_feedback_events.consent_policy_version
           and c.granted_at = sms_learning_feedback_events.consent_granted_at
           and not exists (
             select 1 from public.user_consents newer
              where newer.profile_id = c.profile_id
                and newer.purpose = c.purpose
                and (newer.granted_at, (not newer.granted), newer.id) >
                    (c.granted_at, (not c.granted), c.id)
           )
      )
    )
);

-- Exposure visibility is also gated by the older merchant-contribution flag.
-- Check only the caller's own assignment in a narrow SECURITY DEFINER helper
-- so SMS consent can verify attribution without exposing cohort rows.
create or replace function pandapay.sms_user_has_applied_rule_exposure(
  p_source_key text, p_rule_id text
) returns boolean
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  select pandapay.uid() is not null and exists (
    select 1
      from public.sms_rule_candidate_exposures e
      join public.sms_rule_candidate_assignments a
        on a.assignment_id = e.assignment_id
       and a.profile_id = e.profile_id
       and a.candidate_id = e.candidate_id
     where e.profile_id = pandapay.uid()
       and e.source_key = p_source_key
       and e.candidate_id = p_rule_id
       and e.assigned
       and e.applied
       and a.mode = 'apply'
  );
$function$;

revoke all on function pandapay.sms_user_has_applied_rule_exposure(text, text) from public;
grant execute on function pandapay.sms_user_has_applied_rule_exposure(text, text) to app_user;

-- Defense in depth: app_user inserts that bypass the API cannot attach an
-- arbitrary candidate id to a correction event.
drop policy if exists sms_learning_feedback_events_insert
  on public.sms_learning_feedback_events;
create policy sms_learning_feedback_events_insert
  on public.sms_learning_feedback_events
  for insert to public
  with check (
    (current_user in ('service_role', 'postgres') or profile_id = pandapay.uid())
    and (decision_rule_id is null or
         pandapay.sms_user_has_applied_rule_exposure(source_key_hash, decision_rule_id))
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

commit;
