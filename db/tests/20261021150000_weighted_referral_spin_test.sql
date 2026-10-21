-- Verifies the seeded, inactive wheel odds and the maximum pair liability.
-- Run only against a fully migrated disposable database; the transaction rolls back.
\set ON_ERROR_STOP on

begin;
set local role promotions_owner;
do $$
declare
  v_distribution jsonb;
  v_total integer;
  v_up_to_100 integer;
  v_over_100 integer;
  v_zero integer;
  v_top integer;
  v_expected_paise bigint;
begin
  select prize_distribution into v_distribution
    from promotions.campaign_versions
   where version_key = 'bamboo-spin-v1-2026-10';
  if v_distribution is null then
    raise exception 'the weighted referral spin version was not created';
  end if;
  if not promotions.distribution_is_valid(v_distribution) then
    raise exception 'the seeded prize distribution violates validation';
  end if;

  select sum((prize ->> 'weight')::integer),
         sum((prize ->> 'weight')::integer)
           filter (where (prize ->> 'amountPaise')::integer <= 10000),
         sum((prize ->> 'weight')::integer)
           filter (where (prize ->> 'amountPaise')::integer > 10000),
         sum((prize ->> 'weight')::integer)
           filter (where (prize ->> 'amountPaise')::integer = 0),
         sum((prize ->> 'weight')::integer)
           filter (where (prize ->> 'amountPaise')::integer = 50000),
         sum((prize ->> 'amountPaise')::bigint * (prize ->> 'weight')::bigint)
    into v_total, v_up_to_100, v_over_100, v_zero, v_top, v_expected_paise
    from jsonb_array_elements(v_distribution -> 'inviter') prize;

  if v_total <> 10000 or v_up_to_100 <> 9800 or v_over_100 <> 200
     or v_zero <> 1000 or v_top <> 20 or v_expected_paise / v_total <> 2490 then
    raise exception 'unexpected odds: total %, <=₹100 %, >₹100 %, zero %, ₹500 %, expected paise %',
      v_total, v_up_to_100, v_over_100, v_zero, v_top, v_expected_paise / v_total;
  end if;
  if promotions.max_prize_paise(v_distribution, 'inviter') <> 50000
     or promotions.max_prize_paise(v_distribution, 'referee') <> 50000 then
    raise exception 'the maximum reward must be exactly ₹500 for either participant';
  end if;
  if (select active_campaign_version from promotions.access_settings where singleton)
       = 'bamboo-spin-v1-2026-10'
     or (select enrollment_open or not fulfillment_paused or total_budget_paise <> 0
           from promotions.campaign_state where version_key = 'bamboo-spin-v1-2026-10') then
    raise exception 'the migration must not activate or fund the campaign';
  end if;
end
$$;
rollback;
select 'weighted referral spin: OK (odds verified; campaign remains inactive)' as result;
