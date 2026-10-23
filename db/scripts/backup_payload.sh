#!/usr/bin/env bash
# Called only inside backup_snapshot.py while exported snapshots are alive.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup_common.sh"
require_snapshot() { [[ "$1" =~ ^[a-fA-F0-9]+-[a-fA-F0-9]+-[0-9]+$ ]]; }
require_snapshot "$BACKUP_PRODUCT_SNAPSHOT"
require_snapshot "$BACKUP_AUTH_SNAPSHOT"
pg_dump "$PRODUCT_DATABASE_URL" --format=custom --compress=6 --snapshot="$BACKUP_PRODUCT_SNAPSHOT" \
  2>"$BACKUP_PRIVATE_WORK/product-error" | age -R "$BACKUP_AGE_RECIPIENTS_FILE" | python3 "$SCRIPT_DIR/backup_storage.py" write "$BACKUP_DIR" "$BACKUP_ENCRYPTED_WORK/product.dump.age"
pg_dump "$AUTH_DATABASE_URL" --format=custom --compress=6 --snapshot="$BACKUP_AUTH_SNAPSHOT" \
  2>"$BACKUP_PRIVATE_WORK/auth-error" | age -R "$BACKUP_AGE_RECIPIENTS_FILE" | python3 "$SCRIPT_DIR/backup_storage.py" write "$BACKUP_DIR" "$BACKUP_ENCRYPTED_WORK/auth.dump.age"
python3 "$SCRIPT_DIR/backup_manifest.py" create \
  --product-url-env PRODUCT_DATABASE_URL --auth-url-env AUTH_DATABASE_URL \
  --product-dump "$BACKUP_ENCRYPTED_WORK/product.dump.age" --auth-dump "$BACKUP_ENCRYPTED_WORK/auth.dump.age" \
  --set-id "$BACKUP_SET_ID" --output "$BACKUP_PRIVATE_WORK/manifest.json"
age -R "$BACKUP_AGE_RECIPIENTS_FILE" "$BACKUP_PRIVATE_WORK/manifest.json" | python3 "$SCRIPT_DIR/backup_storage.py" write "$BACKUP_DIR" "$BACKUP_ENCRYPTED_WORK/manifest.json.age"
(cd "$BACKUP_ENCRYPTED_WORK" && sha256sum product.dump.age auth.dump.age manifest.json.age > checksums.sha256)
