#!/usr/bin/env bash
# Send a script over SSH without allowing its children to read future source.
# Never put the payload (which may include exported secrets) in process argv.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo 'Usage: ssh_script.sh <user@host> [commit-sha [source-ref]]' >&2
  exit 2
fi
target_host="$1"
shift
[ -n "$target_host" ] && [[ "$target_host" != -* ]] || {
  echo 'FATAL: missing or invalid SSH target' >&2
  exit 2
}

# Only release identifiers are accepted as command arguments. The complete
# script is transmitted on stdin and stored with mode 0600 on the remote host.
remote_command='set -eu; umask 077; remote_script=$(mktemp "${TMPDIR:-/tmp}/pandapay-ssh-script.XXXXXXXX"); trap '\''rm -f "$remote_script"'\'' EXIT; trap '\''exit 129'\'' HUP; trap '\''exit 130'\'' INT; trap '\''exit 143'\'' TERM; cat > "$remote_script"; bash "$remote_script"'
for release_argument in "$@"; do
  [[ "$release_argument" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo 'FATAL: invalid release identifier for SSH script' >&2
    exit 2
  }
  remote_command+=" '$release_argument'"
done
remote_command+=' < /dev/null'

exec ssh -i "$HOME/.ssh/id_deploy" \
  -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
  -- "$target_host" "$remote_command"
