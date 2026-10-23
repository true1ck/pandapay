-- User-owned, future-only merchant category rules.
-- The API derives match_basis/match_value from an owned transaction; clients
-- cannot submit an arbitrary merchant key.
create table if not exists user_merchant_category_rules (
  id                    uuid primary key default gen_random_uuid(),
  profile_id            uuid not null references profiles(id) on delete cascade,
  match_basis            text not null check (match_basis in ('vpa', 'strict_name')),
  match_value            text not null check (length(btrim(match_value)) between 1 and 320),
  category_id            uuid not null references spend_categories(id) on delete restrict,
  user_category_id       uuid references user_categories(id) on delete restrict,
  is_active              boolean not null default true,
  version                bigint not null default 1 check (version > 0),
  source_transaction_id  uuid references transactions(id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index if not exists idx_user_merchant_rules_profile
  on user_merchant_category_rules(profile_id, is_active, updated_at desc);
create unique index if not exists idx_user_merchant_rules_active_key
  on user_merchant_category_rules(profile_id, match_basis, match_value)
  where is_active;
create index if not exists idx_user_merchant_rules_source
  on user_merchant_category_rules(profile_id, source_transaction_id)
  where source_transaction_id is not null;

create trigger trg_user_merchant_rules_touch before update on user_merchant_category_rules
  for each row execute function pandapay.touch_updated_at();

-- A foreign key alone does not prove that a private child belongs to the same
-- profile as the rule. Keep the invariant at the database boundary as well as
-- in the API, including nested private-category parents.
create or replace function pandapay.validate_user_merchant_rule_category()
returns trigger language plpgsql
set search_path = public, pandapay
as $$
begin
  if new.user_category_id is null then
    return new;
  end if;
  if not exists (
    with recursive parents(id, parent_category_id, parent_user_category_id, path) as (
      select uc.id, uc.parent_category_id, uc.parent_user_category_id, array[uc.id]
        from user_categories uc where uc.id = new.user_category_id and uc.profile_id = new.profile_id
      union all
      select parent.id, parent.parent_category_id, parent.parent_user_category_id, child.path || parent.id
        from user_categories parent join parents child on child.parent_user_category_id = parent.id
       where parent.profile_id = new.profile_id and not (parent.id = any(child.path))
    ) select 1 from parents where parent_category_id = new.category_id
  ) then
    raise exception 'user category does not belong to rule parent' using errcode = '23514';
  end if;
  return new;
end $$;

create trigger trg_user_merchant_rules_category_guard
  before insert or update of profile_id, category_id, user_category_id
  on user_merchant_category_rules
  for each row execute function pandapay.validate_user_merchant_rule_category();

create table if not exists user_merchant_category_rule_audit (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  rule_id             uuid not null references user_merchant_category_rules(id) on delete cascade,
  actor_id             uuid,
  operation            text not null check (operation in ('create', 'replace', 'update', 'enable', 'disable', 'delete')),
  old_category_id      uuid references spend_categories(id) on delete set null,
  old_user_category_id uuid references user_categories(id) on delete set null,
  new_category_id      uuid references spend_categories(id) on delete set null,
  new_user_category_id uuid references user_categories(id) on delete set null,
  old_is_active        boolean,
  new_is_active        boolean,
  version              bigint not null check (version > 0),
  created_at           timestamptz not null default now()
);

create index if not exists idx_user_merchant_rule_audit_rule
  on user_merchant_category_rule_audit(profile_id, rule_id, created_at desc);

-- Request idempotency is retained separately from the rule so retries remain
-- safe even when a rule is subsequently edited or disabled.
create table if not exists user_merchant_category_rule_idempotency (
  profile_id       uuid not null references profiles(id) on delete cascade,
  idempotency_key  text not null check (length(btrim(idempotency_key)) between 8 and 200),
  request_hash     text not null check (length(request_hash) = 64),
  result           jsonb,
  created_at       timestamptz not null default now(),
  primary key (profile_id, idempotency_key)
);

alter table user_merchant_category_rules enable row level security;
alter table user_merchant_category_rules force row level security;
alter table user_merchant_category_rule_audit enable row level security;
alter table user_merchant_category_rule_audit force row level security;
alter table user_merchant_category_rule_idempotency enable row level security;
alter table user_merchant_category_rule_idempotency force row level security;

drop policy if exists user_merchant_category_rules_owner on user_merchant_category_rules;
create policy user_merchant_category_rules_owner on user_merchant_category_rules
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
drop policy if exists user_merchant_category_rule_audit_owner on user_merchant_category_rule_audit;
create policy user_merchant_category_rule_audit_owner on user_merchant_category_rule_audit
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
drop policy if exists user_merchant_category_rule_idempotency_owner on user_merchant_category_rule_idempotency;
create policy user_merchant_category_rule_idempotency_owner on user_merchant_category_rule_idempotency
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

grant select, insert, update, delete on
  user_merchant_category_rules,
  user_merchant_category_rule_audit,
  user_merchant_category_rule_idempotency to app_user;

-- Rules are ordinary user-owned sync entities. Creates/changes are written by
-- the API after validation; the field allow-list makes pulls safe and lets
-- older devices ignore this entity without mutating it. Disabled rows are
-- retained, so a stale device cannot resurrect a deleted rule by replaying a
-- delete as an insert.
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
      'match_basis','match_value','category_id','user_category_id','is_active','version'
    ]
    else null::text[]
  end;
$$;

-- Rule sync is version based rather than generic field-clock LWW: a stale
-- device must never turn a disabled rule back on. Creates still go through the
-- authenticated API because they need source-transaction and idempotency
-- checks; a device receives those creates through sync_pull.
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
  incoming_category := nullif(p_payload->>'category_id', '')::uuid;
  incoming_user_category := nullif(p_payload->>'user_category_id', '')::uuid;
  incoming_active := coalesce((p_payload->>'is_active')::boolean, current_rule.is_active);
  if incoming_version is null or incoming_version <= current_rule.version then
    return query select false, 1, 'stale_revision'::text;
    return;
  end if;
  if incoming_category is null or not exists (select 1 from spend_categories where id = incoming_category) then
    return query select false, 0, 'category_not_found'::text;
    return;
  end if;
  if incoming_user_category is not null and not exists (
    with recursive parents(id, parent_category_id, parent_user_category_id, path) as (
      select uc.id, uc.parent_category_id, uc.parent_user_category_id, array[uc.id]
        from user_categories uc where uc.id = incoming_user_category and uc.profile_id = p_profile
      union all
      select parent.id, parent.parent_category_id, parent.parent_user_category_id, child.path || parent.id
        from user_categories parent join parents child on child.parent_user_category_id = parent.id
       where parent.profile_id = p_profile and not (parent.id = any(child.path))
    ) select 1 from parents where parent_category_id = incoming_category
  ) then
    return query select false, 0, 'category_parent_mismatch'::text;
    return;
  end if;
  update user_merchant_category_rules set
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

grant execute on function pandapay.sync_apply_user_merchant_category_rule(uuid, uuid, uuid, sync_op, jsonb, bigint) to public;

comment on table user_merchant_category_rules is
  'User intent for future classification only; existing transactions are never rewritten by rule CRUD.';
comment on table user_merchant_category_rule_audit is
  'Append-only audit of user merchant rule category and enabled-state changes.';
