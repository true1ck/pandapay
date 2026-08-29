#!/bin/bash

# verify_prod_manifest.sh
# Verifies that the prod flavor AndroidManifest.xml correctly strips READ_SMS and RECEIVE_SMS
# to comply with Google Play Store policies.

set -e

# Change to project root if executed from within scripts/
cd "$(dirname "$0")/.."

MANIFEST_PATH="app/android/app/src/prod/AndroidManifest.xml"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Error: $MANIFEST_PATH does not exist."
  exit 1
fi

echo "Verifying $MANIFEST_PATH for Play Store compliance..."

if ! grep -q 'android.permission.READ_SMS.*tools:node="remove"' "$MANIFEST_PATH"; then
  echo "❌ Error: READ_SMS permission is not explicitly removed in the prod manifest."
  echo "Google Play Store Policy bans regular apps from requesting raw READ_SMS."
  exit 1
fi

if ! grep -q 'android.permission.RECEIVE_SMS.*tools:node="remove"' "$MANIFEST_PATH"; then
  echo "❌ Error: RECEIVE_SMS permission is not explicitly removed in the prod manifest."
  exit 1
fi

echo "✅ Success: Prod manifest correctly strips SMS permissions."
exit 0
