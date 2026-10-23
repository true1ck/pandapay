#!/usr/bin/env python3
"""Build and verify private, exact-count metadata for paired PG backups."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlsplit, urlunsplit
from pathlib import Path


class SafeDiagnosticError(RuntimeError):
    """An intentionally bounded diagnostic with no SQL, URL, or row values."""


def sqlstate_from(stderr):
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", errors="replace")
    match = re.search(r"\b(?:ERROR|FATAL|PANIC):\s+([0-9A-Z]{5}):", stderr or "")
    return match.group(1) if match else "unknown"


def client_error_category(stderr):
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", errors="replace")
    message = (stderr or "").lower()
    categories = (
        (("connection refused",), "connection_refused"),
        (("could not translate host name", "name or service not known", "nodename nor servname"), "dns_failure"),
        (("password authentication failed", "no password supplied", "authentication failed"), "authentication_failed"),
        (("timed out", "timeout expired"), "connection_timeout"),
        (("server closed the connection", "connection to server was lost", "could not receive data",
          "connection reset by peer", "broken pipe", "ssl syscall error", "terminating connection"), "connection_lost"),
        (("copy command failed", "copy data failed", "invalid input syntax during copy"), "copy_protocol"),
    )
    return next((category for fragments, category in categories
                 if any(fragment in message for fragment in fragments)), "other_psql_error")


def psql_environment():
    env = os.environ.copy()
    env.setdefault("PGCONNECT_TIMEOUT", "10")
    return env


def cluster_system_identifier(url):
    try:
        rows = psql_rows(url, "SELECT system_identifier::text FROM pg_control_system()")
        return rows[0][0] if rows else None
    except SafeDiagnosticError as error:
        if "sqlstate=42501" in str(error):
            return None
        raise


def psql_json(url: str, sql: str):
    sql = snapshot_sql(url, sql)
    try:
        result = subprocess.run(
            ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--set=VERBOSITY=verbose", url, "-c", sql],
            check=True, capture_output=True, text=True, env=psql_environment(),
        )
    except subprocess.CalledProcessError as error:
        raise SafeDiagnosticError(f"catalog_json_query_failed sqlstate={sqlstate_from(error.stderr)} client_error={client_error_category(error.stderr)}") from None
    output = result.stdout.strip()
    return json.loads(output) if output else None


def psql_rows(url: str, sql: str):
    sql = snapshot_sql(url, sql)
    try:
        result = subprocess.run(
            ["psql", "-X", "-qAt", "-F", "\t", "-v", "ON_ERROR_STOP=1", "--set=VERBOSITY=verbose", url, "-c", sql],
            check=True, capture_output=True, text=True, env=psql_environment(),
        )
    except subprocess.CalledProcessError as error:
        raise SafeDiagnosticError(f"catalog_rows_query_failed sqlstate={sqlstate_from(error.stderr)} client_error={client_error_category(error.stderr)}") from None
    return [tuple(line.split("\t")) for line in result.stdout.splitlines() if line]


def parameter_grant_catalog(url):
    rows = psql_json(url, r"""
      SELECT coalesce(json_agg(json_build_array(p.parname,pg_get_userbyid(a.grantor),
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type,a.is_grantable)
        ORDER BY p.parname,pg_get_userbyid(a.grantor),
          CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
          a.privilege_type,a.is_grantable),'[]'::json)
      FROM pg_parameter_acl p
      CROSS JOIN LATERAL aclexplode(coalesce(p.paracl,ARRAY[]::aclitem[])) a
    """)
    return canonical_parameter_grants(rows)


def canonical_parameter_grants(rows):
    """Canonical grouped parameter ACL tuples; empty ACL rows have no effect."""
    if not isinstance(rows, list):
        raise ValueError("unsupported parameter ACL inventory")
    grouped = {}
    for row in rows:
        if not isinstance(row, (list, tuple)) or len(row) != 5:
            raise ValueError("unsupported parameter ACL inventory")
        name, grantor, grantee, privilege, grantable = row
        for value in (name, grantor, grantee):
            if not isinstance(value, str) or not value or "\x00" in value or re.search(r"[\x01-\x1f\x7f]", value) or len(value.encode("utf-8")) > 63:
                raise ValueError("unsupported parameter ACL identifier")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", name):
            raise ValueError("unsupported parameter ACL identifier")
        # The catalog query emits this exact uppercase token only for grantee=0.
        # Preserve all real role names byte-for-byte, including quoted casing.
        if privilege not in ("SET", "ALTER SYSTEM") or not isinstance(grantable, bool):
            raise ValueError("unsupported parameter ACL privilege")
        grouped.setdefault(name, set()).add((grantor, grantee, privilege, grantable))
    return [[name, [list(grant) for grant in sorted(grouped[name])]] for name in sorted(grouped)]


def canonical_grouped_parameter_grants(groups):
    if not isinstance(groups, list):
        raise ValueError("unsupported parameter ACL inventory")
    flat = []
    for group in groups:
        if not isinstance(group, (list, tuple)) or len(group) != 2 or not isinstance(group[1], list):
            raise ValueError("unsupported parameter ACL inventory")
        for grant in group[1]:
            if not isinstance(grant, (list, tuple)) or len(grant) != 4:
                raise ValueError("unsupported parameter ACL inventory")
            flat.append([group[0]] + list(grant))
    return canonical_parameter_grants(flat)


def validate_parameter_policy_coherence(manifest):
    policies = []
    for archive in ("product.dump", "auth.dump"):
        try:
            database = manifest["archives"][archive]["database"]
            policy = canonical_grouped_parameter_grants(database["parameter_grants"])
        except (KeyError, TypeError) as error:
            raise ValueError("unsupported parameter ACL inventory") from None
        policies.append(policy)
        database["parameter_grants"] = policy
    if policies[0] != policies[1]:
        raise ValueError("paired source databases have different cluster-wide parameter ACL policies")
    return policies[0]


def snapshot_sql(url, sql):
    for name, snapshot_name in (("PRODUCT_DATABASE_URL", "BACKUP_PRODUCT_SNAPSHOT"),
                                ("AUTH_DATABASE_URL", "BACKUP_AUTH_SNAPSHOT")):
        snapshot = os.environ.get(snapshot_name)
        if snapshot and url == os.environ.get(name):
            import re
            if not re.fullmatch(r"[A-Fa-f0-9]+-[A-Fa-f0-9]+-[0-9]+", snapshot):
                raise ValueError("invalid snapshot")
            return "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET TRANSACTION SNAPSHOT '" + snapshot + "';\nSET LOCAL search_path TO pg_catalog;\n" + sql + ";\nCOMMIT;"
    return "SET search_path TO pg_catalog;\n" + sql


def stream_table_digest(url, sql, relation):
    """Hash one table from the same exported snapshot, retrying only client-side failures."""
    sql = snapshot_sql(url, sql)
    retryable = {"connection_lost", "connection_refused", "dns_failure", "connection_timeout", "other_psql_error"}
    final_sqlstate = "unknown"
    final_client_error = "other_psql_error"
    for attempt in range(1, 4):
        digest = hashlib.sha256()
        rows = 0
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(
                ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--set=VERBOSITY=verbose", url, "-c", sql],
                stdout=subprocess.PIPE, stderr=errors, env=psql_environment(),
            )
            for chunk in iter(lambda: process.stdout.read(1024 * 1024), b""):
                digest.update(chunk)
                rows += chunk.count(b"\n")
            status = process.wait()
            if status == 0:
                return digest.hexdigest(), rows
            errors.seek(0)
            diagnostic = errors.read()
        final_sqlstate = sqlstate_from(diagnostic)
        final_client_error = client_error_category(diagnostic)
        if final_sqlstate != "unknown" or final_client_error not in retryable:
            break
        if attempt < 3:
            time.sleep(0.25)
    raise SafeDiagnosticError(
        f"source_digest_failed relation={json.dumps(relation)} attempts={attempt} "
        f"sqlstate={final_sqlstate} client_error={final_client_error}"
    )


def normalize_constraint(definition):
    # PostgreSQL can deparse varchar-literal arrays as a whole-array text cast
    # before dumping and per-element text casts after restore. Normalize only
    # these redundant unconstrained literal casts, retaining the check itself.
    value = definition.replace('::character varying::text', '::text')
    value = re.sub(r"('(?:''|[^'])*')::character varying\b", r'\1::text', value)
    return re.sub(r"(ARRAY\[(?:'(?:''|[^'])*'::text(?:,\s*)?)+\])::text\[\]", r'\1', value)


def inspect_database(url: str):
    metadata = psql_json(url, r"""
      SELECT json_build_object(
        'database', current_database(),
        'server_version', current_setting('server_version'),
        'server_version_num', current_setting('server_version_num')::int,
        'encoding', pg_encoding_to_char(d.encoding),
        'collation', d.datcollate,
        'ctype', d.datctype,
        'owner', pg_get_userbyid(d.datdba),
        'connection_limit', d.datconnlimit,
        'database_settings', (SELECT coalesce(json_agg(json_build_array(
                                  CASE WHEN s.setrole=0 THEN NULL ELSE r.rolname END,cfg.setting)
                                  ORDER BY r.rolname NULLS FIRST,cfg.setting), '[]'::json)
                            FROM pg_db_role_setting s LEFT JOIN pg_roles r ON r.oid=s.setrole
                            CROSS JOIN LATERAL unnest(s.setconfig) cfg(setting)
                            WHERE s.setdatabase=d.oid),
        'database_grants', (SELECT coalesce(json_agg(json_build_array(
                                  CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
                                  x.privilege_type,x.is_grantable)
                                  ORDER BY CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
                                                x.privilege_type), '[]'::json)
                            FROM aclexplode(coalesce(d.datacl, acldefault('d',d.datdba))) x),
        'extensions', (SELECT coalesce(json_agg(json_build_array(e.extname,e.extversion,n.nspname)
                                  ORDER BY e.extname), '[]'::json)
                       FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),
        'extension_owners', (SELECT coalesce(json_agg(json_build_array(e.extname,pg_get_userbyid(e.extowner)) ORDER BY e.extname),'[]'::json) FROM pg_extension e),
        'schema_owners', (SELECT coalesce(json_agg(json_build_array(nspname,pg_get_userbyid(nspowner)) ORDER BY nspname),'[]'::json)
                          FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname<>'information_schema'),
        'extension_function_owners', (SELECT coalesce(json_agg(json_build_array(n.nspname,p.proname,pg_get_function_identity_arguments(p.oid),p.prokind,pg_get_userbyid(p.proowner))
                            ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),'[]'::json)
                          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname !~ '^pg_' AND EXISTS(SELECT 1 FROM pg_depend x WHERE x.classid='pg_proc'::regclass AND x.objid=p.oid AND x.deptype='e')),
        'extension_relation_owners', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,c.relkind,pg_get_userbyid(c.relowner)) ORDER BY n.nspname,c.relname),'[]'::json)
                          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                          WHERE n.nspname !~ '^pg_' AND EXISTS(SELECT 1 FROM pg_depend x WHERE x.classid='pg_class'::regclass AND x.objid=c.oid AND x.deptype='e')),
        'extension_type_owners', (SELECT coalesce(json_agg(json_build_array(n.nspname,t.typname,pg_get_userbyid(t.typowner)) ORDER BY n.nspname,t.typname),'[]'::json)
                          FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
                          WHERE n.nspname !~ '^pg_' AND (t.typrelid=0 OR EXISTS(SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind='c'))
                            AND NOT(t.typelem<>0 AND t.typlen=-1)
                            AND EXISTS(SELECT 1 FROM pg_depend x WHERE x.classid='pg_type'::regclass AND x.objid=t.oid AND x.deptype='e')),
        'schemas', (SELECT coalesce(json_agg(nspname ORDER BY nspname), '[]'::json)
                    FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'),
        'columns', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid))
                                ORDER BY n.nspname,c.relname,a.attnum), '[]'::json)
                    FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
                    LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
                    WHERE a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'constraints', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,k.conname,k.contype,k.convalidated,pg_get_constraintdef(k.oid,true))
                                    ORDER BY n.nspname,c.relname,k.conname), '[]'::json)
                        FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
                        WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'indexes', (SELECT coalesce(json_agg(json_build_array(schemaname,tablename,indexname,indexdef) ORDER BY schemaname,tablename,indexname),'[]'::json)
                    FROM pg_indexes WHERE schemaname !~ '^pg_' AND schemaname <> 'information_schema'),
        'view_definitions', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,c.relkind,
                                      pg_get_viewdef(c.oid,true),c.reloptions,c.relispopulated,
                                      pg_get_userbyid(c.relowner))
                                      ORDER BY n.nspname,c.relname), '[]'::json)
                             FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                             WHERE c.relkind IN ('v','m') AND n.nspname !~ '^pg_'
                               AND n.nspname <> 'information_schema'
                               AND NOT EXISTS (SELECT 1 FROM pg_depend x WHERE x.classid='pg_class'::regclass AND x.objid=c.oid AND x.deptype='e')),
        'rls', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,c.relrowsecurity,c.relforcerowsecurity) ORDER BY n.nspname,c.relname),'[]'::json)
                FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'triggers', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,t.tgname,pg_get_triggerdef(t.oid,true)) ORDER BY n.nspname,c.relname,t.tgname),'[]'::json)
                     FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'relations', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname,c.relkind,c.relpersistence)
                                  ORDER BY n.nspname,c.relname), '[]'::json)
                      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                      WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                        AND c.relkind IN ('r','p','m','v','S','f')),
        'sequences', (SELECT coalesce(json_agg(json_build_array(n.nspname,c.relname) ORDER BY n.nspname,c.relname),'[]'::json)
                      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='S' AND n.nspname !~ '^pg_'),
        'policies', (SELECT coalesce(json_agg(json_build_array(schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check)
                                  ORDER BY schemaname,tablename,policyname), '[]'::json)
                     FROM pg_policies WHERE schemaname !~ '^pg_'),
        'functions', (SELECT coalesce(json_agg(json_build_array(n.nspname,p.proname,pg_get_function_identity_arguments(p.oid),p.prosecdef,p.proconfig)
                                  ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)), '[]'::json)
                      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                      WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'function_definitions', (SELECT coalesce(json_agg(json_build_array(n.nspname,p.proname,
                                    pg_get_function_identity_arguments(p.oid),pg_get_function_result(p.oid),
                                    l.lanname,p.provolatile,p.proisstrict,p.proparallel,p.prosecdef,
                                    p.proconfig,pg_get_userbyid(p.proowner),pg_get_functiondef(p.oid))
                                    ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)), '[]'::json)
                      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                      JOIN pg_language l ON l.oid=p.prolang
                      WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                        AND p.prokind <> 'a'
                        AND NOT EXISTS (SELECT 1 FROM pg_depend x WHERE x.classid='pg_proc'::regclass AND x.objid=p.oid AND x.deptype='e')),
        'aggregates', (SELECT coalesce(json_agg(json_build_array(n.nspname,p.proname,
                                  pg_get_function_identity_arguments(p.oid),pg_get_function_result(p.oid),
                                  a.aggkind,a.aggnumdirectargs,a.aggtransfn::regprocedure::text,
                                  a.aggfinalfn::regprocedure::text,a.aggcombinefn::regprocedure::text,
                                  a.aggserialfn::regprocedure::text,a.aggdeserialfn::regprocedure::text,
                                  a.aggmtransfn::regprocedure::text,a.aggminvtransfn::regprocedure::text,
                                  a.aggmfinalfn::regprocedure::text,a.aggfinalextra,a.aggmfinalextra,
                                  a.aggfinalmodify,a.aggmfinalmodify,
                                  a.aggsortop::regoperator::text,a.aggtranstype::regtype::text,
                                  a.aggtransspace,a.aggmtranstype::regtype::text,a.aggmtransspace,
                                  a.agginitval,a.aggminitval,pg_get_userbyid(p.proowner),p.proacl::text)
                                  ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)), '[]'::json)
                       FROM pg_aggregate a JOIN pg_proc p ON p.oid=a.aggfnoid
                       JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                         AND NOT EXISTS (SELECT 1 FROM pg_depend x WHERE x.classid='pg_proc'::regclass AND x.objid=p.oid AND x.deptype='e')),
        'user_types', (SELECT coalesce(json_agg(json_build_array(n.nspname,t.typname,t.typtype,
                                  format_type(t.oid,NULL),t.typnotnull,t.typdefault,t.typtypmod,
                                  pg_get_userbyid(t.typowner),t.typacl::text,
                                  (SELECT coalesce(json_agg(e.enumlabel ORDER BY e.enumsortorder),'[]'::json)
                                   FROM pg_enum e WHERE e.enumtypid=t.oid))
                                  ORDER BY n.nspname,t.typname), '[]'::json)
                       FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
                       WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                         AND t.typtype IN ('e','d','c','r','m')
                         AND NOT EXISTS (SELECT 1 FROM pg_depend x WHERE x.classid='pg_type'::regclass AND x.objid=t.oid AND x.deptype='e')),
        'composite_attributes', (SELECT coalesce(json_agg(json_build_array(n.nspname,t.typname,a.attname,
                                           format_type(a.atttypid,a.atttypmod),a.attnotnull,
                                           pg_get_expr(d.adbin,d.adrelid))
                                           ORDER BY n.nspname,t.typname,a.attnum), '[]'::json)
                                 FROM pg_type t JOIN pg_class c ON c.oid=t.typrelid
                                 JOIN pg_namespace n ON n.oid=t.typnamespace
                                 JOIN pg_attribute a ON a.attrelid=t.typrelid
                                 LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
                                 WHERE t.typtype='c' AND a.attnum>0 AND NOT a.attisdropped
                                   AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                                   AND NOT EXISTS (SELECT 1 FROM pg_depend x WHERE x.classid='pg_type'::regclass AND x.objid=t.oid AND x.deptype='e')),
        'domain_constraints', (SELECT coalesce(json_agg(json_build_array(n.nspname,t.typname,k.conname,k.convalidated,
                                           pg_get_constraintdef(k.oid,true))
                                           ORDER BY n.nspname,t.typname,k.conname), '[]'::json)
                                FROM pg_constraint k JOIN pg_type t ON t.oid=k.contypid
                                JOIN pg_namespace n ON n.oid=t.typnamespace
                                WHERE k.contypid<>0 AND n.nspname !~ '^pg_'
                                  AND n.nspname <> 'information_schema'),
        'range_types', (SELECT coalesce(json_agg(json_build_array(n.nspname,t.typname,
                                      format_type(r.rngsubtype,NULL),r.rngcollation::regcollation::text,
                                      r.rngsubopc::regclass::text,r.rngcanonical::regprocedure::text,
                                      r.rngsubdiff::regprocedure::text,r.rngmultitypid::regtype::text)
                                      ORDER BY n.nspname,t.typname), '[]'::json)
                        FROM pg_range r JOIN pg_type t ON t.oid=r.rngtypid
                        JOIN pg_namespace n ON n.oid=t.typnamespace
                        WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'table_grants', (SELECT coalesce(json_agg(json_build_array(
                              CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
                              n.nspname,c.relname,x.privilege_type,x.is_grantable,pg_get_userbyid(x.grantor))
                              ORDER BY n.nspname,c.relname,x.grantee::regrole::text,x.privilege_type,x.grantor::regrole::text), '[]'::json)
                         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                         CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault((CASE WHEN c.relkind='S' THEN 'S' ELSE 'r' END)::"char",c.relowner))) x
                         WHERE n.nspname !~ '^pg_' AND n.nspname<>'information_schema'
                           AND c.relkind IN ('r','p','v','m','f','S')),
        'column_grants', (SELECT coalesce(json_agg(json_build_array(
                              CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
                              n.nspname,c.relname,a.attname,x.privilege_type,x.is_grantable,pg_get_userbyid(x.grantor))
                              ORDER BY n.nspname,c.relname,a.attname,x.grantee::regrole::text,x.privilege_type,x.grantor::regrole::text), '[]'::json)
                          FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
                          CROSS JOIN LATERAL aclexplode(a.attacl) x
                          WHERE a.attnum>0 AND NOT a.attisdropped AND n.nspname !~ '^pg_' AND n.nspname<>'information_schema'),
        'routine_grants', (SELECT coalesce(json_agg(json_build_array(n.nspname,p.proname,pg_get_function_identity_arguments(p.oid),
                              (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(x.grantor),
                                CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,x.privilege_type,x.is_grantable)
                                ORDER BY x.grantor::regrole::text,x.grantee::regrole::text,x.privilege_type),'[]'::json)
                               FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x))
                              ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)), '[]'::json)
                           FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'schema_grants', (SELECT coalesce(json_agg(json_build_array(n.nspname,
                              (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(x.grantor),
                                CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,x.privilege_type,x.is_grantable)
                                ORDER BY x.grantor::regrole::text,x.grantee::regrole::text,x.privilege_type),'[]'::json)
                               FROM aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) x)) ORDER BY n.nspname), '[]'::json)
                          FROM pg_namespace n WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
        'default_acl', (SELECT coalesce(json_agg(json_build_array(n.nspname,pg_get_userbyid(d.defaclrole),d.defaclobjtype,
                              (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(x.grantor),
                                CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,x.privilege_type,x.is_grantable)
                                ORDER BY x.grantor::regrole::text,x.grantee::regrole::text,x.privilege_type),'[]'::json)
                               FROM aclexplode(d.defaclacl) x))
                              ORDER BY n.nspname,pg_get_userbyid(d.defaclrole),d.defaclobjtype), '[]'::json)
                        FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace),
        'role_attributes', (SELECT coalesce(json_agg(json_build_array(rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit)
                                             ORDER BY rolname), '[]'::json)
                            FROM pg_roles WHERE rolname !~ '^pg_'),
        'role_memberships', (SELECT coalesce(json_agg(json_build_array(r.rolname,m.rolname,a.admin_option,a.inherit_option,a.set_option)
                                               ORDER BY r.rolname,m.rolname), '[]'::json)
                             FROM pg_auth_members a
                             JOIN pg_roles r ON r.oid=a.roleid
                             JOIN pg_roles m ON m.oid=a.member
                             WHERE TRUE),
        'migration_ledgers', json_build_object(
          'product', to_regclass('public.schema_migrations') IS NOT NULL,
          'auth', to_regclass('public.auth_schema_migrations') IS NOT NULL)
      )
      FROM pg_database d WHERE d.datname=current_database()
    """)
    # Parameter ACLs are cluster-wide rather than database-local. Keep only
    # the effective non-empty grant tuples; REVOKE may leave an empty catalog
    # row that is equivalent to no grant.
    metadata["parameter_grants"] = parameter_grant_catalog(url)
    # Exact table counts catch successful-looking but incomplete restores.
    counts = {}
    digests = {}
    relations = psql_rows(url, """
      SELECT n.nspname,c.relname,c.relkind
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
        AND c.relkind IN ('r','p','m','f')
      ORDER BY n.nspname,c.relname
    """)
    if any(kind == "f" for _, _, kind in relations):
        raise ValueError("foreign tables require a separately verified export and are not covered by pg_dump data")
    for schema, relation, _kind in relations:
        ident = '"' + schema.replace('"', '""') + '"."' + relation.replace('"', '""') + '"'
        # Canonical JSON with bytewise ordering, streamed through Python rather
        # than loading the table into agent/process memory. COPY text escapes
        # embedded newlines, leaving one physical newline per source row. Hash
        # and count in the same stream and exported snapshot as pg_dump.
        sql = f'COPY (SELECT to_jsonb(t)::text AS row FROM {ident} t ORDER BY to_jsonb(t)::text COLLATE "C") TO STDOUT'
        digests[f"{schema}.{relation}"], counts[f"{schema}.{relation}"] = stream_table_digest(url, sql, schema + "." + relation)
    sequence_states = {}
    for schema, sequence in psql_rows(url, """
      SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.relkind='S' AND n.nspname !~ '^pg_' ORDER BY n.nspname,c.relname
    """):
        ident = '"' + schema.replace('"', '""') + '"."' + sequence.replace('"', '""') + '"'
        state = psql_rows(url, f"SELECT last_value,is_called FROM {ident}")
        sequence_states[f"{schema}.{sequence}"] = [int(state[0][0]), state[0][1] == "t"]
    # Migration ledger rows are application state too; capture exact values.
    ledgers = {}
    for table in ("schema_migrations", "auth_schema_migrations"):
        exists = psql_rows(url, "SELECT to_regclass('public." + table + "') IS NOT NULL")
        if exists and exists[0][0] == "t":
            ledgers[table] = psql_json(url, f"SELECT coalesce(json_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::json) FROM public.{table} t")
    metadata["exact_row_counts"] = counts
    metadata["canonical_row_sha256"] = digests
    metadata["sequence_states"] = sequence_states
    metadata["migration_ledgers"] = ledgers
    # Include roles required for object ownership, ACLs, RLS policies and
    # SECURITY DEFINER routines. A provider bootstrap must create these before
    # pg_restore; source cluster globals are never imported automatically.
    dependencies = psql_rows(url, r"""
      SELECT DISTINCT role_name FROM (
        SELECT pg_get_userbyid(d.datdba) AS role_name FROM pg_database d WHERE d.datname=current_database()
        UNION ALL SELECT r.rolname FROM pg_db_role_setting s JOIN pg_roles r ON r.oid=s.setrole
          JOIN pg_database d ON d.oid=s.setdatabase WHERE d.datname=current_database()
        UNION ALL SELECT CASE WHEN grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(grantee) END
          FROM pg_database d CROSS JOIN LATERAL aclexplode(coalesce(d.datacl, acldefault('d',d.datdba))) a
          WHERE d.datname=current_database()
        UNION ALL SELECT pg_get_userbyid(n.nspowner) FROM pg_namespace n
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
        UNION ALL SELECT pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'

        UNION ALL SELECT pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'

        UNION ALL SELECT pg_get_userbyid(t.typowner) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'

        UNION ALL SELECT CASE WHEN grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(grantee) END
          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault((CASE WHEN c.relkind='S' THEN 'S' ELSE 'r' END)::"char",c.relowner))) a
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'

        UNION ALL SELECT CASE WHEN grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(grantee) END
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'

        UNION ALL SELECT CASE WHEN grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(grantee) END
          FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n',n.nspowner))) a
          WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
        UNION ALL SELECT unnest(roles)::text FROM pg_policies WHERE schemaname !~ '^pg_'
        UNION ALL SELECT pg_get_userbyid(d.defaclrole) FROM pg_default_acl d
        UNION ALL SELECT CASE WHEN grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(grantee) END
          FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) a
        UNION ALL SELECT pg_get_userbyid(a.grantor) FROM pg_parameter_acl p
          CROSS JOIN LATERAL aclexplode(coalesce(p.paracl,ARRAY[]::aclitem[])) a
        UNION ALL SELECT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END
          FROM pg_parameter_acl p CROSS JOIN LATERAL aclexplode(coalesce(p.paracl,ARRAY[]::aclitem[])) a
      ) required WHERE role_name IS NOT NULL AND role_name !~ '^pg_' ORDER BY role_name
    """)
    roles = {row[0] for row in dependencies if row[0].upper() != "PUBLIC"}
    roles.update(row[1] for row in metadata.get('extension_owners', []))
    for key in ('table_grants', 'column_grants'):
        roles.update(row[-1] for row in metadata.get(key, []))
    for key in ('routine_grants', 'schema_grants', 'default_acl'):
        for row in metadata.get(key, []):
            for grant in row[-1] or []:
                roles.update(grant[:2])
    parameter_roles = {role for _parameter, grants in metadata.get('parameter_grants', [])
                       for grantor, grantee, _privilege, _grantable in grants
                       for role in (grantor, grantee) if role.upper() != 'PUBLIC'}
    metadata["required_roles"] = sorted(name for name in (roles | parameter_roles)
                                        if name.upper() != 'PUBLIC' and
                                        (not name.startswith('pg_') or name in parameter_roles))
    for policy in metadata.get('policies', []):
        policy[4] = sorted(policy[4])
    # PostgreSQL exposes the immutable cluster identity only to sufficiently
    # privileged roles. Preserve it when available; restore requires an
    # explicit operator attestation when either endpoint hides it.
    metadata["cluster_system_identifier"] = cluster_system_identifier(url)
    required_role_set = set(metadata["required_roles"])
    metadata["required_role_attributes"] = [
        role for role in metadata.get("role_attributes", []) if role[0] in required_role_set
    ]
    metadata["required_role_memberships"] = [
        membership for membership in metadata.get("role_memberships", [])
        if membership[0] in required_role_set or membership[1] in required_role_set
    ]
    for constraint in metadata.get('constraints', []):
        constraint[-1] = normalize_constraint(constraint[-1])
    for constraint in metadata.get('domain_constraints', []):
        constraint[-1] = normalize_constraint(constraint[-1])
    # Capture all role names/attributes as a private inventory, but compare
    # only roles referenced by application ACLs. Provider/system roles can
    # legitimately differ between PostgreSQL hosts and are never imported.
    needed_roles = {"PUBLIC"}
    for grant_key, grant_role_index in (("table_grants", 0), ("column_grants", 0)):
        for grant in metadata.get(grant_key, []):
            needed_roles.add(grant[grant_role_index])
    metadata["application_role_attributes"] = [
        role for role in metadata.get("role_attributes", []) if role[0] in needed_roles
    ]
    metadata["application_role_memberships"] = [
        membership for membership in metadata.get("role_memberships", [])
        if membership[0] in needed_roles or membership[1] in needed_roles
    ]
    return metadata


def sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sql_ident(value):
    return '"' + str(value).replace('"', '""') + '"'


def sql_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_psql(url, sql):
    with tempfile.TemporaryFile() as errors:
        result = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "--set=VERBOSITY=verbose", url],
                                input=";\n".join(sql) + ";\n", text=True,
                                stdout=subprocess.DEVNULL, stderr=errors)
        if result.returncode:
            errors.seek(0)
            diagnostic = errors.read()
            raise SafeDiagnosticError(f"target_postgresql_operation_failed sqlstate={sqlstate_from(diagnostic)} client_error={client_error_category(diagnostic)}")


def load_manifest(path):
    manifest = json.loads(path.read_text())
    if manifest.get("format") != "pandapay-paired-postgresql-backup-v5":
        raise ValueError("unsupported backup manifest format; a fresh paired v5 backup is required")
    if not isinstance(manifest.get("dump_client_major"), int):
        raise ValueError("unsupported backup manifest format")
    validate_parameter_policy_coherence(manifest)
    return manifest


def dump_client_version():
    try:
        result = subprocess.run(["pg_dump", "--version"], check=True, capture_output=True,
                                text=True, env=psql_environment())
    except subprocess.CalledProcessError as error:
        raise SafeDiagnosticError(f"pg_dump_version_query_failed client_error={client_error_category(error.stderr)}") from None
    match = re.search(r"PostgreSQL\)?\s+(\d+)(?:\.(\d+))?", result.stdout)
    if not match:
        raise ValueError("unsupported pg_dump client version output")
    return {"version": match.group(1) + ("." + match.group(2) if match.group(2) else ""),
            "major": int(match.group(1))}


def validate_restore_major(target_version_num, source_version_num, dump_client_major):
    target_major = int(target_version_num) // 10000
    source_major = int(source_version_num) // 10000
    minimum_major = max(source_major, int(dump_client_major))
    if target_major < minimum_major:
        raise ValueError("restore target major version is older than source or pg_dump client")


def validate_target_roles(manifest, urls):
    missing = set()
    mismatched = set()
    for env_name, archive in zip(urls, ("product.dump", "auth.dump")):
        url = os.environ[env_name]
        expected = manifest["archives"][archive]["database"]
        required = set(expected.get("required_roles", []))
        required_builtin_roles = sorted(name for name in required if name.startswith("pg_"))
        role_filter = "rolname !~ '^pg_'"
        if required_builtin_roles:
            role_filter += " OR rolname IN (" + ",".join(sql_literal(name) for name in required_builtin_roles) + ")"
        actual_attributes = psql_rows(url, "SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit FROM pg_roles WHERE " + role_filter + " ORDER BY rolname")
        actual_by_name = {row[0]: list(row) for row in actual_attributes}
        missing.update(required - set(actual_by_name))
        expected_by_name = {row[0]: row for row in expected.get("required_role_attributes", [])}
        for name in required & set(actual_by_name) & set(expected_by_name):
            source = expected_by_name[name]
            normalized = [str(source[0])] + ["t" if value else "f" for value in source[1:8]] + [str(source[8])]
            if normalized != actual_by_name[name]:
                mismatched.add(name)
        memberships = psql_rows(url, "SELECT r.rolname,m.rolname,a.admin_option,a.inherit_option,a.set_option FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member ORDER BY r.rolname,m.rolname")
        actual_memberships = [list(row) for row in memberships if row[0] in required or row[1] in required]
        source_memberships = [[row[0], row[1], "t" if row[2] else "f", "t" if row[3] else "f", "t" if row[4] else "f"]
                              for row in expected.get("required_role_memberships", [])]
        if sorted(actual_memberships) != sorted(source_memberships):
            mismatched.update(required)
    if missing:
        raise ValueError("recovery role bootstrap is missing required source roles: " + ", ".join(sorted(missing)))
    if mismatched:
        raise ValueError("recovery role attributes or memberships differ for required roles: " + ", ".join(sorted(mismatched)))


def validate_cluster_independence(manifest, admin_url):
    source_ids = {manifest["archives"][name]["database"].get("cluster_system_identifier")
                  for name in ("product.dump", "auth.dump")}
    source_ids.discard(None)
    target_id = cluster_system_identifier(admin_url)
    target_ids = {target_id} if target_id else set()
    if source_ids and target_ids:
        if source_ids & target_ids:
            raise ValueError("recovery endpoint has the same PostgreSQL cluster identity as the source")
        return
    if os.environ.get("RESTORE_INDEPENDENCE_ATTESTATION") != "I_HAVE_VERIFIED_A_DIFFERENT_POSTGRES_CLUSTER":
        raise ValueError("cluster identity is unavailable; set RESTORE_INDEPENDENCE_ATTESTATION only after independently verifying the recovery cluster")


PARAMETER_ACL_ATTESTATION = "I_HAVE_VERIFIED_FRESH_ISOLATED_RECOVERY_CLUSTER"


def url_database_name(url):
    name = unquote(urlsplit(url).path.lstrip("/"))
    if not name or "/" in name or "\x00" in name:
        raise ValueError("restore database URL does not contain a valid database name")
    return name


def url_for_database(url, database_name):
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, "/" + database_name, parts.query, ""))


def validate_parameter_acl_target(manifest, admin_url, allowed_database_names=None):
    validate_parameter_policy_coherence(manifest)
    if os.environ.get("RESTORE_PARAMETER_ACL_ATTESTATION") != PARAMETER_ACL_ATTESTATION:
        raise ValueError("fresh isolated cluster attestation is required for global parameter ACL changes")
    connected_database = psql_rows(admin_url, "SELECT current_database()")
    if connected_database != [("postgres",)]:
        raise ValueError("fresh-cluster admin connection must use the postgres database")
    relation_inventory_sql = r"""
      SELECT count(*)::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.relkind IN ('r','p','v','m','f','S')
        AND n.nspname <> 'information_schema'
        AND n.nspname !~ '^pg_(catalog|toast|temp|toast_temp)'
    """
    user_relations = psql_rows(admin_url, relation_inventory_sql)
    if user_relations != [("0",)]:
        raise ValueError("fresh-cluster admin database contains user relations; global ACL replay is refused")
    template_relations = psql_rows(url_for_database(admin_url, "template1"), relation_inventory_sql)
    if template_relations != [("0",)]:
        raise ValueError("fresh-cluster template1 contains user relations; global ACL replay is refused")
    default_databases = {"postgres", "template0", "template1"}
    allowed = default_databases | set(allowed_database_names or ())
    actual = {row[0] for row in psql_rows(admin_url, "SELECT datname FROM pg_database ORDER BY datname")}
    if actual != allowed:
        raise ValueError("target cluster contains databases outside the fresh isolated restore set")


def order_parameter_grants(groups, superusers):
    """Topologically seed grant-option chains, or reject unsupported policies."""
    pending = sorted((name, grantor, grantee, privilege, grantable)
                     for name, grants in groups
                     for grantor, grantee, privilege, grantable in grants)
    ordered = []
    grant_options = set()
    while pending:
        ready = [row for row in pending
                 if row[1] in superusers or (row[0], row[1], row[3]) in grant_options]
        if not ready:
            raise ValueError("unsupported parameter ACL grantor chain")
        for row in ready:
            pending.remove(row)
            ordered.append(row)
            name, _grantor, grantee, privilege, grantable = row
            if grantable:
                if grantee == "PUBLIC":
                    raise ValueError("unsupported parameter ACL grant option to PUBLIC")
                grant_options.add((name, grantee, privilege))
    return ordered


def parameter_grantor_superusers(data):
    return {row[0] for row in data.get("role_attributes", []) if len(row) > 1 and row[1] is True}


def restore_parameter_acls(manifest, admin_url, product_url, auth_url):
    """Replace cluster-wide parameter grants on a fresh isolated target only."""
    source = validate_parameter_policy_coherence(manifest)
    allowed_databases = {url_database_name(product_url), url_database_name(auth_url)}
    validate_parameter_acl_target(manifest, admin_url, allowed_databases)
    product_data = manifest["archives"]["product.dump"]["database"]
    auth_data = manifest["archives"]["auth.dump"]["database"]
    superusers = parameter_grantor_superusers(product_data) | parameter_grantor_superusers(auth_data)
    source_order = order_parameter_grants(source, superusers)

    current = parameter_grant_catalog(admin_url)
    target_superusers = {row[0] for row in psql_rows(admin_url, "SELECT rolname FROM pg_roles WHERE rolsuper ORDER BY rolname")}
    revoke_order = list(reversed(order_parameter_grants(current, target_superusers)))
    statements = ["BEGIN"]
    for name, grantor, grantee, privilege, _grantable in revoke_order:
        role = "PUBLIC" if grantee == "PUBLIC" else sql_ident(grantee)
        statements.extend((f"SET SESSION AUTHORIZATION {sql_ident(grantor)}",
                           f"REVOKE {privilege} ON PARAMETER {sql_ident(name)} FROM {role} CASCADE",
                           "RESET SESSION AUTHORIZATION"))
    for name, grantor, grantee, privilege, grantable in source_order:
        role = "PUBLIC" if grantee == "PUBLIC" else sql_ident(grantee)
        statements.extend((f"SET SESSION AUTHORIZATION {sql_ident(grantor)}",
                           f"GRANT {privilege} ON PARAMETER {sql_ident(name)} TO {role}" +
                           (" WITH GRANT OPTION" if grantable else ""),
                           "RESET SESSION AUTHORIZATION"))
    statements.append("COMMIT")
    run_psql(admin_url, statements)


def create_target_database(manifest, archive, database_name, admin_url):
    data = manifest["archives"][archive]["database"]
    database = sql_ident(database_name)
    owner = sql_ident(data["owner"])
    encoding = sql_literal(data.get("encoding", "UTF8"))
    collation = sql_literal(data["collation"])
    ctype = sql_literal(data["ctype"])
    run_psql(admin_url, [f"CREATE DATABASE {database} OWNER {owner} TEMPLATE template0 "
                         f"ENCODING {encoding} LC_COLLATE {collation} LC_CTYPE {ctype}"])
    try:
        statements = [f"ALTER DATABASE {database} CONNECTION LIMIT {int(data['connection_limit'])}"]
        settings = []
        for role, entry in data.get("database_settings", []):
            if "=" not in entry:
                raise ValueError("unsupported database setting inventory")
            key, value = entry.split("=", 1)
            settings.append((role, key, value))
        target_settings = psql_rows(admin_url, "SELECT coalesce(r.rolname,''),cfg.setting FROM pg_db_role_setting s LEFT JOIN pg_roles r ON r.oid=s.setrole CROSS JOIN LATERAL unnest(s.setconfig) cfg(setting) JOIN pg_database d ON d.oid=s.setdatabase WHERE d.datname=" + sql_literal(database_name))
        expected_keys = {(role or '', key) for role, key, _ in settings}
        for role, entry in target_settings:
            key = entry.split("=", 1)[0]
            if (role, key) not in expected_keys:
                if role:
                    statements.append(f"ALTER ROLE {sql_ident(role)} IN DATABASE {database} RESET {sql_ident(key)}")
                else:
                    statements.append(f"ALTER DATABASE {database} RESET {sql_ident(key)}")
        for role, key, value in settings:
            if role:
                statements.append(f"ALTER ROLE {sql_ident(role)} IN DATABASE {database} SET {sql_ident(key)} TO {sql_literal(value)}")
            else:
                statements.append(f"ALTER DATABASE {database} SET {sql_ident(key)} TO {sql_literal(value)}")
        # CREATE DATABASE gives PUBLIC default CONNECT/TEMPORARY. Reset it, then
        # apply the captured effective source ACL without importing cluster ACLs.
        statements.append(f"REVOKE ALL ON DATABASE {database} FROM PUBLIC")
        privileges = {"CONNECT", "CREATE", "TEMPORARY"}
        for grantee, privilege, grantable in data.get("database_grants", []):
            if grantee == data["owner"]:
                continue  # ownership supplies the owner's implicit privileges
            if privilege not in privileges:
                raise ValueError("unsupported database privilege in source inventory")
            role = "PUBLIC" if grantee.upper() == "PUBLIC" else sql_ident(grantee)
            suffix = " WITH GRANT OPTION" if grantable else ""
            statements.append(f"GRANT {privilege} ON DATABASE {database} TO {role}{suffix}")
        run_psql(admin_url, statements)
    except Exception:
        try:
            run_psql(admin_url, [f"DROP DATABASE IF EXISTS {database}"])
        except Exception:
            pass
        raise


def prepare_target_extensions(manifest, archive, url):
    """Create schemas/extensions with original owners in a fresh recovery DB."""
    data = manifest["archives"][archive]["database"]
    owners = dict(data.get("extension_owners", []))
    attributes = {row[0]: row for row in data.get("role_attributes", [])}
    existing = dict(psql_rows(url, "SELECT e.extname,pg_get_userbyid(e.extowner) FROM pg_extension e"))
    needs_role_bootstrap = any(name not in existing and not attributes[owners[name]][1]
                               for name, _, _ in data.get("extensions", []))
    if needs_role_bootstrap and os.environ.get("RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION") != "THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER":
        raise ValueError("extension role bootstrap requires an isolated disposable recovery cluster attestation")
    statements = []
    for name, owner in data.get("schema_owners", []):
        statements.extend((f"CREATE SCHEMA IF NOT EXISTS {sql_ident(name)} AUTHORIZATION {sql_ident(owner)}",
                           f"ALTER SCHEMA {sql_ident(name)} OWNER TO {sql_ident(owner)}"))
    if statements:
        run_psql(url, statements)
    for name, version, schema in data.get("extensions", []):
        owner = owners[name]
        if name in existing:
            if existing[name] != owner:
                raise ValueError("existing target extension owner differs; initialize the recovery cluster with the source bootstrap owner")
            continue
        original_superuser = attributes[owner][1]
        try:
            run_psql(url, [f"ALTER ROLE {sql_ident(owner)} SUPERUSER",
                           f"SET SESSION AUTHORIZATION {sql_ident(owner)}",
                           f"CREATE EXTENSION {sql_ident(name)} WITH SCHEMA {sql_ident(schema)} VERSION {sql_literal(version)}"])
        finally:
            if not original_superuser:
                run_psql(url, [f"ALTER ROLE {sql_ident(owner)} NOSUPERUSER"])
    # Trusted extension scripts can create members as the bootstrap superuser;
    # their owners are separately captured and restored, independent of the
    # role that owns the extension itself.
    statements = []
    for schema, name, arguments, kind, owner in data.get("extension_function_owners", []):
        object_type = {"p": "PROCEDURE", "a": "AGGREGATE"}.get(kind, "FUNCTION")
        if kind == "a" and not arguments:
            arguments = "*"
        statements.append(f"ALTER {object_type} {sql_ident(schema)}.{sql_ident(name)}({arguments}) OWNER TO {sql_ident(owner)}")
    for schema, name, kind, owner in data.get("extension_relation_owners", []):
        if kind not in ("r", "p", "v", "m", "S", "f"):
            continue  # Index/composite relation ownership follows its parent.
        object_type = {"v": "VIEW", "m": "MATERIALIZED VIEW", "S": "SEQUENCE", "f": "FOREIGN TABLE"}.get(kind, "TABLE")
        statements.append(f"ALTER {object_type} {sql_ident(schema)}.{sql_ident(name)} OWNER TO {sql_ident(owner)}")
    for schema, name, owner in data.get("extension_type_owners", []):
        statements.append(f"ALTER TYPE {sql_ident(schema)}.{sql_ident(name)} OWNER TO {sql_ident(owner)}")
    if statements:
        run_psql(url, statements)


def restore_schema_acls(manifest, archive, url):
    """Replay catalog ACLs, including provider initial grants omitted by dumps."""
    data = manifest["archives"][archive]["database"]
    owners = dict(data["schema_owners"])
    current = {}
    for schema, grantee in psql_rows(url, """
        SELECT n.nspname,CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END
        FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) x
        WHERE n.nspname !~ '^pg_' AND n.nspname<>'information_schema'
    """):
        current.setdefault(schema, set()).add(grantee)
    statements = ["BEGIN"]
    for schema, grants in data["schema_grants"]:
        owner = owners[schema]
        # Validate the entire ACL before making any target mutation.
        if any(privilege not in ("CREATE", "USAGE") or not isinstance(grantable, bool)
               for grantor, grantee, privilege, grantable in grants):
            raise ValueError("unsupported schema privilege inventory")
        statements.append(f"SET SESSION AUTHORIZATION {sql_ident(owner)}")
        grantees = current.get(schema, set()) | {row[1] for row in grants} | {"PUBLIC", owner}
        for grantee in sorted(grantees):
            role = "PUBLIC" if grantee == "PUBLIC" else sql_ident(grantee)
            statements.append(f"REVOKE ALL PRIVILEGES ON SCHEMA {sql_ident(schema)} FROM {role} CASCADE")
        statements.append("RESET SESSION AUTHORIZATION")
        # The owner seeds grant-option chains before delegated grantors. Any
        # unsupported chain fails closed and must be reviewed by the operator.
        for grantor, grantee, privilege, grantable in sorted(grants, key=lambda row: (row[0] != owner, not row[3], row[0], row[1], row[2])):
            role = "PUBLIC" if grantee == "PUBLIC" else sql_ident(grantee)
            statements.extend((f"SET SESSION AUTHORIZATION {sql_ident(grantor)}",
                               f"GRANT {privilege} ON SCHEMA {sql_ident(schema)} TO {role}" +
                               (" WITH GRANT OPTION" if grantable else ""),
                               "RESET SESSION AUTHORIZATION"))
    statements.append("COMMIT")
    run_psql(url, statements)


def validation_category(error):
    message = str(error)
    categories = (
        ("foreign tables require", "foreign_tables_require_separate_export"),
        ("unsupported backup manifest format", "unsupported_manifest_version"),
        ("recovery role bootstrap is missing", "required_recovery_roles_missing"),
        ("recovery role attributes or memberships differ", "required_recovery_roles_mismatch"),
        ("recovery endpoint has the same PostgreSQL cluster identity", "same_cluster_identity"),
        ("cluster identity is unavailable", "independence_attestation_required"),
        ("unsupported database setting", "unsupported_database_setting"),
        ("unsupported database privilege", "unsupported_database_privilege"),
        ("invalid snapshot", "invalid_snapshot_id"),
        ("restored schema/data/grants inventory differs", "restored_inventory_mismatch"),
        ("restore target major version is older", "target_postgresql_version_too_old"),
        ("extension role bootstrap requires", "isolated_extension_bootstrap_attestation_required"),
        ("paired source databases have different cluster-wide parameter ACL policies", "parameter_acl_source_pair_mismatch"),
        ("fresh isolated cluster attestation is required", "parameter_acl_isolation_attestation_required"),
        ("target cluster contains databases outside", "parameter_acl_target_not_fresh_isolated"),
        ("unsupported parameter ACL", "unsupported_parameter_acl_policy"),
    )
    return next((category for prefix, category in categories if message.startswith(prefix)), "validation_failed")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    create = sub.add_parser("create")
    create.add_argument("--product-url-env", required=True)
    create.add_argument("--auth-url-env", required=True)
    create.add_argument("--product-dump", type=Path, required=True)
    create.add_argument("--auth-dump", type=Path, required=True)
    create.add_argument("--set-id", required=True)
    create.add_argument("--output", type=Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--product-url-env", required=True)
    verify.add_argument("--auth-url-env", required=True)
    verify.add_argument("--product-dump", type=Path, required=True)
    verify.add_argument("--auth-dump", type=Path, required=True)
    validate = sub.add_parser("validate-target")
    validate.add_argument("--manifest", type=Path, required=True)
    validate.add_argument("--admin-url-env", required=True)
    validate.add_argument("--product-url-env", required=True)
    validate.add_argument("--auth-url-env", required=True)
    independence = sub.add_parser("validate-independence")
    independence.add_argument("--manifest", type=Path, required=True)
    independence.add_argument("--admin-url-env", required=True)
    rolecheck = sub.add_parser("validate-roles")
    rolecheck.add_argument("--manifest", type=Path, required=True)
    rolecheck.add_argument("--product-url-env", required=True)
    rolecheck.add_argument("--auth-url-env", required=True)
    create_target = sub.add_parser("create-target-database")
    create_target.add_argument("--manifest", type=Path, required=True)
    create_target.add_argument("--archive", choices=("product.dump", "auth.dump"), required=True)
    create_target.add_argument("--database-name", required=True)
    create_target.add_argument("--admin-url-env", required=True)
    extensions = sub.add_parser("prepare-target-extensions")
    extensions.add_argument("--manifest", type=Path, required=True)
    extensions.add_argument("--archive", choices=("product.dump", "auth.dump"), required=True)
    extensions.add_argument("--url-env", required=True)
    schema_acls = sub.add_parser("restore-schema-acls")
    schema_acls.add_argument("--manifest", type=Path, required=True)
    schema_acls.add_argument("--archive", choices=("product.dump", "auth.dump"), required=True)
    schema_acls.add_argument("--url-env", required=True)
    parameter_target = sub.add_parser("validate-parameter-acl-target")
    parameter_target.add_argument("--manifest", type=Path, required=True)
    parameter_target.add_argument("--admin-url-env", required=True)
    parameter_restore = sub.add_parser("restore-parameter-acls")
    parameter_restore.add_argument("--manifest", type=Path, required=True)
    parameter_restore.add_argument("--admin-url-env", required=True)
    parameter_restore.add_argument("--product-url-env", required=True)
    parameter_restore.add_argument("--auth-url-env", required=True)
    args = parser.parse_args()

    try:
        if args.action == "restore-schema-acls":
            restore_schema_acls(load_manifest(args.manifest), args.archive, os.environ[args.url_env])
            return 0
        if args.action == "validate-parameter-acl-target":
            validate_parameter_acl_target(load_manifest(args.manifest), os.environ[args.admin_url_env])
            return 0
        if args.action == "restore-parameter-acls":
            restore_parameter_acls(load_manifest(args.manifest), os.environ[args.admin_url_env],
                                   os.environ[args.product_url_env], os.environ[args.auth_url_env])
            return 0
        if args.action == "prepare-target-extensions":
            prepare_target_extensions(load_manifest(args.manifest), args.archive, os.environ[args.url_env])
            return 0
        if args.action == "create":
            product_url = os.environ[args.product_url_env]
            auth_url = os.environ[args.auth_url_env]
            dump_client = dump_client_version()
            product_metadata = inspect_database(product_url)
            auth_metadata = inspect_database(auth_url)
            for metadata in (product_metadata, auth_metadata):
                if dump_client["major"] < int(metadata["server_version_num"]) // 10000:
                    raise ValueError("pg_dump client major version is older than a source database")
            manifest = {
                "format": "pandapay-paired-postgresql-backup-v5",
                "set_id": args.set_id,
                "dump_client_version": dump_client["version"],
                "dump_client_major": dump_client["major"],
                "source_endpoint_sha256": [hashlib.sha256((urlsplit(url).hostname.lower() + ':' + str(urlsplit(url).port or 5432)).encode()).hexdigest() for url in (product_url, auth_url)],
                "created_at_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
                "archives": {
                    "product.dump": {"sha256": sha256(args.product_dump), "size_bytes": args.product_dump.stat().st_size,
                                     "database": product_metadata},
                    "auth.dump": {"sha256": sha256(args.auth_dump), "size_bytes": args.auth_dump.stat().st_size,
                                  "database": auth_metadata},
                },
            }
            validate_parameter_policy_coherence(manifest)
            args.output.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
            os.chmod(args.output, 0o600)
            return 0

        if args.action == "validate-target":
            manifest = load_manifest(args.manifest)
            admin_url = os.environ[args.admin_url_env]
            validate_cluster_independence(manifest, admin_url)
            validate_parameter_acl_target(manifest, admin_url)
            validate_target_roles(manifest, (args.product_url_env, args.auth_url_env))
            print("Recovery cluster and required role checks passed")
            return 0

        if args.action == "validate-independence":
            manifest = load_manifest(args.manifest)
            validate_cluster_independence(manifest, os.environ[args.admin_url_env])
            return 0

        if args.action == "validate-roles":
            manifest = load_manifest(args.manifest)
            validate_target_roles(manifest, (args.product_url_env, args.auth_url_env))
            return 0

        if args.action == "create-target-database":
            manifest = load_manifest(args.manifest)
            create_target_database(manifest, args.archive, args.database_name,
                                   os.environ[args.admin_url_env])
            return 0

        manifest = load_manifest(args.manifest)
        comparisons = []
        for name, env_name, dump_path in (("product.dump", args.product_url_env, args.product_dump),
                                          ("auth.dump", args.auth_url_env, args.auth_dump)):
            expected = manifest["archives"][name]["database"]
            archive_meta = manifest["archives"][name]
            if sha256(dump_path) != archive_meta["sha256"] or dump_path.stat().st_size != archive_meta["size_bytes"]:
                comparisons.append(name + " archive checksum")
            actual = inspect_database(os.environ[env_name])
            validate_restore_major(actual["server_version_num"], expected["server_version_num"],
                                   manifest["dump_client_major"])
            for key in ("server_version", "server_version_num"):
                expected.pop(key, None)
                actual.pop(key, None)
            expected.pop("database", None)  # drill databases deliberately use fresh names
            actual.pop("database", None)
            # Different clusters necessarily have different control-system IDs;
            # equality is checked separately before restore-side mutations.
            expected.pop("cluster_system_identifier", None)
            actual.pop("cluster_system_identifier", None)
            # Sequence values are not MVCC data and can advance independently
            # while a live export runs. The dump's setval is authoritative;
            # source-side observations are inventory, not an equality gate.
            expected.pop("sequence_states", None)
            actual.pop("sequence_states", None)
            expected.pop("role_attributes", None)
            actual.pop("role_attributes", None)
            expected.pop("role_memberships", None)
            actual.pop("role_memberships", None)
            if expected != actual:
                comparisons.extend(name + ':' + key for key in sorted(set(expected) | set(actual)) if expected.get(key) != actual.get(key))
                if expected.get('schema_grants') != actual.get('schema_grants') and os.environ.get('RESTORE_DIAGNOSE_SCHEMA_ACLS') == 'true':
                    expected_acls = dict(expected.get('schema_grants', []))
                    actual_acls = dict(actual.get('schema_grants', []))
                    for schema in sorted(set(expected_acls) | set(actual_acls)):
                        values = {'schema': schema, 'expected': expected_acls.get(schema), 'actual': actual_acls.get(schema)}
                        encoded = json.dumps(values)
                        # This opt-in diagnostic emits identifiers/privilege
                        # labels only; omit unexpected strings entirely.
                        strings = [schema] + [str(value) for grants in (values['expected'], values['actual'])
                                               for grant in (grants or []) for value in grant if isinstance(value, str)]
                        if values['expected'] != values['actual'] and all(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,127}', value) for value in strings):
                            print('Restore schema ACL diagnostic: ' + encoded[:8192], file=sys.stderr)
        if comparisons:
            print('Restore mismatch categories: ' + ', '.join(comparisons), file=sys.stderr)
            raise ValueError("restored schema/data/grants inventory differs")
        return 0
    except SafeDiagnosticError as error:
        print(f"backup manifest {args.action} failed: {error}", file=sys.stderr)
        return 1
    except ValueError as error:  # emit a bounded category, never arbitrary exception text
        print(f"backup manifest {args.action} failed: category={validation_category(error)}", file=sys.stderr)
        return 1
    except Exception as error:  # avoid printing URLs or query/result contents
        print(f"backup manifest {args.action} failed: category=internal_{type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
