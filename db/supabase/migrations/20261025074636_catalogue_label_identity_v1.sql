-- Additive label identity enforcement. Existing labels, IDs, states and history
-- are never rewritten or merged. Existing semantic indexes are retained.
-- Requires a protected clone review before production. A collision refuses
-- the complete transaction; it does not choose an account/rule survivor.
-- ASCII whitespace/case folding is deliberate and provider-locale independent.
-- Non-ASCII case, accents, punctuation and all other discriminators stay exact.
-- Repeated supported migration-runner calls skip this checksummed migration.
-- A manual SQL replay refuses existing v1 names for operator review.
SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';
SET LOCAL row_security=off;
LOCK TABLE public.cap_rules,public.card_benefits IN SHARE ROW EXCLUSIVE MODE;
DO $guard$
BEGIN
 IF pg_catalog.current_setting('server_version_num')::integer<150000 THEN
  RAISE EXCEPTION 'Catalogue identity requires PostgreSQL 15 or newer' USING ERRCODE='0A000';END IF;
 IF (SELECT pg_catalog.array_agg(a.attname::text ORDER BY a.attname COLLATE "C") FROM pg_catalog.pg_attribute a
      WHERE a.attrelid='public.cap_rules'::pg_catalog.regclass AND a.attnum>0 AND NOT a.attisdropped)
      IS DISTINCT FROM ARRAY['benefit_kind','cap_value','card_product_id','category_id','created_at','id','label','measure','period','post_cap_rate','post_cap_unit','resets_on_day','reward_rule_id']::text[] THEN
  RAISE EXCEPTION 'Catalogue identity schema requires reviewed update' USING ERRCODE='55000';END IF;
 IF pg_catalog.to_regclass('public.uq_cap_rules_label_identity_v1') IS NOT NULL THEN
  RAISE EXCEPTION 'Existing catalogue identity index requires reviewed migration ledger' USING ERRCODE='55000';END IF;
 IF (SELECT pg_catalog.count(*) FROM (SELECT 1 FROM public.cap_rules LIMIT 100001) bounded)>100000 THEN
  RAISE EXCEPTION 'Catalogue identity row review bound exceeded' USING ERRCODE='54000';END IF;
 IF EXISTS(SELECT 1 FROM public.cap_rules t GROUP BY t.card_product_id,t.reward_rule_id,t.category_id,t.benefit_kind,pg_catalog.translate(pg_catalog.btrim(pg_catalog.regexp_replace(t.label, E'[\011-\015 ]+', ' ', 'g')), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') COLLATE "C",t.measure,t.period,t.cap_value,t.post_cap_unit,t.post_cap_rate,t.resets_on_day HAVING pg_catalog.count(*)>1 LIMIT 1) THEN
  RAISE EXCEPTION 'Normalized catalogue collisions require reviewed ID mapping; no rows changed' USING ERRCODE='23514';END IF;
 IF (SELECT pg_catalog.array_agg(a.attname::text ORDER BY a.attname COLLATE "C") FROM pg_catalog.pg_attribute a
      WHERE a.attrelid='public.card_benefits'::pg_catalog.regclass AND a.attnum>0 AND NOT a.attisdropped)
      IS DISTINCT FROM ARRAY['card_product_id','conditions','created_at','description','id','kind','label','network_program','quota_count','quota_period','value_estimate_inr']::text[] THEN
  RAISE EXCEPTION 'Catalogue identity schema requires reviewed update' USING ERRCODE='55000';END IF;
 IF pg_catalog.to_regclass('public.uq_card_benefits_label_identity_v1') IS NOT NULL THEN
  RAISE EXCEPTION 'Existing catalogue identity index requires reviewed migration ledger' USING ERRCODE='55000';END IF;
 IF (SELECT pg_catalog.count(*) FROM (SELECT 1 FROM public.card_benefits LIMIT 100001) bounded)>100000 THEN
  RAISE EXCEPTION 'Catalogue identity row review bound exceeded' USING ERRCODE='54000';END IF;
 IF EXISTS(SELECT 1 FROM public.card_benefits t GROUP BY t.card_product_id,t.kind,pg_catalog.translate(pg_catalog.btrim(pg_catalog.regexp_replace(t.label, E'[\011-\015 ]+', ' ', 'g')), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') COLLATE "C",t.description,t.quota_count,t.quota_period,t.network_program,t.value_estimate_inr,t.conditions HAVING pg_catalog.count(*)>1 LIMIT 1) THEN
  RAISE EXCEPTION 'Normalized catalogue collisions require reviewed ID mapping; no rows changed' USING ERRCODE='23514';END IF;
END $guard$;
CREATE UNIQUE INDEX uq_cap_rules_label_identity_v1 ON public.cap_rules (card_product_id,reward_rule_id,category_id,benefit_kind,(pg_catalog.translate(pg_catalog.btrim(pg_catalog.regexp_replace(label, E'[\011-\015 ]+', ' ', 'g')), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')) COLLATE "C",measure,period,cap_value,post_cap_unit,post_cap_rate,resets_on_day) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX uq_card_benefits_label_identity_v1 ON public.card_benefits (card_product_id,kind,(pg_catalog.translate(pg_catalog.btrim(pg_catalog.regexp_replace(label, E'[\011-\015 ]+', ' ', 'g')), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')) COLLATE "C",description,quota_count,quota_period,network_program,value_estimate_inr,conditions) NULLS NOT DISTINCT;
-- No new function, definer, trigger, table or grant is introduced. Expression
-- indexes apply to every existing writer and preserve NULLS NOT DISTINCT.
