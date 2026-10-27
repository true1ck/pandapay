-- Dismissed Need Review messages are represented as positive ignore_noise
-- learning examples. Older installations created this CHECK before that
-- family was added to the application contract, and CREATE TABLE IF NOT
-- EXISTS does not update an existing CHECK constraint.
begin;

alter table public.sms_learning_examples
  drop constraint if exists sms_learning_examples_fact_family_check;

alter table public.sms_learning_examples
  add constraint sms_learning_examples_fact_family_check
  check (fact_family in (
    'posted_movement', 'pending_or_failed_attempt', 'balance_snapshot',
    'bill_obligation', 'bill_payment', 'mandate_lifecycle',
    'card_identity_hint', 'security_or_service_alert', 'promotion', 'ignore_noise'
  )) not valid;

alter table public.sms_learning_examples
  validate constraint sms_learning_examples_fact_family_check;

commit;
