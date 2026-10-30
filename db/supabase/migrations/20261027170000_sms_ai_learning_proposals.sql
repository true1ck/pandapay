begin;

create table if not exists public.sms_ai_learning_proposals (
  proposal_id uuid not null default gen_random_uuid() unique,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  event_id uuid not null,
  source_key_hash text not null check (source_key_hash ~ '^[0-9a-f]{64}$'),
  sender_fingerprint text not null check (sender_fingerprint ~ '^[0-9a-f]{64}$'),
  user_hash text not null check (user_hash ~ '^[0-9a-f]{64}$'),
  issuer_prefix text,
  sender_pattern text not null,
  redacted_pattern text not null,
  template_text text,
  synthetic_sample text,
  fact_family text not null check (fact_family in (
    'posted_movement', 'balance_snapshot', 'bill_obligation', 'bill_payment',
    'mandate_lifecycle', 'ignore_noise'
  )),
  resolved_kind text not null,
  proposed_fields jsonb not null default '{}'::jsonb,
  ai_score numeric,
  consent_policy_version text not null check (consent_policy_version = 'sms-shared-learning-v2'),
  consent_granted_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_reason text,
  created_at timestamptz not null default now(),
  primary key (profile_id, event_id),
  check (length(redacted_pattern) between 3 and 1201),
  check (ai_score is null or ai_score between 0 and 1)
);

create index if not exists idx_sms_ai_learning_proposals_pending
  on public.sms_ai_learning_proposals(status, created_at desc);

alter table public.sms_ai_learning_proposals enable row level security;
alter table public.sms_ai_learning_proposals force row level security;
revoke all on public.sms_ai_learning_proposals from public, app_user;
grant select, insert, update, delete on public.sms_ai_learning_proposals to app_user;

-- Admin review must verify the proposal owner's current consent. The existing
-- owner policy alone hides those rows from an admin using the app_user role.
create policy user_consents_sms_learning_admin_read on public.user_consents
  for select to app_user using (pandapay.is_admin());

create policy sms_ai_learning_proposals_read on public.sms_ai_learning_proposals
  for select to app_user using (profile_id = pandapay.uid() or pandapay.is_admin());
create policy sms_ai_learning_proposals_insert on public.sms_ai_learning_proposals
  for insert to app_user with check (
    profile_id = pandapay.uid() and status = 'pending'
    and exists (
      select 1 from public.user_consents c
       where c.profile_id = sms_ai_learning_proposals.profile_id
         and c.purpose = 'sms_shared_learning'
         and c.granted and c.policy_version = 'sms-shared-learning-v2'
         and c.granted_at = sms_ai_learning_proposals.consent_granted_at
         and not exists (
           select 1 from public.user_consents newer
            where newer.profile_id = c.profile_id and newer.purpose = c.purpose
              and (newer.granted_at, newer.id) > (c.granted_at, c.id)
         )
    )
  );
create policy sms_ai_learning_proposals_admin_update on public.sms_ai_learning_proposals
  for update to app_user using (pandapay.is_admin()) with check (pandapay.is_admin());
create policy sms_ai_learning_proposals_owner_delete on public.sms_ai_learning_proposals
  for delete to app_user using (profile_id = pandapay.uid() or pandapay.is_admin());

do $worker_access$
begin
  if exists (select 1 from pg_roles where rolname = 'sms_learning_worker') then
    grant select on public.sms_ai_learning_proposals to sms_learning_worker;
    create policy sms_ai_learning_proposals_worker_read
      on public.sms_ai_learning_proposals for select to sms_learning_worker
      using (status = 'approved');
  end if;
end
$worker_access$;

comment on table public.sms_ai_learning_proposals is
  'AI-only auto resolutions awaiting admin review. Pattern and fields are generalized; these rows never vote or reach devices directly.';

-- Withdrawal removes all AI-origin examples in the same transaction even if
-- consent is written outside the API route. Worker queries only retained rows.
create or replace function pandapay.sms_purge_ai_proposals_on_opt_out()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $function$
begin
  if new.purpose = 'sms_shared_learning' and new.granted = false then
    delete from public.sms_ai_learning_proposals where profile_id = new.profile_id;
  end if;
  return new;
end;
$function$;
drop trigger if exists sms_purge_ai_proposals_on_opt_out on public.user_consents;
create trigger sms_purge_ai_proposals_on_opt_out
after insert on public.user_consents
for each row execute function pandapay.sms_purge_ai_proposals_on_opt_out();

-- An admin-approved AI decision may contribute one category vote for its
-- source user. AI-only decisions that are merely auto-resolved or pending
-- admin review never count. A later explicit user correction supersedes it.
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
         order by c.granted_at desc, c.id desc limit 1
      ) current_consent on current_consent.granted = true
     where e.action = 'category_changed'
    union all
    select p.profile_id,
           upper(regexp_replace(btrim(p.proposed_fields->>'merchant'), '\s+', ' ', 'g')),
           p.proposed_fields->>'categorySlug', p.reviewed_at, p.event_id,
           0 as source_priority
      from public.sms_ai_learning_proposals p
      join lateral (
        select c.granted, c.policy_version from public.user_consents c
         where c.profile_id = p.profile_id and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.id desc limit 1
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
         'groceries', 'dining', 'online', 'fuel', 'travel', 'bills', 'health',
         'entertainment', 'rent', 'investments', 'emi', 'insurance',
         'education', 'income', 'wallet', 'cash'
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

commit;
