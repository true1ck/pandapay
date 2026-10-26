-- Durable push delivery references an inbox row and a bounded immutable
-- content revision snapshot, so later dedupe updates cannot rewrite intent.
-- Both capabilities are explicit opt-in at runtime and separate from app_user.
do $$ begin
  if not exists(select 1 from pg_roles where rolname='notification_outbox_owner') then
    create role notification_outbox_owner nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
  end if;
  if not exists(select 1 from pg_roles where rolname='notification_worker') then
    create role notification_worker nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
  end if;
  if exists(select 1 from pg_roles where rolname in ('notification_outbox_owner','notification_worker') and
      (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
    raise exception 'unsafe notification delivery role';
  end if;
end $$;
create schema if not exists notification_delivery;
revoke all on schema notification_delivery from public;
grant usage,create on schema notification_delivery to notification_outbox_owner;
grant usage on schema notification_delivery, public to app_user, notification_worker, notification_outbox_owner;
grant usage on schema pandapay to notification_outbox_owner;
grant execute on function pandapay.uid() to notification_outbox_owner;

-- The existing API and category_transactions preference already expose this
-- category; the earlier preference-only migration omitted its inbox CHECK.
-- Retain every previously accepted category and widen without rewriting rows.
alter table public.notifications drop constraint if exists notifications_category_check;
alter table public.notifications add constraint notifications_category_check check (
  category in ('location','caps','milestones','fee_waivers','bills','expiry',
    'monthly_report','needs_review','streak','card_added','budget_warning',
    'budget_exceeded','transactions')
);

alter table public.notifications add column if not exists delivery_version uuid default gen_random_uuid();
update public.notifications set delivery_version=gen_random_uuid() where delivery_version is null;
alter table public.notifications alter column delivery_version set not null;
grant select(id,profile_id,delivery_version,category,severity,title,body,deep_link) on public.notifications to notification_outbox_owner;
grant select(id,deletion_requested_at) on public.profiles to notification_outbox_owner;
grant references(id) on public.notifications, public.profiles to notification_outbox_owner;
grant select(profile_id,category_location,category_caps,category_milestones,category_fee_waivers,category_bills,category_expiry,category_monthly_report,category_needs_review,category_transactions,category_budget_warning,category_budget_exceeded)
  on public.notification_preferences to notification_outbox_owner;
drop policy if exists notification_outbox_read_inbox on public.notifications;
create policy notification_outbox_read_inbox on public.notifications for select to notification_outbox_owner using(true);
drop policy if exists notification_outbox_read_profile on public.profiles;
create policy notification_outbox_read_profile on public.profiles for select to notification_outbox_owner using(true);
drop policy if exists notification_outbox_read_preferences on public.notification_preferences;
create policy notification_outbox_read_preferences on public.notification_preferences for select to notification_outbox_owner using(true);
set role notification_outbox_owner;
create or replace function notification_delivery.bump_version()
returns trigger language plpgsql set search_path=''
as $$ begin
  if tg_op='INSERT' or (new.category,new.severity,new.title,new.body,new.deep_link) is distinct from
       (old.category,old.severity,old.title,old.body,old.deep_link) then
    new.delivery_version:=pg_catalog.gen_random_uuid();
  end if;
  return new;
end $$;
reset role;
drop trigger if exists notification_delivery_version on public.notifications;
create trigger notification_delivery_version before insert or update on public.notifications
  for each row execute function notification_delivery.bump_version();
set role notification_outbox_owner;

create table if not exists notification_delivery.revisions(
  id uuid primary key default gen_random_uuid(), notification_id uuid not null references public.notifications(id) on delete cascade,
  delivery_version uuid not null unique, profile_id uuid not null references public.profiles(id) on delete cascade,
  category text not null, severity text not null, title text not null, body text, deep_link text,
  created_at timestamptz not null default pg_catalog.now(), unique(notification_id,delivery_version)
);
alter table notification_delivery.revisions enable row level security;
alter table notification_delivery.revisions force row level security;
drop policy if exists notification_revisions_owner_all on notification_delivery.revisions;
create policy notification_revisions_owner_all on notification_delivery.revisions for all to notification_outbox_owner using(true) with check(true);
grant select,insert,delete on notification_delivery.revisions to notification_outbox_owner;
create table if not exists notification_delivery.outbox(
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  revision_id uuid not null unique references notification_delivery.revisions(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  state text not null default 'pending' check(state in ('pending','leased','delivered','dead','suppressed')),
  attempts integer not null default 0 check(attempts between 0 and 8),
  available_at timestamptz not null default pg_catalog.now(),
  lease_until timestamptz, lease_token uuid, lease_owner text,
  last_error_code text check(last_error_code is null or last_error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
  completed_at timestamptz, terminal_expires_at timestamptz, created_at timestamptz not null default pg_catalog.now(),
  check((state='leased')=(lease_until is not null and lease_token is not null and lease_owner is not null)),
  check((state in ('delivered','dead','suppressed'))=(completed_at is not null))
);
create index if not exists notification_outbox_ready on notification_delivery.outbox(available_at,created_at,id) where state in ('pending','leased');
alter table notification_delivery.outbox enable row level security;
alter table notification_delivery.outbox force row level security;
drop policy if exists notification_outbox_owner_all on notification_delivery.outbox;
create policy notification_outbox_owner_all on notification_delivery.outbox for all to notification_outbox_owner using(true) with check(true);
grant select,insert,update,delete on notification_delivery.outbox to notification_outbox_owner;

create table if not exists notification_delivery.profile_queue_counts(profile_id uuid primary key,pending integer not null check(pending between 0 and 500));
create table if not exists notification_delivery.global_queue_count(singleton boolean primary key default true check(singleton),pending integer not null check(pending between 0 and 10000),retained integer not null default 0 check(retained between 0 and 10000));
insert into notification_delivery.global_queue_count(singleton,pending) values(true,0) on conflict(singleton) do nothing;
alter table notification_delivery.profile_queue_counts enable row level security;
alter table notification_delivery.profile_queue_counts force row level security;
drop policy if exists notification_counts_owner on notification_delivery.profile_queue_counts;
create policy notification_counts_owner on notification_delivery.profile_queue_counts for all to notification_outbox_owner using(true) with check(true);
alter table notification_delivery.global_queue_count enable row level security;
alter table notification_delivery.global_queue_count force row level security;
drop policy if exists notification_global_count_owner on notification_delivery.global_queue_count;
create policy notification_global_count_owner on notification_delivery.global_queue_count for all to notification_outbox_owner using(true) with check(true);
grant select,insert,update,delete on notification_delivery.profile_queue_counts,notification_delivery.global_queue_count to notification_outbox_owner;
create or replace function notification_delivery.track_queue_count()
returns trigger language plpgsql security definer set search_path=''
as $$ declare old_active boolean:=false; new_active boolean:=false; begin
  if tg_op<>'INSERT' then old_active:=old.state in ('pending','leased'); end if;
  if tg_op<>'DELETE' then new_active:=new.state in ('pending','leased'); end if;
  if tg_op='INSERT' then
    update notification_delivery.global_queue_count set retained=retained+1 where singleton and retained<10000;
    if not found then raise exception 'notification_retained_storage_full' using errcode='54000'; end if;
  elsif tg_op='DELETE' then
    update notification_delivery.global_queue_count set retained=retained-1 where singleton and retained>0;
  end if;
  if not old_active and new_active then
    insert into notification_delivery.profile_queue_counts(profile_id,pending) values(new.profile_id,1)
      on conflict(profile_id) do update set pending=notification_delivery.profile_queue_counts.pending+1
      where notification_delivery.profile_queue_counts.pending<500;
    if not found then raise exception 'notification_profile_queue_full' using errcode='54000'; end if;
    update notification_delivery.global_queue_count set pending=pending+1 where singleton and pending<10000;
    if not found then raise exception 'notification_global_queue_full' using errcode='54000'; end if;
  elsif old_active and not new_active then
    update notification_delivery.profile_queue_counts set pending=pending-1 where profile_id=old.profile_id and pending>0;
    delete from notification_delivery.profile_queue_counts where profile_id=old.profile_id and pending=0;
    update notification_delivery.global_queue_count set pending=pending-1 where singleton and pending>0;
  elsif old_active and new_active and old.profile_id<>new.profile_id then
    raise exception 'notification_outbox_recipient_immutable' using errcode='23514';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists notification_outbox_track_count on notification_delivery.outbox;
create trigger notification_outbox_track_count after insert or update of state,profile_id or delete on notification_delivery.outbox
  for each row execute function notification_delivery.track_queue_count();
create or replace function notification_delivery.enqueue(p_notification_id uuid)
returns boolean language plpgsql security definer set search_path='' set lock_timeout='500ms' set statement_timeout='5s'
as $$ declare v_profile uuid; v_revision uuid; v_version uuid; begin
  select n.profile_id,n.delivery_version into v_profile,v_version from public.notifications n where n.id=p_notification_id;
  if v_profile is null or v_profile is distinct from pandapay.uid() then raise exception 'notification_enqueue_denied' using errcode='42501'; end if;
  insert into notification_delivery.revisions(notification_id,delivery_version,profile_id,category,severity,title,body,deep_link)
    select n.id,n.delivery_version,n.profile_id,n.category,n.severity,n.title,n.body,n.deep_link
      from public.notifications n where n.id=p_notification_id
      and n.category in ('location','caps','milestones','fee_waivers','bills','expiry','monthly_report','needs_review','transactions','budget_warning','budget_exceeded','streak','card_added')
      and n.severity in ('info','good','urgent') and pg_catalog.octet_length(n.title) between 1 and 512
      and coalesce(pg_catalog.octet_length(n.body),0)<=4096 and coalesce(pg_catalog.octet_length(n.deep_link),0)<=1024
    on conflict(delivery_version) do nothing returning id into v_revision;
  if v_revision is null then select id into v_revision from notification_delivery.revisions where delivery_version=v_version; end if;
  if v_revision is null then raise exception 'notification_payload_invalid' using errcode='22023'; end if;
  insert into notification_delivery.outbox(notification_id,revision_id,profile_id)
    values(p_notification_id,v_revision,v_profile) on conflict(revision_id) do nothing;
  return true;
end $$;

create or replace function notification_delivery.claim(p_worker_id text,p_limit integer default 1,p_lease_seconds integer default 90)
returns table(id uuid,notification_id uuid,revision_id uuid,profile_id uuid,category text,severity text,title text,body text,deep_link text,lease_token uuid,attempts integer)
language plpgsql security definer set search_path='' set statement_timeout='10s'
as $$ declare v_now timestamptz:=pg_catalog.clock_timestamp(); begin
  if p_worker_id is null or p_worker_id !~ '^[A-Za-z0-9._:-]{1,120}$'
     or p_limit is null or p_limit not between 1 and 10
     or p_lease_seconds is null or p_lease_seconds not between 60 and 900 then
    raise exception 'invalid_notification_claim' using errcode='22023'; end if;
  delete from notification_delivery.outbox o where o.id in (select x.id from notification_delivery.outbox x
    where x.terminal_expires_at<=v_now order by x.terminal_expires_at,x.id for update skip locked limit 250);
  delete from notification_delivery.revisions r0 where r0.id in (select r.id from notification_delivery.revisions r
    where r.created_at<=v_now-interval '180 days' and not exists(select 1 from notification_delivery.outbox o where o.revision_id=r.id)
    order by r.created_at,r.id for update skip locked limit 250);
  with suppressed as materialized(select o.id from notification_delivery.outbox o
    left join notification_delivery.revisions n on n.id=o.revision_id
    left join public.notification_preferences pref on pref.profile_id=n.profile_id
    where o.state in ('pending','leased') and (o.lease_until is null or o.lease_until<=v_now)
     and (not exists(select 1 from public.profiles p where p.id=o.profile_id and p.deletion_requested_at is null)
       or (pref.profile_id is not null and case n.category
         when 'location' then not pref.category_location when 'caps' then not pref.category_caps
         when 'milestones' then not pref.category_milestones when 'fee_waivers' then not pref.category_fee_waivers
         when 'bills' then not pref.category_bills when 'expiry' then not pref.category_expiry
         when 'monthly_report' then not pref.category_monthly_report when 'needs_review' then not pref.category_needs_review
         when 'transactions' then not pref.category_transactions when 'budget_warning' then not pref.category_budget_warning
         when 'budget_exceeded' then not pref.category_budget_exceeded
         else false end))
    order by o.available_at,o.created_at,o.id for update of o skip locked limit 250)
    update notification_delivery.outbox o set state='suppressed',completed_at=v_now,terminal_expires_at=v_now+interval '180 days',
      lease_until=null,lease_token=null,lease_owner=null,last_error_code='preference_or_account_disabled'
     from suppressed s where o.id=s.id;
  with dead as materialized(select o.id from notification_delivery.outbox o where o.state in ('pending','leased')
    and (o.lease_until is null or o.lease_until<=v_now) and o.attempts>=8 order by o.available_at,o.created_at,o.id
    for update skip locked limit 250)
  update notification_delivery.outbox o set state='dead',completed_at=v_now,terminal_expires_at=v_now+interval '180 days',last_error_code='attempt_limit',lease_until=null,lease_token=null,lease_owner=null
   from dead d where o.id=d.id;
  return query with candidates as materialized(
    select o.id from notification_delivery.outbox o join notification_delivery.revisions n on n.id=o.revision_id
     join public.profiles p on p.id=o.profile_id and p.deletion_requested_at is null
     left join public.notification_preferences pref on pref.profile_id=o.profile_id
     where ((o.state='pending' and o.available_at<=v_now) or (o.state='leased' and o.lease_until<=v_now)) and o.attempts<8
       and (pref.profile_id is null or case n.category
         when 'location' then pref.category_location when 'caps' then pref.category_caps
         when 'milestones' then pref.category_milestones when 'fee_waivers' then pref.category_fee_waivers
         when 'bills' then pref.category_bills when 'expiry' then pref.category_expiry
         when 'monthly_report' then pref.category_monthly_report when 'needs_review' then pref.category_needs_review
         when 'transactions' then pref.category_transactions when 'budget_warning' then pref.category_budget_warning
         when 'budget_exceeded' then pref.category_budget_exceeded
         else true end)
     order by o.available_at,o.created_at,o.id for update of o skip locked limit p_limit
  ), claimed as(update notification_delivery.outbox o set state='leased',attempts=o.attempts+1,lease_until=v_now+pg_catalog.make_interval(secs=>p_lease_seconds),lease_token=pg_catalog.gen_random_uuid(),lease_owner=p_worker_id,last_error_code=null from candidates c where o.id=c.id returning o.*)
   select c.id,c.notification_id,c.revision_id,c.profile_id,n.category,n.severity,n.title,n.body,n.deep_link,c.lease_token,c.attempts
   from claimed c join notification_delivery.revisions n on n.id=c.revision_id;
end $$;

create or replace function notification_delivery.allowed(p_id uuid,p_token uuid)
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from notification_delivery.outbox o
  join notification_delivery.revisions r on r.id=o.revision_id
  join public.profiles p on p.id=o.profile_id and p.deletion_requested_at is null
  left join public.notification_preferences pref on pref.profile_id=o.profile_id
 where o.id=p_id and o.state='leased' and o.lease_token=p_token and o.lease_until>pg_catalog.clock_timestamp()
   and (pref.profile_id is null or case r.category
     when 'location' then pref.category_location when 'caps' then pref.category_caps
     when 'milestones' then pref.category_milestones when 'fee_waivers' then pref.category_fee_waivers
     when 'bills' then pref.category_bills when 'expiry' then pref.category_expiry
     when 'monthly_report' then pref.category_monthly_report when 'needs_review' then pref.category_needs_review
         when 'transactions' then pref.category_transactions when 'budget_warning' then pref.category_budget_warning
         when 'budget_exceeded' then pref.category_budget_exceeded
     else true end)) $$;

create or replace function notification_delivery.finish(p_id uuid,p_token uuid,p_success boolean,p_error text default null,p_permanent boolean default false)
returns jsonb language plpgsql security definer set search_path=''
as $$ declare r notification_delivery.outbox%rowtype; e text; wait_s integer; t timestamptz:=pg_catalog.clock_timestamp(); begin
  if p_id is null or p_token is null or p_success is null or p_permanent is null then raise exception 'invalid_notification_finalization' using errcode='22023'; end if;
  select * into r from notification_delivery.outbox where id=p_id and state='leased' and lease_token=p_token and lease_until>t for update;
  if not found then return jsonb_build_object('accepted',false,'state','lease_lost'); end if;
  if p_success then update notification_delivery.outbox set state='delivered',completed_at=t,terminal_expires_at=t+interval '180 days',lease_until=null,lease_token=null,lease_owner=null where id=p_id;
    return jsonb_build_object('accepted',true,'state','delivered'); end if;
  e:=case when p_error ~ '^[a-z][a-z0-9_]{0,63}$' then p_error else 'notification_error' end;
  if p_permanent or r.attempts>=8 then update notification_delivery.outbox set state='dead',completed_at=t,terminal_expires_at=t+interval '180 days',lease_until=null,lease_token=null,lease_owner=null,last_error_code=e where id=p_id;
    return jsonb_build_object('accepted',true,'state','dead'); end if;
  wait_s:=least(30*(2^greatest(r.attempts-1,0)),3600);
  update notification_delivery.outbox set state='pending',available_at=t+pg_catalog.make_interval(secs=>wait_s),lease_until=null,lease_token=null,lease_owner=null,last_error_code=e where id=p_id;
  return jsonb_build_object('accepted',true,'state','pending','retryAfterSeconds',wait_s);
end $$;
reset role;

set role notification_outbox_owner;
revoke all on notification_delivery.outbox from public,app_user,notification_worker;
revoke all on notification_delivery.revisions,notification_delivery.profile_queue_counts,notification_delivery.global_queue_count from public,app_user,notification_worker;
revoke all on function notification_delivery.bump_version() from public;
revoke all on function notification_delivery.track_queue_count() from public;
revoke all on function notification_delivery.enqueue(uuid) from public;
revoke all on function notification_delivery.claim(text,integer,integer) from public,app_user;
revoke all on function notification_delivery.finish(uuid,uuid,boolean,text,boolean) from public,app_user;
revoke all on function notification_delivery.allowed(uuid,uuid) from public,app_user;
grant execute on function notification_delivery.enqueue(uuid) to app_user;
grant execute on function notification_delivery.claim(text,integer,integer) to notification_worker;
grant execute on function notification_delivery.finish(uuid,uuid,boolean,text,boolean) to notification_worker;
grant execute on function notification_delivery.allowed(uuid,uuid) to notification_worker;
comment on table notification_delivery.revisions is 'Bounded immutable customer-visible content revision snapshots for queued push intent.';
comment on table notification_delivery.outbox is 'Private push queue referencing an immutable revision snapshot; provider response loss may repeat delivery without provider idempotency.';
reset role;
