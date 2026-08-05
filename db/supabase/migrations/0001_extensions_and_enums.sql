-- >>> MIGRATION 0001 — EXTENSIONS AND ENUMS ===================================

create extension if not exists "pgcrypto";   -- gen_random_uuid, digest
create extension if not exists "citext";     -- case-insensitive email/vpa
create extension if not exists "pg_trgm";    -- merchant fuzzy search


create schema if not exists pandapay;        -- helper functions live here
comment on schema pandapay is 'Internal helper functions; not exposed via PostgREST.';

-- ---- Card / catalogue enums -------------------------------------------------
create type card_network       as enum ('rupay','visa','mastercard','amex','diners');
create type card_type          as enum ('credit','debit','prepaid','forex');
create type publish_status     as enum ('draft','in_review','published','archived');
create type reward_unit        as enum (
  'cashback_percent',      -- x% of spend returned as cash
  'points_per_100',        -- n points per ₹100 spent
  'points_per_150',        -- n points per ₹150 spent (common: HDFC)
  'points_per_200',
  'miles_per_100',
  'flat_points',           -- fixed points per qualifying txn
  'discount_percent'       -- instant discount, not accrual
);
create type cap_period         as enum ('statement_cycle','calendar_month','quarter','half_year','annual','lifetime');
create type cap_measure        as enum ('reward_value','spend_amount','txn_count');
create type benefit_kind       as enum (
  'lounge_domestic','lounge_international','golf','concierge','insurance_travel',
  'insurance_purchase','extended_warranty','dining_program','movie','fuel_surcharge',
  'roadside_assistance','other'
);

-- ---- Transaction / tracking enums ------------------------------------------
create type txn_source         as enum ('manual','sms','email','statement','sms_bulk','imported');
create type txn_confidence     as enum ('estimated','confirmed');  -- product-plan §5.10 (R3)
create type txn_status         as enum ('active','ignored','reversed','deleted');
create type txn_rail           as enum ('upi_qr','swipe','online','contactless','atm','emi','unknown');
create type review_state       as enum ('pending','resolved','dismissed');

-- ---- Crowdsource enums ------------------------------------------------------
create type contribution_kind  as enum ('vpa_merchant','merchant_location','category_correction','acceptance','effective_rate');
create type acceptance_result  as enum ('accepted','declined','not_supported','unknown');
create type record_confidence  as enum ('unverified','low','medium','high','operator_verified');

-- ---- Admin / policy-change enums -------------------------------------------
create type source_kind        as enum ('bank_official','news_review','regulator','other');
create type scrape_status      as enum ('queued','running','success','failed','skipped_robots','skipped_unchanged');
create type alert_signal       as enum ('scrape_diff','empirical_divergence','email_keyword','user_report','manual');
create type alert_state        as enum ('open','needs_more_evidence','approved','rejected','superseded');

-- ---- Sync / platform enums --------------------------------------------------
create type sync_op            as enum ('insert','update','delete');
create type conflict_strategy  as enum ('last_write_wins','server_wins','client_wins','manual');


