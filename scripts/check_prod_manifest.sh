#!/usr/bin/env bash
#
# smsextractionimple.md Task S-2 — fail the build if a permission Play Store
# review punishes us for has crept back into the shipped prod manifest.
#
# WHY THIS EXISTS
#
# app/android/app/src/prod/AndroidManifest.xml strips READ_SMS/RECEIVE_SMS
# with `tools:node="remove"`, and that is currently working. But the property
# it guarantees — "the prod artefact declares no SMS permission" — is not
# actually enforced by anything. It can regress silently in at least three
# ways, none of which touch the file a human would think to check:
#
#   1. A plugin bump. Library manifests merge into the app's, and a
#      dependency that adds READ_EXTERNAL_STORAGE (or an SMS permission) does
#      so with no diff in this repo at all beyond a version bump.
#   2. Someone adds the permission to the main manifest without knowing the
#      prod flavor is supposed to strip it.
#   3. A refactor of the flavor manifest that drops or misspells a
#      `tools:node="remove"` — which fails OPEN, keeping the permission.
#
# All three ship a Play Store review problem that no test catches, because
# the app's own tests never look at the merged manifest.
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

# Permissions that must never appear in a prod release.
#
# The SMS pair is Play's SMS/Call Log policy: allowed only for an app that is
# the user's default SMS handler with the permission as core, unremovable
# functionality. PandaPay is not, and the backup-file import path
# deliberately needs neither.
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
  "android.permission.READ_SMS"
  "android.permission.RECEIVE_SMS"
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

The prod release manifest declares a permission that must not ship.

This usually means a dependency's library manifest merged one in. Find it:

  cd app && flutter build appbundle --flavor prod --release
  # then read the merge report:
  cat build/app/outputs/logs/manifest-merger-prodRelease-report.txt

Strip it in app/android/app/src/prod/AndroidManifest.xml alongside the
existing SMS entries:

  <uses-permission android:name="THE.PERMISSION" tools:node="remove"/>

then re-run this check.
EOF
  exit 1
fi

echo "check_prod_manifest: prod release manifest is clean"
