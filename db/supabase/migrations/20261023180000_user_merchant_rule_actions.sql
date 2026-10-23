-- Additive extension for future merchant rules.
--
-- Existing rows are category rules.  The explicit action discriminator keeps
-- future flag rules from being mistaken for category assignments.  A flag is
-- deliberately an opaque, user-facing action key; this migration does not
-- reinterpret transactions.status (active/ignored/reversed/deleted) and does
-- not create support reports.  The importer decides which supported flag
-- actions can be materialized once that product contract is available.

alter table user_merchant_category_rules
  add column if not exists action text not null default 'category',
  add column if not exists flag text;

alter table user_merchant_category_rules
  alter column category_id drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'user_merchant_category_rules'::regclass
       and conname = 'user_merchant_rule_action_check'
  ) then
    alter table user_merchant_category_rules
      add constraint user_merchant_rule_action_check
      check (action in ('category', 'flag'));
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'user_merchant_category_rules'::regclass
       and conname = 'user_merchant_rule_target_check'
  ) then
    alter table user_merchant_category_rules
      add constraint user_merchant_rule_target_check
      check (
        (action = 'category' and category_id is not null and flag is null)
        or (action = 'flag' and category_id is null and user_category_id is null and flag is not null)
      );
  end if;
end $$;

alter table user_merchant_category_rules
  add constraint user_merchant_rule_flag_format_check
  check (flag is null or flag ~ '^[a-z][a-z0-9_.:-]{0,63}$');

alter table user_merchant_category_rule_audit
  add column if not exists old_action text,
  add column if not exists old_flag text,
  add column if not exists new_action text,
  add column if not exists new_flag text;

alter table user_merchant_category_rule_audit
  add constraint user_merchant_rule_audit_action_check
  check (old_action is null or old_action in ('category', 'flag')),
  add constraint user_merchant_rule_audit_new_action_check
  check (new_action is null or new_action in ('category', 'flag'));

create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','user_category_id','rail','status','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode',
      'statement_day_source','due_day_source'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    when 'user_merchant_category_rules' then array[
      'action','flag','match_basis','match_value','category_id','user_category_id','is_active','version'
    ]
    else null::text[]
  end;
$$;

create or replace function pandapay.sync_apply_user_merchant_category_rule(
  p_profile uuid, p_device uuid, p_entity_id uuid, p_op sync_op,
  p_payload jsonb, p_client_seq bigint
) returns table(out_applied boolean, out_conflicts int, out_reason text)
language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  current_rule user_merchant_category_rules%rowtype;
  incoming_version bigint;
  incoming_action text;
  incoming_flag text;
  incoming_category uuid;
  incoming_user_category uuid;
  incoming_active boolean;
begin
  if p_op = 'insert' then
    return query select false, 0, 'not_found'::text;
    return;
  end if;
  select * into current_rule from user_merchant_category_rules
   where id = p_entity_id and profile_id = p_profile for update;
  if not found then
    return query select false, 0, 'not_found'::text;
    return;
  end if;
  incoming_version := nullif(p_payload->>'version', '')::bigint;
  incoming_action := coalesce(nullif(p_payload->>'action', ''), current_rule.action, 'category');
  incoming_flag := case when p_payload ? 'flag' then nullif(p_payload->>'flag', '') else current_rule.flag end;
  incoming_category := case when p_payload ? 'category_id' then nullif(p_payload->>'category_id', '')::uuid else current_rule.category_id end;
  incoming_user_category := case when p_payload ? 'user_category_id' then nullif(p_payload->>'user_category_id', '')::uuid else current_rule.user_category_id end;
  incoming_active := coalesce((p_payload->>'is_active')::boolean, current_rule.is_active);
  if incoming_version is null or incoming_version <= current_rule.version then
    return query select false, 1, 'stale_revision'::text;
    return;
  end if;
  if incoming_action not in ('category', 'flag') then
    return query select false, 0, 'action_invalid'::text;
    return;
  end if;
  if incoming_action = 'category' then
    if incoming_category is null or not exists (select 1 from spend_categories where id = incoming_category)
       or incoming_flag is not null then
      return query select false, 0, 'category_action_target_invalid'::text;
      return;
    end if;
  elsif incoming_flag is null or incoming_category is not null or incoming_user_category is not null then
    return query select false, 0, 'flag_action_target_invalid'::text;
    return;
  end if;
  update user_merchant_category_rules set
    action = incoming_action,
    flag = incoming_flag,
    category_id = incoming_category,
    user_category_id = incoming_user_category,
    is_active = incoming_active,
    version = incoming_version,
    updated_at = now()
   where id = p_entity_id and profile_id = p_profile;
  insert into change_log(profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
    values (p_profile, p_device, 'user_merchant_category_rules', p_entity_id, 'update', p_payload, '{}'::jsonb, p_client_seq);
  return query select true, 0, null::text;
end $$;

comment on column user_merchant_category_rules.action is
  'Future action discriminator. category assigns category_id; flag stores an explicit action key without changing transaction status.';
comment on column user_merchant_category_rules.flag is
  'Opaque future flag action key. It is not transactions.status and is never interpreted as a support report.';
