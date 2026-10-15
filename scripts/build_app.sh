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
#   scripts/build_app.sh dev [apk|appbundle] [extra flutter build args...]
#   scripts/build_app.sh staging
#   scripts/build_app.sh prod appbundle --release   # what Play Console needs
#
# staging/prod require PANDAPAY_API_BASE_URL and PANDAPAY_AUTH_BASE_URL to
# already be set in the environment (deploy/DEPLOY.md documents where
# those come from) — dev defaults to 10.0.2.2, the Android emulator's alias
# for this Mac. Set the variables explicitly when running a dev build on iOS,
# desktop, or a physical device.
#
# Target defaults to `apk` (sideloading/testing) — pass `appbundle` as the
# second argument for a Play Console upload; Play no longer accepts a bare
# APK for new app submissions.

set -Eeuo pipefail

ENV_NAME="${1:-}"
if [ -z "$ENV_NAME" ]; then
  echo "Usage: scripts/build_app.sh <dev|staging|prod> [apk|appbundle] [extra flutter build args...]" >&2
  exit 1
fi
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$ENV_NAME" = "prod" ] && [ ! -f "$REPO_ROOT/app/android/key.properties" ]; then
  echo "Production builds require app/android/key.properties; refusing to use the Android debug signing key." >&2
  exit 1
fi

BUILD_TARGET="apk"
if [ "${1:-}" = "apk" ] || [ "${1:-}" = "appbundle" ]; then
  BUILD_TARGET="$1"
  shift
fi

if [ "$ENV_NAME" = "prod" ] && [ "$BUILD_TARGET" = "apk" ]; then
  case " $* " in
    *" --split-per-abi "*) ;;
    *) echo "Production phone APKs require --split-per-abi; build an app bundle separately for Play Console delivery." >&2; exit 1 ;;
  esac
  case " $* " in
    *" --build-number="[1-9][0-9]*"*) ;;
    *) echo "Production builds require an explicit --build-number so an older APK cannot be shared by mistake." >&2; exit 1 ;;
  esac
fi

case "$ENV_NAME" in
  dev)
    FLAVOR=dev
    API_BASE_URL="${PANDAPAY_API_BASE_URL:-http://10.0.2.2:4000}"
    AUTH_BASE_URL="${PANDAPAY_AUTH_BASE_URL:-http://10.0.2.2:3210}"
    LEGAL_BASE_URL="${PANDAPAY_LEGAL_BASE_URL:-http://10.0.2.2:4000/legal/}"
    ;;
  staging)
    FLAVOR=staging
    : "${PANDAPAY_API_BASE_URL:?staging build requires PANDAPAY_API_BASE_URL to be set}"
    : "${PANDAPAY_AUTH_BASE_URL:?staging build requires PANDAPAY_AUTH_BASE_URL to be set}"
    API_BASE_URL="$PANDAPAY_API_BASE_URL"
    AUTH_BASE_URL="$PANDAPAY_AUTH_BASE_URL"
    LEGAL_BASE_URL="${PANDAPAY_LEGAL_BASE_URL:-${API_BASE_URL%/}/legal/}"
    ;;
  prod)
    FLAVOR=prod
    : "${PANDAPAY_API_BASE_URL:?prod build requires PANDAPAY_API_BASE_URL to be set}"
    : "${PANDAPAY_AUTH_BASE_URL:?prod build requires PANDAPAY_AUTH_BASE_URL to be set}"
    API_BASE_URL="$PANDAPAY_API_BASE_URL"
    AUTH_BASE_URL="$PANDAPAY_AUTH_BASE_URL"
    LEGAL_BASE_URL="${PANDAPAY_LEGAL_BASE_URL:-${API_BASE_URL%/}/legal/}"
    ;;
  *)
    echo "Unknown environment '$ENV_NAME' — expected dev, staging, or prod" >&2
    exit 1
    ;;
esac

cd "$REPO_ROOT/app"

echo "==> Building $FLAVOR flavor ($BUILD_TARGET) against:"
echo "    PANDAPAY_API_BASE_URL=$API_BASE_URL"
echo "    PANDAPAY_AUTH_BASE_URL=$AUTH_BASE_URL"
echo "    PANDAPAY_LEGAL_BASE_URL=$LEGAL_BASE_URL"

exec flutter build "$BUILD_TARGET" \
  --flavor "$FLAVOR" \
  --dart-define=PANDAPAY_ENV="$ENV_NAME" \
  --dart-define=PANDAPAY_API_BASE_URL="$API_BASE_URL" \
  --dart-define=PANDAPAY_AUTH_BASE_URL="$AUTH_BASE_URL" \
  --dart-define=PANDAPAY_LEGAL_BASE_URL="$LEGAL_BASE_URL" \
  "$@"
