-- S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3): forced upgrade +
-- maintenance mode. A single-row config table rather than per-flavor rows —
-- this app has one build target today (see providers.dart's own
-- "no flavors yet" note), so one row is honest, not a placeholder for
-- multi-flavor support that doesn't exist.
create table app_status (
  id boolean primary key default true,
  min_supported_version text not null default '1.0.0',
  maintenance_mode boolean not null default false,
  maintenance_message text,
  updated_at timestamptz not null default now(),
  constraint app_status_singleton check (id)
);

insert into app_status (id, min_supported_version, maintenance_mode)
values (true, '1.0.0', false)
on conflict (id) do nothing;

alter table app_status enable row level security;

-- Public read — GET /app-status is called before a session exists (a
-- signed-out user must still see a forced-upgrade/maintenance screen), same
-- pattern as GET /catalogue's card_products_public_read (0015) and GET
-- /categories.
create policy app_status_public_read on app_status
  for select to public
  using (true);

-- No public write policy: admin_users only. Deliberately no console UI for
-- this yet — updated via direct DB access until an admin screen exists
-- (flagged, not hidden; matches this repo's existing pattern for
-- admin-only backend rows with no console coverage yet).
