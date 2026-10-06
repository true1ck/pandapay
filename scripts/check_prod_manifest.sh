#!/usr/bin/env bash
#
# smsextractionimple.md Task S-2 — verify the shipped prod manifest keeps
# the permissions required by automatic SMS spending detection.
#
# WHY THIS EXISTS
#
# The production manifest inherits READ_SMS/RECEIVE_SMS and the telephony
# receiver from the main manifest. The packaged manifest is checked because
# plugin and flavor merges can change the final permission set.
#
# A plugin bump can still accidentally remove the receiver or add broad
# storage permissions, so this check covers both required SMS entries and the
# storage denylist.
#
# This checks the MERGED, PACKAGED manifest for the prodRelease variant —
# the actual bytes that go in the bundle — not the source manifest, which
# says nothing about what plugins contributed.
#
# USAGE
#   scripts/check_prod_manifest.sh [path-to-manifest]
#
# With no argument it looks for the packaged manifest from a previous
# `flutter build appbundle --flavor prod --release`. It exits 2 (not 1) when
# it can't find one, so "no build to check" is distinguishable from
# "the build is bad".

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"
DEFAULT_MANIFEST="$APP_DIR/build/app/intermediates/packaged_manifests/prodRelease/processProdReleaseManifestForPackage/AndroidManifest.xml"
MANIFEST="${1:-$DEFAULT_MANIFEST}"

# Permissions that must be present in every prod release.
#
# These are required for the live SMS auto-import feature. Runtime permission
# and explicit user consent are still enforced by the app.
REQUIRED_SMS=(
  "android.permission.READ_SMS"
  "android.permission.RECEIVE_SMS"
)

# Permissions that must never appear in a prod release.
#
# The storage pair is the Scoped Storage era: `file_picker` goes through the
# Storage Access Framework and needs no permission, so one appearing means a
# dependency pulled in a legacy path — and broad storage access attracts
# exactly the manual review this whole approach is built to avoid.
#
# NOTE ON BACKGROUND LOCATION: smsextractionimple.md §1.2 recommends stripping
# ACCESS_BACKGROUND_LOCATION from the prod flavor too, but that is an open
# product decision (it removes a working feature), so it is NOT enforced here
# yet. Uncomment the line below once that decision is made — the check is
# already written.
DENYLIST=(
  "android.permission.READ_EXTERNAL_STORAGE"
  "android.permission.WRITE_EXTERNAL_STORAGE"
  # "android.permission.ACCESS_BACKGROUND_LOCATION"   # see §1.2
)

if [ ! -f "$MANIFEST" ]; then
  echo "check_prod_manifest: no packaged prodRelease manifest at" >&2
  echo "  $MANIFEST" >&2
  echo "Build one first, e.g.:" >&2
  echo "  scripts/build_app.sh prod appbundle --release" >&2
  exit 2
fi

echo "check_prod_manifest: checking $MANIFEST"

failed=0
for perm in "${REQUIRED_SMS[@]}"; do
  if grep -Eq "uses-permission[^>]*android:name=\"${perm//./\\.}\"" "$MANIFEST"; then
    echo "  ok: $perm present"
  else
    echo "  MISSING: $perm is not declared in the prod release manifest" >&2
    failed=1
  fi
done

for perm in "${DENYLIST[@]}"; do
  # Match the permission name inside a uses-permission element specifically,
  # so a comment mentioning the constant doesn't trip the check.
  if grep -Eq "uses-permission[^>]*android:name=\"${perm//./\\.}\"" "$MANIFEST"; then
    echo "  DENIED: $perm is declared in the prod release manifest" >&2
    failed=1
  else
    echo "  ok: $perm absent"
  fi
done

if [ "$failed" -ne 0 ]; then
  cat >&2 <<'EOF'

The prod release manifest has an invalid permission set.

This usually means a dependency's library manifest merged one in. Find it:

  cd app && flutter build appbundle --flavor prod --release
  # then read the merge report:
  cat build/app/outputs/logs/manifest-merger-prodRelease-report.txt

For missing SMS permissions, check app/android/app/src/main/AndroidManifest.xml
and the flavor merge. For unwanted permissions, strip them in
app/android/app/src/prod/AndroidManifest.xml:

  <uses-permission android:name="THE.PERMISSION" tools:node="remove"/>

then re-run this check.
EOF
  exit 1
fi

echo "check_prod_manifest: prod release manifest is clean"
