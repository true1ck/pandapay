#!/usr/bin/env python3
"""Isolated Android component fixture; never upgrades the production app.

Run with --device emulator-ID. Uses cached packages by default; native library
build hooks must also have their reviewed downloads cached. No real .env/data
is copied. Only the fixture package app.pandapay.keycipherfixture.pandapay is
installed. Logs, exact copied-source hashes and the resolved lock stay in the
private temporary fixture directory.
"""
from pathlib import Path
import subprocess,os,shutil,json,hashlib,tempfile,argparse
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--device',required=True);args=parser.parse_args()
work=Path(tempfile.mkdtemp(prefix='pandapay-key-cipher-'));work.chmod(0o700)
root=Path(__file__).resolve().parents[2];h=work/'fixture'
print('Private fixture output:',work,flush=True)
env={k:os.environ[k] for k in ('PATH','HOME','TMPDIR') if k in os.environ};env['CI']='true'
def run(name,args):
 with (work/(name+'.log')).open('w') as log:r=subprocess.run(args,cwd=h if h.exists() else work,env=env,stdout=log,stderr=subprocess.STDOUT)
 print(name,r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
run('native-fixture-create',['flutter','create','--platforms=android','--project-name=pandapay','--org=app.pandapay.keycipherfixture','--no-pub',str(h)])
(h/'pubspec.yaml').write_text('''name: pandapay
version: 1.0.0+1
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  sqlite3: 3.5.2
  flutter_secure_storage: ^11.0.0
  path_provider: ^2.1.5
  path: ^1.9.0
  crypto: ^3.0.7
  cryptography: ^2.9.0
dev_dependencies:
  integration_test:
    sdk: flutter
  flutter_test:
    sdk: flutter
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc
''')
files=['lib/data/local/app_database.dart','lib/data/portable_backup/account_recovery_operation_gate.dart','lib/data/portable_backup/private_temporary_workspace.dart','lib/data/secure_storage/local_database_key_custody.dart','lib/data/secure_storage/local_key_provisioning_lease.dart','lib/data/secure_storage/flutter_secure_key_value_store.dart','lib/data/secure_storage/encrypted_database_copy.dart','lib/data/secure_storage/encrypted_receipt_file.dart','integration_test/security_storage_key_test.dart','integration_test/security_encrypted_engine_test.dart','integration_test/security_database_copy_test.dart','integration_test/security_encrypted_receipt_test.dart']
manifest={}
for name in files:
 target=h/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/'app'/name,target);manifest[name]=hashlib.sha256(target.read_bytes()).hexdigest()
(work/'native-key-cipher-source.json').write_text(json.dumps({'scope':'isolated debug fixture, no account data or production app installation','package':'app.pandapay.keycipherfixture.pandapay','source_sha256':manifest},indent=2)+'\n')
p=h/'android/app/build.gradle.kts';p.write_text(p.read_text().replace('compileSdk = flutter.compileSdkVersion','compileSdk = 37'))
run('native-fixture-deps',['flutter','pub','get','--offline'])
run('native-key-cipher-test',['flutter','test','--no-pub','--reporter=expanded','-d',args.device,'integration_test/security_storage_key_test.dart','integration_test/security_encrypted_engine_test.dart','integration_test/security_database_copy_test.dart','integration_test/security_encrypted_receipt_test.dart'])
