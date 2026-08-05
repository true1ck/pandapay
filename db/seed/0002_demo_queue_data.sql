-- Demo data for AD-2's Request & Error queues (Chunk 8). There is no
-- user-facing submission flow yet (that's app/ future work — these queues
-- were built admin-side first per the priority list), so this seeds
-- realistic-shaped rows to prove the console queues and their approve/
-- reject/start-scraping actions against real data, not empty tables.
-- Idempotent: guarded by a marker check so re-running doesn't duplicate rows.

do $$
begin
  if not exists (select 1 from card_requests where issuer_name = 'IDFC First Bank') then
    insert into card_requests (issuer_name, product_name, network_guess, request_count, state) values
      ('IDFC First Bank', 'FIRST Millennia', 'visa', 14, 'pending'),
      ('IDFC First Bank', 'FIRST Millennia', 'visa', 1, 'pending'),
      ('Kotak Mahindra Bank', 'Kotak 811 #Dream Different', 'rupay', 6, 'pending'),
      ('American Express', 'Membership Rewards Credit Card', 'amex', 3, 'pending');
  end if;

  if not exists (select 1 from data_error_reports where source_url = 'https://www.sbicard.com/en/personal/credit-cards/shopping/cashback-sbi-card.page') then
    insert into data_error_reports (card_product_id, field_path, shown_value, claimed_value, source_url, state)
    select id,
           'reward_rules.' || (select rr.id::text from reward_rules rr
                                where rr.card_product_id = card_products.id
                                  and rr.unit = 'cashback_percent' limit 1) || '.rate',
           '5', '4.5',
           'https://www.sbicard.com/en/personal/credit-cards/shopping/cashback-sbi-card.page',
           'pending'
      from card_products where slug = 'sbi-cashback';

    insert into data_error_reports (card_product_id, field_path, shown_value, claimed_value, source_url, state)
    select id,
           'reward_rules.' || (select rr.id::text from reward_rules rr
                                where rr.card_product_id = card_products.id
                                  and rr.unit = 'points_per_100' limit 1) || '.rate',
           '5', '3',
           'https://www.icicibank.com/personal-banking/cards/credit-card/amazon-pay-credit-card',
           'pending'
      from card_products where slug = 'icici-amazon-pay';
  end if;
end $$;
