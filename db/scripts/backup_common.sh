#!/usr/bin/env bash
# Shared local-directory transport and retention helpers for paired backups.

# Provide the GNU coreutils interface on macOS as well. `shasum -a 256` emits
# the same checksum format and supports `-c`, so manifests stay portable.
sha256sum() {
  local binary
  binary="$(type -P sha256sum 2>/dev/null || true)"
  if [ -n "$binary" ]; then
    "$binary" "$@"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    echo "Required SHA-256 command is unavailable (install coreutils or Perl shasum)" >&2
    return 127
  fi
}

require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "Required backup setting is missing: $name" >&2
      return 2
    fi
  done
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "Required backup command is unavailable: $command_name" >&2
      return 2
    }
  done
}

validate_backup_inputs() {
  [ -r "$BACKUP_AGE_RECIPIENTS_FILE" ] || {
    echo "BACKUP_AGE_RECIPIENTS_FILE must be readable" >&2; return 2;
  }
  if grep -Eq 'AGE-SECRET-KEY-' "$BACKUP_AGE_RECIPIENTS_FILE"; then
    echo "Recipient file contains a private age identity; only public recipients belong on the backup host" >&2
    return 2
  fi
  grep -Eq '^[[:space:]]*age1[[:alnum:]]{20,}[[:space:]]*$' "$BACKUP_AGE_RECIPIENTS_FILE" || {
    echo "Recipient file contains no recognizable age recipient" >&2; return 2;
  }
  [ "${BACKUP_MODE:-offhost}" != local ] || return 0
  [ "$BACKUP_DESTINATION_A" != "$BACKUP_DESTINATION_B" ] || {
    echo "Backup destinations must be distinct" >&2; return 2;
  }
  for directory in "$BACKUP_DESTINATION_A" "$BACKUP_DESTINATION_B"; do
    [ -d "$directory" ] || { echo "Backup destination must be an existing mounted directory: $directory" >&2; return 2; }
    [ -w "$directory" ] || { echo "Backup destination is not writable: $directory" >&2; return 2; }
  done
  if ! python3 - "$BACKUP_DIR" "$BACKUP_DESTINATION_A" "$BACKUP_DESTINATION_B" <<'PY'
import os, sys
paths = [os.path.realpath(path) for path in sys.argv[1:]]
for i, left in enumerate(paths):
    for right in paths[i + 1:]:
        if os.path.commonpath((left, right)) in (left, right):
            raise SystemExit(1)
PY
  then
    echo "BACKUP_DIR and off-host destinations must be separate, non-nested directories" >&2
    return 2
  fi
}

write_complete_marker() {
  local set_dir="$1" set_id="$2" temporary marker=OFFSITE_COMPLETE status=offsite_uploaded
  if [ "${BACKUP_MODE:-offhost}" = local ]; then marker=LOCAL_COMPLETE; status=local_saved; fi
  temporary="$set_dir/.OFFSITE_COMPLETE.tmp"
  printf 'set_id=%s\nstatus=%s\ncompleted_epoch=%s\n' "$set_id" "$status" "$(date -u +%s)" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$set_dir/$marker"
}

publish_backup_set() {
  local source_dir="$1" destination_root="$2" set_id="$3" final pending
  final="$destination_root/$set_id"
  pending="$destination_root/.pending-$set_id"
  [ ! -e "$final" ] || { echo "Backup set already exists at destination: $set_id" >&2; return 1; }
  rm -rf -- "$pending"
  mkdir -m 700 "$pending"
  local file
  for file in product.dump.age auth.dump.age manifest.json.age checksums.sha256; do
    python3 "$SCRIPT_DIR/backup_storage.py" copy "$destination_root" "$source_dir/$file" "$pending/$file"
  done
  (cd "$pending" && sha256sum -c checksums.sha256 >/dev/null)
  mv "$pending" "$final"
}

prune_complete_backup_sets() {
  python3 "$SCRIPT_DIR/backup_storage.py" prune "$1"
}

complete_set_ids() {
  python3 "$SCRIPT_DIR/backup_storage.py" list "$1"
}
