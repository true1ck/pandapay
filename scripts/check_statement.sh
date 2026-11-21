#!/usr/bin/env bash
# Reads one bank statement (PDF, CSV or XLSX) through the app's own import path and
# prints a summary: row counts, totals, and whether the statement's running balance
# proves the rows. No narrations or names are printed. The rows themselves are
# written to a private folder outside the repository (personal data).
#
#   scripts/check_statement.sh ~/Downloads/statement.pdf
#
# A PDF asks for its password with hidden input (press Enter if it has none).
set -euo pipefail

file="${1:?usage: scripts/check_statement.sh /path/to/statement.pdf|csv|xlsx}"
[ -f "$file" ] || { echo "No such file: $file" >&2; exit 1; }
out="${STMT_OUT:-$HOME/.pandapay-statement-checks}"
password=""
case "$file" in
  *.pdf|*.PDF)
    read -r -s -p "Password for this PDF (Enter if none): " password
    echo
    ;;
esac

cd "$(dirname "$0")/../app"
STMT_FILE="$file" STMT_OUT="$out" STMT_PASSWORD="$password" \
  flutter test test/tool/statement_probe_test.dart 2>&1 \
  | grep -E "PROBE|Exception|password|Error" || true
echo "Rows saved in: $out"
