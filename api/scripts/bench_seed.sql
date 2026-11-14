-- Synthetic bench user for scripts/bench_http.js. Run ONLY against a scratch database
-- (pandapay_bench): psql -d pandapay_bench -f scripts/bench_seed.sql
\set ON_ERROR_STOP on
INSERT INTO profiles (id, email, display_name) VALUES
  ('b0000000-0000-4000-8000-000000000001', 'bench@bench.invalid', 'Bench User')
ON CONFLICT (id) DO NOTHING;
INSERT INTO user_cards (id, profile_id, card_product_id, nickname, last4, statement_day, due_day, credit_limit_inr)
SELECT ('b1000000-0000-4000-8000-00000000000' || n)::uuid, 'b0000000-0000-4000-8000-000000000001',
       (SELECT id FROM card_products ORDER BY id OFFSET n LIMIT 1), 'Bench card ' || n, lpad((1000 + n)::text, 4, '0'), 5 + n, 25 + n, 200000
FROM generate_series(1, 3) n ON CONFLICT (id) DO NOTHING;
DELETE FROM transactions WHERE profile_id = 'b0000000-0000-4000-8000-000000000001';
INSERT INTO transactions (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail, source, status, entry_kind, instrument, source_key, dedupe_hash, expected_value_inr, state_applied, source_account_last4)
SELECT 'b0000000-0000-4000-8000-000000000001',
       ('b1000000-0000-4000-8000-00000000000' || (1 + i % 3))::uuid,
       round((50 + (i * 7919) % 9000)::numeric, 2),
       now() - ((i * 13) % (540 * 24 * 60)) * interval '1 minute',
       (ARRAY['SWIGGY','ZOMATO','AMAZON','FLIPKART','UBER','BIGBASKET','NETFLIX','IRCTC','SHELL FUEL','APOLLO PHARMACY'])[1 + i % 10],
       (SELECT id FROM spend_categories ORDER BY id OFFSET (i % (SELECT count(*) FROM spend_categories)) LIMIT 1),
       'online', 'sms', 'active', 'spend', 'credit_card', 'bench-' || i, 'benchhash-' || i,
       -- steady state: priced and applied. For the one-off "history import backlog" case run:
       --   UPDATE transactions SET expected_value_inr = NULL, state_applied = false WHERE profile_id = 'b0000000-0000-4000-8000-000000000001';
       round(((50 + (i * 7919) % 9000) * 0.01)::numeric, 2), true,
       CASE WHEN i % 2 = 0 THEN '4321' END  -- half the rows carry the account suffix, the rest need the observation lookup
FROM generate_series(1, 40000) i;
-- one SMS observation per transaction, as the SMS pipeline writes them
INSERT INTO transaction_observations (profile_id, transaction_id, source, source_key, observed_at, metadata)
SELECT profile_id, id, 'sms', 'obs-' || source_key, occurred_at,
       jsonb_build_object('accountLast4', '4321', 'cardLast4', lpad((1000 + (abs(hashtext(id::text)) % 3 + 1))::text, 4, '0'))
FROM transactions WHERE profile_id = 'b0000000-0000-4000-8000-000000000001';
ANALYZE transactions;
ANALYZE transaction_observations;
