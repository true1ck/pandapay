begin;

alter table public.sms_learning_feedback_events
  add column if not exists review_status text not null default 'pending',
  add column if not exists reviewed_by uuid references public.profiles(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_reason text;

alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_review_status_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_review_status_check
  check (review_status in ('pending', 'approved', 'rejected', 'revoked'));

create index if not exists idx_sms_learning_feedback_review_status
  on public.sms_learning_feedback_events (review_status, created_at desc)
  where superseded_at is null;

-- Admin review only changes whether explicit category corrections may enter
-- the existing category-candidate aggregate. It never publishes a rule.
create or replace function pandapay.sms_review_correction_case(
  p_event_id uuid, p_decision text, p_admin_id uuid, p_reason text
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $function$
declare
  v_event public.sms_learning_feedback_events%rowtype;
  v_consent record;
begin
  if not pandapay.is_admin() then
    raise exception 'admin required' using errcode = '42501';
  end if;
  if p_admin_id is null or p_admin_id is distinct from pandapay.uid() then
    raise exception 'admin identity mismatch' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected', 'revoked') or
     p_reason is null or length(btrim(p_reason)) < 5 or length(p_reason) > 500 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_review');
  end if;

  select * into v_event
    from public.sms_learning_feedback_events
   where event_id = p_event_id
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_event.superseded_at is not null or
     (p_decision = 'revoked' and v_event.review_status <> 'approved') or
     (p_decision in ('approved', 'rejected') and v_event.review_status <> 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'case_no_longer_reviewable');
  end if;
  if p_decision = 'approved' and v_event.correction_kind in
       ('cosmetic', 'preference_only', 'duplicate', 'already_paid') then
    return jsonb_build_object('ok', false, 'reason', 'non_training_case');
  end if;

  if p_decision <> 'revoked' then
    select c.granted, c.policy_version, c.granted_at into v_consent
      from public.user_consents c
     where c.profile_id = v_event.profile_id
       and c.purpose = 'sms_shared_learning'
     order by c.granted_at desc, c.granted asc, c.id desc
     limit 1;
    if not found or v_consent.granted is distinct from true or
       v_consent.policy_version is null or
       v_event.consent_policy_version <> v_consent.policy_version or
       v_event.consent_granted_at <> v_consent.granted_at then
      return jsonb_build_object('ok', false, 'reason', 'consent_changed');
    end if;
  end if;

  update public.sms_learning_feedback_events
     set review_status = p_decision,
         reviewed_by = p_admin_id,
         reviewed_at = now(),
         review_reason = btrim(p_reason)
   where profile_id = v_event.profile_id and event_id = p_event_id;

  insert into public.admin_audit_log
    (admin_id, action, entity, entity_id, before_value, after_value, reason)
  values
    (p_admin_id, 'review_sms_correction_case', 'sms_learning_feedback_events',
     p_event_id, jsonb_build_object('reviewStatus', v_event.review_status),
     jsonb_build_object('reviewStatus', p_decision), btrim(p_reason));

  return jsonb_build_object('ok', true, 'decision', p_decision);
end;
$function$;

revoke all on function pandapay.sms_review_correction_case(uuid, text, uuid, text) from public;
grant execute on function pandapay.sms_review_correction_case(uuid, text, uuid, text) to app_user;

-- Pending and rejected corrections are visible for admin review but cannot
-- contribute votes. Explicit approval only makes eligible corrections enter
-- the pre-existing aggregate; normal threshold and rule approval still apply.
create or replace function pandapay.sms_shared_category_rules()
returns table (
  merchant_key text,
  category_slug text,
  support_count integer,
  agreement_rate numeric
)
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  with eligible as (
    select e.profile_id, e.merchant_key, e.category_slug,
           e.created_at, e.event_id, 1 as source_priority
      from public.sms_learning_feedback_events e
      join lateral (
        select c.granted from public.user_consents c
         where c.profile_id = e.profile_id and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.granted asc, c.id desc limit 1
      ) current_consent on current_consent.granted = true
     where e.superseded_at is null
       and e.review_status = 'approved'
       and e.category_slug is not null
       and e.category_slug is distinct from e.original_category_slug
       and coalesce(e.correction_kind, 'misclassified_category') not in (
         'preference_only', 'cosmetic', 'duplicate', 'already_paid'
       )
    union all
    select p.profile_id,
           upper(regexp_replace(btrim(p.proposed_fields->>'merchant'), '\s+', ' ', 'g')),
           p.proposed_fields->>'categorySlug', p.reviewed_at, p.event_id,
           0 as source_priority
      from public.sms_ai_learning_proposals p
      join lateral (
        select c.granted, c.policy_version from public.user_consents c
         where c.profile_id = p.profile_id and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.granted asc, c.id desc limit 1
      ) current_consent on current_consent.granted = true
                       and current_consent.policy_version = 'sms-shared-learning-v2'
     where p.status = 'approved'
       and p.proposed_fields ? 'merchant'
       and p.proposed_fields ? 'categorySlug'
  ), valid_votes as (
    select * from eligible
     where merchant_key is not null
       and length(merchant_key) between 3 and 80
       and merchant_key = upper(regexp_replace(btrim(merchant_key), '\s+', ' ', 'g'))
       and merchant_key !~ '^(UNKNOWN|OTHER|ONLINE|MERCHANT|PAYMENT|TRANSACTION)$'
       and category_slug in (
         'groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent',
         'insurance', 'education', 'government', 'wallet', 'entertainment',
         'health', 'emi', 'other'
       )
  ), latest_user_vote as (
    select distinct on (profile_id, merchant_key)
           profile_id, merchant_key, category_slug
      from valid_votes
     order by profile_id, merchant_key, source_priority desc,
              created_at desc, event_id desc
  ), votes as (
    select merchant_key, category_slug, count(*)::integer as user_count
      from latest_user_vote group by merchant_key, category_slug
  ), ranked as (
    select votes.*,
           sum(user_count) over (partition by merchant_key) as total_user_votes,
           row_number() over (partition by merchant_key
             order by user_count desc, category_slug asc) as rank
      from votes
  )
  select merchant_key, category_slug, user_count,
         user_count::numeric / nullif(total_user_votes, 0)
    from ranked
   where rank = 1 and user_count >= 10 and total_user_votes >= 10
     and user_count::numeric / nullif(total_user_votes, 0) >= 0.90
   order by merchant_key, category_slug;
$function$;

revoke all on function pandapay.sms_shared_category_rules() from public;
grant execute on function pandapay.sms_shared_category_rules() to app_user;

commit;
