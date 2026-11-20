-- Categories that belong to one kind of entry only.
--
-- spend_categories used to hold just the 15 spend categories, so the edit
-- screens offered Travel/Entertainment on an Investment. Each row now says
-- which entry kinds may use it. Existing rows stay spend-only (the default),
-- so budgets, caps, reward chips and the SMS vocabulary see no change.
alter table spend_categories
  add column if not exists entry_kinds text[] not null default '{spend}';

insert into spend_categories (slug, name, is_primary_chip, sort_order, entry_kinds) values
  ('inv_sip',          'SIP',                  false, 200, '{investment}'),
  ('inv_mutual_funds', 'Mutual funds',         false, 201, '{investment}'),
  ('inv_stocks',       'Stocks',               false, 202, '{investment}'),
  ('inv_etfs',         'ETFs',                 false, 203, '{investment}'),
  ('inv_ipo',          'IPO',                  false, 204, '{investment}'),
  ('inv_bonds',        'Bonds',                false, 205, '{investment}'),
  ('inv_gold',         'Gold',                 false, 206, '{investment}'),
  ('inv_fd_rd',        'Fixed deposit / RD',   false, 207, '{investment}'),
  ('inv_retirement',   'NPS / PPF / EPF',      false, 208, '{investment}'),
  ('inv_crypto',       'Crypto',               false, 209, '{investment}'),
  ('inv_real_estate',  'Real estate',          false, 210, '{investment}'),
  ('inv_other',        'Other investment',     false, 211, '{investment}'),

  ('ret_redemption',   'Redemption',           false, 220, '{investment_return}'),
  ('ret_dividend',     'Dividend',             false, 221, '{investment_return}'),
  ('ret_interest',     'Interest',             false, 222, '{investment_return}'),
  ('ret_maturity',     'Maturity',             false, 223, '{investment_return}'),
  ('ret_capital_gains','Capital gains',        false, 224, '{investment_return}'),
  ('ret_other',        'Other return',         false, 225, '{investment_return}'),

  ('inc_salary',       'Salary',               false, 230, '{income}'),
  ('inc_business',     'Business income',      false, 231, '{income}'),
  ('inc_freelance',    'Freelance',            false, 232, '{income}'),
  ('inc_interest',     'Interest',             false, 233, '{income}'),
  ('inc_rental',       'Rental income',        false, 234, '{income}'),
  ('inc_gift',         'Gift',                 false, 235, '{income}'),
  ('inc_cashback',     'Cashback',             false, 236, '{income}'),
  ('inc_pension',      'Pension',              false, 237, '{income}'),
  ('inc_other',        'Other income',         false, 238, '{income}'),

  ('xfer_self',        'Self transfer',        false, 240, '{transfer}'),
  ('xfer_family',      'Family',               false, 241, '{transfer}'),
  ('xfer_friend',      'Friend',               false, 242, '{transfer}'),
  ('xfer_person',      'Another person',       false, 243, '{transfer}')
on conflict (slug) do update
set name = excluded.name,
    sort_order = excluded.sort_order,
    entry_kinds = excluded.entry_kinds;
