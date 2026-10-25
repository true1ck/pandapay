"""Offline database explorer, generated from local metadata without data rows."""
from collections import Counter
from datetime import datetime
from html import escape
import json
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent

DOMAINS = {
    'Identity & wallet': 'profiles admin_users user_cards user_settings user_consents user_devices card_requests'.split(),
    'Spending & rewards': 'transactions transaction_observations transaction_splits points_ledger cap_states fee_waiver_states milestone_states lounge_usage budgets budget_periods recurring_series monthly_reports spend_categories mcc_categories'.split(),
    'Card catalogue': 'issuers card_products reward_rules cap_rules card_benefits billing_cycle_rules fee_waiver_rules forex_rules fuel_surcharge_rules milestone_rules redemption_options card_overrides card_catalogue_changes issuer_emergency_contacts'.split(),
    'Merchants & discovery': 'merchants merchant_locations merchant_category_rules merchant_contributions merchant_conflicts acceptance_reports acceptance_summary contribution_quotas contribution_salts duplicate_candidates effective_rate_samples effective_rate_summary'.split(),
    'Import & sync': 'imap_connections forwarding_addresses inbound_emails statement_imports sms_import_batches parser_failures parser_patterns needs_review_items sync_conflicts sync_cursors change_log'.split(),
    'Operations & publishing': 'sources source_pages page_snapshots scrape_runs extraction_proposals policy_change_alerts policy_alert_evidence data_error_reports admin_audit_log anonymization_audit_runs backup_runs restore_drills schema_migrations'.split(),
    'Engagement & configuration': 'notifications notification_preferences notification_muted_merchants analytics_events support_tickets partner_programs partner_clicks partner_conversions referral_program referral_codes referrals feature_flags app_versions app_status remote_config kill_switches abuse_signals changelog_entries'.split(),
}


def domain(database, name):
    if database == 'pandapay_auth':
        return 'Authentication'
    return next((label for label, names in DOMAINS.items() if name in names), 'Other')


def e(value):
    return escape(str(value if value is not None else '—'), quote=True)


def code(value):
    return f'<code>{e(value)}</code>'


def grid(headers, rows):
    return '<div class="table-wrap"><table><thead><tr>' + ''.join(
        f'<th scope="col">{e(h)}</th>' for h in headers) + '</tr></thead><tbody>' + ''.join(
        '<tr>' + ''.join(f'<td>{c}</td>' for c in row) + '</tr>' for row in rows
    ) + '</tbody></table></div>'


def source_link(source):
    return f'<a href="../{e(source["path"])}#L{e(source["line"])}">{e(source["path"])}:{e(source["line"])}</a>'


def optimization_inventory():
    evidence_path = HERE / 'database-optimization-evidence.json'
    if not evidence_path.exists():
        return ''
    evidence = json.loads(evidence_path.read_text())
    candidates = {('pandapay_auth', 'otp_codes'), ('pandapay_auth', 'oauth_accounts'),
                  ('pandapay', 'feature_flags'), ('pandapay', 'app_versions')}
    parts = []
    for database, metadata in evidence['databases'].items():
        rows = []
        for t in sorted(metadata['tables'], key=lambda t: t['table_name']):
            name = t['table_name']
            key = f'{database}.{t["schema_name"]}.{name}'
            functions = [f['function_name'] for f in metadata['function_table_mentions'] if f['table_name'] == name]
            mentions = t['source_mentions']
            if (database, name) in candidates:
                assessment = 'Retirement candidate; compatibility/owner check still required'
            elif database == 'pandapay' and name in ('kill_switches', 'remote_config'):
                assessment = 'Control ownership/read-consumer review; do not drop automatically'
            elif not mentions and functions:
                assessment = 'Database-routine evidence; not unused from missing JS mentions'
            elif mentions:
                assessment = 'Source references found; zero rows/scans do not justify deletion'
            else:
                assessment = 'No direct source match; investigate dependencies/owners'
            reference = f'{len(mentions)} source locations'
            if mentions:
                reference += '<br>' + '<br>'.join(source_link(m) for m in mentions[:2])
                if len(mentions) > 2:
                    reference += '<br><small>Full location list in evidence JSON</small>'
            rows.append((f'<a href="#table-{e(key.replace(".", "-"))}" data-table-link="{e(key)}">{code(name)}</a>',
                         f'{t["exact_rows"]:,}', f'{t["total_bytes"]/1024:,.1f}',
                         f'{t["index_bytes"]/1024:,.1f}', reference,
                         '<br>'.join(code(f) for f in functions) or 'None found', e(assessment)))
        parts.append(f'<h4>{code(database)} · {len(rows)} tables</h4>' +
                     grid(['Table', 'Local rows', 'Allocated KiB', 'Index KiB', 'Source locations', 'Routine mentions', 'Assessment'], rows))
    return f'''<div class="scope-note"><strong>Optimization review available:</strong> four table-retirement candidates, confirmed rule duplicates, two overlapping index pairs and retention improvements. <a href="#10-database-optimization-and-table-usage-review" data-show-audit>Read recommendations and verification steps →</a></div>
<details class="source-table" id="database-usage-inventory"><summary><strong>Table usage & size inventory · 96 tables</strong><span class="pill">Local aggregates only</span></summary><p>Exact local row counts and allocated relation/index sizes; no row values are exported. Size includes allocated pages and may include reusable/free space. Source locations are literal matches that can include comments and other databases' same-named tables. Routine mentions are source evidence, not a guarantee of executed queries. Neither zero rows nor missing direct JavaScript matches prove a table is unused in production. Captured {e(evidence['captured_at'])} (UTC).</p><p><a href="../artifacts/security-review-2026-10-20/database-optimization-evidence.json" download>Download complete size, index, counter and source-location evidence</a></p>{''.join(parts)}</details>'''


def render_database(status_anchor="implementation-status"):
    snapshot = json.loads((HERE / 'schema-details.json').read_text())
    supplement_path = HERE / 'schema-source-supplement.json'
    supplement = json.loads(supplement_path.read_text()) if supplement_path.exists() else {}
    all_tables, dictionaries = [], []
    for database, metadata in snapshot['databases'].items():
        for table in metadata['tables']:
            table = dict(table, database=database, domain=domain(database, table['table_name']))
            table['key'] = f'{database}.{table["schema_name"]}.{table["table_name"]}'
            table['anchor'] = 'table-' + table['key'].replace('.', '-')
            all_tables.append(table)
    count = len(all_tables)
    fk_count = sum(k['kind'] == 'f' for t in all_tables for k in t['constraints'])
    column_count = sum(len(t['columns']) for t in all_tables)
    policy_count = sum(len(t['policies']) for t in all_tables)
    view_count = sum(len(v['views']) for v in snapshot['databases'].values())
    function_count = sum(len(v['functions']) for v in snapshot['databases'].values())
    enum_count = sum(len(v['enums']) for v in snapshot['databases'].values())
    trigger_count = sum(len(t['triggers']) for t in all_tables)
    domains = sorted(set(t['domain'] for t in all_tables))
    for table in all_tables:
        pk = {col for k in table['constraints'] if k['kind'] == 'p' for col in k['columns'] or []}
        fk = {col for k in table['constraints'] if k['kind'] == 'f' for col in k['columns'] or []}
        unique = {col for k in table['constraints'] if k['kind'] == 'u' and len(k['columns'] or []) == 1 for col in k['columns']}
        composite_unique = {col for k in table['constraints'] if k['kind'] == 'u' and len(k['columns'] or []) > 1 for col in k['columns']}
        inbound = [(other, key) for other in all_tables if other['database'] == table['database']
                   for key in other['constraints'] if key['kind'] == 'f'
                   and key['target_schema'] == table['schema_name'] and key['target_table'] == table['table_name']]
        rows = [(code(c['name']), code(c['type']), 'Yes' if c['nullable'] else 'No',
                 ' · '.join(label for label, cols in [('PK', pk), ('FK', fk), ('UNIQUE', unique), ('Composite UNIQUE member', composite_unique)] if c['name'] in cols) or '—',
                 code(c['default']) if c['default'] is not None else '—') for c in table['columns']]
        rls = ('Enabled · forced' if table['rls_forced'] else 'Enabled') if table['rls_enabled'] else 'Disabled'
        summary = f'<span class="table-title">{e(table["table_name"])}</span><span class="table-meta">{e(table["database"])}.{e(table["schema_name"])} · {len(rows)} columns · {len(table["indexes"])} indexes</span><span class="pill {"ok" if table["rls_enabled"] else "warn"}">RLS {rls}</span>'
        content = f'<p class="footnote">{code(table["key"])} · {e(table["domain"])}. {len(inbound)} incoming foreign keys; {sum(k["kind"] == "f" for k in table["constraints"])} outgoing foreign keys.</p>'
        if table.get('description'):
            content += f'<p>{e(table["description"])}</p>'
        content += grid(['Column', 'PostgreSQL type', 'Nullable', 'Key', 'Default / generated'], rows)
        display_constraints = [k for k in table['constraints'] if k['kind'] != 'n']
        if display_constraints:
            content += '<h4>Keys & checks</h4>' + grid(['Constraint', 'Kind', 'Definition'], [
                (code(k['name']), e({'p': 'Primary key', 'f': 'Foreign key', 'u': 'Unique', 'c': 'Check', 'n': 'Not null', 'x': 'Exclusion'}.get(k['kind'], k['kind'])), code(k['definition']))
                for k in display_constraints])
        if inbound:
            content += '<h4>Tables that reference this table</h4>' + grid(['From', 'Columns', 'Constraint'], [
                (f'<a href="#{e(other["anchor"])}" data-table-link="{e(other["key"])}">{e(other["table_name"])}</a>',
                 code(', '.join(key['columns'] or [])), code(key['name'])) for other, key in inbound])
        if table['indexes']:
            content += '<h4>Indexes</h4>' + grid(['Index', 'Definition'], [
                (code(idx['name']), code(idx['definition'])) for idx in table['indexes']])
        if table['policies']:
            content += '<h4>Row-level security policies</h4>' + grid(['Policy / roles', 'Command', 'USING', 'WITH CHECK'], [
                (code(p['name']) + '<br>' + e(', '.join(p['roles'])), e(p['command']), code(p['using']), code(p['check']))
                for p in table['policies']])
        else:
            content += '<p class="footnote">No row-level security policies recorded for this table. Service authorization and database grants are separate controls; their presence is not implied by this diagram.</p>'
        if table['triggers']:
            content += '<h4>Triggers</h4>' + grid(['Trigger', 'Definition'], [
                (code(t['name']), code(t['definition'])) for t in table['triggers']])
        dictionaries.append(f'<details class="schema-table" id="{e(table["anchor"])}" data-key="{e(table["key"])}"><summary>{summary}</summary><div class="table-content">{content}</div></details>')
    counts = Counter(t['domain'] for t in all_tables)
    domain_cards = ''.join(f'<button type="button" class="domain-card" data-domain="{e(label)}"><strong>{e(label)}</strong><span>{n} tables</span></button>' for label, n in counts.items())
    source_sections = []
    for table in supplement.get('source_only_product_tables', []):
        source_sections.append(f'<details class="source-table"><summary>{code(table["table_name"])} <span class="pill warn">Source only</span></summary><p>{e(table.get("description", ""))}</p><p>{source_link(table["source"])}</p><pre><code>{e(table["create_sql"])}</code></pre></details>')
    sqlite = supplement.get('flutter_sqlite', {})
    sqlite_sections = []
    for table in sqlite.get('tables', []):
        sqlite_sections.append(f'<details class="source-table"><summary>{code(table["table_name"])} <span class="pill">Device SQLite</span></summary><p>{e(table.get("description", ""))}</p><p>{source_link(table["source"])}</p><pre><code>{e(table["create_sql"])}</code></pre>' +
                               (grid(['Runtime-added column', 'Definition'], [(code(c['name']), code(c['definition'])) for c in table['runtime_alter_columns']]) if table.get('runtime_alter_columns') else '') + '</details>')
    namespace_rows = []
    for database, metadata in snapshot['databases'].items():
        for schema in metadata['schemas']:
            base_tables = sum(t['schema_name'] == schema for t in metadata['tables'])
            purpose = ('Identity, OTP, sessions, devices and authentication audit'
                       if database == 'pandapay_auth' else
                       'Wallet, transactions, catalogue, rewards and application data'
                       if schema == 'public' else 'Product helper functions, including user context and access helpers')
            namespace_rows.append((code(database), code(schema), str(base_tables),
                                   str(sum(v['schema'] == schema for v in metadata['views'])),
                                   str(sum(f['schema'] == schema for f in metadata['functions'])), e(purpose)))
    namespace_table = grid(['Database', 'Schema namespace', 'Tables', 'Views', 'App functions', 'Responsibility'], namespace_rows)
    database_objects = []
    for database, metadata in snapshot['databases'].items():
        database_objects.append(f'<h3>{e(database)}</h3>')
        for view in metadata['views']:
            database_objects.append(f'<details class="source-table"><summary>{code(view["schema"] + "." + view["name"])} <span class="pill">View</span></summary><pre><code>{e(view["definition"])}</code></pre></details>')
        database_objects.append('<h4>Enum types</h4>' + grid(['Type', 'Allowed values'], [(code(v['schema'] + '.' + v['name']), e(', '.join(v['values']))) for v in metadata['enums']]))
        database_objects.append('<h4>Application functions / procedures</h4><p class="footnote">Extension-owned functions are excluded. Signatures are listed here; function bodies and effective role grants require a separate code/permissions review.</p>' + grid(['Function', 'Arguments', 'Returns', 'Execution context'], [
            (code(f['schema'] + '.' + f['name']), code(f['arguments']), code(f['returns']), 'SECURITY DEFINER' if f['security_definer'] else 'Invoker') for f in metadata['functions']]))
    payload = json.dumps(all_tables, separators=(',', ':')).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    captured_local = datetime.fromisoformat(snapshot['captured_at']).astimezone(ZoneInfo('Asia/Kolkata')).strftime('%d %b %Y, %H:%M IST')
    return f'''
<section class="db-panel" id="database-panel" role="tabpanel" aria-labelledby="database-tab" tabindex="0" hidden>
  <div class="section-heading"><div><div class="eyebrow">Data architecture · product + authentication</div><h2>Two server databases, distinct schemas</h2><p>Explore product and authentication separately, with device storage listed on its own.</p></div><a class="download-link" href="../artifacts/security-review-2026-10-20/schema-details.json" download>Download metadata JSON ↗</a></div>
  <div id="database-boundaries"><h3>Database & schema boundaries</h3><p><strong>2 PostgreSQL databases · 3 database-scoped schema namespaces.</strong> The name <code>public</code> appears in both databases, but each is a separate namespace with its own tables. The <code>pandapay</code> schema inside the product database contains helper functions; it is distinct from the database with the same name.</p>{namespace_table}<p class="footnote"><strong>Device storage:</strong> the app also uses SQLite for local financial stores, caches and queues. Its {e(sqlite.get('table_count', ''))} source-defined tables are documented separately; SQLite is not a third backend database. System/internal PostgreSQL schemas are outside the application schema inventory.</p><div class="boundary-actions"><button type="button" class="control-button" data-database-scope="pandapay">Product diagram · 89 tables</button><button type="button" class="control-button" data-database-scope="pandapay_auth">Authentication diagram · 7 tables</button><a href="#database-device">Device SQLite schemas ↓</a></div></div>
  <div class="db-metrics"><div><strong>{count}</strong><span>PostgreSQL tables</span></div><div><strong>{column_count:,}</strong><span>Columns</span></div><div><strong>{fk_count}</strong><span>Foreign keys</span></div><div><strong>{view_count} / {function_count}</strong><span>Views / app functions</span></div><div><strong>{enum_count} / {trigger_count}</strong><span>Enum types / triggers</span></div><div><strong>{policy_count}</strong><span>RLS policies</span></div></div>
  <p class="scope-note"><strong>Historical local metadata snapshot:</strong> {e(captured_local)}. This explorer was not recaptured for this implementation status update and does not represent the current production schema. At capture, all user-defined schemas in <code>pandapay</code> and <code>pandapay_auth</code> were inspected; their {count} base tables were in <code>public</code>. No customer records or production database were inspected for this metadata snapshot. Primary keys (PK), foreign keys (FK), defaults, indexes, checks, policies and triggers are included below. The capture includes <code>recurring_series.user_edited</code>, added locally after the original audit dictionary. See <a href="#{e(status_anchor)}" data-show-audit>current implementation status</a> for later backend/recovery work.</p>
  <div class="identity-bridge"><div><span class="pill">Identity database · public schema</span><strong>pandapay_auth.public.users.id</strong><small>Identity, OTP, sessions and devices</small></div><span class="logical-bridge" aria-hidden="true">- - - →</span><div><span class="pill">Product database · public schema</span><strong>pandapay.public.profiles.id</strong><small>Wallet, transactions, rewards and preferences</small></div><p>Shared identity is coordinated by the services. There is <strong>no cross-database foreign key</strong>; provisioning, logout and account erasure must coordinate across both. Labels use <code>database.schema.table.column</code> to make ownership explicit.</p></div>
  <div class="domain-grid">{domain_cards}</div>
  <div class="explorer-controls"><label class="search-label">Search tables or columns<input id="schema-search" type="search" placeholder="Try transactions, email, card_product_id…" autocomplete="off"></label><label>Database<select id="schema-database"><option value="">Both databases</option><option value="pandapay">Product · pandapay</option><option value="pandapay_auth">Identity · pandapay_auth</option></select></label><label>Domain<select id="schema-domain"><option value="">All domains</option>{''.join(f'<option>{e(d)}</option>' for d in domains)}</select></label><button type="button" id="schema-reset" class="control-button">Reset filters</button></div>
  <div class="diagram-card"><div class="diagram-toolbar"><div><strong>Entity relationship diagram</strong><span id="schema-count" role="status" aria-live="polite">{count} tables · {fk_count} foreign keys</span></div><div class="zoom-controls"><button type="button" id="zoom-out" aria-label="Zoom out">−</button><output id="zoom-label">100%</output><button type="button" id="zoom-in" aria-label="Zoom in">+</button><button type="button" id="zoom-fit">Fit width</button></div></div><div class="diagram-legend"><span><i class="legend-line"></i> Enforced FK · child → parent</span><span>PK primary key · FK foreign key</span><span>Click a table to inspect its full schema</span></div><div class="diagram-scroll" id="diagram-scroll" tabindex="0" aria-label="Scrollable database relationship diagram"><svg id="schema-diagram" role="group" aria-label="Database table relationships" xmlns="http://www.w3.org/2000/svg"></svg></div><p id="diagram-selection" class="diagram-selection">Every table is included. Use filters for a clearer view; zoom and scroll to explore.</p></div>
  {optimization_inventory()}
  <h3>Table dictionary</h3><p class="footnote">Open any table to inspect all columns and controls. RLS enabled does not establish that every API operation is correctly authorized. The auth service uses application-level checks; its tables do not have RLS.</p><p id="schema-empty" hidden>No tables match. Try another search or reset the filters.</p><div id="schema-dictionary">{''.join(dictionaries)}</div>
  <h3 id="database-source-only">Migration definitions absent from the local snapshot</h3><p>These tables exist in source migrations but were absent from the inspected local database. Pending migration filenames do not prove that all their objects are absent: some objects already exist locally. This tab keeps those states explicit.</p>{''.join(source_sections)}
  <h3 id="database-device">On-device SQLite storage</h3><p>{e(sqlite.get('table_count', ''))} source-defined device tables are listed below. This is a source inventory, not an inspection of an emulator or user device. Local queues, caches and stores serve different purposes from server tables; matching names do not establish a foreign key or a redundant copy.</p>{''.join(sqlite_sections)}<ul>{''.join(f'<li>{e(note)}</li>' for note in sqlite.get('notes', []))}</ul>
  <h3 id="database-other-objects">Views, enum types & application functions</h3>{''.join(database_objects)}
  <p class="scope-note">Review candidates such as unused auth tables, duplicate catalogue definitions and migration drift remain documented in the <a href="#5-redundant-data-code-and-misleading-words" data-show-audit>audit findings</a>. This explorer adds visibility; it does not change the schema or resolve the security findings.</p>
  <noscript><p>JavaScript is needed for the interactive diagram and filters. The full table dictionary and schema definitions remain readable below.</p></noscript>
  <script type="application/json" id="schema-data">{payload}</script>
</section>'''


DATABASE_CSS = r'''
[hidden]{display:none!important}.report-tabs{display:flex;gap:6px;padding:6px;margin:4px 0 24px;border:1px solid var(--line);background:#e8efed;border-radius:14px;width:max-content;max-width:100%}.report-tabs button{border:0;background:transparent;padding:11px 22px;border-radius:10px;font:700 14px inherit;color:#526175;cursor:pointer}.report-tabs button[aria-selected=true]{background:#fff;color:var(--green);box-shadow:0 2px 7px #183e2620}.report-tabs .tab-count{font-size:11px;padding:3px 7px;background:var(--green-soft);border-radius:10px;margin-left:6px}.stack-strip{display:grid;grid-template-columns:repeat(4,1fr);border-top:1px solid var(--line);margin-top:24px;padding-top:18px;gap:16px}.stack-strip strong{display:block;color:#324557;font-size:12px}.stack-strip span{font-size:12px;color:var(--muted);display:block}.stack-tags{margin-top:12px;display:flex;gap:6px;flex-wrap:wrap}.stack-tags span{background:#edf3f1;border-radius:5px;font:600 11px/1.5 ui-monospace,monospace;color:#386251;padding:3px 7px}.db-panel{min-width:0}.db-panel h2{font-size:30px;letter-spacing:-.03em;margin:3px 0 5px;line-height:1.25}.db-panel h3{font-size:23px;margin:32px 0 10px;letter-spacing:-.02em}.db-panel h4{font-size:15px;margin:18px 0 6px}.section-heading{display:flex;align-items:center;justify-content:space-between;gap:20px}.section-heading p{color:var(--muted);font-size:14px;margin:6px 0 16px}.download-link{font-size:12px;font-weight:700;white-space:nowrap}.db-metrics{display:grid;grid-template-columns:repeat(6,1fr);gap:10px;margin:16px 0}.db-metrics>div{padding:15px 17px;background:white;border:1px solid var(--line);border-radius:13px}.db-metrics strong{font-size:25px;display:block;line-height:1.15}.db-metrics span{font-size:11px;color:var(--muted)}.scope-note{padding:14px 17px;border:1px solid #cbded5;background:#edf6f1;border-radius:12px;font-size:13px;color:#3d5b50}.identity-bridge{display:grid;grid-template-columns:1fr 90px 1fr;background:#fff;border:1px solid var(--line);border-radius:16px;padding:20px 24px;gap:10px;align-items:center;margin:20px 0}.identity-bridge>div{display:flex;flex-direction:column;align-items:flex-start;gap:5px}.identity-bridge strong{font:700 15px ui-monospace,monospace}.identity-bridge small{color:var(--muted)}.identity-bridge p{grid-column:1/-1;font-size:12px;border-top:1px solid var(--line);margin:9px 0 0;padding-top:10px;color:var(--muted)}.logical-bridge{color:var(--amber);text-align:center;font-size:21px}.pill{font-size:10px;line-height:1.4;padding:4px 8px;border-radius:6px;background:#edf2f6;color:#4d6273;font-weight:700;white-space:nowrap}.pill.ok{background:var(--green-soft);color:var(--green)}.pill.warn{background:var(--amber-soft);color:var(--amber)}.domain-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin:16px 0}.domain-card{border:1px solid var(--line);border-radius:11px;background:white;text-align:left;padding:12px 14px;cursor:pointer;color:var(--ink)}.domain-card strong{display:block;font-size:12px}.domain-card span{font-size:11px;color:var(--muted)}.domain-card:hover,.domain-card.active{border-color:#79b89e;background:var(--green-soft)}.explorer-controls{display:flex;align-items:flex-end;gap:12px;flex-wrap:wrap;background:#fff;border:1px solid var(--line);padding:16px;border-radius:14px;margin:20px 0 12px}.explorer-controls label{font-size:11px;font-weight:700;color:var(--muted);display:flex;flex-direction:column;gap:6px;min-width:180px}.explorer-controls .search-label{flex:1;min-width:240px}.explorer-controls input,.explorer-controls select{width:100%;height:42px;border:1px solid #cfdae0;border-radius:8px;font:13px inherit;color:var(--ink);background:#fbfcfd;padding:9px 11px}.control-button,.zoom-controls button{border:1px solid #cbd9d2;border-radius:8px;background:#fff;color:#295c48;padding:9px 12px;font:600 12px inherit;cursor:pointer;min-height:36px}.control-button{height:42px}.control-button:hover,.zoom-controls button:hover{background:var(--green-soft)}button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible,a:focus-visible,[tabindex]:focus-visible{outline:3px solid #348a76;outline-offset:3px}.diagram-card{border:1px solid var(--line);border-radius:16px;background:#fff;overflow:hidden}.diagram-toolbar{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:15px 18px;border-bottom:1px solid var(--line)}.diagram-toolbar strong{font-size:14px}.diagram-toolbar span{display:block;font-size:11px;color:var(--muted)}.zoom-controls{display:flex;align-items:center;gap:5px}.zoom-controls output{min-width:50px;text-align:center;font:600 11px ui-monospace,monospace}.diagram-legend{display:flex;gap:18px;flex-wrap:wrap;font-size:10px;padding:9px 18px;color:var(--muted)}.legend-line{width:20px;height:0;border-top:2px solid #527b8b;display:inline-block;vertical-align:middle;margin-right:3px}.diagram-scroll{height:570px;overflow:auto;background-color:#f7faf9;background-image:radial-gradient(#c9d9d1 .7px,transparent .7px);background-size:18px 18px;overscroll-behavior:contain}.diagram-scroll svg{display:block;max-width:none}.diagram-selection{margin:0;padding:12px 18px;font-size:12px;color:var(--muted);border-top:1px solid var(--line)}.erd-node{cursor:pointer}.erd-node rect{fill:#fff;stroke:#bdcfc5;stroke-width:1.3}.erd-node .node-head{fill:#eaf4ee;stroke:none}.erd-node.auth .node-head{fill:#edf1fb}.erd-node.selected rect{stroke:#08775c;stroke-width:2.7}.erd-node.related rect{stroke:#4683aa;stroke-width:2}.erd-node text{fill:#26394a;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;pointer-events:none}.erd-node .erd-title{font-size:12px;font-weight:750}.erd-node .erd-subtitle{font:9px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;fill:#61788a}.erd-node .erd-column{font-size:10px;fill:#465d6c}.erd-node .erd-more{font-size:9px;fill:#7a8c96}.erd-edge{stroke:#819ca7;stroke-width:1.4;fill:none;opacity:.24}.erd-edge.active{stroke:#08775c;stroke-width:2.5;opacity:.95}.erd-node.dim{opacity:.28}.schema-table{background:#fff;border:1px solid var(--line);border-radius:12px;margin:9px 0;scroll-margin-top:20px;overflow:hidden}.schema-table>summary{display:flex;align-items:center;gap:14px;list-style:none;padding:14px 17px;cursor:pointer}.schema-table>summary:before{content:'+';font-size:18px;color:var(--green);width:14px;flex-shrink:0}.schema-table[open]>summary:before{content:'−'}.schema-table>summary::-webkit-details-marker{display:none}.table-title{font:700 13px ui-monospace,monospace;min-width:240px;color:#234739;overflow-wrap:anywhere}.table-meta{font-size:11px;color:var(--muted);flex:1}.table-content{padding:2px 18px 18px;border-top:1px solid var(--line)}.schema-table .table-wrap{margin:12px 0}.schema-table .table-wrap th,.schema-table .table-wrap td{min-width:80px}.schema-table .table-wrap th:nth-child(1){min-width:160px}.source-table{background:#fff;border:1px solid var(--line);border-radius:12px;padding:13px 17px;margin:9px 0}.source-table summary{cursor:pointer;font-size:13px}.source-table summary .pill{margin-left:12px}.source-table pre{font-size:11px;max-height:430px}.source-table p{font-size:13px}.db-panel .table-wrap pre{font-size:11px}.db-panel footer{margin-top:30px}
@media(max-width:1000px){.db-metrics{grid-template-columns:repeat(3,1fr)}.explorer-controls label{flex:1}.stack-strip{grid-template-columns:repeat(2,1fr)}.domain-grid{grid-template-columns:repeat(3,1fr)}}
@media(max-width:600px){.section-heading{display:block}.db-panel h2{font-size:25px}.download-link{display:inline-block;margin-bottom:7px}.db-metrics{grid-template-columns:repeat(2,1fr)}.domain-grid{grid-template-columns:repeat(2,1fr)}.identity-bridge{grid-template-columns:1fr;padding:16px}.logical-bridge{transform:rotate(90deg);height:36px}.identity-bridge strong{font-size:12px}.explorer-controls{padding:12px;gap:9px}.explorer-controls label,.explorer-controls .search-label{min-width:100%;flex:auto}.diagram-toolbar{align-items:flex-start;flex-direction:column}.diagram-scroll{height:450px}.schema-table>summary{gap:6px;flex-wrap:wrap}.table-title{min-width:0;flex:1;font-size:12px}.table-meta{width:100%;flex:auto;order:3;margin-left:20px}.schema-table>summary .pill{font-size:9px}.table-content{padding:0 10px 12px}.report-tabs{width:100%}.report-tabs button{flex:1;padding:10px}.stack-strip{gap:12px}}
@media print{[role=tabpanel][hidden]{display:block!important}.report-tabs,.explorer-controls,.zoom-controls,.domain-grid{display:none}.db-panel{break-before:page}.diagram-scroll{height:auto;overflow:visible}.diagram-scroll svg{width:100%!important;height:auto!important}.schema-table{break-inside:avoid}.table-content .table-wrap{break-inside:auto}}
.report-tabs button{font-family:inherit;font-size:14px;font-weight:700}.explorer-controls input,.explorer-controls select{font-family:inherit;font-size:13px}.control-button,.zoom-controls button{font-family:inherit;font-size:12px;font-weight:600}
.boundary-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin:12px 0 22px}.boundary-actions a{font-size:12px}.identity-bridge strong{overflow-wrap:anywhere}
'''


DATABASE_JS = r'''
(() => {
  'use strict';
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  function selectTab(id, updateHash = true) {
    for (const tab of tabs) {
      const active = tab.id === id;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      document.getElementById(tab.getAttribute('aria-controls')).hidden = !active;
    }
    if (updateHash) history.replaceState(null, '', id === 'database-tab' ? '#database' : '#audit');
  }
  for (const tab of tabs) {
    tab.addEventListener('click', () => selectTab(tab.id));
    tab.addEventListener('keydown', event => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
      event.preventDefault();
      const index = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (tabs.indexOf(tab) + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      selectTab(tabs[index].id); tabs[index].focus();
    });
  }
  const tables = JSON.parse(document.getElementById('schema-data').textContent);
  const byKey = new Map(tables.map(t => [t.key, t]));
  const edges = tables.flatMap(t => t.constraints.filter(c => c.kind === 'f').map(c => ({source:t.key,target:`${t.database}.${c.target_schema}.${c.target_table}`,definition:c.definition,columns:c.columns}))).filter(e => byKey.has(e.target));
  const search = document.getElementById('schema-search');
  const database = document.getElementById('schema-database');
  const domain = document.getElementById('schema-domain');
  const diagram = document.getElementById('schema-diagram');
  const scroll = document.getElementById('diagram-scroll');
  let visible = tables, zoom = 1, selected = '', width = 1360, height = 1000;
  const ns = 'http://www.w3.org/2000/svg';
  const svg = (name, attrs = {}, text) => { const el = document.createElementNS(ns,name); for (const [key,value] of Object.entries(attrs)) el.setAttribute(key,String(value)); if (text != null) el.textContent=text; return el; };
  function size() { diagram.style.width=`${width*zoom}px`; diagram.style.height=`${height*zoom}px`; document.getElementById('zoom-label').textContent=`${Math.round(zoom*100)}%`; }
  function inspect(key) {
    const table = byKey.get(key); if (!table) return;
    selected=key; draw();
    const details=document.getElementById(table.anchor); details.open=true;
    details.scrollIntoView({behavior:'smooth',block:'start'});
    details.querySelector('summary').focus({preventScroll:true});
  }
  function draw() {
    diagram.replaceChildren();
    const cols = Math.min(4,Math.max(1,visible.length));
    width=cols*330+40; height=Math.max(260,Math.ceil(visible.length/cols)*178+40);
    diagram.setAttribute('viewBox',`0 0 ${width} ${height}`);
    diagram.append(svg('title',{},'All filtered database tables and enforced foreign-key relationships'));
    const defs=svg('defs'), marker=svg('marker',{id:'fk-arrow',viewBox:'0 0 10 10',refX:9,refY:5,markerWidth:6,markerHeight:6,orient:'auto-start-reverse'});
    marker.append(svg('path',{d:'M 0 0 L 10 5 L 0 10 z',fill:'#527b8b'}));defs.append(marker);diagram.append(defs);
    const ordered=[...visible].sort((a,b)=>a.domain.localeCompare(b.domain)||a.table_name.localeCompare(b.table_name));
    const positions=new Map(ordered.map((t,i)=>[t.key,{x:24+(i%cols)*330,y:24+Math.floor(i/cols)*178}]));
    const visibleEdges=edges.filter(e=>positions.has(e.source)&&positions.has(e.target));
    const related=new Set(edges.filter(e=>e.source===selected||e.target===selected).flatMap(e=>[e.source,e.target]));
    const lineLayer=svg('g',{'aria-hidden':'true'});
    for(const edge of [...visibleEdges].sort((a,b)=>Number(a.source===selected||a.target===selected)-Number(b.source===selected||b.target===selected))) {
      const a=positions.get(edge.source), b=positions.get(edge.target), right=b.x>a.x;
      const x1=a.x+(right?300:0),x2=b.x+(right?0:300),y1=a.y+75,y2=b.y+75;
      const bend=right?50:-50;
      const d=edge.source===edge.target?`M ${a.x+300} ${a.y+55} C ${a.x+340} ${a.y+55},${a.x+340} ${a.y+118},${a.x+300} ${a.y+118}`:`M ${x1} ${y1} C ${x1+bend} ${y1},${x2-bend} ${y2},${x2} ${y2}`;
      const path=svg('path',{d,class:`erd-edge${edge.source===selected||edge.target===selected?' active':''}`,'marker-end':'url(#fk-arrow)'});path.append(svg('title',{},edge.definition));lineLayer.append(path);
    }
    diagram.append(lineLayer);
    for (const table of ordered) {
      const p=positions.get(table.key), isAuth=table.database==='pandapay_auth';
      const node=svg('g',{class:`erd-node${isAuth?' auth':''}${table.key===selected?' selected':related.has(table.key)?' related':selected?' dim':''}`,transform:`translate(${p.x},${p.y})`,tabindex:0,role:'button','aria-label':`${table.database}.${table.table_name}, ${table.columns.length} columns. Open table details.`});
      node.append(svg('rect',{width:300,height:150,rx:10}),svg('path',{d:'M 10 0 H 290 Q 300 0 300 10 V 43 H 0 V 10 Q 0 0 10 0 Z',class:'node-head'}));
      node.append(svg('text',{x:12,y:19,class:'erd-title'},table.table_name),svg('text',{x:12,y:34,class:'erd-subtitle'},`${isAuth?'AUTH':'PRODUCT'} · ${table.domain}`));
      const keyColumns=new Set(table.constraints.filter(k=>k.kind==='p'||k.kind==='f').flatMap(k=>k.columns||[]));
      const preview=[...table.columns.filter(c=>keyColumns.has(c.name)),...table.columns.filter(c=>!keyColumns.has(c.name))].slice(0,4);
      preview.forEach((column,i)=>{
        const flags=table.constraints.filter(k=>(k.kind==='p'||k.kind==='f')&&(k.columns||[]).includes(column.name)).map(k=>k.kind==='p'?'PK':'FK').join('/');
        node.append(svg('text',{x:12,y:61+i*18,class:'erd-column'},`${flags?flags+' ':''}${column.name}`));
      });
      node.append(svg('text',{x:12,y:138,class:'erd-more'},`${table.columns.length} columns · ${table.rls_enabled?'RLS on':'RLS off'} · click for full schema`));
      node.addEventListener('click',()=>inspect(table.key));
      node.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();inspect(table.key);}});
      diagram.append(node);
    }
    document.getElementById('schema-count').textContent=`${visible.length} of ${tables.length} tables · ${visibleEdges.length} visible foreign keys`;
    document.getElementById('diagram-selection').textContent=selected?`${byKey.get(selected).table_name}: related tables and connecting keys are highlighted. Its complete definition is open below.`:'Every matching table is included. Use filters for a clearer view; zoom and scroll to explore.';
    size();
  }
  function filter() {
    const term=search.value.trim().toLowerCase();
    visible=tables.filter(t=>(!database.value||t.database===database.value)&&(!domain.value||t.domain===domain.value)&&(!term||[t.table_name,t.domain,...t.columns.map(c=>c.name)].some(v=>v.toLowerCase().includes(term))));
    const keys=new Set(visible.map(t=>t.key));
    for(const details of document.querySelectorAll('.schema-table')) details.hidden=!keys.has(details.dataset.key);
    for(const card of document.querySelectorAll('.domain-card'))card.classList.toggle('active',card.dataset.domain===domain.value);
    document.getElementById('schema-empty').hidden=visible.length!==0;
    selected='';draw(); scroll.scrollTo(0,0);
  }
  search.addEventListener('input',filter);database.addEventListener('change',filter);domain.addEventListener('change',filter);
  document.getElementById('schema-reset').addEventListener('click',()=>{search.value='';database.value='';domain.value='';filter();});
  for(const button of document.querySelectorAll('[data-database-scope]'))button.addEventListener('click',()=>{database.value=button.dataset.databaseScope;domain.value='';search.value='';filter();scroll.scrollIntoView({behavior:'smooth',block:'center'});});
  for(const card of document.querySelectorAll('.domain-card'))card.addEventListener('click',()=>{domain.value=card.dataset.domain;database.value='';search.value='';filter();scroll.scrollIntoView({behavior:'smooth',block:'center'});});
  document.getElementById('zoom-in').addEventListener('click',()=>{zoom=Math.min(2,zoom+.15);size();});
  document.getElementById('zoom-out').addEventListener('click',()=>{zoom=Math.max(.25,zoom-.15);size();});
  document.getElementById('zoom-fit').addEventListener('click',()=>{zoom=Math.max(.2,Math.min(1,scroll.clientWidth/width));size();});
  document.addEventListener('click',event=>{
    const link=event.target.closest('a[data-table-link]');if(link){event.preventDefault();const target=byKey.get(link.dataset.tableLink);if(!visible.includes(target)){search.value='';database.value='';domain.value='';filter();}inspect(link.dataset.tableLink);history.replaceState(null,'','#'+target.anchor);}
    if(event.target.closest('[data-show-audit]'))selectTab('audit-tab',false);
  });
  function fromHash() {
    let hash=location.hash.slice(1);try{hash=decodeURIComponent(hash);}catch{}
    selectTab(hash==='database'||hash.startsWith('table-')||hash.startsWith('database-')?'database-tab':'audit-tab',false);
    const details=document.getElementById(hash);if(details?.classList.contains('schema-table')){details.open=true;selected=details.dataset.key;draw();}
  }
  window.addEventListener('hashchange',fromHash);
  draw();fromHash();
})();
'''
