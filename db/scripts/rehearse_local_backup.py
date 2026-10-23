#!/usr/bin/env python3
"""Restore an actual local encrypted backup into a disposable RAM-backed PG.

The caller supplies retained application keys via its protected environment.
No source connection is opened and no source/global role SQL is blindly run.
"""
import argparse
import json
import os
import re
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
from urllib.parse import quote


def execute(arguments, *, env=None, stdin=None):
    result = subprocess.run(arguments, env=env, input=stdin, text=True, capture_output=True)
    if result.returncode:
        # Restore helpers already emit safe categories, not raw database detail.
        if arguments[0] == "bash":
            for line in result.stderr.splitlines():
                if line.startswith(("backup manifest ", "Restore mismatch categories:", "Restore schema ACL diagnostic:", "Recovery step failed at script line ", "Recovery diagnostic step=", "Recovery missing object_type=")):
                    print(line, flush=True)
        raise RuntimeError(f"{Path(arguments[0]).name} recovery operation failed")
    return result.stdout


def ident(value):
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def role_bootstrap(manifest):
    databases = [item["database"] for item in manifest["archives"].values()]
    attributes = {row[0]: row for data in databases for row in data["role_attributes"]}
    needed = {name for data in databases for name in data["required_roles"]}
    memberships = {tuple(row) for data in databases for row in data["required_role_memberships"]}
    needed.update(name for row in memberships for name in row[:2])
    sql = []
    flags = ((1, "SUPERUSER"), (2, "INHERIT"), (3, "CREATEROLE"),
             (4, "CREATEDB"), (5, "LOGIN"), (6, "REPLICATION"), (7, "BYPASSRLS"))
    for name in sorted(needed):
        if name.startswith("pg_"):
            continue  # Standard built-in roles already exist in matching PG.
        if name not in attributes:
            raise ValueError("Required role attributes are missing from the manifest")
        row = attributes[name]
        body = ("BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=" +
                literal(name) + ") THEN CREATE ROLE " + ident(name) + "; END IF; END")
        sql.append("DO " + literal(body) + ";")
        options = " ".join(flag if row[index] else "NO" + flag for index, flag in flags)
        sql.append(f"ALTER ROLE {ident(name)} {options} CONNECTION LIMIT {int(row[8])};")
    for parent, member, admin, inherit, can_set in sorted(memberships):
        sql.append(f"GRANT {ident(parent)} TO {ident(member)} WITH ADMIN " +
                   ("TRUE" if admin else "FALSE") + ", INHERIT " +
                   ("TRUE" if inherit else "FALSE") + ", SET " + ("TRUE" if can_set else "FALSE") + ";")
    return "\n".join(sql) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("recovery_folder", type=Path)
    parser.add_argument("--image", required=True, help="Reviewed Supabase PG image with source extensions")
    parser.add_argument("--contact-upgrade", action="store_true", help="Rehearse the owner-approved test contact resolution on the disposable copy")
    parser.add_argument("--product-baseline", type=Path, help="Also rehearse the product upgrade using this independently reviewed source baseline")
    parser.add_argument("--dump-image", default=os.environ.get("BACKUP_PG_DUMP_IMAGE"), help="Reviewed matching pg_dump client image for the product baseline")
    args = parser.parse_args()
    if args.product_baseline and (not args.contact_upgrade or not args.product_baseline.is_file()):
        parser.error("--product-baseline requires --contact-upgrade and an existing reviewed baseline file")
    if args.product_baseline and (not args.dump_image or not re.fullmatch(r"[a-z0-9][a-z0-9._/:@-]{0,240}", args.dump_image)):
        parser.error("--product-baseline requires the reviewed dump client image used to capture its baseline")
    os.umask(0o077)
    root = args.recovery_folder.resolve()
    completed = list((root / "sets").glob("*/LOCAL_COMPLETE"))
    if not completed:
        raise SystemExit("No complete local paired backup is available")
    selected = max(completed, key=lambda p: p.stat().st_mtime).parent
    manifest = json.loads(execute([str(root / "tools/age"), "-d", "-i",
        str(root / "keys/recovery-identity.txt"), str(selected / "manifest.json.age")]))
    bootstrap_owners = {dict(item["database"]["extension_owners"])["plpgsql"]
                        for item in manifest["archives"].values()}
    if len(bootstrap_owners) != 1:
        raise ValueError("The two source databases need different bootstrap extension owners; use separate reviewed targets")
    bootstrap_owner = next(iter(bootstrap_owners))
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", bootstrap_owner):
        raise ValueError("Review the source bootstrap role name before starting recovery")
    container = "pandapay-recovery-" + secrets.token_hex(8)
    password = secrets.token_hex(32)
    env = dict(os.environ, PP_RECOVERY_PASSWORD=password, PP_RECOVERY_BOOTSTRAP_ROLE=bootstrap_owner)
    created = False
    try:
        start_script = r'''set -Eeuo pipefail
initdb -D /var/lib/postgresql/data -U "$PP_RECOVERY_BOOTSTRAP_ROLE" --encoding=UTF8 --locale=en_US.UTF-8 --auth-local=trust --auth-host=scram-sha-256 --pwfile=<(printf '%s\n' "$PP_RECOVERY_PASSWORD") >/dev/null
printf '%s\n' 'host all pp_recovery_admin 0.0.0.0/0 scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf
printf 'host all %s 0.0.0.0/0 scram-sha-256\n' "$PP_RECOVERY_BOOTSTRAP_ROLE" >> /var/lib/postgresql/data/pg_hba.conf
exec postgres -D /var/lib/postgresql/data -k /tmp -c listen_addresses='*' -c shared_buffers=64MB -c max_connections=20 -c shared_preload_libraries=pg_stat_statements -c log_min_error_statement=panic -c log_error_verbosity=terse
'''
        execute(["docker", "run", "-d", "--pull", "never", "--name", container,
                 "--memory", "1g", "--cpus", "1", "--user", "100:101",
                 "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,nodev,size=512m,uid=100,gid=101,mode=0700",
                 "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m,mode=1777",
                 "-p", "127.0.0.1::5432", "-e", "PP_RECOVERY_PASSWORD", "-e", "PP_RECOVERY_BOOTSTRAP_ROLE",
                 "--entrypoint", "bash", args.image, "-c", start_script], env=env)
        created = True
        print("Disposable memory-backed recovery container started.", flush=True)
        for _ in range(60):
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-h", "127.0.0.1",
                                    "-U", "pp_recovery_admin", "-d", "postgres"], capture_output=True)
            if ready.returncode == 0:
                break
            time.sleep(0.5)
        else:
            logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
            startup_log = root / "status" / "recovery-startup.log"
            startup_log.write_text((logs.stdout + logs.stderr)[-8192:])
            startup_log.chmod(0o600)
            raise RuntimeError("Disposable recovery cluster did not become ready")
        print("Independent recovery PostgreSQL is ready; applying reviewed roles and restore checks.", flush=True)
        port = execute(["docker", "port", container, "5432/tcp"]).strip().rsplit(":", 1)[1]
        base = f"postgresql://pp_recovery_admin:{quote(password)}@127.0.0.1:{int(port)}"
        connection_env = dict(env, PGSSLMODE="disable", PGCONNECT_TIMEOUT="10")
        boot_url = f"postgresql://{quote(bootstrap_owner)}:{quote(password)}@127.0.0.1:{int(port)}/postgres"
        execute(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", boot_url], env=connection_env,
                stdin="CREATE ROLE pp_recovery_admin SUPERUSER LOGIN PASSWORD " + literal(password) + ";\n")
        connection = subprocess.run(["psql", "-X", "-qAt", base + "/postgres", "-c", "SELECT 1"],
                                    env=connection_env, capture_output=True, text=True)
        if connection.returncode:
            diagnostic = root / "status" / "recovery-connect.log"
            diagnostic.write_text(connection.stderr[-4096:])
            diagnostic.chmod(0o600)
            raise RuntimeError("The host cannot connect to its disposable PostgreSQL target; private diagnostic saved")
        with tempfile.TemporaryDirectory(prefix="pp-reviewed-recovery-") as temporary:
            bootstrap = Path(temporary) / "application-roles.sql"
            bootstrap.write_text(role_bootstrap(manifest))
            bootstrap.chmod(0o600)
            # A newer host pg_restore can emit unsupported session settings
            # for PostgreSQL 17 even when the archive was created by 17.
            # Stream through the matching client in this disposable container.
            tools = Path(temporary) / "bin"
            tools.mkdir(mode=0o700)
            adapter = tools / "pg_restore"
            adapter.write_text('''#!/usr/bin/env python3
import os,sys,subprocess
from urllib.parse import urlsplit,urlunsplit
arguments=[]
for value in sys.argv[1:]:
    if value.startswith('--use-list='):
        path=value.split('=',1)[1]
        destination='/tmp/'+os.path.basename(path)
        # Docker cp can write beneath a tmpfs mount instead of into it.
        # Stream the small TOC through exec so it lands in recovery RAM with
        # the running PostgreSQL user's ownership and private permissions.
        with open(path,'rb') as selection:
            result=subprocess.run(['docker','exec','-i',os.environ['PP_RECOVERY_CONTAINER'],'bash','-c',
                'umask 077; cat > "$1"','toc-copy',destination],stdin=selection,capture_output=True)
        if result.returncode: raise SystemExit('Could not transfer the reviewed archive selection into recovery memory')
        value='--use-list='+destination
    if value.startswith('--dbname='):
        url=urlsplit(value.split('=',1)[1])
        if url.hostname != '127.0.0.1' or url.port != int(os.environ['PP_RECOVERY_HOST_PORT']) or url.username != 'pp_recovery_admin':
            raise SystemExit('Recovery client refuses an unexpected database target')
        value='--dbname='+urlunsplit((url.scheme,'pp_recovery_admin@127.0.0.1:5432',url.path,url.query,url.fragment))
    arguments.append(value)
command=['docker','exec','-i',os.environ['PP_RECOVERY_CONTAINER'],'bash','-c',
    'export PGPASSWORD="$PP_RECOVERY_PASSWORD"; exec pg_restore "$@"','pg_restore',*arguments]
os.execvp(command[0],command)
''')
            adapter.chmod(0o700)
            dump_adapter = tools / "pg_dump"
            dump_adapter.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
from urllib.parse import urlsplit,urlunsplit
arguments=[]
is_database=False
for value in sys.argv[1:]:
    prefix=''
    if value.startswith('--dbname='):
        prefix='--dbname='
        value=value.split('=',1)[1]
    if prefix or is_database:
        url=urlsplit(value)
        if url.hostname != '127.0.0.1' or url.port != int(os.environ['PP_RECOVERY_HOST_PORT']) or url.username != 'pp_recovery_admin':
            raise SystemExit('Recovery dump client refuses an unexpected target')
        value=prefix+urlunsplit((url.scheme,'pp_recovery_admin@127.0.0.1:5432',url.path,url.query,url.fragment))
    is_database=value=='--dbname'
    arguments.append(value)
image=os.environ.get('PP_RECOVERY_DUMP_IMAGE')
if image:
    # Only the fresh disposable target's random credential is passed to the
    # matching client container. No source URL, application key or age identity
    # is mounted or inherited by that container.
    entries=[line.split(':') for line in Path(os.environ['PGPASSFILE']).read_text().splitlines()]
    passwords={row[4] for row in entries if len(row)==5 and row[0]=='127.0.0.1'
        and row[1]==os.environ['PP_RECOVERY_HOST_PORT'] and row[3]=='pp_recovery_admin'}
    if len(passwords)!=1: raise SystemExit('Recovery client credential is unavailable')
    password=next(iter(passwords))
    if len(password)!=64 or any(c not in '0123456789abcdef' for c in password):
        raise SystemExit('Recovery client refuses a non-generated credential')
    os.environ['PGPASSWORD']=password
    command=['docker','run','--rm','--pull','never','--memory','256m','--cpus','0.5',
        '--network','container:'+os.environ['PP_RECOVERY_CONTAINER'],'--env','PGPASSWORD',
        '--entrypoint','pg_dump',image,*arguments]
else:
    command=['docker','exec','-i',os.environ['PP_RECOVERY_CONTAINER'],'bash','-c',
        'export PGPASSWORD="$PP_RECOVERY_PASSWORD"; exec pg_dump "$@"','pg_dump',*arguments]
os.execvp(command[0],command)
''')
            dump_adapter.chmod(0o700)
            env.update(NODE_ENV="test", DB_SSL="false", DB_SSL_CA="", DB_SSL_CA_FILE="",
                       RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION="THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER",
                       RESTORE_PARAMETER_ACL_ATTESTATION="I_HAVE_VERIFIED_FRESH_ISOLATED_RECOVERY_CLUSTER",
                       PP_RECOVERY_CONTAINER=container, PP_RECOVERY_HOST_PORT=port,
                       PATH=str(tools) + os.pathsep + env["PATH"],
                       RESTORE_ADMIN_DATABASE_URL=base + "/postgres",
                       RESTORE_PRODUCT_DATABASE_URL=base + "/product_template",
                       RESTORE_AUTH_DATABASE_URL=base + "/auth_template",
                       RESTORE_AGE_IDENTITY_FILE=str(root / "keys/recovery-identity.txt"),
                       RESTORE_DIAGNOSTIC_RECIPIENTS_FILE=str(root / "public-recipients.txt"),
                       RESTORE_ROLE_BOOTSTRAP_FILE=str(bootstrap), RESTORE_STATUS_DIR=str(root / "status"),
                       BACKUP_SET_DIR=str(selected), BACKUP_DIR=str(root / "sets"),
                       RESTORE_APPLICATION_CHECK=str(Path(__file__).with_name("verify_recovery.js")))
            if args.contact_upgrade:
                env.update(RESTORE_UPGRADE_CHECK=str(Path(__file__).with_name("rehearse_contact_upgrade.js")),
                           CONTACT_PROPOSAL_FILE=str(root / "contact-review/contact-conflict-proposal.json.age"),
                           CONTACT_IDENTITY_FILE=str(root / "keys/recovery-identity.txt"),
                           CONTACT_RECIPIENTS_FILE=str(root / "public-recipients.txt"))
            if args.product_baseline:
                env["PRODUCT_REVIEWED_BASELINE_FILE"] = str(args.product_baseline.resolve())
                env["PP_RECOVERY_DUMP_IMAGE"] = args.dump_image
            result = execute(["bash", str(Path(__file__).with_name("restore_drill.sh"))], env=env)
            print(result.strip(), flush=True)
    finally:
        if created:
            removed = subprocess.run(["docker", "rm", "-f", "-v", container], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
            if removed.returncode:
                raise RuntimeError("Could not remove the disposable recovery container; inspect local Docker before retrying")
    print("Actual local backup restored and verified; disposable RAM-backed recovery cluster removed.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError) as error:
        print(f"Local recovery rehearsal failed: {error}")
        raise SystemExit(1)
