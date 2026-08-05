-- >>> MIGRATION 0002 — REFERENCE DATA =========================================

-- Shared trigger: maintain updated_at.
create or replace function pandapay.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create table issuers (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  name              text not null,
  short_name        text,
  logo_url          text,
  website_url       text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger trg_issuers_touch before update on issuers
  for each row execute function pandapay.touch_updated_at();

-- G4 Emergency Card Info: must work offline + logged out, so it ships to device.
create table issuer_emergency_contacts (
  id                uuid primary key default gen_random_uuid(),
  issuer_id         uuid not null references issuers(id) on delete cascade,
  label             text not null,                   -- 'Lost card (India)'
  phone             text not null,
  is_international  boolean not null default false,
  is_collect_call   boolean not null default false,
  block_procedure   text,                            -- SMS/IVR steps
  sort_order        int not null default 0,
  updated_at        timestamptz not null default now()
);

-- Internal spend taxonomy. The engine ranks on THIS, not on raw MCC.
create table spend_categories (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,            -- 'groceries','fuel','dining'
  name              text not null,
  icon              text,
  is_primary_chip   boolean not null default false,  -- shown on B1 chip row
  sort_order        int not null default 0
);

-- MCC -> category. Seeded from the ISO 18245 list; QR `mc` maps through here.
create table mcc_categories (
  mcc               char(4) primary key,
  description       text not null,
  category_id       uuid references spend_categories(id),
  is_p2p_indicator  boolean not null default false   -- helps B3 P2P detection
);


