"""Render the audit Markdown as a standalone, responsive HTML document."""
from html import escape
from collections import Counter
import os
import json
from pathlib import Path
import re
from database_report import DATABASE_CSS, DATABASE_JS, render_database

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'docs/security-and-backend-audit-2026-10-20.md'
DESTINATION = ROOT / 'docs/security-and-backend-audit-2026-10-20.html'

STATUS_STYLES = {
    'Implemented in source': 'implemented',
    'Partial': 'partial',
    'Open': 'open',
}

STATUS_CSS = '''
.status-pill{display:inline-block;padding:4px 9px;border-radius:8px;font-size:11px;font-weight:750;line-height:1.4;white-space:normal}
.status-pill.implemented{background:#e8f5ef;color:#086246;border:1px solid #b9decc}
.status-pill.partial{background:#fff3e7;color:#85440d;border:1px solid #efd5b2}
.status-pill.open{background:#fff0f0;color:#9b2934;border:1px solid #edc4ca}
.snapshot-note{padding:13px 17px;border:1px solid #cbded5;background:#edf6f1;border-radius:12px;font-size:13px;color:#3d5b50;margin:0 0 24px}
.architecture-svg .verified-label{fill:#08775c}
'''


def inline(text):
    if text in STATUS_STYLES:
        return f'<span class="status-pill {STATUS_STYLES[text]}">{escape(text)}</span>'
    for label, style in STATUS_STYLES.items():
        if text.startswith(label + ' — '):
            return f'<span class="status-pill {style}">{escape(label)}</span> — {inline(text[len(label) + 3:])}'
    token = re.compile(r'\[([^\]]+)\]\(([^)]+)\)|`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*')
    output, cursor = [], 0
    for match in token.finditer(text):
        output.append(escape(text[cursor:match.start()]))
        if match.group(1) is not None:
            label, raw_url = match.group(1), match.group(2)
            line = re.search(r':(\d+)$', raw_url)
            target = raw_url[:line.start()] if line else raw_url
            if target.startswith('https://') or target.startswith('http://'):
                href = target
            else:
                if target.startswith('/'):
                    absolute_target = Path(target)
                    try:
                        absolute_target.relative_to(ROOT)
                        href = os.path.relpath(absolute_target, DESTINATION.parent)
                    except ValueError:
                        href = ''
                else:
                    href = os.path.normpath(target)
                if line:
                    href += f'#L{line.group(1)}'
            external = ' target="_blank" rel="noopener noreferrer"' if href.startswith('http') else ''
            output.append(f'<a href="{escape(href, quote=True)}"{external}>{inline(label)}</a>')
        elif match.group(3) is not None:
            output.append(f'<code>{escape(match.group(3))}</code>')
        elif match.group(4) is not None:
            output.append(f'<strong>{escape(match.group(4))}</strong>')
        else:
            output.append(f'<em>{escape(match.group(5))}</em>')
        cursor = match.end()
    output.append(escape(text[cursor:]))
    return ''.join(output)


def slug(text):
    return re.sub(r'[^a-z0-9]+', '-', re.sub(r'[`*_]', '', text).lower()).strip('-')


ARCHITECTURE_SVG = '''
<svg class="architecture-svg" viewBox="0 0 1120 600" role="img" aria-labelledby="arch-title arch-desc" xmlns="http://www.w3.org/2000/svg">
  <title id="arch-title">PandaPay high-level architecture and trust boundaries</title>
  <desc id="arch-desc">Current source connects Flutter clients through a TLS proxy to separate identity and product services. Product access checks auth session state with a five-second cache and uses user-context row-level security. Operations cover encrypted recovery for both databases. The amber worker arrow marks remaining privilege acceptance; local recovery proof is not production rollout approval.</desc>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#526175"/></marker>
    <marker id="arrow-gap" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#c77725"/></marker>
  </defs>
  <g class="edges" fill="none" stroke="#526175" stroke-width="2" marker-end="url(#arrow)">
    <path d="M 255 128 C 290 128 300 128 335 128"/><path d="M 480 112 C 520 112 515 75 555 75"/><path d="M 480 145 C 520 145 515 215 555 215"/>
    <path d="M 795 75 L 850 75"/><path d="M 795 215 L 850 215"/>
    <path d="M 675 165 L 675 120" stroke="#08775c"/>
    <path d="M 555 224 C 490 260 465 300 250 348"/><path d="M 790 260 C 790 300 790 312 790 350"/>
    <path d="M 535 455 C 665 485 780 350 850 260" stroke="#c77725" stroke-dasharray="7 6" marker-end="url(#arrow-gap)"/><path d="M 860 455 C 915 400 950 300 950 270"/>
    <path d="M 860 455 C 900 360 930 220 930 120" stroke="#08775c"/>
  </g>
  <g class="edge-label"><text x="280" y="114">HTTPS</text><text x="495" y="91">auth routes</text><text x="493" y="183">product routes</text><text x="804" y="62">JWT + identity</text><text x="700" y="141" class="verified-label">session check</text><text x="700" y="156" class="verified-label">5 s cache</text><text x="500" y="281">email / SMS / Google</text><text x="803" y="304">user context + RLS</text><text x="656" y="475" class="gap-label">worker role gate</text><text x="891" y="382">paired exports</text><text x="937" y="356" class="verified-label">auth included</text></g>
  <g class="node clients"><rect x="25" y="35" width="230" height="210" rx="18"/><text class="node-title" x="45" y="68">Clients</text><rect class="inner" x="43" y="84" width="194" height="61" rx="12"/><text x="57" y="109">Flutter app</text><text class="muted" x="57" y="131">SQLite + offline queue</text><rect class="inner" x="43" y="160" width="194" height="61" rx="12"/><text x="57" y="196">Flutter admin console</text></g>
  <g class="node edge"><rect x="335" y="88" width="145" height="80" rx="16"/><text class="node-title" x="354" y="120">TLS edge</text><text class="muted" x="354" y="144">reverse proxy</text></g>
  <g class="node service"><rect x="555" y="30" width="240" height="90" rx="16"/><text class="node-title" x="575" y="65">Auth service</text><text class="muted" x="575" y="91">OTP · identity · sessions</text></g>
  <g class="node service"><rect x="555" y="165" width="240" height="95" rx="16"/><text class="node-title" x="575" y="201">Product API</text><text class="muted" x="575" y="229">JWT · user/admin guards</text></g>
  <g class="node data"><rect x="850" y="30" width="235" height="90" rx="16"/><text class="node-title" x="870" y="65">Auth database</text><text class="muted" x="870" y="91">users · OTP · refresh · audit</text></g>
  <g class="node data"><rect x="850" y="175" width="235" height="95" rx="16"/><text class="node-title" x="870" y="211">Product database</text><text class="muted" x="870" y="239">wallet · transactions · catalogue</text></g>
  <g class="node support"><rect x="25" y="305" width="225" height="92" rx="16"/><text class="node-title" x="45" y="341">Providers</text><text class="muted" x="45" y="367">mail · SMS · Google</text></g>
  <g class="node support"><rect x="325" y="410" width="210" height="90" rx="16"/><text class="node-title" x="345" y="446">Workers</text><text class="muted" x="345" y="473">mail · maintenance</text></g>
  <g class="node support"><rect x="600" y="410" width="260" height="90" rx="16"/><text class="node-title" x="620" y="446">Operations</text><text class="muted" x="620" y="473">migrations · backups · restore</text></g>
</svg>
'''


def render(markdown):
    lines = markdown.splitlines()
    html, headings, i = [], [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith('```'):
            lang = line[3:].strip()
            block = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                block.append(lines[i])
                i += 1
            i += 1
            if lang == 'mermaid':
                html.append(f'<figure class="architecture">{ARCHITECTURE_SVG}<figcaption>Current source flow includes authoritative session checks and paired encrypted recovery. The amber worker arrow marks remaining privilege work. Recovery evidence is local and predates the latest merged feature migrations; target acceptance is still required.</figcaption></figure>')
            else:
                html.append(f'<pre><code>{escape(chr(10).join(block))}</code></pre>')
            continue
        header = re.match(r'^(#{1,6})\s+(.+)$', line)
        if header:
            level, title = len(header.group(1)), header.group(2)
            anchor = slug(title)
            if level > 1:
                html.append(f'<h{level} id="{anchor}">{inline(title)}</h{level}>')
            if level == 2:
                headings.append((anchor, re.sub(r'[`*_]', '', title)))
            i += 1
            continue
        if re.fullmatch(r'\s*[-*_]{3,}\s*', line):
            html.append('<hr>')
            i += 1
            continue
        if i + 1 < len(lines) and line.lstrip().startswith('|') and re.match(r'^\s*\|?\s*:?-{3,}', lines[i + 1]):
            raw_rows = [line]
            i += 2
            while i < len(lines) and lines[i].lstrip().startswith('|'):
                raw_rows.append(lines[i])
                i += 1
            rows = [[cell.strip() for cell in row.strip().strip('|').split('|')] for row in raw_rows]
            if rows:
                head = ''.join(f'<th scope="col">{inline(cell)}</th>' for cell in rows[0])
                body = ''.join('<tr>' + ''.join(f'<td>{inline(cell)}</td>' for cell in row) + '</tr>' for row in rows[1:])
                html.append(f'<div class="table-wrap"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>')
            continue
        if re.match(r'^\s*[-+]\s+', line):
            items = []
            while i < len(lines) and re.match(r'^\s*[-+]\s+', lines[i]):
                items.append(re.sub(r'^\s*[-+]\s+', '', lines[i]))
                i += 1
            html.append('<ul>' + ''.join(f'<li>{inline(item)}</li>' for item in items) + '</ul>')
            continue
        if re.match(r'^\s*\d+\.\s+', line):
            items = []
            while i < len(lines) and re.match(r'^\s*\d+\.\s+', lines[i]):
                items.append(re.sub(r'^\s*\d+\.\s+', '', lines[i]))
                i += 1
            html.append('<ol>' + ''.join(f'<li>{inline(item)}</li>' for item in items) + '</ol>')
            continue
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r'^(#{1,6}\s|```|\s*[-+]\s|\s*\d+\.\s|\s*\|)', lines[i]):
            if re.fullmatch(r'\s*[-*_]{3,}\s*', lines[i]):
                break
            para.append(lines[i].strip())
            i += 1
        html.append(f'<p>{inline(" ".join(para))}</p>')
    return '\n'.join(html), headings


markdown_source = SOURCE.read_text()
review = re.search(r'^Review update: (.+)\.$', markdown_source, re.M)
revision = re.search(r'^Reviewed source: `([^`]+)` at `([^`]+)`', markdown_source, re.M)
if not review or not revision:
    raise ValueError('Audit Markdown must declare its review date and source revision')
review_date = escape(review.group(1))
review_branch, review_revision = map(escape, revision.groups())
if re.search(r'^Reviewed source:.*uncommitted', markdown_source, re.M):
    review_revision += ' + working changes'
security_status = Counter(re.findall(
    r'^\| S\d{2} \| (Implemented in source|Partial|Open) \|', markdown_source, re.M,
))
if sum(security_status.values()) != 18:
    raise ValueError('Expected exactly 18 current security finding statuses')
# Count the whole report, including the additional system-design findings.
# The S01–S18 subset alone must not appear to describe the full backlog.
remaining_work = json.loads((ROOT / 'artifacts/security-review-2026-10-20/remaining-work-2026-10-25.json').read_text())
finding_statuses = dict(re.findall(
    r'^\| ((?:S|B|A|D|C|N|M|W)\d{1,2}) \| (Implemented in source|Partial|Open) \|', markdown_source, re.M,
))
if len(finding_statuses) != 68:
    raise ValueError('Expected 68 original current finding statuses')
for line in markdown_source.splitlines():
    match = re.match(r'^\| (SD\d{2}) — ', line)
    if match:
        finding_statuses[match.group(1)] = line.split('|')[-2].strip().split(' — ')[0]
if finding_statuses != remaining_work['finding_statuses']:
    raise ValueError('Remaining-work register and current finding statuses disagree')
all_status = Counter(finding_statuses.values())
if dict(all_status) != remaining_work['status_counts'] or len(finding_statuses) != remaining_work['total_findings']:
    raise ValueError('Remaining-work counts are stale')
implementation_count = len(remaining_work['implementation_packages'])
gate_count = len(remaining_work['release_gates'])
covered = set()
for kind in ['implementation_packages', 'release_gates']:
    identifiers = [item['id'] for item in remaining_work[kind]]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError('Duplicate remaining-work package identity')
    for item in remaining_work[kind]:
        covered.update(item['finding_ids'])
unfinished = {name for name, status in finding_statuses.items() if status != 'Implemented in source'}
if not unfinished <= covered or not covered <= finding_statuses.keys():
    raise ValueError('Remaining-work mapping misses an unfinished finding or has unknown IDs')
remaining_source = ROOT / 'docs/security-remaining-work-2026-10-25.md'
remaining_markdown = remaining_source.read_text()
for text in [markdown_source, remaining_markdown]:
    for kind in ['implementation_packages', 'release_gates']:
        expected = [item['id'] for item in remaining_work[kind]]
        prefix = 'I' if kind == 'implementation_packages' else 'G'
        actual = re.findall(r'^\| (' + prefix + r'\d{2}) — ', text, re.M)
        if actual != expected:
            raise ValueError('Markdown package IDs disagree with the remaining-work register')

body, headings = render(markdown_source)
status_anchor = next(anchor for anchor, title in headings if title.startswith('Implementation status'))
toc = ''.join(f'<a href="#{anchor}">{escape(title)}</a>' for anchor, title in headings)
database_body = render_database(status_anchor=status_anchor)
document = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>PandaPay · Security and backend audit</title>
<style>
:root{{--ink:#1d2836;--muted:#637184;--paper:#f3f6f8;--card:#fff;--line:#dfe6eb;--green:#08775c;--green-soft:#e8f5ef;--amber:#a34b13;--amber-soft:#fff3e7;--red:#ad323b;--red-soft:#fff0f0;--blue:#355c8a;--shadow:0 16px 44px rgba(22,42,62,.08)}}
*{{box-sizing:border-box}}html{{scroll-behavior:smooth;scroll-padding-top:22px}}body{{margin:0;background:var(--paper);color:var(--ink);font:16px/1.65 Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}a{{color:#075f91;text-decoration-thickness:1px;text-underline-offset:3px}}a:hover{{color:#003d61}}.topbar{{height:5px;background:linear-gradient(90deg,#08775c,#56b99a 55%,#c3e8d5)}}.shell{{max-width:1440px;margin:0 auto;padding:42px 36px 70px}}.masthead{{display:flex;align-items:center;gap:14px;margin-bottom:26px;color:var(--muted);font-size:13px;letter-spacing:.09em;text-transform:uppercase;font-weight:700}}.mark{{display:grid;place-items:center;width:38px;height:38px;border-radius:12px;background:var(--green-soft);color:var(--green);font-size:20px;letter-spacing:0}}.hero{{position:relative;overflow:hidden;padding:38px 42px;border:1px solid var(--line);border-radius:24px;background:radial-gradient(ellipse at 92% 0%,#e6f5ec 0,transparent 38%),var(--card);box-shadow:var(--shadow)}}.eyebrow{{font-size:12px;letter-spacing:.14em;text-transform:uppercase;font-weight:800;color:var(--green)}}h1{{max-width:900px;margin:9px 0 10px;font-size:clamp(32px,4vw,48px);line-height:1.12;letter-spacing:-.04em}}.hero p{{max-width:960px;color:var(--muted);margin:10px 0}}.badge-row{{display:flex;flex-wrap:wrap;gap:9px;margin-top:22px}}.badge{{padding:7px 11px;border:1px solid var(--line);border-radius:999px;background:#fff;font-size:12px;font-weight:700;color:#415166}}.badge.red{{color:var(--red);background:var(--red-soft);border-color:#f4d2d2}}.stats{{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin:18px 0 24px}}.stat{{padding:16px 18px;border:1px solid var(--line);border-radius:16px;background:#fff;box-shadow:0 5px 15px rgba(22,42,62,.035)}}.stat strong{{display:block;font-size:25px;line-height:1.1;letter-spacing:-.03em}}.stat span{{display:block;margin-top:5px;color:var(--muted);font-size:12px}}.layout{{display:grid;grid-template-columns:258px minmax(0,1fr);gap:22px;align-items:start}}nav{{position:sticky;top:20px;max-height:calc(100vh - 40px);overflow:auto;padding:18px 14px;border:1px solid var(--line);border-radius:18px;background:#fff}}nav h2{{margin:0 8px 10px;font-size:12px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}}nav a{{display:block;padding:7px 8px;border-radius:9px;font-size:13px;line-height:1.4;color:#435168;text-decoration:none}}nav a:hover{{background:var(--green-soft);color:var(--green)}}main{{min-width:0}}main>h2{{margin:28px 0 14px;padding:0 2px;font-size:24px;line-height:1.25;letter-spacing:-.025em}}main>h2:first-child{{margin-top:0}}main h3{{margin:27px 0 8px;font-size:19px;line-height:1.35;letter-spacing:-.015em}}p{{margin:10px 0 15px}}main>p,main>ul,main>ol,main>pre,main>hr,main>figure,main>.table-wrap,main>h2,main>h3{{position:relative}}main>p,main>ul,main>ol,main>pre,main>figure,main>.table-wrap{{padding:0 2px}}main>h2:not(:first-child){{padding-top:16px;border-top:1px solid var(--line)}}strong{{font-weight:760}}code{{padding:2px 5px;border-radius:5px;background:#eef2f5;color:#34435a;font: .9em ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}}ul,ol{{padding-left:25px}}li{{padding-left:2px;margin:6px 0}}li::marker{{color:#138a6c;font-weight:700}}.table-wrap{{margin:16px 0 22px;overflow-x:auto;border:1px solid var(--line);border-radius:15px;background:#fff;box-shadow:0 5px 18px rgba(22,42,62,.035)}}table{{border-collapse:collapse;width:100%;font-size:13px;line-height:1.5}}th,td{{padding:12px 13px;text-align:left;vertical-align:top;border-bottom:1px solid #e8edf0;min-width:90px}}th{{background:#eef5f3;color:#254b43;font-size:11px;letter-spacing:.045em;text-transform:uppercase}}tbody tr:last-child td{{border-bottom:0}}tbody tr:hover{{background:#f8fbfa}}td strong{{color:#27384a}}td code{{font-size:.86em}}pre{{overflow:auto;padding:16px;border:1px solid var(--line);border-radius:13px;background:#1d2836;color:#edf5fa;line-height:1.5}}pre code{{padding:0;background:transparent;color:inherit}}hr{{border:0;border-top:1px solid var(--line);margin:26px 0}}.architecture{{margin:18px 0;padding:18px 12px 10px;border:1px solid var(--line);border-radius:18px;background:linear-gradient(160deg,#fff,#f8fbfa);overflow:hidden}}.architecture-svg{{width:100%;height:auto;display:block;max-height:590px}}.architecture figcaption{{padding:12px 14px 4px;color:var(--muted);font-size:12px}}.node rect{{stroke-width:1.6}}.node-title{{font-size:17px;font-weight:750;fill:#243349}}.node text:not(.node-title){{font-size:12px;fill:#394a5e}}.node .muted{{fill:#66778a}}.clients rect,.data rect{{fill:#f0f8f4;stroke:#a5d6c1}}.service rect,.edge rect{{fill:#edf4fb;stroke:#a9c4df}}.support rect{{fill:#fff7ec;stroke:#ebc996}}.node .inner{{fill:#fff;stroke:#d7e8df}}.edge-label text{{font-size:11px;fill:#526175;font-weight:650}}.edge-label .gap-label{{fill:#a34b13}}.edges path{{vector-effect:non-scaling-stroke}}.callout{{padding:15px 18px;border-left:4px solid var(--amber);border-radius:0 12px 12px 0;background:var(--amber-soft)}}.footnote{{font-size:13px;color:var(--muted)}}footer{{margin-top:38px;padding:20px 2px 0;border-top:1px solid var(--line);font-size:12px;color:var(--muted)}}
@media(max-width:900px){{.shell{{padding:24px 18px 48px}}.layout{{grid-template-columns:1fr}}nav{{position:static;max-height:260px;display:flex;flex-wrap:wrap;gap:3px;padding:12px}}nav h2{{width:100%}}nav a{{padding:6px 8px}}.stats{{grid-template-columns:repeat(3,minmax(0,1fr))}}.hero{{padding:30px 26px}}}}
@media(max-width:560px){{body{{font-size:15px}}.shell{{padding:16px 12px 32px}}.hero{{padding:25px 20px;border-radius:18px}}.stats{{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}}.stat{{padding:13px}}.stat strong{{font-size:21px}}.table-wrap{{border-radius:11px}}th,td{{padding:9px 10px;min-width:110px}}main>h2{{font-size:21px}}main h3{{font-size:17px}}.architecture{{padding:8px 4px}}}}
@media print{{body{{background:white;font-size:10pt}}.shell{{max-width:none;padding:0}}nav{{display:none}}.layout{{display:block}}.hero,.table-wrap,.architecture{{box-shadow:none;break-inside:avoid}}main>h2{{break-before:page}}a{{color:inherit;text-decoration:none}}}}
{DATABASE_CSS}
{STATUS_CSS}
</style>
</head>
<body>
<div class="topbar"></div>
<div class="shell">
  <div class="masthead"><span class="mark" aria-hidden="true">P</span><span>PandaPay · Engineering review</span></div>
  <header class="hero">
    <div class="eyebrow">Security · Backend · Data</div>
    <h1>PandaPay system audit</h1>
    <p>Security, API authentication, backend flows, database redundancy and architecture. Source status updated {review_date} · <code>{review_branch}@{review_revision}</code>. Original audit: 20 October 2026.</p>
    <p class="callout"><strong>Launch target: 100,000 signups across the first day.</strong> Unrestricted launch is not accepted. <a href="#production-launch-priorities" data-show-audit>Start with the ranked production priorities ↓</a>. The existing backlog remains {implementation_count} implementation packages and {gate_count} validation/rollout gates.</p>
    <div class="badge-row"><a class="badge red" href="#production-launch-priorities" data-show-audit>Launch priorities first ↓</a><span class="badge red">Release gates open</span><span class="badge">Source + recorded recovery evidence</span><span class="badge">Historical schema explorer</span><a class="badge" href="security-remaining-work-2026-10-25.html">Numbered remaining-work page →</a><a class="badge" href="#how-many-implementations-remain" data-show-audit>Full remaining-work list ↓</a><a class="badge" href="#{status_anchor}" data-show-audit>Completed & remaining ↓</a><a class="badge" href="#9-solutions-for-every-finding" data-show-audit>Solutions & verification ↓</a><a class="badge" href="#10-database-optimization-and-table-usage-review" data-show-audit>Database optimization ↓</a><a class="badge" href="#11-backend-design-brief-and-caching-recommendations" data-show-audit>Backend design & caching ↓</a><a class="badge" href="#12-additional-system-design-gaps-and-priorities" data-show-audit>System-design gaps ↓</a><a class="badge" href="#13-scalability-low-ram-servers-and-storage-plan" data-show-audit>Scalability & server sizing ↓</a><a class="badge" href="#14-cdn-redis-and-the-supporting-services-pandapay-needs" data-show-audit>CDN, Redis & queues ↓</a></div>
    <div class="stack-strip" aria-label="Technology stack">
      <div><strong>Clients</strong><span>Flutter · Dart · Riverpod<br>Mobile app + admin console</span></div>
      <div><strong>Backend services</strong><span>Node.js 22 · Express 5<br>Product API + identity service</span></div>
      <div><strong>Storage</strong><span>PostgreSQL · 2 databases<br>SQLite device stores + offline queues</span></div>
      <div><strong>Delivery & integrations</strong><span>Docker · nginx TLS edge<br>Email OTP · Google · optional SMS</span></div>
    </div>
    <div class="stack-tags" aria-label="Architecture and review tags"><span>Authoritative session checks</span><span>Product row-level security</span><span>Paired encrypted recovery</span><span>Historical local metadata</span><span>Backend release gates</span></div>
  </header>
  <section class="stats" aria-label="Audit at a glance">
    <div class="stat" data-count="implementation-packages"><strong>{implementation_count}</strong><span>Remaining implementation packages</span></div>
    <div class="stat" data-count="release-gates"><strong>{gate_count}</strong><span>Pending validation / rollout gates</span></div>
    <div class="stat" data-count="source-implemented"><strong>{all_status['Implemented in source']}/{len(finding_statuses)}</strong><span>Findings implemented in source</span></div>
    <div class="stat" data-count="partial"><strong>{all_status['Partial']}/{len(finding_statuses)}</strong><span>Findings partially covered</span></div>
    <div class="stat" data-count="open"><strong>{all_status['Open']}/{len(finding_statuses)}</strong><span>Findings still open</span></div>
  </section>
  <p class="snapshot-note"><strong>Counts use different units.</strong> The {len(finding_statuses)} findings comprise 68 original audit items and eight system-design items; {len(unfinished)} are partial/open. They map to {implementation_count} implementation packages and {gate_count} release gates, with overlapping finding mappings. Dated implementation-test evidence is linked in the status ledger; it does not establish launch capacity. This update adds read-only project metadata and production priorities, with no load test or new application test. The Database explorer remains a historical local snapshot.</p>
  <div class="report-tabs" role="tablist" aria-label="Review sections">
    <button type="button" id="audit-tab" role="tab" aria-controls="audit-panel" aria-selected="true">Audit & architecture</button>
    <button type="button" id="database-tab" role="tab" aria-controls="database-panel" aria-selected="false" tabindex="-1">Database explorer <span class="tab-count">96 historical tables</span></button>
  </div>
  <div class="layout" id="audit-panel" role="tabpanel" aria-labelledby="audit-tab" tabindex="0">
    <nav aria-label="Report contents"><h2>Contents</h2>{toc}</nav>
    <main>{body}
      <footer>Generated from the updated audit Markdown and dated local schema metadata for offline review. Current source statuses, historical probes/test records and release gates are labeled separately. The explorer was not recaptured, and source fixes do not establish deployed production state.</footer>
    </main>
  </div>
  {database_body}
</div>
<noscript><style>#database-panel[hidden]{{display:block!important}}</style></noscript>
<script>{DATABASE_JS}</script>
</body>
</html>
'''
DESTINATION.write_text(document)
print(f'Wrote {DESTINATION} ({len(document):,} bytes, {len(headings)} sections)')


# A shorter offline page makes the numbered backlog directly reviewable.
remaining_body, remaining_headings = render(remaining_markdown.split('\n', 1)[1])
remaining_destination = remaining_source.with_suffix('.html')
remaining_document = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PandaPay · Remaining security implementation</title>
<style>
*{{box-sizing:border-box}}body{{margin:0;background:#f3f6f8;color:#1d2836;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}.shell{{max-width:1400px;margin:auto;padding:32px 24px 60px}}header,main{{background:white;border:1px solid #dfe6eb;border-radius:18px;padding:28px;margin-bottom:20px}}h1{{margin:4px 0 12px;font-size:clamp(28px,4vw,42px);line-height:1.2}}h2{{margin-top:28px;color:#08775c}}.eyebrow{{color:#08775c;font-weight:750;font-size:13px;letter-spacing:.08em}}a{{color:#075f91}}.stats{{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin:20px 0}}.stat{{padding:16px;border:1px solid #dfe6eb;border-radius:12px;background:#fff}}.stat strong{{display:block;font-size:28px}}.stat span{{font-size:13px;color:#526175}}.table-wrap{{overflow:auto}}table{{border-collapse:collapse;width:100%;font-size:14px}}th,td{{border:1px solid #dfe6eb;padding:13px;text-align:left;vertical-align:top;min-width:180px}}th{{background:#edf6f1}}td:first-child{{font-weight:650}}code{{overflow-wrap:anywhere;font-size:13px}}footer{{font-size:13px;color:#637184;margin-top:28px}}@media(max-width:800px){{.stats{{grid-template-columns:repeat(2,minmax(0,1fr))}}.shell{{padding:16px 12px}}header,main{{padding:18px}}}}@media print{{body{{background:white}}.shell{{padding:0}}header,main{{border:0}}}}
</style></head>
<body><div class="shell"><header>
<div class="eyebrow">PANDAPAY · REMAINING WORK · {review_date}</div>
<h1>What is left to implement?</h1>
<p><strong>{implementation_count} implementation packages + {gate_count} validation/rollout gates.</strong> The full security plan is not complete and is not deployed.</p>
<p><a href="security-and-backend-audit-2026-10-20.html#how-many-implementations-remain">Complete audit</a> · <a href="security-remaining-work-2026-10-25.md">Markdown source</a> · <a href="../artifacts/security-review-2026-10-20/remaining-work-2026-10-25.json">Finding mappings and count register</a></p>
<div class="stats" aria-label="Remaining work counts">
<div class="stat" data-count="implementation-packages"><strong>{implementation_count}</strong><span>Implementation packages remaining</span></div>
<div class="stat" data-count="release-gates"><strong>{gate_count}</strong><span>Pending validation / rollout gates</span></div>
<div class="stat" data-count="source-implemented"><strong>{all_status['Implemented in source']}/{len(finding_statuses)}</strong><span>Findings implemented in source</span></div>
<div class="stat" data-count="partial"><strong>{all_status['Partial']}/{len(finding_statuses)}</strong><span>Partial findings</span></div>
<div class="stat" data-count="open"><strong>{all_status['Open']}/{len(finding_statuses)}</strong><span>Open findings</span></div>
</div></header><main>{remaining_body}
<footer>Generated from the remaining-work Markdown and its checked finding register. Counts are grouped backlog identities, not security percentages. No application behavior, data or deployment changed during this documentation update.</footer>
</main></div></body></html>'''
remaining_destination.write_text(remaining_document)
print(f'Wrote {remaining_destination} ({implementation_count} implementation packages, {gate_count} release gates)')
