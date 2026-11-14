-- Many synthetic bench users, each with their own history, for the realistic burst test:
--   psql -d pandapay_bench -v users=200 -v txns=1500 -f scripts/bench_seed_users.sql
-- LOCAL SCRATCH DATABASE ONLY (pandapay_bench). Synthetic data; users are benchu<N>@bench.invalid.
\set ON_ERROR_STOP on
DELETE FROM profiles WHERE email LIKE 'benchu%@bench.invalid';
INSERT INTO profiles (id, email, display_name)
SELECT format('b0000001-0000-4000-8000-%s', lpad(n::text, 12, '0'))::uuid, 'benchu' || n || '@bench.invalid', 'Bench ' || n
FROM generate_series(1, :users) n;
INSERT INTO user_cards (profile_id, card_product_id, nickname, last4, statement_day, due_day, credit_limit_inr)
SELECT p.id, (SELECT id FROM card_products ORDER BY id OFFSET c LIMIT 1), 'Bench card ' || c, lpad((1000 + c)::text, 4, '0'), 5 + c, 25 + c, 200000
FROM profiles p CROSS JOIN generate_series(1, 3) c WHERE p.email LIKE 'benchu%@bench.invalid';
WITH cards AS (
  SELECT profile_id, array_agg(id ORDER BY nickname) ids FROM user_cards
   WHERE profile_id IN (SELECT id FROM profiles WHERE email LIKE 'benchu%@bench.invalid') GROUP BY profile_id
), cats AS (SELECT array_agg(id ORDER BY id) a FROM spend_categories)
INSERT INTO transactions (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail, source, status, entry_kind,
                          instrument, source_key, dedupe_hash, expected_value_inr, state_applied, source_account_last4)
SELECT c.profile_id, c.ids[1 + i % 3],
       round((50 + (i * 7919) % 9000)::numeric, 2),
       now() - ((i * 13) % (540 * 24 * 60)) * interval '1 minute',
       (ARRAY['SWIGGY','ZOMATO','AMAZON','FLIPKART','UBER','BIGBASKET','NETFLIX','IRCTC','SHELL FUEL','APOLLO PHARMACY'])[1 + i % 10],
       cats.a[1 + i % array_length(cats.a, 1)],
       'online', 'sms', 'active', 'spend', 'credit_card', 'bench-' || i, 'bh-' || c.profile_id || '-' || i,
       round(((50 + (i * 7919) % 9000) * 0.01)::numeric, 2), true,
       CASE WHEN i % 2 = 0 THEN '4321' END
FROM cards c CROSS JOIN cats CROSS JOIN generate_series(1, :txns) i;
INSERT INTO transaction_observations (profile_id, transaction_id, source, source_key, observed_at, metadata)
SELECT t.profile_id, t.id, 'sms', 'obs-' || t.profile_id || '-' || t.source_key, t.occurred_at,
       jsonb_build_object('accountLast4', '4321', 'cardLast4', lpad((1000 + (abs(hashtext(t.id::text)) % 3 + 1))::text, 4, '0'))
FROM transactions t WHERE t.profile_id IN (SELECT id FROM profiles WHERE email LIKE 'benchu%@bench.invalid');
ANALYZE transactions; ANALYZE transaction_observations; ANALYZE user_cards;
SELECT count(*) AS users FROM profiles WHERE email LIKE 'benchu%@bench.invalid';
SELECT count(*) AS txns FROM transactions WHERE profile_id IN (SELECT id FROM profiles WHERE email LIKE 'benchu%@bench.invalid');
