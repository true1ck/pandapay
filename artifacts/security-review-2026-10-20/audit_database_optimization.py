"""Read-only LOCAL database size/usage evidence. No row values are exported."""
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
QUERY = r"""
SELECT json_build_object(
 'database_bytes',pg_database_size(current_database()),
 'stats_reset',(SELECT stats_reset FROM pg_stat_database WHERE datname=current_database()),
 'server_started_at',pg_postmaster_start_time(),
 'extensions',(SELECT json_agg(extname ORDER BY extname) FROM pg_extension),
 'tables',(SELECT json_agg(t ORDER BY t.total_bytes DESC,t.table_name) FROM (
   SELECT c.relname AS table_name,n.nspname AS schema_name,
    pg_total_relation_size(c.oid) AS total_bytes,pg_table_size(c.oid) AS table_bytes,
    pg_relation_size(c.oid) AS heap_bytes,pg_indexes_size(c.oid) AS index_bytes,
    CASE WHEN c.reltoastrelid<>0 THEN pg_total_relation_size(c.reltoastrelid) ELSE 0 END AS toast_bytes,
    s.n_live_tup AS estimated_live_rows,s.n_dead_tup AS estimated_dead_rows,
    s.seq_scan,s.seq_tup_read,s.idx_scan,s.n_tup_ins,s.n_tup_upd,s.n_tup_del,
    s.last_vacuum,s.last_autovacuum,s.last_analyze,s.last_autoanalyze,
    s.n_mod_since_analyze,c.relrowsecurity AS rls_enabled
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   LEFT JOIN pg_stat_user_tables s ON s.relid=c.oid
   WHERE n.nspname='public' AND c.relkind IN ('r','p')) t),
 'indexes',(SELECT json_agg(x ORDER BY x.table_name,x.index_name) FROM (
   SELECT t.relname AS table_name,c.relname AS index_name,pg_relation_size(c.oid) AS bytes,
    i.indisunique AS is_unique,i.indisprimary AS is_primary,i.indisvalid AS is_valid,
    i.indisready AS is_ready,s.idx_scan,s.idx_tup_read,s.idx_tup_fetch,
    pg_get_indexdef(i.indexrelid) AS definition,
    pg_get_expr(i.indpred,i.indrelid) AS predicate,
    (SELECT json_agg(k.conname) FROM pg_constraint k WHERE k.conindid=i.indexrelid) AS constraints
   FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
   JOIN pg_class t ON t.oid=i.indrelid JOIN pg_namespace n ON n.oid=t.relnamespace
   LEFT JOIN pg_stat_user_indexes s ON s.indexrelid=i.indexrelid
   WHERE n.nspname='public') x),
 'foreign_keys_without_unfiltered_btree_prefix',(SELECT coalesce(json_agg(x ORDER BY x.table_name,x.constraint_name),'[]'::json) FROM (
   SELECT t.relname AS table_name,k.conname AS constraint_name,pg_get_constraintdef(k.oid) AS definition,
    ARRAY(SELECT a.attname FROM unnest(k.conkey) WITH ORDINALITY u(num,ord)
          JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=u.num ORDER BY u.ord) AS columns
   FROM pg_constraint k JOIN pg_class t ON t.oid=k.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
   WHERE k.contype='f' AND n.nspname='public' AND NOT EXISTS (
    SELECT 1 FROM pg_index i JOIN pg_class ix ON ix.oid=i.indexrelid JOIN pg_am am ON am.oid=ix.relam
    WHERE i.indrelid=k.conrelid AND i.indisvalid AND i.indisready AND i.indpred IS NULL
      AND am.amname='btree' AND i.indnkeyatts>=cardinality(k.conkey)
      AND ARRAY(SELECT v FROM unnest(i.indkey) WITH ORDINALITY u(v,ord) WHERE ord<=cardinality(k.conkey) ORDER BY v)
          = ARRAY(SELECT v FROM unnest(k.conkey) v ORDER BY v))) x),
 'equivalent_index_pairs',(SELECT coalesce(json_agg(x),'[]'::json) FROM (
  SELECT t.relname AS table_name,a.relname AS index_a,b.relname AS index_b,
   i.indisunique AS a_unique,j.indisunique AS b_unique,
   pg_relation_size(a.oid) AS a_bytes,pg_relation_size(b.oid) AS b_bytes
  FROM pg_index i JOIN pg_index j ON i.indrelid=j.indrelid AND i.indexrelid<j.indexrelid
  JOIN pg_class a ON a.oid=i.indexrelid JOIN pg_class b ON b.oid=j.indexrelid
  JOIN pg_class t ON t.oid=i.indrelid JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='public' AND i.indkey=j.indkey AND i.indclass=j.indclass
   AND i.indoption=j.indoption AND i.indcollation=j.indcollation
   AND i.indpred::text IS NOT DISTINCT FROM j.indpred::text
   AND i.indexprs::text IS NOT DISTINCT FROM j.indexprs::text) x),
 'function_table_mentions',(SELECT coalesce(json_agg(x),'[]'::json) FROM (
  SELECT c.relname AS table_name,n.nspname||'.'||p.proname AS function_name
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  CROSS JOIN pg_class c JOIN pg_namespace cn ON cn.oid=c.relnamespace
  WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname<>'information_schema'
   AND p.prokind IN ('f','p') AND cn.nspname='public' AND c.relkind='r'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')
   AND p.prosrc ~ ('\m'||c.relname||'\M')) x)
);
"""


def read(database, query):
    response = subprocess.run(
        ['psql','-X','-q','-A','-t','-w','-h','127.0.0.1','-U','chandresh_kerkar',
         '-d',database,'-v','ON_ERROR_STOP=1'],
        input="BEGIN READ ONLY; SET LOCAL statement_timeout='20s';\n"+query+'\nCOMMIT;',
        text=True,capture_output=True,check=True)
    return json.loads(response.stdout.strip())


def ident(name):
    return '"'+name.replace('"','""')+'"'


def literal(value):
    return "'"+value.replace("'","''")+"'"


def source_mentions(table, roots):
    roots=[p for p in roots if (ROOT/p).exists()]
    result=subprocess.run(['rg','-n','-w','-F',table,*roots,
                           '-g','*.js','-g','*.py','-g','*.sql','-g','*.dart','-g','*.sh'],
                          cwd=ROOT,text=True,capture_output=True)
    if result.returncode not in (0,1):
        raise RuntimeError(result.stderr)
    # Do not retain source-line values; locations suffice for manual inspection.
    return [{'path':p,'line':int(line)} for raw in result.stdout.splitlines()
            if len(parts:=raw.split(':',2))==3 for p,line in [parts[:2]] if line.isdigit()]


def capture():
    databases={}
    source_roots=['api/src','api/scripts','auth/src','scraper','scrapers','tools','db/scripts',
                  'app/lib','console/lib','packages']
    for database in ('pandapay','pandapay_auth'):
        metadata=read(database,QUERY)
        counts_sql=' UNION ALL '.join(
            f'SELECT {literal(t["table_name"])} AS table_name,count(*) AS exact_rows FROM {ident(t["schema_name"])}.{ident(t["table_name"])}'
            for t in metadata['tables'])
        counts=read(database,'SELECT json_agg(t) FROM ('+counts_sql+') t;')
        count_map={t['table_name']:t['exact_rows'] for t in counts}
        for table in metadata['tables']:
            table['exact_rows']=count_map[table['table_name']]
            table['source_mentions']=source_mentions(table['table_name'],source_roots)
            table['schema_source_mentions']=source_mentions(table['table_name'],['db/supabase/migrations','auth/db'])
        databases[database]=metadata
    databases['pandapay']['payload_metrics']=read('pandapay',r"""
SELECT json_build_object(
 'card_products_extended_data',(SELECT json_build_object('rows',count(*),
   'non_null',count(extended_data),'stored_value_bytes',sum(pg_column_size(extended_data)),
   'json_text_bytes',sum(octet_length(extended_data::text)),
   'max_json_text_bytes',max(octet_length(extended_data::text))) FROM card_products),
 'transaction_observations_metadata',(SELECT json_build_object('rows',count(*),
   'stored_value_bytes',sum(pg_column_size(metadata)),
   'max_json_text_bytes',max(octet_length(metadata::text))) FROM transaction_observations),
 'duplicate_definitions',(SELECT json_agg(x) FROM (
   SELECT 'cap_rules' AS table_name,count(*) AS groups,coalesce(sum(n-1),0) AS extra_rows
   FROM (SELECT count(*) n FROM cap_rules GROUP BY to_jsonb(cap_rules)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
   UNION ALL SELECT 'card_benefits',count(*),coalesce(sum(n-1),0)
   FROM (SELECT count(*) n FROM card_benefits GROUP BY to_jsonb(card_benefits)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
   UNION ALL SELECT 'reward_rules',count(*),coalesce(sum(n-1),0)
   FROM (SELECT count(*) n FROM reward_rules GROUP BY to_jsonb(reward_rules)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
   UNION ALL SELECT 'milestone_rules',count(*),coalesce(sum(n-1),0)
   FROM (SELECT count(*) n FROM milestone_rules GROUP BY to_jsonb(milestone_rules)-'id'-'created_at'-'updated_at' HAVING count(*)>1) d
 ) x)
);
""")
    databases['pandapay_auth']['retention_counts']=read('pandapay_auth',r"""
SELECT json_build_object(
 'otp_requests',(SELECT json_build_object('total',count(*),
   'expired',count(*) FILTER(WHERE expires_at<now()),
   'expired_unconsumed',count(*) FILTER(WHERE expires_at<now() AND consumed_at IS NULL),
   'older_than_30_days',count(*) FILTER(WHERE created_at<now()-interval '30 days')) FROM otp_requests),
 'refresh_tokens',(SELECT json_build_object('total',count(*),
   'expired',count(*) FILTER(WHERE expires_at<now()),
   'revoked',count(*) FILTER(WHERE revoked_at IS NOT NULL),
   'expired_and_revoked',count(*) FILTER(WHERE expires_at<now() AND revoked_at IS NOT NULL)) FROM refresh_tokens)
);
""")
    snapshot={'captured_at':datetime.now(timezone.utc).isoformat(),
              'scope':'Local metadata, size/statistics and aggregate counts only; no customer values exported; not production.',
              'caveats':['Literal source mentions may be comments, table maps or another database\'s same-named table; require manual verification.',
                         'Cumulative local scan counters and zero rows do not establish production usage or obsolescence.',
                         'Missing broad FK-prefix candidates exclude partial indexes; query plans and workload are required before adding indexes.',
                         'Dead/live tuple counts are estimates, not a measured bloat percentage.'],
              'databases':databases}
    (OUT/'database-optimization-evidence.json').write_text(json.dumps(snapshot,indent=2)+'\n')
    print(json.dumps({db:{'tables':len(v['tables']),'database_bytes':v['database_bytes'],
                         'zero_row_tables':sum(t['exact_rows']==0 for t in v['tables']),
                         'fk_prefix_candidates':len(v['foreign_keys_without_unfiltered_btree_prefix']),
                         'equivalent_index_pairs':len(v['equivalent_index_pairs'])}
                      for db,v in databases.items()},indent=2))


if __name__=='__main__':
    capture()
