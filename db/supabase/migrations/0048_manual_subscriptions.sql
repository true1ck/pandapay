-- User-entered subscriptions have no recorded charge yet. Keep their
-- observed transaction dates empty until an actual expense is captured.
alter table recurring_series
  alter column first_seen_on drop not null,
  alter column last_seen_on drop not null;

alter table recurring_series
  drop constraint if exists recurring_series_occurrence_count_check;

alter table recurring_series
  add constraint recurring_series_occurrence_count_check
  check (occurrence_count >= 0);

alter table recurring_series
  drop constraint if exists recurring_series_detection_source_check;

alter table recurring_series
  add constraint recurring_series_detection_source_check
  check (detection_source in ('observed', 'mandate', 'manual'));
