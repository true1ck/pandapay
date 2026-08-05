#!/usr/bin/env bash
# AD-9.4: nightly anonymization-audit run, independent of the CI gate
# (.github/workflows/anonymization-audit.yml only fires on push/PR — this
# catches a data-level regression on a day with no deploy at all, per the
# plan's explicit "even without a deploy" wording). Invoked by cron or a
# systemd timer (see pandapay-audit.timer alongside this script — same
# pattern as scraper/scripts/run_weekly.sh).
#
# "With alerting" per AD-9.4 is NOT implemented here — same honest gap as
# AD-8.4: no notification channel (email/Slack/etc.) exists in this
# codebase yet. This script fails loudly (non-zero exit, logged) so it's
# alertable the moment a real channel exists, but nothing pages anyone today.
set -euo pipefail

: "${AUDIT_DATABASE_URL:?AUDIT_DATABASE_URL must be set (postgresql://user:pass@host:port/pandapay)}"

LOG_DIR="${PANDAPAY_AUDIT_LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/audit-logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/audit-$(date +%Y%m%dT%H%M%S).log"

{
  RUN_ID=$(psql "$AUDIT_DATABASE_URL" -tAc "select pandapay.run_anonymization_audit('nightly-cron')")
  RESULT=$(psql "$AUDIT_DATABASE_URL" -tAc "select checks_failed, findings from anonymization_audit_runs where id = '$RUN_ID'")
  echo "Audit run $RUN_ID: $RESULT"
  FAILED=$(echo "$RESULT" | cut -d'|' -f1)
  if [ "$FAILED" != "0" ]; then
    echo "ANONYMIZATION AUDIT FAILED: $FAILED check(s) failed. Findings: $(echo "$RESULT" | cut -d'|' -f2)"
    exit 1
  fi
  echo "Anonymization audit passed."
} | tee "$LOG_FILE"
