-- SMS v2 core tables (WP-08). Disposable fully-migrated local PG fixture.
-- Synthetic ids only; every row is rolled back.
\set ON_ERROR_STOP on
begin;
select gen_random_uuid()::text as a, gen_random_uuid()::text as b,
       gen_random_uuid()::text as inst_a, gen_random_uuid()::text as inst_a2, gen_random_uuid()::text as inst_b \gset
insert into profiles(id) values (:'a'::uuid), (:'b'::uuid);

-- Profile A writes one row in each table.
set local role app_user;
select set_config('app.user_id', :'a', true);
insert into sms_v2_instruments(instrument_id, profile_id, kind, issuer_slug, mask_digits, display_name, status, first_seen_at, last_seen_at)
  values (:'inst_a'::uuid, :'a'::uuid, 'credit_card', 'hdfc', '5678', 'HDFC card', 'detected', now(), now());
insert into sms_v2_facts(fact_id, profile_id, source_key, fact_type, contract_version, observed_at, payload, provenance)
  values (repeat('a', 64), :'a'::uuid, 'sms:synthetic:1', 'movement', '2.0', now(), '{}', '{}');
insert into sms_v2_events(event_id, profile_id, type, status, legs, confidence, occurred_at, amount_minor)
  values (repeat('a', 64), :'a'::uuid, 'purchase', 'complete', '[{"factId":"a","role":"debit_leg"}]', 0.9, now(), 100);
insert into sms_v2_ledger_entries(entry_id, profile_id, event_id, from_instrument_id, to_external, amount_minor, unit, occurred_at,
    counts_as_transaction, is_spend, is_income, is_investment)
  values (repeat('b', 64), :'a'::uuid, repeat('a', 64), :'inst_a'::uuid, 'SWIGGY', 100, 'INR', now(), true, true, false, false);

-- Shape constraints.
do $$ declare ia text := current_setting('app.user_id'); begin
  begin
    insert into sms_v2_instruments(instrument_id, profile_id, kind, issuer_slug, display_name, status, first_seen_at, last_seen_at)
      values (gen_random_uuid(), ia::uuid, 'savings', 'hdfc', 'x', 'detected', now(), now());
    raise exception 'instrument kind check missing';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_instruments(instrument_id, profile_id, kind, issuer_slug, mask_digits, display_name, status, first_seen_at, last_seen_at)
      values (gen_random_uuid(), ia::uuid, 'credit_card', 'hdfc', '5678', 'dup key', 'detected', now(), now());
    raise exception 'instrument identity key not unique';
  exception when unique_violation then null; end;
  -- Two instruments without a mask share a key.
  insert into sms_v2_instruments(instrument_id, profile_id, kind, issuer_slug, display_name, status, first_seen_at, last_seen_at)
    values (gen_random_uuid(), ia::uuid, 'wallet', 'paytm', 'Paytm', 'detected', now(), now());
  begin
    insert into sms_v2_instruments(instrument_id, profile_id, kind, issuer_slug, display_name, status, first_seen_at, last_seen_at)
      values (gen_random_uuid(), ia::uuid, 'wallet', 'paytm', 'Paytm again', 'detected', now(), now());
    raise exception 'null-mask identity key not unique';
  exception when unique_violation then null; end;
  begin
    insert into sms_v2_events(event_id, profile_id, type, status, legs, confidence, occurred_at, amount_minor)
      values (repeat('c', 64), ia::uuid, 'purchase', 'complete', '[]', 0.5, now(), 1);
    raise exception 'empty legs allowed';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_events(event_id, profile_id, type, status, legs, confidence, occurred_at, amount_minor)
      values (repeat('c', 64), ia::uuid, 'purchase', 'finished', '[{"factId":"a","role":"debit_leg"}]', 0.5, now(), 1);
    raise exception 'event status check missing';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_facts(fact_id, profile_id, source_key, fact_type, contract_version, observed_at, payload, provenance)
      values (repeat('d', 64), ia::uuid, 'k', 'info', '2.0', now(), '{}', '{}');
    raise exception 'info facts must never be stored';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_ledger_entries(entry_id, profile_id, event_id, from_instrument_id, from_external, to_external, amount_minor, unit,
        occurred_at, counts_as_transaction, is_spend, is_income, is_investment)
      values (repeat('e', 64), ia::uuid, repeat('a', 64), gen_random_uuid(), 'both', 'X', 1, 'INR', now(), true, true, false, false);
    raise exception 'two endpoints on one side allowed';
  exception when check_violation then null; end;
  begin
    insert into sms_v2_ledger_entries(entry_id, profile_id, event_id, to_external, amount_minor, unit,
        occurred_at, counts_as_transaction, is_spend, is_income, is_investment)
      values (repeat('f', 64), ia::uuid, repeat('a', 64), 'X', 1, 'INR', now(), true, true, false, false);
    raise exception 'missing from endpoint allowed';
  exception when check_violation then null; end;
end $$;

-- transactions: pipeline_version defaults to 1, refund is a valid kind, one row per (profile, event).
insert into transactions(profile_id, amount_inr, occurred_at, source, event_id, pipeline_version, entry_kind)
  values (:'a'::uuid, 1.00, now(), 'sms', repeat('a', 64), 2, 'refund');
insert into transactions(profile_id, amount_inr, occurred_at, source) values (:'a'::uuid, 2.00, now(), 'manual');
do $$ begin
  if (select pipeline_version from transactions where amount_inr = 2.00 and event_id is null) <> 1 then
    raise exception 'pipeline_version default must be 1';
  end if;
  begin
    insert into transactions(profile_id, amount_inr, occurred_at, source, event_id, pipeline_version)
      values (current_setting('app.user_id')::uuid, 3.00, now(), 'sms', repeat('a', 64), 2);
    raise exception 'one transaction per event expected';
  exception when unique_violation then null; end;
end $$;

-- Profile B sees nothing of A's, cannot change it and cannot write as A.
select set_config('app.user_id', :'b', true);
do $$ declare a text; begin
  if (select count(*) from sms_v2_instruments) <> 0 then raise exception 'instruments visible across profiles'; end if;
  if (select count(*) from sms_v2_facts) <> 0 then raise exception 'facts visible across profiles'; end if;
  if (select count(*) from sms_v2_events) <> 0 then raise exception 'events visible across profiles'; end if;
  if (select count(*) from sms_v2_ledger_entries) <> 0 then raise exception 'ledger visible across profiles'; end if;
  if (select count(*) from transactions where event_id is not null) <> 0 then raise exception 'projected transactions visible across profiles'; end if;
end $$;
update sms_v2_events set status = 'user_confirmed';
delete from sms_v2_events;
delete from sms_v2_instruments;
delete from sms_v2_facts;
delete from sms_v2_ledger_entries;
do $$ begin
  begin
    insert into sms_v2_events(event_id, profile_id, type, status, legs, confidence, occurred_at, amount_minor)
      values (repeat('9', 64), (select id from profiles where id <> current_setting('app.user_id')::uuid limit 1), 'purchase', 'complete',
              '[{"factId":"a","role":"debit_leg"}]', 0.5, now(), 1);
    raise exception 'wrote a row as another profile';
  exception when insufficient_privilege then null; end;
end $$;

-- Still intact for A.
select set_config('app.user_id', :'a', true);
do $$ begin
  if (select count(*) from sms_v2_instruments where kind = 'credit_card') <> 1 then raise exception 'A instrument gone'; end if;
  if (select status from sms_v2_events where event_id = repeat('a', 64)) <> 'complete' then raise exception 'A event changed by B'; end if;
  if (select count(*) from sms_v2_ledger_entries) <> 1 then raise exception 'A ledger changed by B'; end if;
end $$;

-- No session identity: nothing visible at all (default deny).
select set_config('app.user_id', '', true);
do $$ begin
  if (select count(*) from sms_v2_events) <> 0 or (select count(*) from sms_v2_facts) <> 0 then
    raise exception 'rows visible without a session identity';
  end if;
end $$;

reset role;
rollback;
select 'sms_v2_core ok' as result;
