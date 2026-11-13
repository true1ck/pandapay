-- Widen transactions.payment_method so a manually entered transaction can say HOW
-- it was paid (cheque, NEFT, net banking, auto-debit, EMI, pay later, ...).
--
-- Migration 20261115030000 added the column with an anonymous CHECK that only
-- allowed null or 'upi'. Its name was auto-generated, so it is found here
-- through pg_constraint rather than assumed. `transactions.instrument` is not
-- touched: a cheque is instrument `upi_bank` with payment_method = 'cheque'.
--
-- The vocabulary below mirrors app/test/fixtures/payment_methods_v1.json (the
-- frozen contract) and api/src/payment_methods.js; a contract test in
-- api/test/payment_method_api.test.js fails if any of the three drift apart.
--
-- Additive and idempotent. No existing row is read or rewritten: every stored
-- value is null or 'upi', both of which the new CHECK allows. The constraint is
-- added NOT VALID here (no table scan while the lock is held). Validation is the
-- NEXT migration file (20261122000100_validate_transaction_payment_method.sql):
-- the migration runner wraps each file in one transaction, so validating in the
-- same file would hold the ADD CONSTRAINT lock through the whole table scan.

do $$
declare
  c record;
begin
  -- Drop the previous single-column CHECK(s) on payment_method, whatever the
  -- generated name was, plus a previous run of this migration so it can be re-run.
  for c in
    select con.conname
      from pg_constraint con
     where con.conrelid = 'public.transactions'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%payment_method%'
  loop
    execute format('alter table public.transactions drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.transactions
  add constraint transactions_payment_method_wire_check
  check (
    payment_method is null
    or payment_method in (
      'upi', 'net_banking', 'neft', 'imps', 'rtgs', 'cheque', 'demand_draft',
      'auto_debit', 'emi', 'pay_later', 'prepaid_card', 'gift_card', 'reward_points'
    )
  ) not valid;

comment on column public.transactions.payment_method is
  'How the transaction was paid. Wire vocabulary: contract transaction-payment-methods v1 (upi, net_banking, neft, imps, rtgs, cheque, demand_draft, auto_debit, emi, pay_later, prepaid_card, gift_card, reward_points). Independent of the instrument enum, which is unchanged.';
