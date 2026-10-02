#!/bin/bash

# verify_prod_manifest.sh
# Verifies that the prod flavor AndroidManifest.xml keeps the SMS permissions
# and receiver required for automatic spending detection.

set -e

# Change to project root if executed from within scripts/
cd "$(dirname "$0")/.."

MANIFEST_PATH="app/android/app/src/prod/AndroidManifest.xml"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "Error: $MANIFEST_PATH does not exist."
  exit 1
fi

echo "Verifying $MANIFEST_PATH for SMS auto-import..."

if grep -q 'android.permission.READ_SMS.*tools:node="remove"' "$MANIFEST_PATH"; then
  echo "❌ Error: READ_SMS is explicitly removed in the prod manifest."
  exit 1
fi

if grep -q 'android.permission.RECEIVE_SMS.*tools:node="remove"' "$MANIFEST_PATH"; then
  echo "❌ Error: RECEIVE_SMS is explicitly removed in the prod manifest."
  exit 1
fi

echo "✅ Success: Prod manifest does not remove SMS permissions."
exit 0
