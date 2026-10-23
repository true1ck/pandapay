'use strict';

const { createHash } = require('node:crypto');

// pg_dump omits the schema migration ledger table. Its output carries object
// definitions and ownership, while the catalog inventory below carries the
// effective ACL semantics that pg_dump can serialize differently after a
// provider restore (notably default and extension-initial privileges).
const ACL_INVENTORY_SQL = String.raw`
SELECT json_build_object(
  'database', (SELECT json_build_array(pg_get_userbyid(d.datdba),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a))
    FROM pg_database d WHERE d.datname=current_database()),
  'schemas', (SELECT coalesce(json_agg(json_build_array(n.nspname, pg_get_userbyid(n.nspowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a))
    ORDER BY n.nspname), '[]'::json)
    FROM pg_namespace n WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
  'relations', (SELECT coalesce(json_agg(json_build_array(n.nspname, c.relname, c.relkind,
    pg_get_userbyid(c.relowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(c.relacl, acldefault((CASE WHEN c.relkind='S' THEN 'S' ELSE 'r' END)::"char", c.relowner))) a))
    ORDER BY n.nspname, c.relname, c.relkind), '[]'::json)
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND c.relkind IN ('r','p','v','m','S','f')
      AND NOT (n.nspname='public' AND c.relname='schema_migrations')),
  'columns', (SELECT coalesce(json_agg(json_build_array(n.nspname, c.relname, a.attname,
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(x.grantor),
      CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
      x.privilege_type, x.is_grantable)
      ORDER BY pg_get_userbyid(x.grantor), CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
        x.privilege_type, x.is_grantable), '[]'::json)
     FROM aclexplode(a.attacl) x))
    ORDER BY n.nspname, c.relname, a.attnum), '[]'::json)
    FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE a.attnum>0 AND NOT a.attisdropped AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND NOT (n.nspname='public' AND c.relname='schema_migrations')),
  'routines', (SELECT coalesce(json_agg(json_build_array(n.nspname, p.proname,
    pg_get_function_identity_arguments(p.oid), p.prokind, pg_get_userbyid(p.proowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a))
    ORDER BY n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), p.prokind), '[]'::json)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
  'types', (SELECT coalesce(json_agg(json_build_array(n.nspname, t.typname, t.typtype,
    pg_get_userbyid(t.typowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(t.typacl, acldefault('T', t.typowner))) a))
    ORDER BY n.nspname, t.typname), '[]'::json)
    FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND (t.typrelid=0 OR EXISTS (SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind='c'))
      AND NOT (n.nspname='public' AND t.typname='schema_migrations')),
  'languages', (SELECT coalesce(json_agg(json_build_array(l.lanname,
    CASE WHEN l.lanname IN ('internal','c','sql') AND owner_role.rolsuper THEN json_build_object('semantic_owner','builtin-language') ELSE to_json(pg_get_userbyid(l.lanowner)) END,
    (SELECT coalesce(json_agg(json_build_array(
           CASE WHEN l.lanname IN ('internal','c','sql') AND owner_role.rolsuper AND a.grantor=l.lanowner THEN json_build_object('semantic_owner','builtin-language') ELSE to_json(pg_get_userbyid(a.grantor)) END,
           CASE WHEN l.lanname IN ('internal','c','sql') AND owner_role.rolsuper AND a.grantee=l.lanowner THEN json_build_object('semantic_owner','builtin-language')
                WHEN a.grantee=0 THEN to_json('PUBLIC'::text) ELSE to_json(pg_get_userbyid(a.grantee)) END,
           a.privilege_type, a.is_grantable)), '[]'::json)
           FROM aclexplode(coalesce(l.lanacl, acldefault('l', l.lanowner))) a))
    ORDER BY l.lanname), '[]'::json) FROM pg_language l JOIN pg_roles owner_role ON owner_role.oid=l.lanowner),
  'foreign_data_wrappers', (SELECT coalesce(json_agg(json_build_array(w.fdwname, pg_get_userbyid(w.fdwowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(w.fdwacl, acldefault('F', w.fdwowner))) a))
    ORDER BY w.fdwname), '[]'::json) FROM pg_foreign_data_wrapper w),
  'foreign_servers', (SELECT coalesce(json_agg(json_build_array(s.srvname, pg_get_userbyid(s.srvowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(s.srvacl, acldefault('S', s.srvowner))) a))
    ORDER BY s.srvname), '[]'::json) FROM pg_foreign_server s),
  'tablespaces', (SELECT coalesce(json_agg(json_build_array(t.spcname,
    CASE WHEN t.spcname IN ('pg_default','pg_global') AND owner_role.rolsuper THEN json_build_object('semantic_owner','builtin-tablespace') ELSE to_json(pg_get_userbyid(t.spcowner)) END,
    (SELECT coalesce(json_agg(json_build_array(
           CASE WHEN t.spcname IN ('pg_default','pg_global') AND owner_role.rolsuper AND a.grantor=t.spcowner THEN json_build_object('semantic_owner','builtin-tablespace') ELSE to_json(pg_get_userbyid(a.grantor)) END,
           CASE WHEN t.spcname IN ('pg_default','pg_global') AND owner_role.rolsuper AND a.grantee=t.spcowner THEN json_build_object('semantic_owner','builtin-tablespace')
                WHEN a.grantee=0 THEN to_json('PUBLIC'::text) ELSE to_json(pg_get_userbyid(a.grantee)) END,
           a.privilege_type, a.is_grantable)), '[]'::json)
           FROM aclexplode(coalesce(t.spcacl, acldefault('t', t.spcowner))) a))
    ORDER BY t.spcname), '[]'::json) FROM pg_tablespace t JOIN pg_roles owner_role ON owner_role.oid=t.spcowner),
  'large_objects', (SELECT coalesce(json_agg(json_build_array(m.oid::text, pg_get_userbyid(m.lomowner),
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(m.lomacl, acldefault('L', m.lomowner))) a))
    ORDER BY m.oid), '[]'::json) FROM pg_largeobject_metadata m),
  'parameter_acl', (SELECT coalesce(json_agg(json_build_array(p.parname,
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(coalesce(p.paracl, ARRAY[]::aclitem[])) a))
    ORDER BY p.parname), '[]'::json) FROM pg_parameter_acl p),
  'default_acl', (SELECT coalesce(json_agg(json_build_array(coalesce(n.nspname,''),
    pg_get_userbyid(d.defaclrole), d.defaclobjtype,
    (SELECT coalesce(json_agg(json_build_array(pg_get_userbyid(a.grantor),
      CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
      a.privilege_type, a.is_grantable)
      ORDER BY pg_get_userbyid(a.grantor), CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type, a.is_grantable), '[]'::json)
     FROM aclexplode(d.defaclacl) a))
    ORDER BY coalesce(n.nspname,''), pg_get_userbyid(d.defaclrole), d.defaclobjtype), '[]'::json)
    FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
    WHERE n.oid IS NULL OR (n.nspname !~ '^pg_' AND n.nspname <> 'information_schema')),
  'extensions', (SELECT coalesce(json_agg(json_build_array(e.extname, e.extversion,
    n.nspname, pg_get_userbyid(e.extowner)) ORDER BY e.extname), '[]'::json)
    FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),
  'extension_members', (SELECT coalesce(json_agg(json_build_array(e.extname, d.deptype,
    identified.type, identified.schema, identified.name, identified.identity, member_owner.owner)), '[]'::json)
    FROM pg_depend d
    JOIN pg_extension e ON d.refclassid='pg_extension'::regclass AND d.refobjid=e.oid AND d.deptype='e'
    CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) identified
    LEFT JOIN LATERAL (
      SELECT coalesce(catalog_owner.owner, shared_owner.owner) AS owner
      FROM (SELECT CASE d.classid
        WHEN 'pg_class'::regclass THEN (SELECT pg_get_userbyid(x.relowner) FROM pg_class x WHERE x.oid=d.objid)
        WHEN 'pg_proc'::regclass THEN (SELECT pg_get_userbyid(x.proowner) FROM pg_proc x WHERE x.oid=d.objid)
        WHEN 'pg_type'::regclass THEN (SELECT pg_get_userbyid(x.typowner) FROM pg_type x WHERE x.oid=d.objid)
        WHEN 'pg_language'::regclass THEN (SELECT pg_get_userbyid(x.lanowner) FROM pg_language x WHERE x.oid=d.objid)
        WHEN 'pg_operator'::regclass THEN (SELECT pg_get_userbyid(x.oprowner) FROM pg_operator x WHERE x.oid=d.objid)
        WHEN 'pg_opclass'::regclass THEN (SELECT pg_get_userbyid(x.opcowner) FROM pg_opclass x WHERE x.oid=d.objid)
        WHEN 'pg_opfamily'::regclass THEN (SELECT pg_get_userbyid(x.opfowner) FROM pg_opfamily x WHERE x.oid=d.objid)
        WHEN 'pg_collation'::regclass THEN (SELECT pg_get_userbyid(x.collowner) FROM pg_collation x WHERE x.oid=d.objid)
        WHEN 'pg_conversion'::regclass THEN (SELECT pg_get_userbyid(x.conowner) FROM pg_conversion x WHERE x.oid=d.objid)
        WHEN 'pg_namespace'::regclass THEN (SELECT pg_get_userbyid(x.nspowner) FROM pg_namespace x WHERE x.oid=d.objid)
        WHEN 'pg_ts_dict'::regclass THEN (SELECT pg_get_userbyid(x.dictowner) FROM pg_ts_dict x WHERE x.oid=d.objid)
        WHEN 'pg_ts_config'::regclass THEN (SELECT pg_get_userbyid(x.cfgowner) FROM pg_ts_config x WHERE x.oid=d.objid)
        WHEN 'pg_foreign_data_wrapper'::regclass THEN (SELECT pg_get_userbyid(x.fdwowner) FROM pg_foreign_data_wrapper x WHERE x.oid=d.objid)
        WHEN 'pg_foreign_server'::regclass THEN (SELECT pg_get_userbyid(x.srvowner) FROM pg_foreign_server x WHERE x.oid=d.objid)
        WHEN 'pg_event_trigger'::regclass THEN (SELECT pg_get_userbyid(x.evtowner) FROM pg_event_trigger x WHERE x.oid=d.objid)
        WHEN 'pg_statistic_ext'::regclass THEN (SELECT pg_get_userbyid(x.stxowner) FROM pg_statistic_ext x WHERE x.oid=d.objid)
        WHEN 'pg_publication'::regclass THEN (SELECT pg_get_userbyid(x.pubowner) FROM pg_publication x WHERE x.oid=d.objid)
        WHEN 'pg_subscription'::regclass THEN (SELECT pg_get_userbyid(x.subowner) FROM pg_subscription x WHERE x.oid=d.objid)
        ELSE NULL END AS owner) catalog_owner
      LEFT JOIN LATERAL (
        SELECT pg_get_userbyid(shared.refobjid) AS owner
        FROM pg_shdepend shared
        WHERE shared.dbid=(SELECT oid FROM pg_database WHERE datname=current_database())
          AND shared.classid=d.classid AND shared.objid=d.objid AND shared.objsubid=0
          AND shared.refclassid='pg_authid'::regclass AND shared.deptype='o'
        LIMIT 1
      ) shared_owner ON TRUE
      WHERE catalog_owner.owner IS NOT NULL OR d.classid NOT IN (
        'pg_cast'::regclass, 'pg_am'::regclass, 'pg_ts_parser'::regclass,
        'pg_ts_template'::regclass, 'pg_transform'::regclass, 'pg_rewrite'::regclass,
        'pg_trigger'::regclass, 'pg_attrdef'::regclass, 'pg_constraint'::regclass
      )
    ) member_owner ON TRUE
    WHERE d.refclassid='pg_extension'::regclass AND d.deptype='e')
) AS inventory;
`;

function canonicalJson(value) {
  if (Array.isArray(value)) return value.map(canonicalJson);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonicalJson(value[key])]));
  }
  return value;
}

// PostgreSQL text ORDER BY follows the database collation. Providers can use
// different locales even when every catalog tuple is identical. Sort only
// collections (and ACL-entry collections), preserving each tuple's positions.
function canonicalInventory(inventory) {
  const aclPosition = {
    schemas: 2, relations: 4, columns: 3, routines: 5, types: 4, default_acl: 3,
    languages: 2, foreign_data_wrappers: 2, foreign_servers: 2, tablespaces: 2,
    large_objects: 2, parameter_acl: 1,
  };
  const collections = new Set([...Object.keys(aclPosition), 'extensions', 'extension_members']);
  function ordered(values) {
    return values.map(canonicalJson).sort((a, b) => {
      const left = JSON.stringify(a), right = JSON.stringify(b);
      return left < right ? -1 : left > right ? 1 : 0;
    });
  }
  const result = {};
  for (const [category, value] of Object.entries(inventory)) {
    if (category === 'database') {
      result[category] = [value[0], ordered(value[1])];
    } else if (collections.has(category)) {
      result[category] = ordered(value.map(tuple => {
        const copy = [...tuple];
        if (Object.hasOwn(aclPosition, category)) copy[aclPosition[category]] = ordered(copy[aclPosition[category]]);
        return copy;
      }));
    } else result[category] = canonicalJson(value);
  }
  return canonicalJson(result);
}

function splitSqlStatements(sql) {
  const statements = [];
  let start = 0;
  let state = 'normal';
  let dollarTag = null;
  let blockDepth = 0;
  let escapeString = false;
  for (let i = 0; i < sql.length; i++) {
    const char = sql[i], next = sql[i + 1];
    if (state === 'single') {
      if (escapeString && char === '\\') { i++; continue; }
      if (char === "'" && next === "'") { i++; continue; }
      if (char === "'") { state = 'normal'; escapeString = false; }
      continue;
    }
    if (state === 'double') {
      if (char === '"' && next === '"') { i++; continue; }
      if (char === '"') state = 'normal';
      continue;
    }
    if (state === 'dollar') {
      if (sql.startsWith(dollarTag, i)) { i += dollarTag.length - 1; state = 'normal'; dollarTag = null; }
      continue;
    }
    if (state === 'line_comment') {
      if (char === '\n') state = 'normal';
      continue;
    }
    if (state === 'block_comment') {
      if (char === '/' && next === '*') { blockDepth++; i++; }
      else if (char === '*' && next === '/') {
        blockDepth--; i++;
        if (blockDepth === 0) state = 'normal';
      }
      continue;
    }

    if (char === '-' && next === '-') { state = 'line_comment'; i++; continue; }
    if (char === '/' && next === '*') { state = 'block_comment'; blockDepth = 1; i++; continue; }
    if (char === '"') { state = 'double'; continue; }
    if (char === "'") {
      escapeString = (sql[i - 1] === 'E' || sql[i - 1] === 'e') &&
        (i < 2 || !/[A-Za-z0-9_$]/.test(sql[i - 2]));
      state = 'single';
      continue;
    }
    if (char === '$') {
      const match = sql.slice(i).match(/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/);
      if (match) { dollarTag = match[0]; state = 'dollar'; i += dollarTag.length - 1; continue; }
    }
    if (char === ';') {
      statements.push({ text: sql.slice(start, i + 1), start, end: i + 1 });
      start = i + 1;
    }
  }
  if (start < sql.length) statements.push({ text: sql.slice(start), start, end: sql.length });
  return statements;
}

function firstSqlTokenOffset(statement) {
  let i = 0;
  while (i < statement.length) {
    if (/\s/.test(statement[i])) { i++; continue; }
    if (statement.startsWith('--', i)) {
      const newline = statement.indexOf('\n', i + 2);
      i = newline < 0 ? statement.length : newline + 1;
      continue;
    }
    if (statement.startsWith('/*', i)) {
      let depth = 1;
      i += 2;
      while (i < statement.length && depth > 0) {
        if (statement.startsWith('/*', i)) { depth++; i += 2; }
        else if (statement.startsWith('*/', i)) { depth--; i += 2; }
        else i++;
      }
      if (depth !== 0) throw new Error('Unclosed SQL comment in schema dump');
      continue;
    }
    break;
  }
  return i;
}

function scanSqlTokens(sql) {
  const tokens = [];
  let state = 'normal', dollarTag = null, blockDepth = 0, escapeString = false, parenDepth = 0;
  for (let i = 0; i < sql.length; i++) {
    const char = sql[i], next = sql[i + 1];
    if (state === 'single') {
      if (escapeString && char === '\\') { i++; continue; }
      if (char === "'" && next === "'") { i++; continue; }
      if (char === "'") { state = 'normal'; escapeString = false; }
      continue;
    }
    if (state === 'double') {
      if (char === '"' && next === '"') { i++; continue; }
      if (char === '"') state = 'normal';
      continue;
    }
    if (state === 'dollar') {
      if (sql.startsWith(dollarTag, i)) { i += dollarTag.length - 1; state = 'normal'; dollarTag = null; }
      continue;
    }
    if (state === 'line_comment') {
      if (char === '\n') state = 'normal';
      continue;
    }
    if (state === 'block_comment') {
      if (char === '/' && next === '*') { blockDepth++; i++; }
      else if (char === '*' && next === '/') {
        blockDepth--; i++;
        if (blockDepth === 0) state = 'normal';
      }
      continue;
    }
    if (char === '-' && next === '-') { state = 'line_comment'; i++; continue; }
    if (char === '/' && next === '*') { state = 'block_comment'; blockDepth = 1; i++; continue; }
    if (char === '"') {
      const start = i;
      for (i++; i < sql.length; i++) {
        if (sql[i] === '"' && sql[i + 1] === '"') { i++; continue; }
        if (sql[i] === '"') break;
      }
      if (i >= sql.length) throw new Error('Unclosed quoted identifier in schema dump');
      tokens.push({ type: 'identifier', value: sql.slice(start, i + 1), start, end: i + 1, depth: parenDepth });
      continue;
    }
    if (char === "'") {
      escapeString = (sql[i - 1] === 'E' || sql[i - 1] === 'e') &&
        (i < 2 || !/[A-Za-z0-9_$]/.test(sql[i - 2]));
      state = 'single';
      continue;
    }
    if (char === '$') {
      const match = sql.slice(i).match(/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/);
      if (match) { dollarTag = match[0]; state = 'dollar'; i += dollarTag.length - 1; continue; }
    }
    if (/[A-Za-z_]/.test(char)) {
      const start = i;
      while (i + 1 < sql.length && /[A-Za-z0-9_$]/.test(sql[i + 1])) i++;
      tokens.push({ type: 'word', value: sql.slice(start, i + 1), start, end: i + 1, depth: parenDepth });
      continue;
    }
    if (char === '(') {
      tokens.push({ type: 'punct', value: char, start: i, end: i + 1, depth: parenDepth });
      parenDepth++;
      continue;
    }
    if (char === ')') {
      if (parenDepth === 0) throw new Error('Unbalanced parentheses in schema dump');
      parenDepth--;
      tokens.push({ type: 'punct', value: char, start: i, end: i + 1, depth: parenDepth });
      continue;
    }
    if (char === '.' || char === ',' || char === ';') {
      tokens.push({ type: 'punct', value: char, start: i, end: i + 1, depth: parenDepth });
    }
  }
  if (state === 'single' || state === 'double' || state === 'dollar' || state === 'block_comment' || parenDepth !== 0) {
    throw new Error('Unterminated SQL construct in schema dump');
  }
  return tokens;
}

function qualifiedObjectStart(tokens, keywordIndex, row) {
  let index = keywordIndex + 1;
  if (row.object_kind === 'table' && tokens[index]?.value.toUpperCase() === 'IF') index += 3;
  if (tokens[index]?.value !== row.quoted_schema || tokens[index + 1]?.value !== '.' ||
      tokens[index + 2]?.value !== row.quoted_object) return -1;
  return index + 2;
}

function inlineConstraintOffsets(statement, row) {
  const tokens = scanSqlTokens(statement);
  if (tokens[0]?.value.toUpperCase() !== 'CREATE' || tokens[0]?.depth !== 0) return [];
  const expectedKind = row.object_kind === 'table' ? 'TABLE' : 'DOMAIN';
  const kindIndex = tokens.findIndex((token, index) => index > 0 && token.depth === 0 &&
    token.type === 'word' && token.value.toUpperCase() === expectedKind);
  if (kindIndex < 0) return [];
  const objectIndex = qualifiedObjectStart(tokens, kindIndex, row);
  if (objectIndex < 0) return [];
  if (row.object_kind === 'domain') {
    const offsets = [];
    for (let i = objectIndex + 1; i + 2 < tokens.length; i++) {
      if (tokens[i].depth === 0 && tokens[i].value.toUpperCase() === 'CONSTRAINT' &&
          tokens[i + 1].value === row.quoted_name && tokens[i + 2].value.toUpperCase() === 'CHECK') {
        offsets.push(tokens[i + 2].start);
      }
    }
    return offsets;
  }

  const openIndex = tokens.findIndex((token, index) => index > objectIndex && token.value === '(' && token.depth === 0);
  if (openIndex < 0) return [];
  const closeIndex = tokens.findIndex((token, index) => index > openIndex && token.value === ')' && token.depth === 0);
  if (closeIndex < 0) return [];
  const ranges = [];
  let rangeStart = tokens[openIndex].end;
  for (let i = openIndex + 1; i < closeIndex; i++) {
    if (tokens[i].value === ',' && tokens[i].depth === 1) {
      ranges.push([rangeStart, tokens[i].start]);
      rangeStart = tokens[i].end;
    }
  }
  ranges.push([rangeStart, tokens[closeIndex].start]);
  const offsets = [];
  for (const [start, end] of ranges) {
    const element = tokens.filter(token => token.start >= start && token.end <= end && token.depth === 1);
    for (let i = 0; i + 2 < element.length; i++) {
      if (element[i].type === 'word' && element[i].value.toUpperCase() === 'CONSTRAINT' &&
          element[i + 1].type === 'identifier' && element[i + 1].value === row.quoted_name &&
          element[i + 2].type === 'word' && element[i + 2].value.toUpperCase() === 'CHECK') {
        offsets.push(element[i + 2].start);
      }
    }
  }
  return offsets;
}

function checkConstraintDefinitionOffsets(statement, row) {
  let offset = firstSqlTokenOffset(statement);
  const body = statement.slice(offset);
  const table = row.object_kind === 'table';
  if (!table && row.object_kind !== 'domain') throw new Error('Unsupported local CHECK object kind');
  const keyword = table ? /^ALTER\s+TABLE\s+(?:ONLY\s+)?/i : /^ALTER\s+DOMAIN\s+/i;
  const match = body.match(keyword);
  if (match) {
    offset += match[0].length;
    let tail = statement.slice(offset);
    const objectName = `${row.quoted_schema}.${row.quoted_object}`;
    if (tail.startsWith(objectName)) {
      offset += objectName.length;
      tail = statement.slice(offset);
      const add = tail.match(/^\s+ADD\s+CONSTRAINT\s+/i);
      if (add) {
        offset += add[0].length;
        if (statement.startsWith(row.quoted_name, offset)) {
          offset += row.quoted_name.length;
          const separator = statement.slice(offset).match(/^\s+/);
          if (separator) return [offset + separator[0].length];
        }
      }
    }
  }
  return inlineConstraintOffsets(statement, row);
}

function normalizeCheckDump(dump, constraints) {
  const statements = splitSqlStatements(dump);
  const normalized = new Map();
  for (const row of constraints) {
    const raw = row.raw_definition;
    const pretty = row.pretty_definition;
    if (typeof raw !== 'string' || typeof pretty !== 'string' ||
        typeof row.quoted_name !== 'string' || typeof row.quoted_schema !== 'string' ||
        typeof row.quoted_object !== 'string' || !['table', 'domain'].includes(row.object_kind)) {
      throw new Error('Malformed local CHECK constraint fingerprint metadata');
    }
    const normalizedPretty = normalizeConstraint(pretty);
    const matches = [];
    for (let index = 0; index < statements.length; index++) {
      for (const definitionOffset of checkConstraintDefinitionOffsets(statements[index].text, row)) {
        const tail = statements[index].text.slice(definitionOffset);
        const definition = tail.startsWith(raw) ? raw : tail.startsWith(normalizedPretty) ? normalizedPretty : null;
        if (definition !== null && /^(?:\s|;|,|\)|$)/.test(tail.slice(definition.length))) {
          matches.push({ index, definitionOffset, definition });
        }
      }
    }
    if (matches.length !== 1) throw new Error('Local CHECK constraint is missing or ambiguous in schema dump');
    const { index, definitionOffset, definition } = matches[0];
    if (definition === raw && raw !== normalizedPretty) {
      const statement = statements[index];
      const text = statement.text.slice(0, definitionOffset) + normalizedPretty +
        statement.text.slice(definitionOffset + raw.length);
      statements[index] = { ...statement, text };
    }
    const key = `${row.object_kind}:${row.quoted_schema}.${row.quoted_object}:${row.quoted_name}`;
    if (normalized.has(key)) throw new Error('Duplicate local CHECK constraint fingerprint metadata');
    normalized.set(key, true);
  }
  const replacements = new Map(statements.map(statement => [statement.start, statement.text]));
  let cursor = 0;
  let result = '';
  for (const statement of statements) {
    result += dump.slice(cursor, statement.start) + (replacements.get(statement.start) || statement.text);
    cursor = statement.end;
  }
  return result + dump.slice(cursor);
}

function normalizeConstraint(definition) {
  let value = definition.replaceAll('::character varying::text', '::text');
  value = value.replace(/('(?:''|[^'])*')::character varying\b/g, '$1::text');
  return value.replace(/(ARRAY\[(?:'(?:''|[^'])*'::text(?:,\s*)?)+\])::text\[\]/g, '$1');
}

async function schemaFingerprint({ client, snapshot, dump }) {
  if (typeof dump !== 'string') throw new Error('Schema dump is required for baseline verification');
  // Keep the catalog lookup under the caller's exported snapshot and fix
  // deparser lookup to pg_catalog for stable constraint definitions.
  const previous = (await client.query("SELECT current_setting('search_path') AS search_path, current_setting('quote_all_identifiers') AS quote_all_identifiers")).rows[0];
  if (typeof previous?.search_path !== 'string' || !['on', 'off'].includes(previous?.quote_all_identifiers)) throw new Error('Schema deparser settings could not be captured');
  try {
    // Match pg_dump's --quote-all-identifiers session setting for expression
    // deparsing too, including otherwise ordinary column/type identifiers.
    await client.query("SELECT set_config('search_path', 'pg_catalog', false), set_config('quote_all_identifiers', 'on', false)");
    const constraintResult = await client.query(String.raw`SELECT c.conname AS name,
      ('"' || replace(c.conname::text, '"', '""') || '"') AS quoted_name,
      ('"' || replace(coalesce(rn.nspname,tn.nspname)::text, '"', '""') || '"') AS quoted_schema,
      ('"' || replace(coalesce(r.relname,t.typname)::text, '"', '""') || '"') AS quoted_object,
      CASE WHEN r.oid IS NOT NULL THEN 'table' ELSE 'domain' END AS object_kind,
      pg_get_constraintdef(c.oid, false) AS raw_definition,
      pg_get_constraintdef(c.oid, true) AS pretty_definition
    FROM pg_constraint c
    LEFT JOIN pg_class r ON r.oid=c.conrelid
    LEFT JOIN pg_namespace rn ON rn.oid=r.relnamespace
    LEFT JOIN pg_type t ON t.oid=c.contypid
    LEFT JOIN pg_namespace tn ON tn.oid=t.typnamespace
    WHERE c.contype='c'
      AND c.conislocal
      AND ((r.oid IS NOT NULL AND rn.nspname !~ '^pg_' AND rn.nspname <> 'information_schema'
            AND NOT (rn.nspname='public' AND r.relname='schema_migrations'))
        OR (t.oid IS NOT NULL AND tn.nspname !~ '^pg_' AND tn.nspname <> 'information_schema'
            AND NOT (tn.nspname='public' AND t.typname='schema_migrations')))
      AND NOT EXISTS (SELECT 1 FROM pg_depend e
        WHERE e.refclassid='pg_extension'::regclass AND e.deptype='e'
          AND ((e.classid='pg_constraint'::regclass AND e.objid=c.oid)
            OR (r.oid IS NOT NULL AND e.classid='pg_class'::regclass AND e.objid=r.oid)
            OR (t.oid IS NOT NULL AND e.classid='pg_type'::regclass AND e.objid=t.oid)))
      ORDER BY coalesce(rn.nspname,tn.nspname), coalesce(r.relname,t.typname), c.conname`);
    const normalizedDump = normalizeCheckDump(dump, constraintResult.rows);
    const definitionDump = normalizedDump.split('\n')
      .filter(line => !line.startsWith('\\restrict ') && !line.startsWith('\\unrestrict ') && !line.startsWith('-- Dumped ')).join('\n');
    const aclResult = await client.query(ACL_INVENTORY_SQL);
    const inventoryValue = aclResult.rows[0]?.inventory;
    if (!inventoryValue || typeof inventoryValue !== 'object') throw new Error('ACL inventory is unavailable');
    const catalog = JSON.stringify(canonicalInventory(inventoryValue));
    const tuple = JSON.stringify({ definitions: sha256(definitionDump), catalog: sha256(catalog) });
    return sha256(tuple);
  } finally {
    await client.query("SELECT set_config('search_path', $1, false), set_config('quote_all_identifiers', $2, false)", [previous.search_path, previous.quote_all_identifiers]);
  }
}

function sha256(value) { return createHash('sha256').update(value).digest('hex'); }

module.exports = { ACL_INVENTORY_SQL, canonicalJson, canonicalInventory, normalizeCheckDump, schemaFingerprint, normalizeConstraint };
