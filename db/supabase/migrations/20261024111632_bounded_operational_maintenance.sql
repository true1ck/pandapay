-- Fixed, bounded replacement jobs. All controls start disabled. Raw mail
-- retention requires an explicit >=30 day policy; no account/financial rows
-- or mail metadata are deleted. Existing cron is changed only by a reviewed
-- fenced activation, after the bounded replacement has passed acceptance.
do $$ declare r text; prior jsonb; begin
 foreach r in array array['maintenance_owner','pandapay_maintenance','pandapay_maintenance_reader','pandapay_auth_retention_coordinator'] loop
  if not exists(select 1 from pg_catalog.pg_roles where rolname=r) then
   execute pg_catalog.format('create role %I nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls',r);
  elsif exists(select 1 from pg_catalog.pg_roles where rolname=r and
   (rolcanlogin or rolsuper or rolcreatedb or rolcreaterole or rolinherit or rolreplication or rolbypassrls)) then
   raise exception 'Unsafe existing maintenance role';
  end if;
  if exists(select 1 from pg_catalog.pg_auth_members where member=r::regrole) then
   raise exception 'Maintenance capabilities cannot inherit other roles';
  end if;
 end loop;
 select pg_catalog.jsonb_build_object('inherit',m.inherit_option,'set',m.set_option) into prior
  from pg_catalog.pg_auth_members m where m.roleid='maintenance_owner'::regrole
  and m.member=current_user::regrole and m.grantor=current_user::regrole;
 perform pg_catalog.set_config('pandapay.maintenance_prior_grant',coalesce(prior::text,'null'),true);
 perform pg_catalog.set_config('pandapay.maintenance_migration_role',current_user,true);
 execute pg_catalog.format('grant maintenance_owner to %I with inherit false granted by %I',current_user,current_user);
 execute pg_catalog.format('grant maintenance_owner to %I with set true granted by %I',current_user,current_user);
end $$;
create schema maintenance;
revoke all on schema maintenance from public;
grant usage,create on schema maintenance to maintenance_owner;
grant usage on schema public to maintenance_owner;
grant usage on schema maintenance to pandapay_maintenance,pandapay_maintenance_reader,pandapay_auth_retention_coordinator;

grant select(id,operator_locked) on public.merchants to maintenance_owner;
grant update(distinct_device_count,confirmation_count,confidence_score,confidence,is_published,last_confirmed_on,updated_at)
 on public.merchants to maintenance_owner;
grant select(merchant_id,device_hash,is_counted,submitted_on) on public.merchant_contributions to maintenance_owner;
create policy maintenance_merchant_read on public.merchants for select to maintenance_owner using(true);
create policy maintenance_merchant_write on public.merchants for update to maintenance_owner using(true) with check(true);
create policy maintenance_contribution_read on public.merchant_contributions for select to maintenance_owner using(true);
grant select(id,purge_after,received_at,policy_keyword_hit,body_text),update(body_text)
 on public.inbound_emails to maintenance_owner;
create policy maintenance_mail_read on public.inbound_emails for select to maintenance_owner
 using(not policy_keyword_hit);
create policy maintenance_mail_scrub on public.inbound_emails for update to maintenance_owner
 using(not policy_keyword_hit) with check(not policy_keyword_hit);
grant select(card_product_id,category_id,period_month,distinct_devices,published_rate,divergence_pct,observed_rate_p50,alert_raised_at),
 update(alert_raised_at,is_divergent) on public.effective_rate_summary to maintenance_owner;
create policy maintenance_summary_read on public.effective_rate_summary for select to maintenance_owner using(true);
create policy maintenance_summary_write on public.effective_rate_summary for update to maintenance_owner using(true) with check(true);
grant select(id,card_product_id,field_path,state),insert(card_product_id,field_path,field_label,current_value,proposed_value,signal_count,distinct_signal_kinds,corroboration_score),
 update(signal_count,corroboration_score,last_signal_at) on public.policy_change_alerts to maintenance_owner;
-- UPDATE expressions need these existing values, never decision/operator data.
grant select(signal_count,corroboration_score) on public.policy_change_alerts to maintenance_owner;
grant insert(alert_id,signal,rate_summary_key,excerpt,weight) on public.policy_alert_evidence to maintenance_owner;
create policy maintenance_alert_read on public.policy_change_alerts for select to maintenance_owner using(true);
create policy maintenance_alert_insert on public.policy_change_alerts for insert to maintenance_owner with check(true);
create policy maintenance_alert_update on public.policy_change_alerts for update to maintenance_owner using(state in ('open','needs_more_evidence')) with check(state in ('open','needs_more_evidence'));
create policy maintenance_evidence_insert on public.policy_alert_evidence for insert to maintenance_owner with check(signal='empirical_divergence');

set local role maintenance_owner;
create table maintenance.jobs(
 job text primary key check(job in ('merchant_confidence','rate_divergence','inbound_body_retention','auth_retention')),
 enabled boolean not null default false,
 interval_seconds integer not null default 86400 check(interval_seconds between 60 and 86400),
 batch_size integer not null default 25 check(batch_size between 1 and 100),
 retention_days integer check(retention_days between 30 and 3650),
 next_run_at timestamptz not null default pg_catalog.now(),
 lease_token uuid,lease_until timestamptz,
 generation bigint not null default 0 check(generation>=0),
 merchant_cursor uuid,
 heartbeat_at timestamptz,last_completed_at timestamptz,
 consecutive_failures integer not null default 0 check(consecutive_failures between 0 and 1000000),
 processed bigint not null default 0 check(processed>=0),
 check((lease_token is null)=(lease_until is null)),
 check(job<>'inbound_body_retention' or not enabled or retention_days is not null)
);
insert into maintenance.jobs(job) values('merchant_confidence'),('rate_divergence'),('inbound_body_retention'),('auth_retention');
create table maintenance.notifications(
 job text not null references maintenance.jobs(job),
 code text not null check(code in ('job_failed','lease_expired','heartbeat_late')),
 generation bigint not null default 1 check(generation>=1),
 occurrences bigint not null default 1 check(occurrences>=1),
 first_seen_at timestamptz not null default pg_catalog.now(),
 last_seen_at timestamptz not null default pg_catalog.now(),
 acknowledged boolean not null default false,
 primary key(job,code)
);
alter table maintenance.jobs enable row level security;
alter table maintenance.jobs force row level security;
alter table maintenance.notifications enable row level security;
alter table maintenance.notifications force row level security;
create policy maintenance_jobs_owner on maintenance.jobs to maintenance_owner using(true) with check(true);
create policy maintenance_notifications_owner on maintenance.notifications to maintenance_owner using(true) with check(true);
revoke all on maintenance.jobs,maintenance.notifications from public;

create function maintenance.notice(p_job text,p_code text) returns void
language sql set search_path='' as $$
 insert into maintenance.notifications(job,code) values(p_job,p_code)
 on conflict(job,code) do update set generation=maintenance.notifications.generation+1,
 occurrences=maintenance.notifications.occurrences+1,last_seen_at=pg_catalog.now(),acknowledged=false
$$;
create function maintenance.claim_internal(p_job text)
returns table(lease_token uuid,generation bigint)
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='1s' as $$
declare j maintenance.jobs%rowtype;t uuid;begin
 select * into j from maintenance.jobs q where q.job=p_job and q.enabled
  and q.next_run_at<=pg_catalog.now() and (q.lease_until is null or q.lease_until<=pg_catalog.now())
  for update skip locked;
 if not found then return;end if;
 if j.lease_token is not null then perform maintenance.notice(p_job,'lease_expired');end if;
 t:=pg_catalog.gen_random_uuid();
 update maintenance.jobs q set lease_token=t,lease_until=pg_catalog.now()+interval '90 seconds',
  generation=q.generation+1,heartbeat_at=pg_catalog.now() where q.job=p_job;
 lease_token:=t;generation:=j.generation+1;return next;
end $$;
create function maintenance.claim_job(p_job text)
returns table(lease_token uuid,generation bigint)
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$ begin
 if p_job not in ('merchant_confidence','rate_divergence','inbound_body_retention') or p_job is null then
  raise exception 'Unsupported product maintenance job' using errcode='22023';end if;
 return query select * from maintenance.claim_internal(p_job);
end $$;
create function maintenance.claim_auth_retention()
returns table(lease_token uuid,generation bigint)
language sql security definer set search_path='' set statement_timeout='5s' as $$
 select * from maintenance.claim_internal('auth_retention')
$$;

create function maintenance.run_batch(p_job text,p_lease uuid)
returns table(processed integer,more boolean)
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='1s' as $$
declare j maintenance.jobs%rowtype;r record;n integer:=0;last_id uuid;v_alert uuid;v_path text;v_devices integer;v_total integer;v_recent integer;v_score numeric;
begin
 select * into j from maintenance.jobs q where q.job=p_job and q.enabled and q.lease_token=p_lease
  and q.lease_until>pg_catalog.now() for update;
 if not found then raise exception 'Maintenance lease unavailable' using errcode='55000';end if;
 if p_job='merchant_confidence' then
  -- A complete UUID rotation catches recency changes and contributions whose
  -- insertion does not update merchants.updated_at. New IDs behind the cursor
  -- are included in the next rotation; no financial/customer rows are read.
  for r in select m.id,m.operator_locked from public.merchants m
   where j.merchant_cursor is null or m.id>j.merchant_cursor order by m.id limit j.batch_size for update loop
   select count(distinct c.device_hash)::integer,count(*)::integer,
    count(distinct c.device_hash) filter(where c.submitted_on>current_date-180)::integer
    into v_devices,v_total,v_recent from public.merchant_contributions c where c.merchant_id=r.id and c.is_counted;
   v_score:=least(1.0,(v_devices*0.6+v_recent*0.4)/5.0);
   update public.merchants m set distinct_device_count=v_devices,confirmation_count=v_total,confidence_score=v_score,
    confidence=(case when r.operator_locked then 'operator_verified' when v_devices>=5 then 'high' when v_devices>=3 then 'medium' when v_devices>=2 then 'low' else 'unverified' end)::public.record_confidence,
    is_published=(v_devices>=2) or r.operator_locked,last_confirmed_on=current_date,updated_at=pg_catalog.now() where m.id=r.id;
   n:=n+1;last_id:=r.id;
  end loop;
 elsif p_job='inbound_body_retention' then
  if j.retention_days is null then raise exception 'Explicit mail retention policy required' using errcode='55000';end if;
  with candidates as(select e.id from public.inbound_emails e where not e.policy_keyword_hit and e.body_text is not null
   and e.purge_after<pg_catalog.now() and e.received_at<pg_catalog.now()-pg_catalog.make_interval(days=>j.retention_days)
   order by e.purge_after,e.id limit j.batch_size for update skip locked), scrubbed as(
   update public.inbound_emails e set body_text=null from candidates c where e.id=c.id and not e.policy_keyword_hit returning 1)
   select count(*)::integer into n from scrubbed;
 elsif p_job='rate_divergence' then
  for r in select s.card_product_id,s.category_id,s.period_month,s.distinct_devices,s.published_rate,s.observed_rate_p50
   from public.effective_rate_summary s where s.distinct_devices>=3 and s.published_rate is not null
   and abs(coalesce(s.divergence_pct,0))>=0.15 and s.alert_raised_at is null
   order by s.card_product_id,s.category_id,s.period_month limit j.batch_size for update skip locked loop
   v_path:='reward_rules.'||coalesce(r.category_id::text,'all')||'.rate';v_alert:=null;
   select a.id into v_alert from public.policy_change_alerts a where a.card_product_id=r.card_product_id and a.field_path=v_path
    and a.state in ('open','needs_more_evidence') order by a.id limit 1 for update;
   if v_alert is null then
    insert into public.policy_change_alerts(card_product_id,field_path,field_label,current_value,proposed_value,signal_count,distinct_signal_kinds,corroboration_score)
     values(r.card_product_id,v_path,'Empirical rate divergence',pg_catalog.to_jsonb(r.published_rate),pg_catalog.to_jsonb(r.observed_rate_p50),1,1,0.35) returning id into v_alert;
   else
    update public.policy_change_alerts a set signal_count=a.signal_count+1,corroboration_score=least(1.0,a.corroboration_score+0.2),last_signal_at=pg_catalog.now() where a.id=v_alert;
   end if;
   insert into public.policy_alert_evidence(alert_id,signal,rate_summary_key,excerpt,weight)
    values(v_alert,'empirical_divergence',pg_catalog.jsonb_build_object('card',r.card_product_id,'category',r.category_id,'month',r.period_month),
     pg_catalog.format('%s devices show %s%% vs published %s%%',r.distinct_devices,r.observed_rate_p50,r.published_rate),0.35);
   update public.effective_rate_summary s set alert_raised_at=pg_catalog.now(),is_divergent=true
    where s.card_product_id=r.card_product_id and s.category_id is not distinct from r.category_id and s.period_month=r.period_month;
   n:=n+1;
  end loop;
 else raise exception 'Unsupported maintenance batch' using errcode='22023';end if;
 more:=n=j.batch_size;processed:=n;
 update maintenance.jobs q set processed=q.processed+n,heartbeat_at=pg_catalog.now(),consecutive_failures=0,
  merchant_cursor=case when p_job='merchant_confidence' and more then last_id else null end,
  lease_token=case when more then q.lease_token else null end,
  lease_until=case when more then pg_catalog.now()+interval '90 seconds' else null end,
  last_completed_at=case when more then q.last_completed_at else pg_catalog.now() end,
  next_run_at=case when more then pg_catalog.now() else pg_catalog.now()+pg_catalog.make_interval(secs=>q.interval_seconds) end where q.job=p_job;
 return next;
end $$;

-- External auth retention uses its separate narrow connection and approved
-- policy; product maintenance never receives an auth connection or audit rows.
create function maintenance.finish_external(p_lease uuid,p_processed integer,p_more boolean) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$ begin
 if p_processed is null or p_processed not between 0 and 100000 or p_more is null then raise exception 'Invalid maintenance count' using errcode='22023';end if;
 update maintenance.jobs q set processed=q.processed+p_processed,heartbeat_at=pg_catalog.now(),last_completed_at=pg_catalog.now(),
  next_run_at=pg_catalog.now()+pg_catalog.make_interval(secs=>case when p_more then 60 else q.interval_seconds end),lease_token=null,lease_until=null,consecutive_failures=0
  where q.job='auth_retention' and q.enabled and q.lease_token=p_lease and q.lease_until>pg_catalog.now();
 return found;
end $$;
create function maintenance.yield_job(p_job text,p_lease uuid) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$ begin
 update maintenance.jobs q set lease_token=null,lease_until=null,next_run_at=pg_catalog.now()+interval '60 seconds',heartbeat_at=pg_catalog.now()
  where q.job=p_job and q.lease_token=p_lease and q.lease_until>pg_catalog.now();return found;
end $$;
create function maintenance.fail_job(p_job text,p_lease uuid) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$ begin
 update maintenance.jobs q set lease_token=null,lease_until=null,consecutive_failures=least(1000000,q.consecutive_failures+1),
  next_run_at=pg_catalog.now()+pg_catalog.make_interval(secs=>least(3600,60*power(2,least(q.consecutive_failures,5))::integer))
  where q.job=p_job and q.lease_token=p_lease and q.lease_until>pg_catalog.now();
 if not found then return false;end if;perform maintenance.notice(p_job,'job_failed');return true;
end $$;
create function maintenance.fail_auth_retention(p_lease uuid) returns boolean
language sql security definer set search_path='' set statement_timeout='5s' as $$
 select maintenance.fail_job('auth_retention',p_lease)
$$;
create function maintenance.defer_auth_retention(p_lease uuid) returns boolean
language sql security definer set search_path='' set statement_timeout='5s' as $$
 select maintenance.yield_job('auth_retention',p_lease)
$$;
create function maintenance.review_health() returns integer
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$ declare r record;n integer:=0;begin
 for r in select q.job from maintenance.jobs q where q.enabled and q.next_run_at+pg_catalog.make_interval(secs=>q.interval_seconds)<pg_catalog.now()
  and not exists(select 1 from maintenance.notifications x where x.job=q.job and x.code='heartbeat_late' and not x.acknowledged) loop
  perform maintenance.notice(r.job,'heartbeat_late');n:=n+1;
 end loop;return n;
end $$;
create function maintenance.read_health()
returns table(job text,enabled boolean,next_run_at timestamptz,heartbeat_at timestamptz,last_completed_at timestamptz,leased boolean,consecutive_failures integer,processed bigint)
language sql stable security definer set search_path='' set statement_timeout='5s' as $$
 select q.job,q.enabled,q.next_run_at,q.heartbeat_at,q.last_completed_at,coalesce(q.lease_until>pg_catalog.now(),false),q.consecutive_failures,q.processed from maintenance.jobs q order by q.job limit 4
$$;
create function maintenance.read_notifications()
returns table(job text,code text,generation bigint,occurrences bigint,first_seen_at timestamptz,last_seen_at timestamptz,acknowledged boolean)
language sql stable security definer set search_path='' set statement_timeout='5s' as $$
 select n.job,n.code,n.generation,n.occurrences,n.first_seen_at,n.last_seen_at,n.acknowledged from maintenance.notifications n order by n.job,n.code limit 12
$$;
create function maintenance.acknowledge_notification(p_job text,p_code text,p_generation bigint) returns boolean
language plpgsql security definer set search_path='' set statement_timeout='5s' as $$ begin
 update maintenance.notifications n set acknowledged=true where n.job=p_job and n.code=p_code and n.generation=p_generation and not n.acknowledged;return found;
end $$;
revoke all on all functions in schema maintenance from public;
grant execute on function maintenance.claim_job(text),maintenance.run_batch(text,uuid),
 maintenance.yield_job(text,uuid),maintenance.fail_job(text,uuid),maintenance.review_health()
 to pandapay_maintenance;
grant execute on function maintenance.claim_auth_retention(),maintenance.finish_external(uuid,integer,boolean),
 maintenance.fail_auth_retention(uuid),maintenance.defer_auth_retention(uuid) to pandapay_auth_retention_coordinator;
grant execute on function maintenance.read_health(),maintenance.read_notifications() to pandapay_maintenance,pandapay_maintenance_reader;
grant execute on function maintenance.acknowledge_notification(text,text,bigint) to pandapay_maintenance_reader;
select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.maintenance_migration_role'),true);
revoke create on schema maintenance from maintenance_owner;
do $$ declare prior jsonb;begin
 prior:=pg_catalog.current_setting('pandapay.maintenance_prior_grant')::jsonb;
 if prior='null'::jsonb then execute pg_catalog.format('revoke maintenance_owner from %I granted by %I',current_user,current_user);
 else
  execute pg_catalog.format('grant maintenance_owner to %I with inherit %s granted by %I',current_user,prior->>'inherit',current_user);
  execute pg_catalog.format('grant maintenance_owner to %I with set %s granted by %I',current_user,prior->>'set',current_user);
 end if;
end $$;
-- Legacy cron is reviewed/replaced by the explicit fenced activation runbook,
-- rather than silently disabled merely by deploying additive schema.
