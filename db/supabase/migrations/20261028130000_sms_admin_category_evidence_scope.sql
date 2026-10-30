begin;

-- A category-rule approver must see an example for the exact proposed
-- merchant/category pair. The old helper chose the latest example by merchant
-- alone, which could display an unrelated context. Only currently consented,
-- admin-approved evidence is eligible; the API applies safeAdminPattern again
-- before returning a pattern to the console.
drop function if exists pandapay.sms_admin_category_evidence();

create or replace function pandapay.sms_admin_category_evidence()
returns table (merchant_key text, category_slug text, redacted_pattern text)
language plpgsql stable security definer
set search_path = pg_catalog, public, pandapay
as $function$
begin
  if not pandapay.is_admin() then
    raise exception 'admin required' using errcode = '42501';
  end if;
  return query
    with current_evidence as (
      select e.merchant_key, e.category_slug, e.redacted_pattern, e.created_at
        from public.sms_learning_feedback_events e
        join lateral (
          select c.granted, c.policy_version, c.granted_at
            from public.user_consents c
           where c.profile_id = e.profile_id
             and c.purpose = 'sms_shared_learning'
           order by c.granted_at desc, c.granted asc, c.id desc
           limit 1
        ) consent on consent.granted = true
                   and consent.policy_version = e.consent_policy_version
                   and consent.granted_at = e.consent_granted_at
       where e.superseded_at is null
         and e.review_status = 'approved'
         and e.redacted_pattern is not null
         and e.merchant_key is not null
         and e.category_slug is not null
         and e.category_slug is distinct from e.original_category_slug
         and coalesce(e.correction_kind, 'misclassified_category') not in
             ('preference_only', 'cosmetic', 'duplicate', 'already_paid')
      union all
      select upper(regexp_replace(btrim(p.proposed_fields->>'merchant'), '\s+', ' ', 'g')),
             p.proposed_fields->>'categorySlug', p.redacted_pattern, p.reviewed_at
        from public.sms_ai_learning_proposals p
        join lateral (
          select c.granted, c.policy_version, c.granted_at
            from public.user_consents c
           where c.profile_id = p.profile_id
             and c.purpose = 'sms_shared_learning'
           order by c.granted_at desc, c.granted asc, c.id desc
           limit 1
        ) consent on consent.granted = true
                   and consent.policy_version = p.consent_policy_version
                   and consent.granted_at = p.consent_granted_at
       where p.status = 'approved'
         and p.proposed_fields ? 'merchant'
         and p.proposed_fields ? 'categorySlug'
         and p.redacted_pattern is not null
    )
    select distinct on (e.merchant_key, e.category_slug)
           e.merchant_key, e.category_slug, e.redacted_pattern
      from current_evidence e
     where e.merchant_key is not null and e.category_slug is not null
     order by e.merchant_key, e.category_slug, e.created_at desc,
              e.redacted_pattern;
end;
$function$;

revoke all on function pandapay.sms_admin_category_evidence() from public;
grant execute on function pandapay.sms_admin_category_evidence() to app_user;

commit;
