-- Read-only aggregates: no identifiers, bank messages, contact values or rows.
BEGIN READ ONLY;
SELECT current_database() AS database, count(*) AS public_tables
FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';
SELECT 'cap_rules' AS table_name, count(*) AS duplicate_groups, coalesce(sum(n-1),0) AS redundant_rows
FROM (SELECT count(*) n FROM cap_rules GROUP BY to_jsonb(cap_rules)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
UNION ALL
SELECT 'card_benefits', count(*), coalesce(sum(n-1),0)
FROM (SELECT count(*) n FROM card_benefits GROUP BY to_jsonb(card_benefits)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
UNION ALL
SELECT 'reward_rules', count(*), coalesce(sum(n-1),0)
FROM (SELECT count(*) n FROM reward_rules GROUP BY to_jsonb(reward_rules)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
UNION ALL
SELECT 'milestone_rules', count(*), coalesce(sum(n-1),0)
FROM (SELECT count(*) n FROM milestone_rules GROUP BY to_jsonb(milestone_rules)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d;
SELECT 'active_user_card_identity' AS group_type, count(*) AS duplicate_groups, coalesce(sum(n-1),0) AS redundant_rows
FROM (SELECT count(*) n FROM user_cards WHERE is_archived=false
      GROUP BY profile_id,card_product_id,btrim(coalesce(last4,'')) HAVING count(*)>1) d;
SELECT t.relname AS table_name, a.relname AS index_a, b.relname AS index_b,
       i.indisunique AS a_unique, j.indisunique AS b_unique
FROM pg_index i JOIN pg_index j ON i.indrelid=j.indrelid AND i.indexrelid<j.indexrelid
JOIN pg_class a ON a.oid=i.indexrelid JOIN pg_class b ON b.oid=j.indexrelid
JOIN pg_class t ON t.oid=i.indrelid JOIN pg_namespace n ON n.oid=t.relnamespace
WHERE n.nspname='public' AND i.indkey=j.indkey AND i.indclass=j.indclass
  AND i.indoption=j.indoption AND i.indcollation=j.indcollation
  AND i.indpred::text IS NOT DISTINCT FROM j.indpred::text AND i.indexprs::text IS NOT DISTINCT FROM j.indexprs::text
ORDER BY t.relname,a.relname;
SELECT count(*) AS ledger_entries, count(*) FILTER (WHERE filename NOT LIKE 'seed:%') AS migration_entries FROM schema_migrations;
COMMIT;
