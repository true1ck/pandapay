-- Validate the constraint added NOT VALID by 20261122000000. A separate file means a
-- separate transaction: VALIDATE only needs a SHARE UPDATE EXCLUSIVE lock, so
-- reads and writes on transactions continue while existing rows are checked.
-- Every stored value is null or 'upi', both allowed, so validation cannot fail.
alter table public.transactions
  validate constraint transactions_payment_method_wire_check;
