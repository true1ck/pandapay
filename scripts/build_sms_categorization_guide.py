#!/usr/bin/env python3
"""Build the offline SMS guide and plain-text narration.

Run: python3 scripts/build_sms_categorization_guide.py
Dependency: Markdown (python3 -m pip install Markdown).
Inputs: the dated Markdown reference, narration, SVG diagrams, captured probe
JSON and docs/templates/sms-categorization-guide.html. No network calls.
"""
from pathlib import Path
import re, json, html, base64
try:
    import markdown
except ImportError as exc:
    raise SystemExit('Install the build dependency with: python3 -m pip install Markdown') from exc
root=Path(__file__).resolve().parents[1]
doc=root/'docs/sms-categorization-pipeline-2026-11-01.md'
text=doc.read_text()
svg=(root/'docs/diagrams/sms-categorization-pipeline-2026-11-01.svg').read_text()
svg=svg.replace('../sms-categorization-pipeline-2026-11-01.html#','#')
probe=json.loads((root/'docs/examples/sms-categorization-validation-2026-11-01.json').read_text())
parts=re.split(r'^## (\d+)\. (.+)$', text, flags=re.M)
nav=[]; sections=[]
shorts={1:'Decisions at a glance',2:'Data flow & contracts',3:'Inputs & supporting data',4:'Capture gates & exclusions',5:'Identity & duplicate handling',6:'Local extraction & routing',7:'Category precedence',8:'Server import & facts',9:'When AI runs',10:'AI reviews & confidence',11:'Retries & later rechecks',12:'Correction & shared learning',13:'Worked examples',14:'Failure modes',15:'Investigate a mistake',16:'Prioritized suggestions',17:'Verification & limits',18:'Source navigation'}
def render(s):
 s=re.sub(r'```mermaid\n(.*?)\n```', lambda m:'<details class="diagram-source"><summary>Inspect the editable Mermaid data-flow source</summary>\n\n```text\n'+m[1]+'\n```\n\n</details>',s,flags=re.S)
 result=markdown.markdown(s,extensions=['tables','fenced_code','toc','sane_lists'])
 return re.sub(r'(<table>.*?</table>)',r'<div class="table-scroll" tabindex="0" role="region" aria-label="Scrollable reference table">\1</div>',result,flags=re.S)
explorer='''<div class="probe-panel" id="validation-probe"><div class="probe-heading"><span class="eyebrow">Executed synthetic code probe</span><h3>What can pass the current validator?</h3><p>Compare the same SMS with three different extracted facts. These are captured local-code results, not live AI responses.</p></div><div class="probe-tabs" role="group" aria-label="Choose a captured validation result"><button type="button" data-variant="correct_charge" aria-pressed="true">Correct charge</button><button type="button" data-variant="limit_as_charge" aria-pressed="false">Limit used as charge</button><button type="button" data-variant="different_category" aria-pressed="false">Different category</button></div><blockquote id="probe-message"></blockquote><div class="probe-facts"><div><span>Proposed charge</span><strong id="probe-amount"></strong></div><div><span>Category</span><strong id="probe-category"></strong></div><div><span>Composite score</span><strong id="probe-score"></strong></div><div><span>Server review required</span><strong id="probe-review"></strong></div></div><p id="probe-result" class="probe-result" role="status" aria-live="polite"></p><details><summary>Inspect schema, evidence and score results</summary><pre><code id="probe-json"></code></pre></details></div>'''
for i in range(1,len(parts),3):
 n,title,body=parts[i:i+3]
 nav.append(f'<a href="#section-{n}" data-nav="{n}"><span>{int(n):02}</span>{html.escape(shorts[int(n)])}</a>')
 rendered=render(body)
 if n=='13': rendered=explorer+rendered
 sections.append(f'<section class="doc-section" id="section-{n}" data-section="{n}" aria-labelledby="heading-{n}"><div class="section-heading"><span class="section-number">{int(n):02}</span><h2 id="heading-{n}">{html.escape(title)}</h2></div>{rendered}</section>')
svg_uri='data:image/svg+xml;base64,'+base64.b64encode(svg.encode()).decode()
mermaid=(root/'docs/diagrams/sms-categorization-pipeline-2026-11-01.mmd').read_text()
md_uri='data:text/markdown;charset=utf-8;base64,'+base64.b64encode(text.encode()).decode()
mermaid_uri='data:text/plain;charset=utf-8;base64,'+base64.b64encode(mermaid.encode()).decode()

# The reference sections are rendered unchanged. Learning aids are additive.
overview_svg=(root/'docs/diagrams/sms-categorization-overview-2026-11-01.svg').read_text().replace('../sms-categorization-pipeline-2026-11-01.html#','#')
narration_path=root/'docs/sms-categorization-narration-2026-11-01.md'
narration_parts=re.split(r'^## (\d+)\. (.+)$',narration_path.read_text(),flags=re.M)
chapters=[]
for index in range(1,len(narration_parts),3):
    number,title,body=narration_parts[index:index+3]
    target=re.search(r'<!-- target: ([a-z0-9-]+) -->',body).group(1)
    visual=re.search(r'\*\*On screen:\*\* (.+)',body).group(1)
    spoken=body.split('### Narration',1)[1].strip()
    spoken=re.sub(r'\[([^\]]+)\]\([^)]+\)',r'\1',spoken).replace('`','').replace('**','')
    chapters.append({'number':int(number),'title':title,'target':target,'visual':visual,'spoken':spoken,'html':render(spoken),'words':len(spoken.split())})
assert len(chapters)==20 and {c['target'] for c in chapters}=={'overview','detailed-pipeline',*[f'section-{i}' for i in range(1,19)]}, 'Narration must cover both diagram levels and all 18 sections'
plain='SMS categorization: guided narration\nOriginal source-audit snapshot: 1 November 2026.\n\n'+'\n\n'.join(f"Chapter {c['number']}. {c['title']}\n\n{c['spoken']}" for c in chapters)+'\n'
(root/'docs/sms-categorization-narration-2026-11-01.txt').write_text(plain)
words=sum(c['words'] for c in chapters)
if words > 2175 or len(plain.split()) > 2175:
    raise SystemExit('Narration exceeds the requested 15-minute word budget at 145 words/minute.')
narration_data={'chapters':chapters,'plain':plain,'words':words,'estimatedMinutes':round(words/145)}
options=''.join(f'<option value="{i}">{c["number"]:02} · {html.escape(c["title"])}</option>' for i,c in enumerate(chapters))
intro_links='<div class="depth-links" aria-label="Choose your level of detail"><a href="#overview"><span>1</span>Overview</a><a href="#detailed-pipeline"><span>2</span>Detailed pipeline</a><a href="#section-1"><span>3</span>Exact rules and reference</a><a href="#narration-panel"><span>▶</span>Guided narration</a></div>'
mobile_overview="""<ol class="overview-mobile"><li><a href="#section-3"><strong>Receive the SMS</strong><span>Sender, body and original receipt time.</span></a></li><li><a href="#section-4"><strong>Check and identify</strong><span>Exclude secrets and clear noise; reuse already-handled sources.</span></a></li><li><a href="#section-6"><strong>Understand on the phone</strong><span>Rules, saved data and corrections; durable local evidence.</span></a><div class="overview-mobile-branches"><a href="#section-8"><strong>Server transaction import</strong><span>Parse, resolve category/card and deduplicate the ledger.</span></a><a href="#section-8"><strong>Structured facts</strong><span>Validate bill, balance, mandate and attempt facts.</span></a><a href="#section-9"><strong>AI fallback</strong><span>Eligible unresolved messages; checked proposals.</span></a></div></li><li><a href="#section-10"><strong>Use the supported result</strong><span>Records, review or a supported dismissal; ownership differs by path.</span></a></li><li><a href="#section-12"><strong>Correct and improve</strong><span>Immediate private rules; reviewed, evaluated and approved shared learning.</span></a></li></ol>"""
svg_overview_uri='data:image/svg+xml;base64,'+base64.b64encode(overview_svg.encode()).decode()
text_narration_uri='data:text/plain;charset=utf-8;base64,'+base64.b64encode(plain.encode()).decode()
template=(root/'docs/templates/sms-categorization-guide.html').read_text()
values={'NAV':''.join(nav),'SVG':svg,'SVG_URI':svg_uri,'MMD_URI':mermaid_uri,'MD_URI':md_uri,'SECTIONS':'\n'.join(sections),'PROBE':json.dumps(probe,ensure_ascii=False).replace('<','\\u003c'),
        'OVERVIEW_SVG':overview_svg,'OVERVIEW_SVG_URI':svg_overview_uri,'DEPTH_LINKS':intro_links,'MOBILE_OVERVIEW':mobile_overview,'NARRATION_OPTIONS':options,
        'NARRATION_TEXT_URI':text_narration_uri,'NARRATION_DATA':json.dumps(narration_data,ensure_ascii=False).replace('<','\\u003c'),
        'NARRATION_FIRST':chapters[0]['html'],'NARRATION_VISUAL':html.escape(chapters[0]['visual']),'NARRATION_MINUTES':str(round(words/145)),'NARRATION_LEARNING_MINUTES':str(round(words/145)+2)}
for key,value in values.items():
    template=template.replace('@@'+key+'@@',value)
assert '@@' not in template, 'Unresolved HTML template placeholder'
out=doc.with_suffix('.html')
out.write_text(template)
print(json.dumps({'html':str(out),'bytes':out.stat().st_size,'referenceSections':len(sections),'narrationChapters':len(chapters),'narrationWords':words,'estimatedMinutesAt145Wpm':round(words/145)}))
