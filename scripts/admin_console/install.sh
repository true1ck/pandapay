#!/bin/sh
set -eu
# Build on this PC only. This does not install OS trust or modify live services.
if [ "$#" -ne 1 ]; then echo 'Usage: install.sh ABSOLUTE_PRIVATE_BUNDLE_DIRECTORY' >&2; exit 2; fi
case "$1" in /*) ;; *) echo 'Absolute destination required' >&2; exit 2;; esac
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ -e "$1" ]; then echo 'Destination must not already exist' >&2; exit 2; fi
umask 077
cd "$task_root/console"
flutter build web --release --csp --no-web-resources-cdn --dart-define=PANDAPAY_PRIVATE_ADMIN=true
mkdir -m 700 "$1"
cp -R build/web/. "$1/"
find "$1" -type d -exec chmod 700 {} +
find "$1" -type f -exec chmod 600 {} +
echo 'Local console bundle installed. Configure protected TLS/SSH files before start.sh.'
