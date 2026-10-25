#!/usr/bin/env bash
# Restore one paired encrypted set onto a separately provisioned recovery PG
# host. Source database URLs are deliberately not accepted by this script.
set -Eeuo pipefail
umask 077
report_restore_failure() {
  printf 'Recovery step failed at script line %s\n' "$1" >&2
  if [ -n "${WORK:-}" ]; then
    python3 - "$WORK" <<'PY'
import pathlib,re,sys
categories = (
    ('unrecognized configuration parameter', 'unsupported_client_setting'),
    ('extension control file', 'missing_extension_package'),
    ('has no installation script', 'missing_extension_version'),
    ('already exists', 'object_already_exists'),
    ('does not exist', 'missing_dependency'),
    ('permission denied', 'permission_denied'),
    ('must be owner', 'owner_privilege_required'),
    ('could not access file', 'missing_extension_library'),
    ('no pg_hba.conf entry', 'recovery_client_access_rule'),
    ('could not transfer the reviewed archive selection', 'archive_selection_transfer_failed'),
    ('input file is too short', 'archive_stream_truncated'),
    ('could not read from input file', 'archive_stream_read_failed'),
    ('could not open toc file', 'archive_selection_unreadable'),
    ('could not execute query', 'postgresql_query_failed'),
    ('cannot', 'postgresql_operation_refused'),
)
for path in pathlib.Path(sys.argv[1]).glob('*-error'):
    error = path.read_text(errors='replace')[:8192].lower()
    if error:
        category = next((label for needle,label in categories if needle in error), 'database_operation_failed')
        print('Recovery diagnostic step=' + path.name + ' category=' + category, file=sys.stderr)
        missing = re.search(r'(role|schema|type|relation|function|extension|operator) "([a-z0-9_.$]{1,128})" does not exist', error)
        if missing:
            print('Recovery missing object_type=' + missing[1] + ' identifier=' + missing[2], file=sys.stderr)
PY
    if [ -n "${RESTORE_DIAGNOSTIC_RECIPIENTS_FILE:-}" ] && [ -r "$RESTORE_DIAGNOSTIC_RECIPIENTS_FILE" ]; then
      # Keep one bounded encrypted diagnostic for the operator. It may contain
      # SQL or data values, so it is never emitted in routine output.
      python3 - "$WORK" <<'PY' | age -R "$RESTORE_DIAGNOSTIC_RECIPIENTS_FILE" >"$RESTORE_STATUS_DIR/.last-restore-error.age.pending" && \
        mv "$RESTORE_STATUS_DIR/.last-restore-error.age.pending" "$RESTORE_STATUS_DIR/last-restore-error.age" || true
import pathlib,sys
for path in pathlib.Path(sys.argv[1]).glob('*-error'):
    value=path.read_bytes()[:8192]
    if value:
        sys.stdout.buffer.write(path.name.encode()+b'\n'+value+b'\n')
PY
    fi
  fi
}
trap 'report_restore_failure "$LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup_common.sh"

require_env RESTORE_ADMIN_DATABASE_URL RESTORE_PRODUCT_DATABASE_URL \
  RESTORE_AUTH_DATABASE_URL RESTORE_AGE_IDENTITY_FILE RESTORE_ROLE_BOOTSTRAP_FILE \
  RESTORE_STATUS_DIR
require_commands age pg_restore psql python3 sha256sum
[ -r "$RESTORE_AGE_IDENTITY_FILE" ] || { echo "Restore age identity is not readable" >&2; exit 2; }
[ -r "$RESTORE_ROLE_BOOTSTRAP_FILE" ] || { echo "Restore role bootstrap SQL is not readable" >&2; exit 2; }

BACKUP_DIR="${BACKUP_DIR:-/var/backups/pandapay}"
LOCK_ROOT="$BACKUP_DIR"
if [ -n "${BACKUP_SET_DIR:-}" ]; then LOCK_ROOT="$(dirname "$BACKUP_SET_DIR")"; fi
if [ "${BACKUP_STORAGE_LOCK_HELD:-}" != 1 ]; then
  export BACKUP_STORAGE_LOCK_HELD=1
  exec python3 "$SCRIPT_DIR/backup_storage.py" lock-many "$LOCK_ROOT" cmd: bash "$0"
fi
if [ -n "${BACKUP_SET_DIR:-}" ]; then
  SET_DIR="$BACKUP_SET_DIR"
else
  latest="$(complete_set_ids "$BACKUP_DIR" | head -n 1)"
  [ -n "$latest" ] || { echo "No complete paired set found" >&2; exit 1; }
  SET_DIR="$BACKUP_DIR/$latest"
fi
MARKER="$SET_DIR/OFFSITE_COMPLETE"
if [ ! -f "$MARKER" ]; then MARKER="$SET_DIR/LOCAL_COMPLETE"; fi
[ -f "$MARKER" ] || { echo "Selected paired set is incomplete" >&2; exit 1; }
SET_ID="$(basename "$SET_DIR")"
grep -Fxq "set_id=$SET_ID" "$MARKER" || { echo "Backup completion marker does not match set" >&2; exit 1; }
(
  cd "$SET_DIR"
  sha256sum -c checksums.sha256 >/dev/null
)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pandapay-restore.XXXXXXXX")"
CREATED_DBS=()
cleanup() {
  local db
  for db in "${CREATED_DBS[@]:-}"; do
    [ -n "$db" ] || continue
    psql "$RESTORE_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1 || true
  done
  rm -rf -- "$WORK"
}
trap cleanup EXIT

python3 "$SCRIPT_DIR/pg_connection.py" --output "$WORK/connection-urls.json" \
  --pgpass "$WORK/pgpass" \
  --url-env RESTORE_ADMIN_DATABASE_URL --url-env RESTORE_PRODUCT_DATABASE_URL \
  --url-env RESTORE_AUTH_DATABASE_URL
export PGPASSFILE="$WORK/pgpass"
RESTORE_ADMIN_DATABASE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["RESTORE_ADMIN_DATABASE_URL"])' "$WORK/connection-urls.json")"
RESTORE_PRODUCT_DATABASE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["RESTORE_PRODUCT_DATABASE_URL"])' "$WORK/connection-urls.json")"
RESTORE_AUTH_DATABASE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["RESTORE_AUTH_DATABASE_URL"])' "$WORK/connection-urls.json")"
export RESTORE_ADMIN_DATABASE_URL RESTORE_PRODUCT_DATABASE_URL RESTORE_AUTH_DATABASE_URL

age -d -i "$RESTORE_AGE_IDENTITY_FILE" -o "$WORK/manifest.json" "$SET_DIR/manifest.json.age"
list_streamed_archive() {
  local status=0
  # --list stops after the TOC. Drain the remaining plaintext into /dev/null
  # so age can authenticate the full stream instead of receiving SIGPIPE.
  pg_restore --list >"$2" 2>"$1" || status=$?
  cat >/dev/null
  return "$status"
}
age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$SET_DIR/product.dump.age" | list_streamed_archive "$WORK/product-list-error" "$WORK/product-toc"
age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$SET_DIR/auth.dump.age" | list_streamed_archive "$WORK/auth-list-error" "$WORK/auth-toc"
python3 "$SCRIPT_DIR/restore_urls.py" \
  --admin "$RESTORE_ADMIN_DATABASE_URL" \
  --product "$RESTORE_PRODUCT_DATABASE_URL" \
  --auth "$RESTORE_AUTH_DATABASE_URL" \
  --set-id "$SET_ID" --output "$WORK/restore-urls.json"

PRODUCT_DB="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["product_db"])' "$WORK/restore-urls.json")"
AUTH_DB="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["auth_db"])' "$WORK/restore-urls.json")"
PRODUCT_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["product_url"])' "$WORK/restore-urls.json")"
AUTH_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["auth_url"])' "$WORK/restore-urls.json")"

# Prove cluster independence before role or database mutations. A source or
# target that hides pg_control_system() requires a separate operator check.
python3 "$SCRIPT_DIR/backup_manifest.py" validate-independence \
  --manifest "$WORK/manifest.json" --admin-url-env RESTORE_ADMIN_DATABASE_URL
python3 "$SCRIPT_DIR/backup_manifest.py" validate-parameter-acl-target \
  --manifest "$WORK/manifest.json" --admin-url-env RESTORE_ADMIN_DATABASE_URL

# The reviewed bootstrap may create only required application roles; it does
# not import provider globals. Check every source object owner/grantee and its
# RLS-relevant role attributes before any database restore begins.
psql "$RESTORE_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$RESTORE_ROLE_BOOTSTRAP_FILE" >"$WORK/role-bootstrap-output" 2>"$WORK/role-bootstrap-error"
python3 "$SCRIPT_DIR/backup_manifest.py" validate-roles \
  --manifest "$WORK/manifest.json" \
  --product-url-env RESTORE_ADMIN_DATABASE_URL --auth-url-env RESTORE_ADMIN_DATABASE_URL

python3 "$SCRIPT_DIR/backup_manifest.py" create-target-database \
  --manifest "$WORK/manifest.json" --archive product.dump --database-name "$PRODUCT_DB" \
  --admin-url-env RESTORE_ADMIN_DATABASE_URL
CREATED_DBS+=("$PRODUCT_DB")
python3 "$SCRIPT_DIR/backup_manifest.py" create-target-database \
  --manifest "$WORK/manifest.json" --archive auth.dump --database-name "$AUTH_DB" \
  --admin-url-env RESTORE_ADMIN_DATABASE_URL
CREATED_DBS+=("$AUTH_DB")

export RESTORE_PRODUCT_TARGET_URL="$PRODUCT_URL" RESTORE_AUTH_TARGET_URL="$AUTH_URL"
python3 "$SCRIPT_DIR/backup_manifest.py" prepare-target-extensions \
  --manifest "$WORK/manifest.json" --archive product.dump --url-env RESTORE_PRODUCT_TARGET_URL
python3 "$SCRIPT_DIR/backup_manifest.py" prepare-target-extensions \
  --manifest "$WORK/manifest.json" --archive auth.dump --url-env RESTORE_AUTH_TARGET_URL
python3 - "$WORK" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
for name in ('product','auth'):
    # Schemas and extensions were deliberately prepared with original owners.
    # Their comments, ACLs and every other archive entry remain selected.
    lines=(root/(name+'-toc')).read_text().splitlines()
    (root/(name+'-restore-toc')).write_text('\n'.join(line for line in lines if not re.match(r'^\d+;\s+\d+\s+\d+\s+(?:SCHEMA|EXTENSION)\s',line))+'\n')
PY
age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$SET_DIR/product.dump.age" | pg_restore --exit-on-error --use-list="$WORK/product-restore-toc" --dbname="$PRODUCT_URL" 2>"$WORK/product-restore-error"
age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$SET_DIR/auth.dump.age" | pg_restore --exit-on-error --use-list="$WORK/auth-restore-toc" --dbname="$AUTH_URL" 2>"$WORK/auth-restore-error"
export RESTORE_PRODUCT_TARGET_URL="$PRODUCT_URL" RESTORE_AUTH_TARGET_URL="$AUTH_URL"
python3 "$SCRIPT_DIR/backup_manifest.py" restore-schema-acls \
  --manifest "$WORK/manifest.json" --archive product.dump --url-env RESTORE_PRODUCT_TARGET_URL
python3 "$SCRIPT_DIR/backup_manifest.py" restore-schema-acls \
  --manifest "$WORK/manifest.json" --archive auth.dump --url-env RESTORE_AUTH_TARGET_URL
python3 "$SCRIPT_DIR/backup_manifest.py" restore-parameter-acls \
  --manifest "$WORK/manifest.json" --admin-url-env RESTORE_ADMIN_DATABASE_URL \
  --product-url-env RESTORE_PRODUCT_TARGET_URL --auth-url-env RESTORE_AUTH_TARGET_URL
python3 "$SCRIPT_DIR/backup_manifest.py" verify \
  --manifest "$WORK/manifest.json" \
  --product-url-env RESTORE_PRODUCT_TARGET_URL --auth-url-env RESTORE_AUTH_TARGET_URL \
  --product-dump "$SET_DIR/product.dump.age" --auth-dump "$SET_DIR/auth.dump.age"
export RESTORE_PRODUCT_EXACT_COMPARISON=passed
export RESTORE_AUTH_EXACT_COMPARISON=passed

mkdir -p "$RESTORE_STATUS_DIR"
application_check=not_run
upgrade_check=not_run
product_upgrade=not_run
contact_upgrade=not_run
if [ -n "${RESTORE_APPLICATION_CHECK:-}" ]; then
  [ -x "$RESTORE_APPLICATION_CHECK" ] || { echo 'Reviewed application recovery check must be executable' >&2; exit 1; }
  "$RESTORE_APPLICATION_CHECK" >"$WORK/application-check-output" 2>"$WORK/application-check-error"
  application_check=passed
fi
if [ -n "${RESTORE_UPGRADE_CHECK:-}" ]; then
  [ -x "$RESTORE_UPGRADE_CHECK" ] || { echo 'Reviewed recovery upgrade check must be executable' >&2; exit 1; }
  "$RESTORE_UPGRADE_CHECK" >"$WORK/upgrade-check-output" 2>"$WORK/upgrade-check-error"
  upgrade_check=passed
  # Publish only fixed, count-only summaries from the reviewed hooks. Their
  # remaining stdout/stderr stays private and is never copied into the log.
  while IFS= read -r summary; do
    if [[ "$summary" =~ ^PRODUCT_UPGRADE_STATUS=passed\ tables_preserved=[0-9]{1,6}\ ledger_entries_verified=[0-9]{1,6}\ runtime_roles_preserved=[0-9]{1,4}\ replay=passed$ ]]; then
      product_upgrade=passed
      echo "$summary"
    elif [[ "$summary" =~ ^CONTACT_UPGRADE_STATUS=passed\ accounts_preserved=[0-9]{1,6}\ phone_claims_archived=[0-9]{1,6}\ preserved_auth_tables=[0-9]{1,6}\ replay=passed$ ]]; then
      contact_upgrade=passed
      echo "$summary"
    fi
  done < "$WORK/upgrade-check-output"
fi
status_tmp="$RESTORE_STATUS_DIR/.restore-verified-$SET_ID.tmp"
# Bind publication proof to the exact ciphertext verified by this drill.
# Historical set-id-only markers remain valid retention hints but cannot
# publish application-visible recovery success.
manifest_ciphertext_sha256="$(sha256sum "$SET_DIR/manifest.json.age" | awk '{print $1}')"
product_ciphertext_sha256="$(sha256sum "$SET_DIR/product.dump.age" | awk '{print $1}')"
auth_ciphertext_sha256="$(sha256sum "$SET_DIR/auth.dump.age" | awk '{print $1}')"
printf 'set_id=%s\nstatus=database_restore_verified\napplication_check=%s\nupgrade_check=%s\nproduct_upgrade=%s\ncontact_upgrade=%s\nverified_at_utc=%s\nproof_format=pandapay-paired-postgresql-restore-proof-v1\nmanifest_ciphertext_sha256=%s\nproduct_ciphertext_sha256=%s\nauth_ciphertext_sha256=%s\n' \
  "$SET_ID" "$application_check" "$upgrade_check" "$product_upgrade" "$contact_upgrade" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$manifest_ciphertext_sha256" "$product_ciphertext_sha256" "$auth_ciphertext_sha256" > "$status_tmp"
chmod 600 "$status_tmp"
mv "$status_tmp" "$RESTORE_STATUS_DIR/RESTORE_VERIFIED-$SET_ID"
cp "$RESTORE_STATUS_DIR/RESTORE_VERIFIED-$SET_ID" "$SET_DIR/RESTORE_VERIFIED"
echo "RESTORE_SET_STATUS=set=$SET_ID status=database_restore_verified application_check=$application_check upgrade_check=$upgrade_check product=ok auth=ok"
