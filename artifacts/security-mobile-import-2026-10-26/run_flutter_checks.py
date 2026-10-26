#!/usr/bin/env python3
"""Selected local Flutter regressions; no live services or deployment."""
from pathlib import Path
import hashlib, json, os, re, subprocess, sys
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
FLUTTER='/Users/chandresh_kerkar/Documents/SetupFiles/flutter/bin/flutter'
DART='/Users/chandresh_kerkar/Documents/SetupFiles/flutter/bin/cache/dart-sdk/bin/dart'
tests=[
 'test/data/secure_storage/statement_import_batch_cipher_test.dart',
 'test/data/local/statement_import_outbox_test.dart',
 'test/data/local/statement_import_pending_test.dart',
 'test/data/statement_import_continuation_test.dart',
 'test/data/statement_import_prepared_repository_test.dart',
 'test/data/transaction_import_pipeline_test.dart',
 'test/data/import_formats_test.dart',
 'test/data/portable_backup/statement_import_recovery_gate_test.dart',
 'test/data/portable_backup/account_recovery_completeness_test.dart',
 'test/data/portable_backup/account_recovery_gate_test.dart',
 'test/data/portable_backup/portable_backup_roundtrip_test.dart',
 'test/features/import/pending_statement_imports_card_test.dart',
]
source=[
 'lib/data/secure_storage/statement_import_batch_cipher.dart',
 'lib/data/local/statement_import_outbox.dart',
 'lib/data/local/statement_import_pending.dart',
 'lib/data/statement_import_continuation.dart',
 'lib/data/import_repository.dart', 'lib/data/transaction_import_pipeline.dart',
 'lib/features/import/statement_import_continuation_provider.dart',
 'lib/features/import/pending_statement_imports_card.dart',
 'lib/features/import/import_review_panel.dart',
 'lib/features/import/import_hub_screen.dart',
 'lib/data/portable_backup/account_recovery_local_snapshot.dart',
 'lib/data/portable_backup/local_restore_writer.dart',
 'lib/data/portable_backup/local_snapshot_source.dart',
 'lib/app/env.dart',
]
env={k:os.environ[k] for k in ('PATH','HOME','TMPDIR','LANG') if k in os.environ}
env.update(CI='true',FLUTTER_SUPPRESS_ANALYTICS='true',DART_SUPPRESS_ANALYTICS='true')
commands=[
 ('flutter-default',[FLUTTER,'test','--no-pub','--reporter','expanded',*tests]),
 ('flutter-enabled-ui',[FLUTTER,'test','--no-pub','--reporter','expanded','--dart-define=PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED=true','test/features/import/pending_statement_imports_card_test.dart']),
 ('analysis',[DART,'analyze',*source,*tests]),
]
summary={}
if '--analysis-only' in sys.argv:
 commands=commands[-1:]
 summary=json.loads((OUT/'flutter-results.json').read_text())
for name,cmd in commands:
 print('Starting '+name,flush=True)
 result=subprocess.run(cmd,cwd=ROOT/'app',env=env,text=True,capture_output=True,timeout=240)
 log=result.stdout+result.stderr
 (OUT/(name+'.log')).write_text(log)
 item={'exit_code':result.returncode,'command':cmd,'log_sha256':hashlib.sha256(log.encode()).hexdigest()}
 counts=re.findall(r'\+(\d+)(?: -\d+)?: All tests passed!',log)
 if counts: item['passed']=int(counts[-1])
 item['tail']=log.splitlines()[-8:]
 summary[name]=item
 (OUT/'flutter-results.json').write_text(json.dumps(summary,indent=2)+'\n')
 print(name+': '+json.dumps(item),flush=True)
 if result.returncode: raise SystemExit(result.returncode)
