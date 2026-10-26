#!/usr/bin/env python3
"""Scan changed candidate files; classify only verified published content hashes."""
from pathlib import Path
import collections
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
base=json.loads((OUT/'verification.json').read_text())['base_commit']
assert re.fullmatch(r'[a-f0-9]{40,64}',base)
changed=subprocess.check_output(['git','diff',base,'--name-only'],cwd=ROOT,text=True).splitlines()+subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=ROOT,text=True).splitlines()
assert changed, 'No candidate changes were selected for scanning'
source=json.loads((OUT/'candidate-source.json').read_text())
public_hashes={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name,value in source['file_sha256'].items() if value!='deleted'}
assert public_hashes==source['file_sha256']
public_hashes.update(json.loads((OUT/'log-hashes.json').read_text())['log_sha256'])
summary={'scope':'changed and new files only; no Git history or saved .env','files_scanned':0,'raw_findings':0,'verified_content_hash_false_positives':0,'unresolved_findings':[]}
with tempfile.TemporaryDirectory(prefix='pandapay-mobile-import-scan-',dir='/private/tmp') as temporary:
 work=Path(temporary);candidate=work/'candidate';candidate.mkdir()
 for name in sorted(set(changed)):
  p=ROOT/name
  if not p.is_file() or name==str((OUT/'secret-scan.json').relative_to(ROOT)):continue
  q=candidate/name;q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,q);summary['files_scanned']+=1
 report=work/'report.json'
 run=subprocess.run(['gitleaks','dir',str(candidate),'--redact=100','--no-banner','--no-color','--report-format','json','--report-path',str(report)],capture_output=True,text=True,timeout=60)
 assert run.returncode in (0,1), 'Scanner failed'
 findings=json.loads(report.read_text()) if report.exists() else []
 summary['raw_exit_code']=run.returncode;summary['raw_findings']=len(findings)
 files=collections.Counter()
 for item in findings:
  path=Path(item['File']);relative=str(path.relative_to(candidate));line=path.read_text().splitlines()[item['StartLine']-1]
  match=re.fullmatch(r'\s*"([^"]+)": "([a-f0-9]{64})",?\s*',line)
  if item['RuleID']=='generic-api-key' and relative.startswith(str(OUT.relative_to(ROOT))+'/') and match and public_hashes.get(match[1])==match[2]:
   summary['verified_content_hash_false_positives']+=1;files[relative]+=1
  else:summary['unresolved_findings'].append({'file':relative,'line':item['StartLine'],'rule':item['RuleID']})
 summary['false_positive_files']=dict(files)
 summary['result']='passed_with_verified_hash_false_positives' if not summary['unresolved_findings'] else 'review_required'
(OUT/'secret-scan.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({k:v for k,v in summary.items() if k!='false_positive_files'}))
raise SystemExit(bool(summary['unresolved_findings']))
