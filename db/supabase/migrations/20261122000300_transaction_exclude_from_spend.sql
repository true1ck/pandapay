-- "Don't count in spending": the person's own choice to leave one transaction
-- out of their spending totals, breakdowns and budgets.
--
-- A separate flag, not a status and not an entry kind. status = 'ignored'
-- reverses card caps, milestones, points and fee-waiver progress and hides the
-- row; changing entry_kind to transfer loses what the row really was and drops
-- it from Money out too. A gift paid for, or a reimbursed expense, still
-- happened on the card and still left the account, so it keeps its status, its
-- kind and its rewards. Only the spending views read this column.
--
-- Additive and defaulted, so existing rows and older apps are unaffected.
alter table transactions
  add column if not exists exclude_from_spend boolean not null default false;

comment on column transactions.exclude_from_spend is
  'True when the person chose not to count this spend row in their spending. Read only by spending totals, breakdowns and budgets; never by rewards, caps, card state, Money in/out or recurring detection.';
