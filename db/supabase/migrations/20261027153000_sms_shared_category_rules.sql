begin;

-- Expose only sufficiently supported merchant/category aggregates to clients.
-- The app role cannot read other users' feedback rows directly; this narrowly
-- scoped SECURITY DEFINER function returns only eligible aggregates.
create or replace function pandapay.sms_shared_category_rules()
returns table (
  merchant_key text,
  category_slug text,
  support_count integer,
  agreement_rate numeric
)
language sql
stable
security definer
set search_path = pg_catalog, public, pandapay
as $function$
  with eligible as (
    select e.profile_id, e.merchant_key, e.category_slug,
           e.created_at, e.event_id
      from public.sms_learning_feedback_events e
      join lateral (
        select c.granted
          from public.user_consents c
         where c.profile_id = e.profile_id
           and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.id desc
         limit 1
      ) current_consent on current_consent.granted = true
     where e.action = 'category_changed'
       and e.merchant_key is not null
       and length(e.merchant_key) between 3 and 80
       and e.merchant_key = upper(regexp_replace(btrim(e.merchant_key), '\s+', ' ', 'g'))
       and e.merchant_key !~ '^(UNKNOWN|OTHER|ONLINE|MERCHANT|PAYMENT|TRANSACTION)$'
       and e.category_slug in (
         'groceries', 'dining', 'online', 'fuel', 'travel', 'bills', 'health',
         'entertainment', 'rent', 'investments', 'emi', 'insurance',
         'education', 'income', 'wallet', 'cash'
       )
  ), latest_user_vote as (
    -- A person's newest explicit correction replaces their previous vote for
    -- this exact merchant. Repeated edits must not inflate support.
    select distinct on (profile_id, merchant_key)
           profile_id, merchant_key, category_slug
      from eligible
     order by profile_id, merchant_key, created_at desc, event_id desc
  ), votes as (
    select merchant_key, category_slug,
           count(*)::integer as user_count
      from latest_user_vote
     group by merchant_key, category_slug
  ), ranked as (
    select votes.*,
           sum(user_count) over (partition by merchant_key) as total_user_votes,
           row_number() over (
             partition by merchant_key
             order by user_count desc, category_slug asc
           ) as rank
      from votes
  )
  select merchant_key, category_slug, user_count,
         user_count::numeric / nullif(total_user_votes, 0)
    from ranked
   where rank = 1
     and user_count >= 10
     and total_user_votes >= 10
     and user_count::numeric / nullif(total_user_votes, 0) >= 0.90
   order by merchant_key, category_slug;
$function$;

revoke all on function pandapay.sms_shared_category_rules() from public;
grant execute on function pandapay.sms_shared_category_rules() to app_user;

comment on function pandapay.sms_shared_category_rules() is
  'Returns only exact merchant/category mappings supported by at least 10 currently opted-in users with at least 90 percent agreement. Each user contributes only their latest correction per merchant. Never returns source SMS or user identifiers.';

commit;
