begin;

-- L13: explicit user feedback outranks an AI-only proposal for the same SMS.
-- A superseded proposal is inert but retained, so the admin audit trail still
-- shows what the AI proposed and why it stopped counting.
alter table public.sms_ai_learning_proposals
  add column if not exists superseded_at timestamptz,
  add column if not exists superseded_reason text,
  add column if not exists superseded_by_event_id uuid;

do $status_check$
declare
  v_name text;
begin
  select conname into v_name
    from pg_constraint
   where conrelid = 'public.sms_ai_learning_proposals'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%status%';
  if v_name is not null then
    execute format('alter table public.sms_ai_learning_proposals drop constraint %I', v_name);
  end if;
  alter table public.sms_ai_learning_proposals
    add constraint sms_ai_learning_proposals_status_check
    check (status in ('pending', 'approved', 'rejected', 'superseded'));
end
$status_check$;

create index if not exists idx_sms_ai_learning_proposals_source
  on public.sms_ai_learning_proposals (profile_id, source_key_hash)
  where status in ('pending', 'approved');

create index if not exists idx_sms_learning_feedback_events_source
  on public.sms_learning_feedback_events (profile_id, source_key_hash);

-- The feedback route owns the calling role (app_user), which the admin-only
-- update policy deliberately excludes. SECURITY DEFINER mirrors the existing
-- sms_delete_learning_examples_for_user / sms_purge_ai_proposals_on_opt_out
-- erasure helpers so an owner can only ever demote their own proposals.
create or replace function pandapay.sms_supersede_ai_proposals(
  p_source_key_hash text, p_event_id uuid default null
)
returns integer
language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $function$
declare
  v_profile uuid := pandapay.uid();
  v_rows integer;
begin
  if v_profile is null or p_source_key_hash is null then
    return 0;
  end if;
  update public.sms_ai_learning_proposals
     set status = 'superseded',
         superseded_at = now(),
         superseded_reason = 'explicit_user_feedback',
         superseded_by_event_id = p_event_id
   where profile_id = v_profile
     and source_key_hash = p_source_key_hash
     and status in ('pending', 'approved');
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$function$;

revoke all on function pandapay.sms_supersede_ai_proposals(text, uuid) from public;
grant execute on function pandapay.sms_supersede_ai_proposals(text, uuid) to app_user;

comment on function pandapay.sms_supersede_ai_proposals(text, uuid) is
  'Demotes the caller''s pending/approved AI-only proposals for one SMS source. Explicit user feedback is the stronger label; the row is kept for audit.';

-- A delayed or retried ai_auto_resolved upload must not resurrect evidence the
-- user already corrected. Dropping the row silently keeps the device outbox
-- from retrying a proposal that can never become eligible.
create or replace function pandapay.sms_block_superseded_ai_proposal()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, pandapay
as $function$
begin
  if exists (
    select 1 from public.sms_learning_feedback_events e
     where e.profile_id = new.profile_id
       and e.source_key_hash = new.source_key_hash
  ) then
    return null;
  end if;
  return new;
end;
$function$;

drop trigger if exists sms_block_superseded_ai_proposal on public.sms_ai_learning_proposals;
create trigger sms_block_superseded_ai_proposal
  before insert on public.sms_ai_learning_proposals
  for each row execute function pandapay.sms_block_superseded_ai_proposal();

-- Rows written before this migration: an already-accepted explicit event for
-- the same source demotes the AI proposal now, so no stale row keeps voting.
update public.sms_ai_learning_proposals p
   set status = 'superseded',
       superseded_at = now(),
       superseded_reason = 'explicit_user_feedback_backfill'
  where p.status in ('pending', 'approved')
    and exists (
      select 1 from public.sms_learning_feedback_events e
       where e.profile_id = p.profile_id
         and e.source_key_hash = p.source_key_hash
    );

comment on column public.sms_ai_learning_proposals.status is
  'pending/approved/rejected are admin review states; superseded means explicit user feedback for the same source_key_hash outranks this AI-only evidence and it can no longer vote or be approved.';

commit;
