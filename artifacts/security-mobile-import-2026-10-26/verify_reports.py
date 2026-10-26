from pathlib import Path
import subprocess,re,json
from collections import Counter
from html.parser import HTMLParser
from urllib.parse import urlsplit,unquote
root=Path(__file__).resolve().parents[2]
base=json.loads((Path(__file__).parent/'verification.json').read_text())['base_commit']
files=['docs/security-and-backend-audit-2026-10-20.html','docs/security-remaining-work-2026-10-25.html']
class Inspect(HTMLParser):
 def __init__(self): super().__init__();self.ids=[];self.links=[];self.table=False;self.rows=[];self.row=None;self.cell=None
 def handle_starttag(self,t,attrs):
  a=dict(attrs)
  if 'id' in a:self.ids.append(a['id'])
  if t=='a' and 'href' in a:self.links.append(a['href'])
  if t=='table' and 'launch-priorities' in a.get('class','').split():self.table=True
  if self.table and t=='tr':self.row=[]
  if self.table and t in ('td','th'):self.cell=[]
 def handle_data(self,s):
  if self.cell is not None:self.cell.append(s)
 def handle_endtag(self,t):
  if self.table and t in ('td','th') and self.cell is not None:self.row.append(' '.join(''.join(self.cell).split()));self.cell=None
  if self.table and t=='tr':self.rows.append(self.row);self.row=None
  if self.table and t=='table':self.table=False
parsers=[]
for f in files:
 s=(root/f).read_text();old=subprocess.check_output(['git','show',base+':'+f],text=True)
 p=Inspect();p.feed(s);q=Inspect();q.feed(old);parsers.append(p)
 assert len(p.rows)==11 and all(len(x)==5 for x in p.rows),(f,'dimensions')
 assert sum(x[1].startswith('Partial') for x in p.rows[1:])==9,(f,'partial')
 assert sum(x[1].startswith('Open') for x in p.rows[1:])==1,(f,'open')
 assert 'LP09' in p.rows[9][0],(f,'LP09')
 assert len(re.findall(r'class="status-pill partial"',s[s.index('<table class="launch-priorities"'):s.index('</table>',s.index('<table class="launch-priorities"'))]))==9,(f,'partial pills')
 assert len(re.findall(r'class="status-pill open"',s[s.index('<table class="launch-priorities"'):s.index('</table>',s.index('<table class="launch-priorities"'))]))==1,(f,'open pills')
 assert re.findall(r'<script\b[^>]*>.*?</script>',s,re.S)==re.findall(r'<script\b[^>]*>.*?</script>',old,re.S),(f,'scripts')
 assert not (Counter(p.ids)-Counter(q.ids)-Counter({'latest-recorded-progress-26-october-2026':1})),(f,'unexpected ids',Counter(p.ids)-Counter(q.ids))
 for link in set(p.links)-set(q.links):
  u=urlsplit(link)
  if u.scheme or u.netloc:continue
  target=(root/f).parent/unquote(u.path) if u.path else root/f
  assert target.exists(),(f,link)
  if u.fragment and target.suffix=='.html':
   other=Inspect();other.feed(target.read_text());assert unquote(u.fragment) in other.ids,(f,link)
 md=(root/f.replace('.html','.md')).read_text();start=md.index('| Rank / requirement |');end=md.index('\n\n',start)
 rows=[x.strip().strip('|').split('|') for x in md[start:end].splitlines()];rows=[rows[0]]+rows[2:]
 def plain(s):
  s=re.sub(r'\[([^\]]+)\]\([^)]+\)',r'\1',s)
  return ' '.join(s.replace('**','').replace('`','').split())
 actual=[[plain(x) for x in row] for row in rows]
 assert actual==p.rows,(f,'md parity',[(i,j,x,y) for i,(r1,r2) in enumerate(zip(actual,p.rows)) for j,(x,y) in enumerate(zip(r1,r2)) if x!=y][:2])
 assert '1,172 API passes (two existing skips)' in s,(f,'latest tests')
 print(f+': 10 priorities, 9 Partial / 1 Open; Markdown parity, new links and scripts pass')
assert parsers[0].rows==parsers[1].rows
f=files[0];s=(root/f).read_text();old=subprocess.check_output(['git','show',base+':'+f],text=True)
assert s[s.index('id="database-panel"'):]==old[old.index('id="database-panel"'):]
v=json.loads((root/'artifacts/security-launch-lp02-lp10-2026-10-26/verification.json').read_text())
assert v['counts']['launch_priorities']=={'partial':9,'open':1,'accepted_for_launch':0}
print('Cross-page statuses match; historical database panel and scripts unchanged; dated verification untouched.')
