-- >>> MIGRATION 0030 — PARTNER ATTRIBUTION ====================================
--
-- Plan Phase 2.3. Card-issuer affiliate commission is the most obvious first
-- revenue line for a card-recommendation product, and there was no plumbing
-- for it anywhere: no apply URL on a card product, no click record, no
-- conversion record, no way to answer "did anyone actually apply for a card
-- we recommended". The word "affiliate" appeared nowhere in the schema, the
-- API, or the app.
--
-- ============================================================================
-- WHAT THIS DELIBERATELY DOES NOT DO
-- ============================================================================
-- It does not change what the app recommends. The ranking engine
-- (`packages/pandapay_domain`) has no access to any of these tables and must
-- never gain it. A recommendation engine that quietly weights toward the
-- cards that pay best is the exact failure mode that makes comparison sites
-- worthless, and in a product that people use to decide where to put real
-- money it would be a straightforward consumer harm. Attribution records what
-- a user chose to do; it must not influence what they are shown.
--
-- That constraint is worth stating in the schema because it is invisible in
-- the code: nothing here would break if someone joined `partner_programs`
-- into the ranking query, which is precisely why it needs to be written down.

alter table card_products
  add column if not exists apply_url text;

comment on column card_products.apply_url is
  'Issuer application page. Plain destination URL with no tracking parameters '
  '— attribution is stamped at click time by pandapay.record_partner_click() '
  'so the token is per-click and per-user, never baked into the catalogue.';

-- ---------------------------------------------------------------------------
-- Programs — the commercial terms, one row per issuer relationship
-- ---------------------------------------------------------------------------
create table if not exists partner_programs (
  id                  uuid primary key default gen_random_uuid(),
  issuer_id           uuid not null references issuers(id) on delete cascade,
  partner_name        text not null,
  -- The network's own id for us, and the query parameter it expects the
  -- click token in. Both vary per partner, so they're data, not code.
  affiliate_id        text,
  token_param         text not null default 'subid',
  payout_model        text not null default 'cpa'
                        check (payout_model in ('cpa', 'cps', 'hybrid', 'none')),
  payout_inr          numeric(12,2),
  is_active           boolean not null default false,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Clicks — one row per outbound tap
-- ---------------------------------------------------------------------------
-- Profile-scoped and therefore RLS-protected like any other user table. This
-- is NOT crowdsource data and must not be confused with it: it is a record of
-- an individual's action, kept under their own identity, and it is covered by
-- the erasure cascade below rather than by the anonymisation gate.
create table if not exists partner_clicks (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null references profiles(id) on delete cascade,
  card_product_id     uuid not null references card_products(id) on delete cascade,
  partner_program_id  uuid references partner_programs(id) on delete set null,
  -- The opaque value handed to the partner and echoed back on conversion.
  -- Random, not derived from the profile id: a token that encodes identity
  -- would leak it to the partner and to anyone who sees the URL.
  click_token         text not null unique,
  -- Where in the app the tap happened ('card_detail', 'comparison', …), so
  -- placement performance is answerable without guessing from timestamps.
  placement           text,
  clicked_at          timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Conversions — what the partner reports back
-- ---------------------------------------------------------------------------
-- No profile_id. The link to a person exists only through click_token, which
-- means revoking or deleting the click row severs it — that's the point.
create table if not exists partner_conversions (
  id                  uuid primary key default gen_random_uuid(),
  click_token         text not null,
  partner_program_id  uuid references partner_programs(id) on delete set null,
  status              text not null default 'pending'
                        check (status in ('pending', 'approved', 'rejected', 'reversed')),
  commission_inr      numeric(12,2),
  external_ref        text,
  raw_payload         jsonb not null default '{}'::jsonb,
  reported_at         timestamptz not null default now(),
  -- A partner retrying a postback must not create a second commission row.
  unique (click_token, external_ref)
);

create index if not exists idx_partner_clicks_profile on partner_clicks (profile_id, clicked_at desc);
create index if not exists idx_partner_clicks_token on partner_clicks (click_token);
create index if not exists idx_partner_conversions_token on partner_conversions (click_token);

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table partner_clicks enable row level security;
alter table partner_clicks force row level security;
drop policy if exists partner_clicks_owner on partner_clicks;
create policy partner_clicks_owner on partner_clicks
  for all to public
  using (profile_id = pandapay.uid())
  with check (profile_id = pandapay.uid());

-- Programs: readable by anyone (the app needs to know an apply link exists),
-- writable only by an admin. Commercial terms are NOT public — see the view
-- below, which is what the app actually reads.
alter table partner_programs enable row level security;
alter table partner_programs force row level security;
drop policy if exists partner_programs_admin on partner_programs;
create policy partner_programs_admin on partner_programs
  for all to public using (pandapay.is_admin()) with check (pandapay.is_admin());

-- Conversions carry commission amounts: admin-only, no user-facing path.
alter table partner_conversions enable row level security;
alter table partner_conversions force row level security;
drop policy if exists partner_conversions_admin on partner_conversions;
create policy partner_conversions_admin on partner_conversions
  for all to public using (pandapay.is_admin()) with check (pandapay.is_admin());

-- ---------------------------------------------------------------------------
-- Click recording
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER because it has to read `partner_programs` (admin-only) to
-- resolve the destination URL and token parameter, while running as the
-- signed-in user. It returns the URL to open and nothing about the commercial
-- terms — the app never learns what a click is worth, which keeps the payout
-- data out of a binary that ships to users.
create or replace function pandapay.record_partner_click(
  p_profile         uuid,
  p_card_product    uuid,
  p_placement       text default null
) returns table(out_url text, out_click_token text)
language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  v_apply_url text;
  v_issuer uuid;
  v_program partner_programs%rowtype;
  v_token text;
  v_sep text;
begin
  select apply_url, issuer_id into v_apply_url, v_issuer
    from card_products
   where id = p_card_product and status = 'published';

  if v_apply_url is null or v_apply_url = '' then
    return; -- no apply link for this card: caller returns 404, not a fake URL
  end if;

  select * into v_program from partner_programs
   where issuer_id = v_issuer and is_active
   order by created_at limit 1;

  v_token := encode(gen_random_bytes(16), 'hex');

  insert into partner_clicks (profile_id, card_product_id, partner_program_id, click_token, placement)
       values (p_profile, p_card_product, v_program.id, v_token, p_placement);

  -- Only append the tracking parameter when there is an active program to
  -- attribute to. Without one this is just the issuer's public page, and
  -- decorating it with a subid nobody reads would be noise in a URL the user
  -- can see.
  if v_program.id is null then
    return query select v_apply_url, v_token;
  end if;

  v_sep := case when position('?' in v_apply_url) > 0 then '&' else '?' end;
  return query select
    v_apply_url || v_sep || v_program.token_param || '=' || v_token
      || coalesce('&aff=' || v_program.affiliate_id, ''),
    v_token;
end $$;

-- Same reasoning as 0029's grants: EXECUTE defaults to PUBLIC, and this one
-- must stay callable by the app role, but it is granted explicitly so the
-- intended surface is stated rather than inherited.
grant execute on function pandapay.record_partner_click(uuid, uuid, text) to public;

-- ---------------------------------------------------------------------------
-- Erasure
-- ---------------------------------------------------------------------------
-- partner_clicks cascades from profiles, so DPDP §8.2 erasure already removes
-- a user's click history. partner_conversions deliberately does NOT cascade:
-- it holds no identity once the click row is gone, and a commission already
-- paid is the company's own financial record, which has its own retention
-- obligation. Stated explicitly because "delete everything" is the intuitive
-- reading and this is a considered exception to it, not an oversight.

-- ---------------------------------------------------------------------------
-- Catalogue exposure
-- ---------------------------------------------------------------------------
-- The app needs to know WHETHER a card has an apply link so it can decide to
-- show the button, but it must not receive the URL itself: the destination is
-- only ever produced by record_partner_click(), which is what guarantees a
-- click is recorded rather than the user being handed an untracked link the
-- app could open directly. So the view exposes a boolean, not the column.
--
-- Appended at the end of the select list, for the reason 0023's own header
-- gives: CREATE OR REPLACE VIEW may only add columns at the end, and dropping
-- these views would cascade through the RLS grants in 0011/0015.
create or replace view v_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.data_version, c.verified_at,
  c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
  c.art_asset, c.art_primary_color, c.point_value_inr,
  i.slug as issuer_slug, i.name as issuer_name,
  coalesce((select jsonb_agg(to_jsonb(r) - 'card_product_id') from reward_rules r
             where r.card_product_id = c.id), '[]'::jsonb) as reward_rules,
  coalesce((select jsonb_agg(to_jsonb(k) - 'card_product_id') from cap_rules k
             where k.card_product_id = c.id), '[]'::jsonb) as cap_rules,
  coalesce((select jsonb_agg(to_jsonb(m) - 'card_product_id') from milestone_rules m
             where m.card_product_id = c.id), '[]'::jsonb) as milestone_rules,
  coalesce((select jsonb_agg(to_jsonb(f) - 'card_product_id') from fee_waiver_rules f
             where f.card_product_id = c.id), '[]'::jsonb) as fee_waiver_rules,
  coalesce((select jsonb_agg(to_jsonb(b) - 'card_product_id') from card_benefits b
             where b.card_product_id = c.id), '[]'::jsonb) as benefits,
  (select to_jsonb(x) - 'card_product_id' from forex_rules x where x.card_product_id = c.id) as forex,
  (select to_jsonb(y) - 'card_product_id' from fuel_surcharge_rules y where y.card_product_id = c.id) as fuel,
  c.base_reward_unit, c.base_reward_rate,
  (c.apply_url is not null and c.apply_url <> '') as has_apply_url
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;
