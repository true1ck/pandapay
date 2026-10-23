#!/usr/bin/env bash
#
# Android flavor and backend environment are separate on purpose. Normal
# builds use the same environment for both. A physical-device QA update can
# opt into `--production-backend` so the existing Dev package id and local
# install data are retained while the release artifact explicitly uses
# hosted production services (`PANDAPAY_ENV=dev_hosted`).
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
# desktop, or a physical device. Pass --production-backend after the target
# to build the Dev flavor against hosted production endpoints while retaining
# the Dev package id and install data.
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

PRODUCTION_BACKEND=0
FILTERED_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--production-backend" ]; then
    PRODUCTION_BACKEND=1
  else
    FILTERED_ARGS+=("$arg")
  fi
done
set -- "${FILTERED_ARGS[@]}"
if [ "$PRODUCTION_BACKEND" -eq 1 ] && [ "$ENV_NAME" != "dev" ]; then
  echo "--production-backend is only valid with the dev flavor." >&2
  exit 1
fi

if [ "$ENV_NAME" = "prod" ] && [ "$BUILD_TARGET" = "apk" ]; then
  case " $* " in
    *" --split-per-abi "*) ;;
    *) echo "Production phone APKs require --split-per-abi; build an app bundle separately for Play Console delivery." >&2; exit 1 ;;
  esac
  HAS_BUILD_NUMBER=0
  for ((i = 1; i <= $#; i++)); do
    arg="${!i}"
    if [[ "$arg" =~ ^--build-number=[1-9][0-9]*$ ]]; then
      HAS_BUILD_NUMBER=1
      break
    elif [ "$arg" = "--build-number" ] && [ "$i" -lt "$#" ]; then
      next_i=$((i + 1))
      next_arg="${!next_i}"
      if [[ "$next_arg" =~ ^[1-9][0-9]*$ ]]; then
        HAS_BUILD_NUMBER=1
        break
      fi
    fi
  done
  if [ "$HAS_BUILD_NUMBER" -ne 1 ]; then
    echo "Production builds require an explicit --build-number so an older APK cannot be shared by mistake." >&2
    exit 1
  fi
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

BACKEND_ENV_NAME="$ENV_NAME"
if [ "$PRODUCTION_BACKEND" -eq 1 ]; then
  case "$API_BASE_URL" in
    http://localhost*|http://127.0.0.1*|http://10.0.2.2*) echo "--production-backend requires a hosted API URL." >&2; exit 1 ;;
  esac
  case "$AUTH_BASE_URL" in
    http://localhost*|http://127.0.0.1*|http://10.0.2.2*) echo "--production-backend requires a hosted auth URL." >&2; exit 1 ;;
  esac
  BACKEND_ENV_NAME=dev_hosted
fi

cd "$REPO_ROOT/app"

echo "==> Building $FLAVOR flavor ($BUILD_TARGET), backend environment $BACKEND_ENV_NAME, against:"
echo "    PANDAPAY_API_BASE_URL=$API_BASE_URL"
echo "    PANDAPAY_AUTH_BASE_URL=$AUTH_BASE_URL"
echo "    PANDAPAY_LEGAL_BASE_URL=$LEGAL_BASE_URL"

exec flutter build "$BUILD_TARGET" \
  --flavor "$FLAVOR" \
  --dart-define=PANDAPAY_ENV="$BACKEND_ENV_NAME" \
  --dart-define=PANDAPAY_API_BASE_URL="$API_BASE_URL" \
  --dart-define=PANDAPAY_AUTH_BASE_URL="$AUTH_BASE_URL" \
  --dart-define=PANDAPAY_LEGAL_BASE_URL="$LEGAL_BASE_URL" \
  "$@"
