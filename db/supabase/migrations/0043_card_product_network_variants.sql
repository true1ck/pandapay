-- >>> MIGRATION 0043 — VERIFIED CARD NETWORK VARIANTS =======================
-- A card product can be issued on several networks. card_products.network is
-- intentionally still the fast scalar for genuinely single-network cards;
-- this child table represents the verified alternatives for generic products
-- without choosing a false "primary" network.

begin;

create table card_product_network_variants (
  id                uuid primary key default gen_random_uuid(),
  card_product_id   uuid not null references card_products(id) on delete cascade,
  network           card_network not null,
  network_tier      text not null default 'N/A',
  label             text,
  source_url        text,
  evidence          text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint card_network_variant_must_be_known check (network::text <> 'unknown'),
  constraint card_network_variant_unique unique (card_product_id, network, network_tier)
);

comment on table card_product_network_variants is
  'Verified issued network alternatives for one generic card product. A row '
  'means the product exists on that network; it is not a separate reward '
  'product and therefore shares the parent card''s economics.';

create index idx_card_network_variants_product
  on card_product_network_variants (card_product_id) where is_active;

create trigger trg_card_network_variants_touch
  before update on card_product_network_variants
  for each row execute function pandapay.touch_updated_at();

create trigger trg_card_network_variants_version
  after insert or update or delete on card_product_network_variants
  for each row execute function pandapay.bump_card_data_version();

alter table card_product_network_variants enable row level security;
create policy card_product_network_variants_public_read
  on card_product_network_variants for select to public using (true);
create policy card_product_network_variants_admin_write
  on card_product_network_variants for all to public
  using (pandapay.is_admin()) with check (pandapay.is_admin());

-- 0042 blocked publication whenever the scalar network was unknown. A
-- verified variant set now satisfies that requirement. Constraint triggers
-- are used because a CHECK constraint cannot query a child table.
alter table card_products drop constraint if exists card_published_needs_known_network;

create or replace function pandapay.enforce_card_network_resolution()
returns trigger language plpgsql as $$
declare
  target uuid;
  target_ids uuid[];
  product_status publish_status;
  product_network card_network;
begin
  if tg_table_name = 'card_products' then
    target_ids := array[new.id];
  else
    target_ids := array[
      case when tg_op <> 'DELETE' then new.card_product_id else null end,
      case when tg_op <> 'INSERT' then old.card_product_id else null end
    ];
  end if;

  foreach target in array target_ids loop
    continue when target is null;
    select status, network into product_status, product_network
      from card_products where id = target;
    continue when not found;
    if product_status = 'published' and product_network::text = 'unknown'
       and not exists (
         select 1 from card_product_network_variants v
          where v.card_product_id = target and v.is_active
       ) then
      raise exception using
        errcode = '23514',
        message = format(
          'published card %s needs a known scalar network or at least one active verified network variant',
          target
        );
    end if;
  end loop;
  return coalesce(new, old);
end $$;

create constraint trigger trg_card_products_network_resolution
  after insert or update of status, network on card_products
  deferrable initially deferred
  for each row execute function pandapay.enforce_card_network_resolution();

create constraint trigger trg_card_network_variants_resolution
  after insert or update or delete on card_product_network_variants
  deferrable initially deferred
  for each row execute function pandapay.enforce_card_network_resolution();

-- Append variants to the public wire shape. Evidence stays admin-only; public
-- clients need only the usable network/tier/label tuple.
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
  (c.apply_url is not null and c.apply_url <> '') as has_apply_url,
  c.excluded_categories,
  coalesce((
    select jsonb_agg(
      jsonb_build_object('id', v.id, 'network', v.network,
        'network_tier', v.network_tier, 'label', v.label)
      order by v.network::text, v.network_tier
    )
    from card_product_network_variants v
    where v.card_product_id = c.id and v.is_active
  ), '[]'::jsonb) as network_variants
from card_products c
join issuers i on i.id = c.issuer_id
where c.status = 'published' and c.is_active;

create or replace view v_admin_card_catalogue_export as
select
  c.id, c.slug, c.name, c.network, c.card_type, c.status, c.data_version,
  c.verified_at, c.annual_fee_inr, c.joining_fee_inr, c.is_upi_linkable,
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
  (select to_jsonb(z) - 'card_product_id' from billing_cycle_rules z where z.card_product_id = c.id) as billing_cycle,
  coalesce((select jsonb_agg(to_jsonb(rd) - 'card_product_id') from redemption_options rd
             where rd.card_product_id = c.id), '[]'::jsonb) as redemption_options,
  c.base_reward_unit, c.base_reward_rate,
  c.extended_data,
  c.excluded_categories,
  c.import_source_hash,
  c.import_source_run_id,
  c.imported_at,
  c.import_transform_version,
  coalesce((
    select jsonb_agg(to_jsonb(v) - 'card_product_id' order by v.network::text, v.network_tier)
    from card_product_network_variants v
    where v.card_product_id = c.id and v.is_active
  ), '[]'::jsonb) as network_variants
from card_products c
join issuers i on i.id = c.issuer_id
where c.is_active;

commit;
