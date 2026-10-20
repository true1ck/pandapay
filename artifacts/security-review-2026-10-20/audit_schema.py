"""Read-only local schema dictionary. Never selects customer/business rows."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
QUERY = """
BEGIN READ ONLY;
SELECT coalesce(json_agg(t ORDER BY t.table_name),'[]'::json) FROM (
 SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled,
   (SELECT json_agg(json_build_object('name',a.column_name,'type',a.data_type,
          'nullable',a.is_nullable='YES') ORDER BY a.ordinal_position)
      FROM information_schema.columns a WHERE a.table_schema='public' AND a.table_name=c.relname) AS columns,
   (SELECT coalesce(json_agg(json_build_object('name',p.policyname,'command',p.cmd,
          'using',p.qual,'check',p.with_check)),'[]'::json)
      FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=c.relname) AS policies,
   (SELECT coalesce(json_agg(pg_get_constraintdef(k.oid)),'[]'::json)
      FROM pg_constraint k WHERE k.conrelid=c.oid AND k.contype='f') AS foreign_keys,
   (SELECT count(*) FROM pg_index i WHERE i.indrelid=c.oid) AS index_count
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind='r'
) t;
COMMIT;
"""


def read(database, query):
    result = subprocess.run(['psql','-X','-q','-A','-t','-w','-h','127.0.0.1',
                             '-U','chandresh_kerkar','-d',database,'-v','ON_ERROR_STOP=1'],
                            input=query, text=True, capture_output=True, check=True)
    return result.stdout.strip()


databases = {name: json.loads(read(name, QUERY)) for name in ('pandapay','pandapay_auth')}
ledger = set(read('pandapay', 'BEGIN READ ONLY; SELECT filename FROM schema_migrations; COMMIT;').splitlines())
migrations = sorted(p.name for p in (ROOT / 'db/supabase/migrations').glob('*.sql'))
pending = [name for name in migrations if name not in ledger]
snapshot = {'date':'2026-10-20','scope':'Local PostgreSQL metadata only; not production',
            'databases': databases, 'source_migration_files':len(migrations),
            'ledger_entries':len(ledger),'pending_migrations':pending}
(OUT / 'schema-inventory.json').write_text(json.dumps(snapshot,indent=2)+'\n')
lines = ['# Local database dictionary — 2026-10-20','',
         'Metadata only: no emails, phone numbers, transaction records, bank messages, or secret values. This is not a production snapshot. Column `?` means nullable.','']
for name, tables in databases.items():
    lines += [f'## {name}', '', f'{len(tables)} public tables; {sum(t["rls_enabled"] for t in tables)} with RLS enabled.', '']
    for table in tables:
        lines += [f'### {table["table_name"]}', '',
                  f'RLS: {"enabled" if table["rls_enabled"] else "disabled"}; indexes: {table["index_count"]}.','',
                  'Columns: '+', '.join(f'`{col["name"]}{"?" if col["nullable"] else ""}` ({col["type"]})' for col in table['columns'])+'.','']
        if table['foreign_keys']:
            lines += ['Foreign keys:', ''] + [f'- `{key}`' for key in table['foreign_keys']] + ['']
        if table['policies']:
            lines += ['Policies:', ''] + [f'- `{p["name"]}` ({p["command"]}): USING `{p["using"]}`; CHECK `{p["check"]}`.' for p in table['policies']] + ['']
lines += ['## Migration drift','',f'{len(migrations)} SQL migration files in source; {len(ledger)} ledger entries (includes seeds). Pending filenames:', '']
lines += [f'- `{name}`'+(' — intentionally skipped by runner' if name=='0013_cron_jobs.sql' else '') for name in pending]
(OUT / 'schema-inventory.md').write_text('\n'.join(lines)+'\n')
print(json.dumps({'tables':{db:len(tables) for db,tables in databases.items()},
                  'migration_files':len(migrations),'ledger_entries':len(ledger),
                  'pending_non_cron':len([name for name in pending if name!='0013_cron_jobs.sql'])},indent=2))
