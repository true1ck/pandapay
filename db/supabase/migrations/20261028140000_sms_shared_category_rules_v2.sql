begin;

-- V2 category rules are scoped to an institutional sender and a bounded
-- category-discriminating SMS context. The app mirrors the API token list:
-- BROADBAND, CAB, DIESEL, DINING, EDUCATION, ELECTRICITY, EMI,
-- ENTERTAINMENT, FLIGHT, FUEL, GROCERIES, GROCERY, HOSPITAL, HOTEL,
-- INSURANCE, INVESTMENT, LOAN, MEDICAL, MOVIE, MUTUAL, PHARMACY, PETROL,
-- RENEWAL, RENEWED, RENT, RESTAURANT, RIDE, SALARY, SCHOOL, SUBSCRIPTION,
-- SUPERMARKET, TAX, TRAIN, TRAVEL, TUITION, UTILITY, WALLET. Context keys
-- are sorted unique tokens.

create or replace function pandapay.sms_category_context_key_valid(p_context_key text)
returns boolean
language sql immutable strict
set search_path = pg_catalog
as $function$
  select array_length(string_to_array(p_context_key, '|'), 1) between 1 and 8
     and coalesce(p_context_key = (
       select string_agg(token, '|' order by token)
         from (select distinct unnest(string_to_array(p_context_key, '|')) as token) tokens
        where token = any (array[
          'BROADBAND','CAB','DIESEL','DINING','EDUCATION','ELECTRICITY','EMI',
          'ENTERTAINMENT','FLIGHT','FUEL','GROCERIES','GROCERY','HOSPITAL',
          'HOTEL','INSURANCE','INVESTMENT','LOAN','MEDICAL','MOVIE','MUTUAL',
          'PHARMACY','PETROL','RENEWAL','RENEWED','RENT','RESTAURANT','RIDE',
          'SALARY','SCHOOL','SUBSCRIPTION','SUPERMARKET','TAX','TRAIN','TRAVEL',
          'TUITION','UTILITY','WALLET'
        ]::text[])
     ), false)
$function$;
revoke all on function pandapay.sms_category_context_key_valid(text) from public;
grant execute on function pandapay.sms_category_context_key_valid(text) to app_user;

alter table public.sms_learning_feedback_events
  add column if not exists sender_key text,
  add column if not exists context_key text,
  add column if not exists fact_family text;

alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_sender_key_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_sender_key_check
  check (sender_key is null or sender_key ~ '^[A-Z]{2}-[A-Z0-9]{3,10}(-[A-Z])?$');
alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_context_key_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_context_key_check
  check (context_key is null or pandapay.sms_category_context_key_valid(context_key));
alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_fact_family_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_fact_family_check
  check (fact_family is null or fact_family = 'posted_movement');

alter table public.sms_ai_learning_proposals
  add column if not exists sender_key text,
  add column if not exists context_key text;
alter table public.sms_ai_learning_proposals
  drop constraint if exists sms_ai_learning_proposals_sender_key_check;
alter table public.sms_ai_learning_proposals
  add constraint sms_ai_learning_proposals_sender_key_check
  check (sender_key is null or sender_key ~ '^[A-Z]{2}-[A-Z0-9]{3,10}(-[A-Z])?$');
alter table public.sms_ai_learning_proposals
  drop constraint if exists sms_ai_learning_proposals_context_key_check;
alter table public.sms_ai_learning_proposals
  add constraint sms_ai_learning_proposals_context_key_check
  check (context_key is null or pandapay.sms_category_context_key_valid(context_key));

create index if not exists idx_sms_feedback_category_v2_scope
  on public.sms_learning_feedback_events
    (merchant_key, sender_key, context_key, category_slug, created_at desc)
  where sender_key is not null and context_key is not null
    and fact_family = 'posted_movement';
create index if not exists idx_sms_ai_category_v2_scope
  on public.sms_ai_learning_proposals
    (sender_key, context_key, created_at desc)
  where sender_key is not null and context_key is not null
    and fact_family = 'posted_movement';

create table if not exists public.sms_category_rule_v2_approvals (
  merchant_key text not null check (length(merchant_key) between 3 and 80),
  sender_key text not null check (sender_key ~ '^[A-Z]{2}-[A-Z0-9]{3,10}(-[A-Z])?$'),
  context_key text not null check (pandapay.sms_category_context_key_valid(context_key)),
  fact_family text not null check (fact_family = 'posted_movement'),
  category_slug text not null check (category_slug ~ '^[a-z0-9_-]{1,64}$'),
  status text not null check (status in ('approved', 'rejected')),
  reviewed_by uuid not null references public.profiles(id),
  reviewed_at timestamptz not null default now(),
  reason text not null,
  support_count_at_review integer not null check (support_count_at_review >= 10),
  agreement_rate_at_review numeric not null
    check (agreement_rate_at_review >= 0.90 and agreement_rate_at_review <= 1.0),
  primary key (merchant_key, sender_key, context_key, fact_family)
);
alter table public.sms_category_rule_v2_approvals enable row level security;
alter table public.sms_category_rule_v2_approvals force row level security;
revoke all on public.sms_category_rule_v2_approvals from public, app_user;
grant select, insert, update on public.sms_category_rule_v2_approvals to app_user;
create policy sms_category_rule_v2_approvals_admin on public.sms_category_rule_v2_approvals
  for all to app_user using (pandapay.is_admin()) with check (pandapay.is_admin());

create or replace function pandapay.sms_shared_category_rules_v2()
returns table (
  merchant_key text,
  sender_key text,
  context_key text,
  fact_family text,
  category_slug text,
  support_count integer,
  agreement_rate numeric
)
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  with eligible as (
    select e.profile_id, e.source_key_hash, e.merchant_key, e.sender_key,
           e.context_key, 'posted_movement'::text as fact_family,
           e.category_slug, e.created_at, e.event_id, 1 as source_priority
      from public.sms_learning_feedback_events e
      join lateral (
        select c.granted, c.policy_version, c.granted_at
          from public.user_consents c
         where c.profile_id = e.profile_id and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.granted asc, c.id desc limit 1
      ) consent on consent.granted = true
                 and consent.policy_version = e.consent_policy_version
                 and consent.granted_at = e.consent_granted_at
     where e.action = 'category_changed'
       and e.review_status = 'approved'
       and e.superseded_at is null
       and (e.correction_kind = 'misclassified_category'
         or (e.correction_kind is null and e.original_category_slug is null))
       and e.resolved_kind = 'transaction'
       and e.merchant_key is not null and e.sender_key is not null
       and e.context_key is not null
       and pandapay.sms_category_context_key_valid(e.context_key)
       and e.fact_family = 'posted_movement'
       and e.category_slug is not null
       and e.category_slug is distinct from e.original_category_slug
    union all
    select p.profile_id, p.source_key_hash,
           upper(regexp_replace(btrim(p.proposed_fields->>'merchant'), '\s+', ' ', 'g')),
           p.sender_key, p.context_key, 'posted_movement'::text,
           p.proposed_fields->>'categorySlug', p.reviewed_at, p.event_id,
           0 as source_priority
      from public.sms_ai_learning_proposals p
      join lateral (
        select c.granted, c.policy_version, c.granted_at
          from public.user_consents c
         where c.profile_id = p.profile_id and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.granted asc, c.id desc limit 1
      ) consent on consent.granted = true
                 and consent.policy_version = p.consent_policy_version
                 and consent.granted_at = p.consent_granted_at
     where p.status = 'approved'
       and p.fact_family = 'posted_movement'
       and p.sender_key is not null and p.context_key is not null
       and p.proposed_fields ? 'merchant'
       and p.proposed_fields ? 'categorySlug'
  ), valid_votes as (
    select * from eligible
     where merchant_key is not null
       and length(merchant_key) between 3 and 80
       and merchant_key = upper(regexp_replace(btrim(merchant_key), '\s+', ' ', 'g'))
       and merchant_key !~ '^(UNKNOWN|OTHER|ONLINE|MERCHANT|PAYMENT|TRANSACTION)$'
       and sender_key ~ '^[A-Z]{2}-[A-Z0-9]{3,10}(-[A-Z])?$'
       and pandapay.sms_category_context_key_valid(context_key)
       and category_slug in (
         'groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent',
         'insurance', 'education', 'government', 'wallet', 'entertainment',
         'health', 'emi', 'other'
       )
  ), latest_user_vote as (
    -- One latest vote per user and scoped rule identity. User/source identity
    -- is never exposed in the aggregate or bundle.
    select distinct on (profile_id, merchant_key, sender_key, context_key, fact_family)
           profile_id, merchant_key, sender_key, context_key, fact_family, category_slug
      from valid_votes
     order by profile_id, merchant_key, sender_key, context_key, fact_family,
              source_priority desc, created_at desc, event_id desc
  ), votes as (
    select merchant_key, sender_key, context_key, fact_family, category_slug,
           count(*)::integer as user_count
      from latest_user_vote
     group by merchant_key, sender_key, context_key, fact_family, category_slug
  ), ranked as (
    select votes.*,
           sum(user_count) over (partition by merchant_key, sender_key, context_key, fact_family)
             as total_user_votes,
           row_number() over (
             partition by merchant_key, sender_key, context_key, fact_family
             order by user_count desc, category_slug asc
           ) as rank
      from votes
  )
  select merchant_key, sender_key, context_key, fact_family, category_slug,
         user_count, user_count::numeric / nullif(total_user_votes, 0)
    from ranked
   where rank = 1 and user_count >= 10 and total_user_votes >= 10
     and user_count::numeric / nullif(total_user_votes, 0) >= 0.90
   order by merchant_key, sender_key, context_key, fact_family, category_slug;
$function$;
revoke all on function pandapay.sms_shared_category_rules_v2() from public;
grant execute on function pandapay.sms_shared_category_rules_v2() to app_user;

create or replace function pandapay.sms_approved_category_rules_v2()
returns table (
  merchant_key text,
  sender_key text,
  context_key text,
  fact_family text,
  category_slug text,
  support_count integer,
  agreement_rate numeric
)
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  select c.merchant_key, c.sender_key, c.context_key, c.fact_family,
         c.category_slug, c.support_count, c.agreement_rate
    from pandapay.sms_shared_category_rules_v2() c
    join public.sms_category_rule_v2_approvals a
      on a.merchant_key = c.merchant_key
     and a.sender_key = c.sender_key
     and a.context_key = c.context_key
     and a.fact_family = c.fact_family
     and a.category_slug = c.category_slug
     and a.status = 'approved'
   order by c.merchant_key, c.sender_key, c.context_key, c.fact_family;
$function$;
revoke all on function pandapay.sms_approved_category_rules_v2() from public;
grant execute on function pandapay.sms_approved_category_rules_v2() to app_user;

create or replace function pandapay.sms_admin_category_evidence_v2()
returns table (
  merchant_key text, sender_key text, context_key text, fact_family text,
  category_slug text, redacted_pattern text
)
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
begin
  if not pandapay.is_admin() then
    raise exception 'admin required' using errcode = '42501';
  end if;
  return query
    with current_evidence as (
      select e.merchant_key, e.sender_key, e.context_key, e.fact_family,
             e.category_slug, e.redacted_pattern, e.created_at
        from public.sms_learning_feedback_events e
        join lateral (
          select c.granted, c.policy_version, c.granted_at
            from public.user_consents c
           where c.profile_id = e.profile_id and c.purpose = 'sms_shared_learning'
           order by c.granted_at desc, c.granted asc, c.id desc limit 1
        ) consent on consent.granted = true
                   and consent.policy_version = e.consent_policy_version
                   and consent.granted_at = e.consent_granted_at
       where e.superseded_at is null and e.review_status = 'approved'
         and (e.correction_kind = 'misclassified_category'
           or (e.correction_kind is null and e.original_category_slug is null))
         and e.resolved_kind = 'transaction'
         and e.sender_key is not null and e.context_key is not null
         and pandapay.sms_category_context_key_valid(e.context_key)
         and e.fact_family = 'posted_movement'
         and e.redacted_pattern is not null
      union all
      select upper(regexp_replace(btrim(p.proposed_fields->>'merchant'), '\s+', ' ', 'g')),
             p.sender_key, p.context_key, p.fact_family,
             p.proposed_fields->>'categorySlug', p.redacted_pattern, p.reviewed_at
        from public.sms_ai_learning_proposals p
        join lateral (
          select c.granted, c.policy_version, c.granted_at
            from public.user_consents c
           where c.profile_id = p.profile_id and c.purpose = 'sms_shared_learning'
           order by c.granted_at desc, c.granted asc, c.id desc limit 1
        ) consent on consent.granted = true
                   and consent.policy_version = p.consent_policy_version
                   and consent.granted_at = p.consent_granted_at
       where p.status = 'approved' and p.fact_family = 'posted_movement'
         and p.sender_key is not null and p.context_key is not null
         and pandapay.sms_category_context_key_valid(p.context_key)
         and p.proposed_fields ? 'merchant'
         and p.proposed_fields ? 'categorySlug'
         and p.redacted_pattern is not null
    )
    select distinct on (e.merchant_key, e.sender_key, e.context_key,
                        e.fact_family, e.category_slug)
           e.merchant_key, e.sender_key, e.context_key, e.fact_family,
           e.category_slug, e.redacted_pattern
      from current_evidence e
     where e.merchant_key is not null and e.sender_key is not null
       and e.context_key is not null and e.category_slug is not null
     order by e.merchant_key, e.sender_key, e.context_key,
              e.fact_family, e.category_slug, e.created_at desc,
              e.redacted_pattern;
end;
$function$;
revoke all on function pandapay.sms_admin_category_evidence_v2() from public;
grant execute on function pandapay.sms_admin_category_evidence_v2() to app_user;

commit;
