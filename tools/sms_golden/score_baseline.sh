#!/bin/sh
# Scores the baseline interpretations of today's parsers with the golden runner
# and writes reports/baseline_phone.{json,md} and reports/baseline_server.{json,md}.
#
# Regenerate the interpretations first (each is skipped in normal CI):
#   cd app && SMS_GOLDEN_BASELINE=1 flutter test test/sms_golden_baseline --tags golden-baseline
#   cd api && SMS_GOLDEN_BASELINE=1 node --test test/sms_golden_baseline/baseline.test.js
# Then run this script from anywhere.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/../sms_rules_cli"
for name in phone server; do
  out="$HERE/reports/.scored_$name"
  # Fields today's parsers cannot represent are not compared: issuer, rail,
  # merchant/biller names, statement dates, references and counterparties.
  dart run bin/sms_rules.dart golden \
    --golden-dir "$HERE" \
    --interpretations "$HERE/reports/baseline_$name.interpretations.json" \
    --profile none \
    --ignore-fields instrument.issuerSlug,attrs.rail,attrs.merchantName,attrs.statementDate,attrs.dueAt,references,counterparty \
    --out "$out"
  mv "$out/report.json" "$HERE/reports/baseline_$name.json"
  mv "$out/report.md" "$HERE/reports/baseline_$name.md"
  rmdir "$out"
done
