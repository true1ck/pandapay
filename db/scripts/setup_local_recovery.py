#!/usr/bin/env python3
"""Prepare an owner-only, portable local recovery folder without live DB access."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess


def private_file(path, contents):
    if not path.exists():
        with path.open("x") as output:
            output.write(contents)
        path.chmod(0o600)


def copy_tool(source, destination):
    """Install a private executable, tolerating source already at destination."""
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if destination.exists() and os.path.samefile(source, destination):
        destination.chmod(0o700)
        return
    shutil.copyfile(source, destination)
    destination.chmod(0o700)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--age", required=True, type=Path)
    parser.add_argument("--age-keygen", required=True, type=Path)
    parser.add_argument("--pg-dump-image", help="Reviewed local Docker image for a matching pg_dump major")
    args = parser.parse_args()
    os.umask(0o077)
    root = args.path.expanduser().resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    for name in ("sets", "keys", "tools", "tooling", "status"):
        folder = root / name
        folder.mkdir(mode=0o700, exist_ok=True)
        folder.chmod(0o700)
    for source, name in ((args.age, "age"), (args.age_keygen, "age-keygen")):
        copy_tool(source, root / "tools" / name)
    identity = root / "keys" / "recovery-identity.txt"
    if not identity.exists():
        if (root / "public-recipients.txt").exists() or any((root / "sets").iterdir()):
            raise SystemExit("Existing recovery state has no private identity; recover the original key before setup")
        # age-keygen prints the public recipient, never the private identity.
        subprocess.run([str(root / "tools" / "age-keygen"), "-o", str(identity)],
                       check=True, capture_output=True)
    identity.chmod(0o600)
    recipient = subprocess.run([str(root / "tools" / "age-keygen"), "-y", str(identity)],
                               check=True, capture_output=True, text=True).stdout
    if (root / "public-recipients.txt").exists() and (root / "public-recipients.txt").read_text() != recipient:
        raise SystemExit("Existing recipient differs from the private identity; preserve and reconcile both before setup")
    private_file(root / "public-recipients.txt", recipient)
    scripts = Path(__file__).resolve().parent
    for name in ("backup.sh", "backup_common.sh", "backup_storage.py", "backup_payload.sh",
                 "backup_snapshot.py", "backup_manifest.py", "pg_connection.py",
                 "restore_drill.sh", "restore_urls.py"):
        shutil.copyfile(scripts / name, root / "tooling" / name)
        (root / "tooling" / name).chmod(0o700)
    private_file(root / "backup.env", """# Fill only the confirmed live product/auth URLs through the local secret channel.
# Empty values intentionally prevent a backup of the wrong dataset.
PRODUCT_DATABASE_URL=''
AUTH_DATABASE_URL=''
NODE_ENV=production
DB_SSL=true
DB_SSL_CA=''
BACKUP_MODE=local
RETENTION_DAYS=7
BACKUP_MAX_SETS=7
BACKUP_MAX_BYTES=1073741824
BACKUP_MIN_FREE_BYTES=5368709120
BACKUP_MAX_USAGE_PERCENT=95
""")
    if args.pg_dump_image:
        config_path = root / "backup.env"
        config = config_path.read_text()
        entry = "BACKUP_PG_DUMP_IMAGE=" + shlex.quote(args.pg_dump_image)
        if re.search(r"^BACKUP_PG_DUMP_IMAGE=.*$", config, re.M):
            config = re.sub(r"^BACKUP_PG_DUMP_IMAGE=.*$", lambda _: entry, config, flags=re.M)
        else:
            config += "\n" + entry + "\n"
        config_path.write_text(config)
        config_path.chmod(0o600)
        copy_tool(scripts / "pg_dump_container.sh", root / "tools" / "pg_dump")
    wrapper = root / "run-backup.sh"
    wrapper.write_text("#!/bin/bash\nset -Eeuo pipefail\numask 077\n" +
        "RECOVERY_ROOT=" + shlex.quote(str(root)) + "\n" +
        'set -a\nsource "$RECOVERY_ROOT/backup.env"\nset +a\n' +
        'export BACKUP_DIR="$RECOVERY_ROOT/sets"\n' +
        'export BACKUP_AGE_RECIPIENTS_FILE="$RECOVERY_ROOT/public-recipients.txt"\n' +
        'export PATH="$RECOVERY_ROOT/tools:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"\n' +
        '# Each run replaces its small status log; logs do not accumulate.\n' +
        'exec /bin/bash "$RECOVERY_ROOT/tooling/backup.sh" > "$RECOVERY_ROOT/status/last-run.log" 2>&1\n')
    wrapper.chmod(0o700)
    schedule = {
        "Label": "app.pandapay.local-recovery",
        "ProgramArguments": ["/bin/bash", str(wrapper)],
        "StartCalendarInterval": {"Hour": 7, "Minute": 45},
        "ProcessType": "Background",
    }
    schedule_file = root / "app.pandapay.local-recovery.plist"
    if not schedule_file.exists():
        schedule_file.write_bytes(plistlib.dumps(schedule))
        schedule_file.chmod(0o600)
    private_file(root / "README.md", """# PandaPay local recovery

Prepared on 22 October 2026. This folder is owner-only. Setup does not take a
database backup. Confirm both live database URLs in backup.env before running
run-backup.sh. Public server CA certificates can go in DB_SSL_CA.

## Storage and schedule

- sets/: encrypted product/auth pairs and encrypted recovery manifests.
- Daily schedule prepared for 07:45 in this Mac's local time. It is not installed
  or active yet. After both source URLs are verified, install the supplied
  launchd plist with launchctl bootstrap in the current user's GUI domain, then
  run launchctl kickstart and inspect the resulting status/last-run.log. A
  successful manual run does not prove scheduled execution. macOS privacy
  controls can deny background launchd jobs access to Documents, Desktop, or
  Downloads even when an interactive shell can read them. Prefer a recovery
  folder under ~/Library/Application Support/PandaPay/Recovery and verify the
  actual scheduled job with a kickstart before relying on it. Keep a Documents
  alias only for interactive convenience; it does not grant launchd access.
  The Mac must be awake and connected; this is not a continuous server job.
- Keep up to seven daily/predeploy pairs within 1 GiB total, including new
  ciphertext. Stop while at least 5 GiB free remains and before disk usage
  exceeds 95%. Older eligible sets are pruned. The two newest complete sets
  and two newest restore-verified sets are protected. If they cannot fit,
  a new backup fails and keeps recovery data. Check status/last-run.log.
- One local copy is recorded as local_saved, never offsite_uploaded.

## Recovery and later transfer

Each complete sets/<id>/ folder contains both PostgreSQL custom archives,
manifest.json.age, checksums.sha256 and LOCAL_COMPLETE. Copy the whole set to
the future recovery host. Verify checksums and rehearse restore_drill.sh on an
independent PostgreSQL endpoint with reviewed application role bootstrap SQL.
The tooling folder contains the portable backup/restore scripts. Native age
binaries in tools/ are for this Mac; install age for the future host's platform.

keys/recovery-identity.txt decrypts archives: transfer it through a separately
protected channel and keep a separate offline copy. public-recipients.txt may
be used on a future backup server. Preserve the original application encryption
and phone lookup HMAC keys through the existing secret escrow too; the age
identity does not replace those keys.

The current Mac is the sole recovery location until another independent copy
is configured. Scheduled backups can lose writes since the previous successful
run. Planned PostgreSQL provider moves use a final write freeze, paired export,
verified target restore and reconciliation before reopening writes.
""")
    print(f"Local recovery folder prepared: {root}")
    config = (root / "backup.env").read_text()
    configured = all(
        (match := re.search(r"^" + name + r"=(.*)$", config, re.M)) and match[1].strip().strip("'\"")
        for name in ("PRODUCT_DATABASE_URL", "AUTH_DATABASE_URL")
    )
    print(("Source connections configured" if configured else "Source connections pending") +
          "; setup does not activate the prepared daily schedule.")


if __name__ == "__main__":
    main()
