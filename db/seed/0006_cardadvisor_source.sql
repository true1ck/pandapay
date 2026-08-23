-- Seed the CardAdvisor structured India dataset as the default third-party
-- structured source. This is intentionally not enabled for crawling by
-- default; it is the metadata anchor for the structured import job.

insert into sources (
  kind, source_class, source_priority, name, base_url,
  tos_reviewed, is_enabled, license_note, last_verified_at, crawl_frequency
)
select
  'other',
  'third_party_structured',
  5,
  'CardAdvisor India Credit Card Facts',
  'https://cardadvisor.in/data',
  false,
  false,
  'CC BY 4.0',
  date '2026-08-16',
  interval '7 days'
where not exists (
  select 1 from sources where base_url = 'https://cardadvisor.in/data'
);

