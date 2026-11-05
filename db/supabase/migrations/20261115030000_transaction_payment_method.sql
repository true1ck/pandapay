-- The payment type of a transaction, when the message states it. Today only
-- plain UPI is recorded: `rail` has no value for it (upi_qr is the closest, and
-- is shared with QR payments), so a person who moved to a new phone lost the
-- "UPI" label on their history. The phone sends the rail of each fact, the
-- server derives this column from it, and the transaction routes return it.
alter table transactions
  add column if not exists payment_method text
  check (payment_method is null or payment_method in ('upi'));

comment on column transactions.payment_method is
  'Payment type the message states, when the app shows it. Currently only upi.';
