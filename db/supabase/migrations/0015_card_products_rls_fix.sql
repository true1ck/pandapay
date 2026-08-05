-- Chunk 7 fix: card_products_public_read (0011) was `using (true)`,
-- unconditional — the only thing hiding drafts from non-admins was
-- v_card_catalogue_export's `WHERE status = 'published'` filter, which only
-- applies to callers going through that view. A direct `select * from
-- card_products` as any authenticated (non-admin) role returned draft rows.
-- Child tables (reward_rules, cap_rules, etc.) don't carry their own status —
-- they inherit visibility from their parent card_product — so they need the
-- same treatment, not just card_products itself.

drop policy card_products_public_read on card_products;
create policy card_products_public_read on card_products
  for select to public
  using (status = 'published' or pandapay.is_admin());

do $$
declare t text;
begin
  foreach t in array array[
    'reward_rules','cap_rules','milestone_rules','fee_waiver_rules',
    'card_benefits','forex_rules','fuel_surcharge_rules','billing_cycle_rules',
    'redemption_options'
  ] loop
    execute format('drop policy %1$s_public_read on %1$I', t);
    execute format(
      $f$create policy %1$s_public_read on %1$I for select to public
         using (exists (
           select 1 from card_products cp
            where cp.id = %1$I.card_product_id
              and (cp.status = 'published' or pandapay.is_admin())
         ))$f$, t);
  end loop;
end $$;
