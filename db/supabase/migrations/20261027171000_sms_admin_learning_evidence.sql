begin;

alter table public.sms_learning_feedback_events
  add column if not exists redacted_pattern text;

create or replace function pandapay.sms_admin_category_evidence()
returns table (merchant_key text, redacted_pattern text)
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
begin
  if not pandapay.is_admin() then
    raise exception 'admin required' using errcode = '42501';
  end if;
  return query
    select distinct on (e.merchant_key) e.merchant_key, e.redacted_pattern
      from public.sms_learning_feedback_events e
      join lateral (
        select c.granted, c.policy_version from public.user_consents c
         where c.profile_id = e.profile_id and c.purpose = 'sms_shared_learning'
         order by c.granted_at desc, c.id desc limit 1
      ) consent on consent.granted = true
     where e.action = 'category_changed'
       and e.merchant_key is not null
       and e.redacted_pattern is not null
     order by e.merchant_key, e.created_at desc, e.event_id desc;
end;
$function$;

revoke all on function pandapay.sms_admin_category_evidence() from public;
grant execute on function pandapay.sms_admin_category_evidence() to app_user;

commit;
