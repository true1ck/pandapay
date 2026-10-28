-- C9: shared/downloaded rules survive on one user's word, but they must not
-- survive a pattern of user corrections. A correction whose decision points at
-- a shared rule (decision_origin = 'shared_rule' or a decision_rule_id naming
-- the published rule) is negative evidence for that exact rule id.
--
-- The evidence itself is already recorded: sms_learning_feedback_events stores
-- decision_rule_id on every explicit correction and sms_supersede_corrections
-- keeps one current state per fact. What was missing is the per-rule rollup and
-- a pause status the rule-serving path can check. A pause is a serving decision,
-- never a data change: corrections and their audit history stay untouched, so a
-- user who corrected the rule keeps their local override.

begin;

-- Operator-tunable thresholds for shared-learning safety valves. app_user has
-- no grants here; the values are read only through SECURITY DEFINER functions.
create table if not exists public.sms_learning_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

revoke all on public.sms_learning_settings from public, app_user;
-- setup_app_role grants broad table privileges to app_user, so forced RLS with
-- no policies is what actually keeps the serving role from reading or tuning
-- the threshold; only the SECURITY DEFINER helpers (and the service role) do.
alter table public.sms_learning_settings enable row level security;
alter table public.sms_learning_settings force row level security;

insert into public.sms_learning_settings (key, value)
values ('sms_shared_rule_negative_pause_threshold', '3'::jsonb)
on conflict (key) do nothing;

comment on table public.sms_learning_settings is
  'Operator-tunable shared-learning thresholds. Editable only by the service role; read through pandapay helper functions.';

-- jsonb -> integer extraction tolerates a number or string written by an
-- operator; an unparseable or out-of-range value falls back to the shipped
-- default of 3 rather than breaking the serving path.
create or replace function pandapay.sms_shared_rule_pause_threshold()
returns integer
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
declare
  v_raw text;
begin
  select case when jsonb_typeof(value) in ('number', 'string')
              then value #>> '{}' end
    into v_raw
    from public.sms_learning_settings
   where key = 'sms_shared_rule_negative_pause_threshold';
  begin
    return coalesce(v_raw::integer, 3);
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      return 3;
  end;
end;
$function$;

revoke all on function pandapay.sms_shared_rule_pause_threshold() from public;
grant execute on function pandapay.sms_shared_rule_pause_threshold() to app_user;

-- Per-rule negative-evidence rollup the admin API can expose. Only current
-- (non-superseded) explicit corrections count; superseded rows are audit
-- history. Cosmetic and preference_only edits make no claim about correctness
-- (the same two kinds that never train a shared rule), and an untyped
-- correction counts only when the corrected category actually differs from the
-- original one, so a user confirming or retracting back to the rule's decision
-- withdraws their evidence instead of adding to it. One correction is one data
-- point, never proof of a global defect: the pause gate additionally counts
-- distinct reporting profiles, so a single user editing many facts of one
-- message cannot pause a rule alone.
create or replace function pandapay.sms_rule_negative_evidence()
returns table (
  decision_rule_id text,
  negative_evidence_count integer,
  distinct_reporting_profiles integer,
  paused boolean
)
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  select e.decision_rule_id,
         count(*)::integer,
         count(distinct e.profile_id)::integer,
         count(distinct e.profile_id) >= pandapay.sms_shared_rule_pause_threshold()
    from public.sms_learning_feedback_events e
   where e.decision_rule_id is not null
     and e.superseded_at is null
     and coalesce(e.correction_kind, 'misclassified_category') not in
         ('cosmetic', 'preference_only')
     and (e.correction_kind is not null
          or e.category_slug is distinct from e.original_category_slug)
   group by e.decision_rule_id;
$function$;

revoke all on function pandapay.sms_rule_negative_evidence() from public;
grant execute on function pandapay.sms_rule_negative_evidence() to app_user;

-- Single-rule check for the rule-serving path (GET /sms/rules/active) and for
-- any worker that stages a rule for delivery.
create or replace function pandapay.sms_shared_rule_paused(p_rule_id text)
returns boolean
language sql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
  select exists (
    select 1
      from public.sms_learning_feedback_events e
     where e.decision_rule_id = p_rule_id
       and e.superseded_at is null
       and coalesce(e.correction_kind, 'misclassified_category') not in
           ('cosmetic', 'preference_only')
       and (e.correction_kind is not null
            or e.category_slug is distinct from e.original_category_slug)
     group by e.decision_rule_id
    having count(distinct e.profile_id) >= pandapay.sms_shared_rule_pause_threshold()
  );
$function$;

revoke all on function pandapay.sms_shared_rule_paused(text) from public;
grant execute on function pandapay.sms_shared_rule_paused(text) to app_user;

comment on function pandapay.sms_rule_negative_evidence() is
  'Current explicit corrections per shared-rule id with the pause verdict. A rule pauses when distinct reporting profiles reach sms_shared_rule_pause_threshold; pausing withholds the rule from NEW users only and never modifies correction data.';

comment on function pandapay.sms_shared_rule_paused(text) is
  'True when the named rule accumulated negative evidence from at least the pause threshold of distinct profiles. Serving paths check this before delivering the rule to users without a prior assignment.';

commit;
