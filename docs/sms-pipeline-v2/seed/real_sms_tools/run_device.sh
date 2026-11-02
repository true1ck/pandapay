#!/bin/zsh
# Usage: run_device.sh <repoRoot> <messages.jsonl> <out.jsonl>
set -e
REPO=$1; IN=$2; OUT=$3; HERE=${0:A:h}
mkdir -p "$REPO/app/test/zz_tmp_real_sms"
cp "$HERE/device_probe_test.dart.tmpl" "$REPO/app/test/zz_tmp_real_sms/probe_test.dart"
cd "$REPO/app"
SMS_IN=$IN SMS_OUT=$OUT flutter test test/zz_tmp_real_sms/probe_test.dart 2>&1 | tail -3 || true
rm -rf "$REPO/app/test/zz_tmp_real_sms"
