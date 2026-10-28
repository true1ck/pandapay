-- One typed, idempotent, consent-gated correction envelope.
--
-- The original event table recorded an action and a bag of fields, which made
-- "wrong category", "do not track", "already paid" and "the app filed this at
-- the wrong amount" indistinguishable, and let one user accumulate several
-- current votes for the same message. This migration adds the missing typed
-- reason, the decision provenance, per-fact identity, and a single current
-- correction per profile/fact. Audit rows are kept: an older correction is
-- marked superseded rather than deleted.

begin;

alter table public.sms_learning_feedback_events
  add column if not exists correction_kind text,
  add column if not exists decision_origin text,
  add column if not exists decision_rule_id text,
  add column if not exists fact_key text,
  add column if not exists message_at timestamptz,
  add column if not exists commitment_category text,
  add column if not exists superseded_at timestamptz,
  add column if not exists superseded_by_event_id uuid;

-- Spend categories and commitment categories are different taxonomies.
-- category_slug stays a canonical spend slug; a bill's commitment category is
-- recorded separately so "subscription" can never enter the spend aggregate.
alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_commitment_category_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_commitment_category_check
  check (commitment_category is null or commitment_category in (
    'utility', 'telecom', 'insurance', 'loanOrEmi', 'rent',
    'education', 'tax', 'subscription', 'other'
  ));

alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_correction_kind_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_correction_kind_check
  check (correction_kind is null or correction_kind in (
    -- The user says the machine decision was wrong in a specific way.
    'misclassified_category', 'misclassified_kind', 'wrong_amount',
    'wrong_merchant', 'wrong_date', 'wrong_direction', 'wrong_instrument',
    'wrong_account', 'wrong_bill_fields',
    -- The machine invented or suppressed a financial event.
    'false_transaction', 'false_dismissal',
    -- The event is real but this instance should not be counted twice.
    'duplicate', 'already_paid',
    -- No claim about correctness: presentation only, or the user simply does
    -- not want tracking. These never train a shared classification rule.
    'cosmetic', 'preference_only'
  ));

alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_decision_origin_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_decision_origin_check
  check (decision_origin is null or decision_origin in (
    'parser', 'downloaded_rule', 'shared_rule', 'ai', 'manual'
  ));

-- fact_key is the source identity plus the index of the fact inside that
-- message, so correcting one amount does not invalidate a second correct fact
-- parsed from the same SMS.
alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_fact_key_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_fact_key_check
  check (fact_key is null or fact_key ~ '^[0-9a-f]{64}:([0-9]|[12][0-9]|3[01])$');

alter table public.sms_learning_feedback_events
  drop constraint if exists sms_learning_feedback_events_rule_id_check;
alter table public.sms_learning_feedback_events
  add constraint sms_learning_feedback_events_rule_id_check
  check (decision_rule_id is null or decision_rule_id ~ '^[A-Za-z0-9:._-]{1,120}$');

-- Legacy rows predate per-fact identity and keep fact_key null, which PostgreSQL
-- treats as distinct, so the partial unique index only constrains new rows.
create unique index if not exists uq_sms_learning_feedback_current
  on public.sms_learning_feedback_events (profile_id, fact_key)
  where superseded_at is null and fact_key is not null;

create index if not exists idx_sms_learning_feedback_source_current
  on public.sms_learning_feedback_events (profile_id, source_key_hash)
  where superseded_at is null;

comment on column public.sms_learning_feedback_events.correction_kind is
  'Typed reason for the correction. preference_only and cosmetic never train a shared rule.';
comment on column public.sms_learning_feedback_events.decision_rule_id is
  'Identifier of the downloaded or shared rule that produced the corrected decision, when known. Never a regex or message text.';
comment on column public.sms_learning_feedback_events.superseded_at is
  'Set when a newer correction from the same profile for the same fact replaces this one. Rows are retained as audit history.';

-- The caller may only demote their own rows: there is no UPDATE grant on the
-- table for app_user and this function is scoped by pandapay.uid().
create or replace function pandapay.sms_supersede_corrections(
  p_source_key_hash text, p_fact_key text, p_event_id uuid
) returns integer
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $$
declare v_count integer;
begin
  if pandapay.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_fact_key is null or p_fact_key !~ '^[0-9a-f]{64}:([0-9]|[12][0-9]|3[01])$' then
    raise exception 'invalid fact key';
  end if;
  update public.sms_learning_feedback_events
     set superseded_at = now(), superseded_by_event_id = p_event_id
   where profile_id = pandapay.uid()
     and source_key_hash = p_source_key_hash
     and fact_key = p_fact_key
     and superseded_at is null
     and event_id <> p_event_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function pandapay.sms_supersede_corrections(text, text, uuid) from public;
grant execute on function pandapay.sms_supersede_corrections(text, text, uuid) to app_user;

-- Re-create the category aggregate so it reads one current, typed correction
-- per user and so a category corrected during a manual review save counts even
-- though that save is recorded as 'edited'. preference_only, cosmetic,
-- duplicate and already_paid never vote.
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
  -- Consent is resolved per profile with a deterministic fail-closed
  -- tie-break: user_consents.id is a random UUID, so two consent rows written
  -- in the same transaction share granted_at and the revocation must win.
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
