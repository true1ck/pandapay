begin;

-- Expense-app exports include bank, wallet, and cash history. Their import
-- batches must not require a credit card or change its rewards/utilization.
alter table statement_imports alter column user_card_id drop not null;

commit;
