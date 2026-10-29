\set ON_ERROR_STOP on
-- Direct RPC calls must reject NULL decisions with the same stable outcome as
-- the API instead of relying on the API's request validator.
begin;

insert into public.profiles (id, contributions_opt_in)
values ('37000000-0000-0000-0000-000000000001'::uuid, true);
insert into public.admin_users (id, email, role, is_active)
values ('37000000-0000-0000-0000-000000000001'::uuid,
        'sms-review-null-decision@example.invalid', 'operator', true);

set local role app_user;
select set_config('app.user_id', '37000000-0000-0000-0000-000000000001', true);
do $$
declare v_result jsonb;
begin
  v_result := pandapay.sms_review_correction_case(
    gen_random_uuid(), null, pandapay.uid(), 'valid reason for test'
  );
  if v_result->>'ok' <> 'false' or v_result->>'reason' <> 'invalid_review' then
    raise exception 'NULL review decision was not rejected cleanly: %', v_result;
  end if;
end $$;
reset role;

rollback;
