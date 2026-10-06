-- >>> MIGRATION 0046 — HIGH-CONFIDENCE SMS FUEL RULES =====================
--
-- These merchants are unambiguous fuel-station names seen in Indian bank
-- SMS alerts.  They are kept in the existing name-keyed rule table so both
-- new SMS imports and the idempotent SMS reconciliation route classify old
-- rows without inserting or changing transaction amounts.

begin;

insert into merchant_category_rules (pattern, category_id, priority, notes) values
  ('qualityfuelstation',
   (select id from spend_categories where slug = 'fuel'),
   20,
   'High-confidence fuel station name from SMS'),
  ('kavlekarpetroleum',
   (select id from spend_categories where slug = 'fuel'),
   20,
   'High-confidence petroleum merchant name from SMS')
on conflict (pattern, category_id) do update
  set priority = excluded.priority,
      is_active = true,
      notes = excluded.notes;

commit;
