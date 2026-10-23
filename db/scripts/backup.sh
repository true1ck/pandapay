#!/usr/bin/env bash
# Paired logical backups: stream ciphertext only to persistent backup storage.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup_common.sh"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pandapay}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
export RETENTION_DAYS BACKUP_DIR
BACKUP_MODE="${BACKUP_MODE:-offhost}"
export BACKUP_MODE
require_env PRODUCT_DATABASE_URL AUTH_DATABASE_URL BACKUP_AGE_RECIPIENTS_FILE
case "$BACKUP_MODE" in
  offhost) require_env BACKUP_DESTINATION_A BACKUP_DESTINATION_B ;;
  local) ;;
  *) echo 'BACKUP_MODE must be offhost or local' >&2; exit 2 ;;
esac
require_commands pg_dump psql age python3 sha256sum
validate_backup_inputs
mkdir -p "$BACKUP_DIR"
if [ "${BACKUP_STORAGE_LOCK_HELD:-}" != 1 ]; then
  LOCK_ROOTS=("$BACKUP_DIR")
  if [ "$BACKUP_MODE" = offhost ]; then
    LOCK_ROOTS+=("$BACKUP_DESTINATION_A" "$BACKUP_DESTINATION_B")
  fi
  exec python3 "$SCRIPT_DIR/backup_storage.py" lock-many "${LOCK_ROOTS[0]}" \
    "${LOCK_ROOTS[@]:1}" cmd: bash "$SCRIPT_DIR/backup.sh"
fi
DESTINATIONS=("$BACKUP_DIR")
if [ "$BACKUP_MODE" = offhost ]; then DESTINATIONS+=("$BACKUP_DESTINATION_A" "$BACKUP_DESTINATION_B"); fi
for destination in "${DESTINATIONS[@]}"; do
  python3 "$SCRIPT_DIR/backup_storage.py" prepare "$destination"
done
# Snapshot metadata and libpq credentials are temporary, never part of the
# durable backup directory. Dumps themselves are never written in plaintext.
BACKUP_PRIVATE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/pandapay-backup.XXXXXXXX")"
BACKUP_SET_ID="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
BACKUP_ENCRYPTED_WORK="$BACKUP_DIR/.pending-$BACKUP_SET_ID"
FINAL="$BACKUP_DIR/$BACKUP_SET_ID"
mkdir -m 700 "$BACKUP_ENCRYPTED_WORK"
cleanup() {
  rm -rf -- "$BACKUP_PRIVATE_WORK" "$BACKUP_ENCRYPTED_WORK"
  # A failed upload must not leave accumulating ineligible generations.
  for destination in "${DESTINATIONS[@]}"; do
    rm -rf -- "$destination/.pending-$BACKUP_SET_ID"
    if [ ! -f "$destination/$BACKUP_SET_ID/OFFSITE_COMPLETE" ] && [ ! -f "$destination/$BACKUP_SET_ID/LOCAL_COMPLETE" ]; then
      rm -rf -- "$destination/$BACKUP_SET_ID"
    fi
  done
}
trap cleanup EXIT
trap 'echo "Paired backup failed; incomplete sets are not restore eligible" >&2; exit 1' ERR INT TERM
python3 "$SCRIPT_DIR/pg_connection.py" --output "$BACKUP_PRIVATE_WORK/urls.json" --pgpass "$BACKUP_PRIVATE_WORK/pgpass" \
  --url-env PRODUCT_DATABASE_URL --url-env AUTH_DATABASE_URL
export PGPASSFILE="$BACKUP_PRIVATE_WORK/pgpass"
PRODUCT_DATABASE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["PRODUCT_DATABASE_URL"])' "$BACKUP_PRIVATE_WORK/urls.json")"
AUTH_DATABASE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["AUTH_DATABASE_URL"])' "$BACKUP_PRIVATE_WORK/urls.json")"
export PRODUCT_DATABASE_URL AUTH_DATABASE_URL BACKUP_PRIVATE_WORK BACKUP_SET_ID BACKUP_ENCRYPTED_WORK
python3 "$SCRIPT_DIR/backup_snapshot.py" bash "$SCRIPT_DIR/backup_payload.sh"
mv "$BACKUP_ENCRYPTED_WORK" "$FINAL"
if [ "$BACKUP_MODE" = offhost ]; then
  publish_backup_set "$FINAL" "$BACKUP_DESTINATION_A" "$BACKUP_SET_ID"
  publish_backup_set "$FINAL" "$BACKUP_DESTINATION_B" "$BACKUP_SET_ID"
fi
for destination in "${DESTINATIONS[@]}"; do
  write_complete_marker "$destination/$BACKUP_SET_ID" "$BACKUP_SET_ID"
done
if [ "$BACKUP_MODE" = offhost ]; then
  echo "BACKUP_SET_STATUS=set=$BACKUP_SET_ID status=offsite_uploaded copies=2"
else
  echo "BACKUP_SET_STATUS=set=$BACKUP_SET_ID status=local_saved copies=1"
fi
for destination in "${DESTINATIONS[@]}"; do
  prune_complete_backup_sets "$destination" "$RETENTION_DAYS"
done
