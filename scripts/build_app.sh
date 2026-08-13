#!/usr/bin/env bash
#
# A code review of app/android/app/build.gradle.kts's new dev/staging/prod
# flavors caught that --flavor and --dart-define are two unconnected
# mechanisms: nothing stopped `--flavor dev` from being built alongside
# `--dart-define=PANDAPAY_API_BASE_URL=https://api.yourapp.com` (the real
# prod URL), and app/lib/app/env.dart's assertReleaseConfigured() only
# checks whether the resolved URL points at localhost — not whether it
# agrees with the flavor. A release built that way ships labeled
# "PandaPay Dev" while silently talking to production, with no warning at
# build or runtime.
#
# This script is the fix: one positional argument picks BOTH the Android
# flavor and the matching --dart-define values together, so there's no
# longer a set of independently-typeable flags that can disagree.
#
# Usage:
#   scripts/build_app.sh dev [extra flutter build args...]
#   scripts/build_app.sh staging
#   scripts/build_app.sh prod
#
# staging/prod require PANDAPAY_API_BASE_URL and PANDAPAY_AUTH_BASE_URL to
# already be set in the environment (deploy/DEPLOY.md documents where
# those come from) — dev defaults to localhost, matching env.dart's own
# defaults, since that's the only flavor a debug/local build should ever
# use.

set -Eeuo pipefail

ENV_NAME="${1:-}"
if [ -z "$ENV_NAME" ]; then
  echo "Usage: scripts/build_app.sh <dev|staging|prod> [extra flutter build args...]" >&2
  exit 1
fi
shift

case "$ENV_NAME" in
  dev)
    FLAVOR=dev
    API_BASE_URL="${PANDAPAY_API_BASE_URL:-http://localhost:4000}"
    AUTH_BASE_URL="${PANDAPAY_AUTH_BASE_URL:-http://localhost:3210}"
    ;;
  staging)
    FLAVOR=staging
    : "${PANDAPAY_API_BASE_URL:?staging build requires PANDAPAY_API_BASE_URL to be set}"
    : "${PANDAPAY_AUTH_BASE_URL:?staging build requires PANDAPAY_AUTH_BASE_URL to be set}"
    API_BASE_URL="$PANDAPAY_API_BASE_URL"
    AUTH_BASE_URL="$PANDAPAY_AUTH_BASE_URL"
    ;;
  prod)
    FLAVOR=prod
    : "${PANDAPAY_API_BASE_URL:?prod build requires PANDAPAY_API_BASE_URL to be set}"
    : "${PANDAPAY_AUTH_BASE_URL:?prod build requires PANDAPAY_AUTH_BASE_URL to be set}"
    API_BASE_URL="$PANDAPAY_API_BASE_URL"
    AUTH_BASE_URL="$PANDAPAY_AUTH_BASE_URL"
    ;;
  *)
    echo "Unknown environment '$ENV_NAME' — expected dev, staging, or prod" >&2
    exit 1
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/app"

echo "==> Building $FLAVOR flavor against:"
echo "    PANDAPAY_API_BASE_URL=$API_BASE_URL"
echo "    PANDAPAY_AUTH_BASE_URL=$AUTH_BASE_URL"

exec flutter build apk \
  --flavor "$FLAVOR" \
  --dart-define=PANDAPAY_ENV="$ENV_NAME" \
  --dart-define=PANDAPAY_API_BASE_URL="$API_BASE_URL" \
  --dart-define=PANDAPAY_AUTH_BASE_URL="$AUTH_BASE_URL" \
  "$@"
