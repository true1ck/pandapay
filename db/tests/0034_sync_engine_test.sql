-- Regression test for migration 0034 (sync engine).
--
-- Same reasoning as db/tests/0029_crowdsource_ingest_test.sql: plpgsql resolves
-- function bodies at CALL time, so a migration that applies cleanly proves
-- almost nothing. This one matters more than most — 0005_sync.sql's header
-- states that "silent data loss during sync is the fastest way to lose a
-- finance user", and every failure mode below is silent by nature. A sync bug
-- does not raise; it quietly keeps the wrong value.
--
-- Run with `psql -v ON_ERROR_STOP=1`.

\set ON_ERROR_STOP on

begin;

insert into profiles (id) values
  ('11110000-0000-0000-0000-00000000aaaa'),   -- the user
  ('22220000-0000-0000-0000-00000000bbbb');   -- an unrelated account
insert into issuers (id, slug, name)
  values ('33330000-0000-0000-0000-00000000cccc', 'sync-test-bank', 'Sync Test Bank');
insert into card_products (id, issuer_id, slug, name, network, card_type, status, verified_at)
  values ('44440000-0000-0000-0000-00000000dddd', '33330000-0000-0000-0000-00000000cccc',
          'sync-test-card', 'Sync Test Card', 'visa', 'credit', 'published', now());
insert into user_cards (id, profile_id, card_product_id)
  values ('55550000-0000-0000-0000-00000000eeee', '11110000-0000-0000-0000-00000000aaaa',
          '44440000-0000-0000-0000-00000000dddd');
insert into transactions (id, profile_id, user_card_id, amount_inr, occurred_at, source, merchant_name, note)
  values ('66660000-0000-0000-0000-00000000ffff', '11110000-0000-0000-0000-00000000aaaa',
          '55550000-0000-0000-0000-00000000eeee', 500.00, now(), 'manual', 'Original', null);

do $$
declare
  v_phone uuid; v_tablet uuid;
  v_applied boolean; v_conflicts int; v_reason text;
  v_note text; v_merchant text; v_owner uuid; v_confirmed numeric;
  v_count int; v_seq bigint; v_archived boolean;
begin
  v_phone  := pandapay.register_sync_device('11110000-0000-0000-0000-00000000aaaa', 'android', 'Phone');
  v_tablet := pandapay.register_sync_device('11110000-0000-0000-0000-00000000aaaa', 'android', 'Tablet');

  -- Re-registering with a known id must return THAT id, not mint a new device
  -- on every app launch.
  if pandapay.register_sync_device('11110000-0000-0000-0000-00000000aaaa','android','Phone',null,v_phone)
     <> v_phone then
    raise exception 'register_sync_device is not idempotent for a known device id';
  end if;

  -- ==========================================================================
  -- Per-field merge: two devices, two different fields, both must survive.
  -- Row-level last-write-wins silently destroys one of these.
  -- ==========================================================================
  select out_applied into v_applied from pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_tablet, 'transactions',
    '66660000-0000-0000-0000-00000000ffff', 'update',
    '{"note":"dinner"}'::jsonb, '{"note":1000}'::jsonb, 1);
  if not v_applied then raise exception 'tablet note write was refused'; end if;

  select out_applied into v_applied from pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_phone, 'transactions',
    '66660000-0000-0000-0000-00000000ffff', 'update',
    '{"merchant_name":"Bombay Canteen"}'::jsonb, '{"merchant_name":2000}'::jsonb, 1);
  if not v_applied then raise exception 'phone merchant write was refused'; end if;

  select note, merchant_name into v_note, v_merchant
    from transactions where id = '66660000-0000-0000-0000-00000000ffff';
  if v_note is distinct from 'dinner' or v_merchant is distinct from 'Bombay Canteen' then
    raise exception 'per-field merge lost a value (note=%, merchant=%)', v_note, v_merchant;
  end if;

  -- ==========================================================================
  -- Genuine conflict: same field, older clock. Newer wins, loser is RECORDED.
  -- ==========================================================================
  select out_conflicts into v_conflicts from pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_tablet, 'transactions',
    '66660000-0000-0000-0000-00000000ffff', 'update',
    '{"merchant_name":"Stale Value"}'::jsonb, '{"merchant_name":1500}'::jsonb, 2);
  if v_conflicts <> 1 then
    raise exception 'a stale same-field write should report exactly 1 conflict, got %', v_conflicts;
  end if;

  select merchant_name into v_merchant
    from transactions where id = '66660000-0000-0000-0000-00000000ffff';
  if v_merchant <> 'Bombay Canteen' then
    raise exception 'a stale write overwrote a newer value (%)', v_merchant;
  end if;

  select count(*) into v_count from sync_conflicts
   where field = 'merchant_name' and local_value = '"Stale Value"'::jsonb;
  if v_count <> 1 then
    raise exception 'the discarded value was not recorded in sync_conflicts';
  end if;

  -- ==========================================================================
  -- Security. Each of these would be a serious defect and none of them raises
  -- on its own — they have to be asserted.
  -- ==========================================================================
  -- Another account's row must be untouchable even with a valid device.
  select out_applied, out_reason into v_applied, v_reason from pandapay.sync_apply_change(
    '22220000-0000-0000-0000-00000000bbbb', v_phone, 'transactions',
    '66660000-0000-0000-0000-00000000ffff', 'update',
    '{"note":"stolen"}'::jsonb, '{"note":99999}'::jsonb, 1);
  if v_applied or v_reason <> 'not_found' then
    raise exception 'a cross-profile write was accepted';
  end if;
  select note into v_note from transactions where id = '66660000-0000-0000-0000-00000000ffff';
  if v_note <> 'dinner' then raise exception 'a cross-profile write mutated the row'; end if;

  -- profile_id is not in the allowlist: ownership cannot be reassigned.
  perform pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_phone, 'transactions',
    '66660000-0000-0000-0000-00000000ffff', 'update',
    '{"profile_id":"22220000-0000-0000-0000-00000000bbbb"}'::jsonb,
    '{"profile_id":99999}'::jsonb, 3);
  select profile_id into v_owner from transactions where id = '66660000-0000-0000-0000-00000000ffff';
  if v_owner <> '11110000-0000-0000-0000-00000000aaaa' then
    raise exception 'sync reassigned row ownership';
  end if;

  -- Server-computed reward fields are not client-writable.
  perform pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_phone, 'transactions',
    '66660000-0000-0000-0000-00000000ffff', 'update',
    '{"confirmed_value_inr":999999}'::jsonb, '{"confirmed_value_inr":99999}'::jsonb, 4);
  select coalesce(confirmed_value_inr, 0) into v_confirmed
    from transactions where id = '66660000-0000-0000-0000-00000000ffff';
  if v_confirmed <> 0 then
    raise exception 'a client rewrote its own reward history (%)', v_confirmed;
  end if;

  -- Unknown entity is refused rather than attempted.
  select out_applied, out_reason into v_applied, v_reason from pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_phone, 'profiles',
    '11110000-0000-0000-0000-00000000aaaa', 'update', '{"x":1}'::jsonb, '{}'::jsonb, 5);
  if v_applied or v_reason <> 'unknown_entity' then
    raise exception 'sync accepted a write to a non-syncable entity';
  end if;

  -- R4: "archive, never delete". A delete over sync must not become the one
  -- path that circumvents it.
  perform pandapay.sync_apply_change(
    '11110000-0000-0000-0000-00000000aaaa', v_phone, 'user_cards',
    '55550000-0000-0000-0000-00000000eeee', 'delete', '{}'::jsonb, '{}'::jsonb, 6);
  select count(*), bool_and(is_archived) into v_count, v_archived
    from user_cards where id = '55550000-0000-0000-0000-00000000eeee';
  if v_count <> 1 or not v_archived then
    raise exception 'a synced delete removed a user_card instead of archiving it';
  end if;

  -- ==========================================================================
  -- Pull / ack
  -- ==========================================================================
  -- A device must not be handed back its own writes.
  select count(*) into v_count from pandapay.sync_pull(
    '11110000-0000-0000-0000-00000000aaaa', v_phone, 0);
  if v_count = 0 then raise exception 'phone pulled nothing despite tablet writes'; end if;
  if exists (select 1 from change_log where device_id = v_phone
              and server_seq in (select server_seq from pandapay.sync_pull(
                '11110000-0000-0000-0000-00000000aaaa', v_phone, 0))) then
    raise exception 'pull echoed the requesting device''s own changes back to it';
  end if;

  -- Ack advances the cursor; a re-pull from it returns nothing.
  select max(server_seq) into v_seq from change_log;
  perform pandapay.sync_ack('11110000-0000-0000-0000-00000000aaaa', v_phone, v_seq);
  select count(*) into v_count from pandapay.sync_pull(
    '11110000-0000-0000-0000-00000000aaaa', v_phone,
    (select last_server_seq from sync_cursors where device_id = v_phone));
  if v_count <> 0 then raise exception 'changes were redelivered after being acknowledged'; end if;

  -- A replayed or out-of-order ack must never rewind the cursor, which would
  -- redeliver changes the client already applied.
  perform pandapay.sync_ack('11110000-0000-0000-0000-00000000aaaa', v_phone, 1);
  select last_server_seq into v_seq from sync_cursors where device_id = v_phone;
  if v_seq <= 1 then raise exception 'a stale ack rewound the sync cursor'; end if;

  raise notice 'sync engine: all checks passed';
end $$;

rollback;
