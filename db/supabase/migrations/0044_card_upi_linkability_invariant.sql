-- >>> MIGRATION 0044 — CARD UPI LINKABILITY INVARIANT =====================
-- is_upi_linkable drives whether the app offers a card for UPI QR payment.
-- It must therefore describe the selected network, not merely whether some
-- version of the product may exist on RuPay.

begin;

-- Record exactly which published values this repair changes. Migrations do
-- not run as an application admin, so admin_id is intentionally null.
insert into admin_audit_log
  (admin_id, action, entity, entity_id, before_value, after_value, reason)
select
  null,
  'repair_card_upi_linkability',
  'card_products',
  c.id,
  jsonb_build_object(
    'slug', c.slug,
    'network', c.network,
    'card_type', c.card_type,
    'is_upi_linkable', c.is_upi_linkable
  ),
  jsonb_build_object(
    'slug', c.slug,
    'network', c.network,
    'card_type', c.card_type,
    'is_upi_linkable', false
  ),
  'UPI linkability requires a RuPay credit-card network or a verified active RuPay variant.'
from card_products c
where c.is_upi_linkable
  and (
    c.card_type <> 'credit'::card_type
    or c.network not in ('rupay'::card_network, 'unknown'::card_network)
    or (
      c.network = 'unknown'::card_network
      and not exists (
        select 1
        from card_product_network_variants v
        where v.card_product_id = c.id
          and v.is_active
          and v.network = 'rupay'::card_network
      )
    )
  );

update card_products c
set is_upi_linkable = false,
    data_version = data_version + 1
where c.is_upi_linkable
  and (
    c.card_type <> 'credit'::card_type
    or c.network not in ('rupay'::card_network, 'unknown'::card_network)
    or (
      c.network = 'unknown'::card_network
      and not exists (
        select 1
        from card_product_network_variants v
        where v.card_product_id = c.id
          and v.is_active
          and v.network = 'rupay'::card_network
      )
    )
  );

-- The migration applies transform v4's UPI projection to existing imported
-- rows as well as new imports. Keep provenance aligned so an unchanged,
-- already-reviewed card remains an importer/publisher no-op.
update card_products
set import_transform_version = '4'
where import_transform_version = '3';

alter table card_products
  drop constraint if exists card_upi_linkable_requires_rupay_credit;

alter table card_products
  add constraint card_upi_linkable_requires_rupay_credit
  check (
    not is_upi_linkable
    or (
      card_type = 'credit'::card_type
      and network in ('rupay'::card_network, 'unknown'::card_network)
    )
  );

-- A CHECK cannot inspect the child variant table. Extend the existing
-- deferred network-resolution guard so an unknown linkable product must
-- still have an active verified RuPay variant at commit time. Deferral lets
-- the importer create the parent before inserting its variant rows.
create or replace function pandapay.enforce_card_network_resolution()
returns trigger language plpgsql as $$
declare
  target uuid;
  target_ids uuid[];
  product_status publish_status;
  product_network card_network;
  product_card_type card_type;
  product_is_upi_linkable boolean;
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
    select status, network, card_type, is_upi_linkable
      into product_status, product_network, product_card_type, product_is_upi_linkable
      from card_products where id = target;
    continue when not found;

    if product_status = 'published' and product_network = 'unknown'::card_network
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

    if product_is_upi_linkable
       and product_network = 'unknown'::card_network
       and not exists (
         select 1 from card_product_network_variants v
          where v.card_product_id = target
            and v.is_active
            and v.network = 'rupay'::card_network
       ) then
      raise exception using
        errcode = '23514',
        message = format(
          'UPI-linkable card %s with unknown scalar network needs an active verified RuPay variant',
          target
        );
    end if;
  end loop;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_card_products_network_resolution on card_products;
create constraint trigger trg_card_products_network_resolution
  after insert or update of status, network, card_type, is_upi_linkable on card_products
  deferrable initially deferred
  for each row execute function pandapay.enforce_card_network_resolution();

commit;
