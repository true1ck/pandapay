#!/usr/bin/env bash
# Host-side pg_dump adapter for a reviewed local client image. Only temporary
# connection material is mounted; private recovery identities stay on the host.
set -Eeuo pipefail
IMAGE="${BACKUP_PG_DUMP_IMAGE:?Set the reviewed local PostgreSQL client image}"
if [ "$#" = 1 ] && [ "$1" = --version ]; then
  exec docker run --rm --pull never --network none --entrypoint pg_dump "$IMAGE" --version
fi
[ -d "${BACKUP_PRIVATE_WORK:-}" ] && [ -r "${PGPASSFILE:-}" ] || {
  echo 'Container pg_dump requires the prepared private connection workspace' >&2
  exit 2
}
case "$PGPASSFILE" in
  "$BACKUP_PRIVATE_WORK"/*) ;;
  *) echo 'pgpass must belong to the private connection workspace' >&2; exit 2 ;;
esac
exec docker run --rm --pull never \
  --mount "type=bind,source=$BACKUP_PRIVATE_WORK,target=$BACKUP_PRIVATE_WORK,readonly" \
  -e "PGPASSFILE=$PGPASSFILE" -e "PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}" \
  --entrypoint pg_dump "$IMAGE" "$@"
