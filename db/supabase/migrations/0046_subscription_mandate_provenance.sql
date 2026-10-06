-- Keep the subscription table compatible with both kinds of evidence:
-- observed repeating debits and an explicit mandate-created SMS. A mandate
-- is not a spend and must never be inserted into transactions; this column
-- only tells the UI why the subscription row exists.
alter table recurring_series
  add column if not exists detection_source text not null default 'observed';

alter table recurring_series
  add column if not exists payment_method text;

alter table recurring_series
  drop constraint if exists recurring_series_detection_source_check;

alter table recurring_series
  add constraint recurring_series_detection_source_check
  check (detection_source in ('observed', 'mandate'));
