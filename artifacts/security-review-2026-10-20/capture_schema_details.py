"""Capture local schema metadata for the offline report; never read data rows."""
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(__file__).resolve().parent
QUERY = r"""
BEGIN READ ONLY;
SELECT json_build_object(
 'schemas', (SELECT json_agg(nspname ORDER BY nspname) FROM pg_namespace
             WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'),
 'tables', (SELECT json_agg(t ORDER BY t.schema_name,t.table_name) FROM (
   SELECT n.nspname AS schema_name,c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,c.relforcerowsecurity AS rls_forced,
    obj_description(c.oid,'pg_class') AS description,
    (SELECT json_agg(json_build_object('name',a.attname,
       'type',format_type(a.atttypid,a.atttypmod),'nullable',NOT a.attnotnull,
       'default',pg_get_expr(ad.adbin,ad.adrelid),
       'description',col_description(c.oid,a.attnum)) ORDER BY a.attnum)
     FROM pg_attribute a LEFT JOIN pg_attrdef ad ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum
     WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped) AS columns,
    (SELECT coalesce(json_agg(json_build_object('name',k.conname,'kind',k.contype,
       'definition',pg_get_constraintdef(k.oid),
       'columns',(SELECT json_agg(a.attname ORDER BY u.ord) FROM unnest(k.conkey) WITH ORDINALITY u(attnum,ord)
                  JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=u.attnum),
       'target_schema',rn.nspname,'target_table',rc.relname,
       'target_columns',(SELECT json_agg(a.attname ORDER BY u.ord) FROM unnest(k.confkey) WITH ORDINALITY u(attnum,ord)
                  JOIN pg_attribute a ON a.attrelid=k.confrelid AND a.attnum=u.attnum)
       ) ORDER BY k.conname),'[]'::json)
     FROM pg_constraint k LEFT JOIN pg_class rc ON rc.oid=k.confrelid
     LEFT JOIN pg_namespace rn ON rn.oid=rc.relnamespace WHERE k.conrelid=c.oid) AS constraints,
    (SELECT coalesce(json_agg(json_build_object('name',ic.relname,'definition',pg_get_indexdef(i.indexrelid),
       'unique',i.indisunique,'primary',i.indisprimary) ORDER BY ic.relname),'[]'::json)
     FROM pg_index i JOIN pg_class ic ON ic.oid=i.indexrelid WHERE i.indrelid=c.oid) AS indexes,
    (SELECT coalesce(json_agg(json_build_object('name',p.policyname,'command',p.cmd,
       'roles',p.roles,'using',p.qual,'check',p.with_check) ORDER BY p.policyname),'[]'::json)
     FROM pg_policies p WHERE p.schemaname=n.nspname AND p.tablename=c.relname) AS policies,
    (SELECT coalesce(json_agg(json_build_object('name',tg.tgname,'definition',pg_get_triggerdef(tg.oid))
       ORDER BY tg.tgname),'[]'::json) FROM pg_trigger tg WHERE tg.tgrelid=c.oid AND NOT tg.tgisinternal) AS triggers
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r','p')
 ) t),
 'views', (SELECT coalesce(json_agg(json_build_object('schema',n.nspname,'name',c.relname,
    'materialized',c.relkind='m','definition',pg_get_viewdef(c.oid,true),
    'options',c.reloptions) ORDER BY n.nspname,c.relname),'[]'::json)
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind IN ('v','m') AND n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'),
 'enums', (SELECT coalesce(json_agg(e ORDER BY e.schema,e.name),'[]'::json) FROM (
    SELECT n.nspname AS schema,t.typname AS name,json_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
    FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace JOIN pg_enum e ON e.enumtypid=t.oid
    WHERE n.nspname NOT LIKE 'pg_%' GROUP BY n.nspname,t.typname) e),
 'functions', (SELECT coalesce(json_agg(json_build_object('schema',n.nspname,'name',p.proname,
    'arguments',pg_get_function_identity_arguments(p.oid),'returns',pg_get_function_result(p.oid),
    'security_definer',p.prosecdef) ORDER BY n.nspname,p.proname,p.oid),'[]'::json)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
    AND p.prokind IN ('f','p') AND NOT EXISTS
      (SELECT 1 FROM pg_depend dep WHERE dep.classid='pg_proc'::regclass AND dep.objid=p.oid AND dep.deptype='e'))
);
COMMIT;
"""


def capture():
    databases = {}
    for database in ('pandapay', 'pandapay_auth'):
        result = subprocess.run(
            ['psql', '-X', '-q', '-A', '-t', '-w', '-h', '127.0.0.1',
             '-U', 'chandresh_kerkar', '-d', database, '-v', 'ON_ERROR_STOP=1'],
            input=QUERY, text=True, capture_output=True, check=True)
        databases[database] = json.loads(result.stdout.strip())
    snapshot = {'captured_at': datetime.now(timezone.utc).isoformat(),
                'scope': 'Local PostgreSQL schema metadata only; not production. No data rows selected.',
                'databases': databases}
    (OUT / 'schema-details.json').write_text(json.dumps(snapshot, indent=2) + '\n')
    print(json.dumps({db: {key: len(value[key] or []) for key in
                          ('tables', 'views', 'enums', 'functions')}
                      for db, value in databases.items()}, indent=2))


if __name__ == '__main__':
    capture()
