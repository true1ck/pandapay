-- EMI is a first-class spend category, including for databases that already
-- ran the original reference-data seed migration.
insert into spend_categories (slug, name, is_primary_chip, sort_order)
values ('emi', 'EMI', false, 140)
on conflict (slug) do update
set name = excluded.name,
    sort_order = excluded.sort_order;
