-- Subscription lifecycle and mandate provenance.
--
-- The original recurring_series row used detection_source as both evidence
-- and state. That made an observed charge look like AutoPay and made a
-- cancelled mandate disappear without retaining why it disappeared. These
-- additive fields keep old rows readable while allowing the API to report
-- current AutoPay state honestly.

alter table recurring_series
  add column if not exists lifecycle_status text not null default 'active';

alter table recurring_series
  add column if not exists autopay_status text not null default 'unknown';

alter table recurring_series
  add column if not exists mandate_reference text;

alter table recurring_series
  add column if not exists mandate_started_on date;

alter table recurring_series
  add column if not exists mandate_cancelled_at timestamptz;

alter table recurring_series
  add column if not exists cadence_confirmed boolean not null default true;

alter table recurring_series
  drop constraint if exists recurring_series_lifecycle_status_check;

alter table recurring_series
  add constraint recurring_series_lifecycle_status_check
  check (lifecycle_status in ('active', 'paused', 'cancelled', 'hidden'));

alter table recurring_series
  drop constraint if exists recurring_series_autopay_status_check;

alter table recurring_series
  add constraint recurring_series_autopay_status_check
  check (autopay_status in ('active', 'cancelled', 'unknown'));

-- Existing mandate rows were created by the old mandate pipeline. Preserve
-- their meaning; ordinary observed/manual rows remain AutoPay-unknown.
update recurring_series
   set autopay_status = 'active'
 where detection_source = 'mandate'
   and is_active
   and dismissed_at is null
   and autopay_status = 'unknown';

update recurring_series
   set autopay_status = 'cancelled',
       lifecycle_status = 'cancelled'
 where detection_source = 'mandate'
   and not is_active
   and autopay_status = 'unknown';

create index if not exists idx_recurring_series_active_lifecycle
  on recurring_series (profile_id, lifecycle_status, autopay_status)
  where is_active and dismissed_at is null;
