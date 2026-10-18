#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$SCRIPT_DIR/../app/android"

# On Apple Silicon, prefer Homebrew Ruby over macOS's built-in Ruby 2.6.
# This avoids picking /usr/bin/bundle even when a supported Ruby is installed.
if [ -x /opt/homebrew/opt/ruby/bin/bundle ]; then
  BUNDLE_BIN=/opt/homebrew/opt/ruby/bin/bundle
else
  BUNDLE_BIN=bundle
fi

cd "$ANDROID_DIR"
exec "$BUNDLE_BIN" "$@"
