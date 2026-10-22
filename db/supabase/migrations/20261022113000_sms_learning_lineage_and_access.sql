begin;

-- Preserve deletion lineage without depending on a secret at profile deletion
-- time. Old rows remain nullable and are erased by the HMAC helper on opt-out.
alter table public.sms_learning_examples
  add column if not exists profile_id uuid references public.profiles(id) on delete cascade;
create index if not exists idx_sms_learning_examples_profile
  on public.sms_learning_examples(profile_id);

drop policy if exists sms_learning_examples_read on public.sms_learning_examples;
create policy sms_learning_examples_read on public.sms_learning_examples
  for select to public
  using (
    current_user in ('service_role', 'postgres')
    or (pandapay.uid() is not null and profile_id = pandapay.uid())
  );

drop policy if exists sms_learning_examples_insert on public.sms_learning_examples;
create policy sms_learning_examples_insert on public.sms_learning_examples
  for insert to public
  with check (
    current_user in ('service_role', 'postgres')
    or (
      pandapay.uid() is not null
      and profile_id = pandapay.uid()
      and exists (
        select 1 from public.profiles p
         where p.id = pandapay.uid() and p.contributions_opt_in
      )
      and nullif(current_setting('app.sms_learning_hmac_key', true), '') is not null
      and user_hash = encode(hmac(pandapay.uid()::text,
        current_setting('app.sms_learning_hmac_key', true), 'sha256'), 'hex')
    )
  );

-- The callable erasure path may only act on the current user. A privileged
-- worker can act on a deleted profile via its own database role.
create or replace function pandapay.sms_delete_learning_examples_for_user(
  p_user_id uuid, p_hmac_key text default null
) returns integer
language plpgsql security definer
set search_path = pg_catalog, public, pandapay, extensions
as $$
declare
  v_user_hash text;
  v_deleted integer;
  v_key text;
begin
  if p_user_id is null then return 0; end if;
  if session_user not in ('postgres', 'service_role')
     and pandapay.uid() is distinct from p_user_id then
    raise exception 'cannot erase another profile';
  end if;
  v_key := coalesce(nullif(p_hmac_key, ''),
    nullif(current_setting('app.sms_learning_hmac_key', true), ''));
  if v_key is not null and length(v_key) >= 32 then
    v_user_hash := encode(hmac(p_user_id::text, v_key, 'sha256'), 'hex');
  end if;
  delete from public.sms_learning_examples
   where profile_id = p_user_id
      or (v_user_hash is not null and user_hash = v_user_hash);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

commit;
