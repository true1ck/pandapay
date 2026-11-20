#!/usr/bin/env bash
# Which tests a production deploy runs: full, server or none. Prints the choice on the last line.
#
#   full    every check, as before (the 8 Flutter app-test shards take ~20 min)
#   server  every server check (API/auth, PostgreSQL, migration/backup recovery, smoke, contracts, rule bundle);
#           skips only the app-test shards, which test the phone app and not what this deploys (~6 min)
#   none    no tests: the deploy starts at once (owner's choice while development is moving fast)
#
# MESSAGE        the pushed tip commit's message; a tag in it wins:
#                [deploy-tests:full] / [deploy-tests:server] / [deploy-tests:none]
# DEFAULT_TESTS  the repository variable DEPLOY_TESTS, a standing setting (gh variable set DEPLOY_TESTS --body server)
# Anything else, or nothing, means full.
set -euo pipefail

choice=""
case "${MESSAGE:-}" in
  *"[deploy-tests:none]"*) choice=none ;;
  *"[deploy-tests:server]"*) choice=server ;;
  *"[deploy-tests:full]"*) choice=full ;;
esac
if [ -z "$choice" ]; then
  case "${DEFAULT_TESTS:-}" in
    full|server|none) choice="$DEFAULT_TESTS" ;;
    *) choice=full ;;
  esac
fi
case "$choice" in
  full) echo "Deploy tests: full (every check)" ;;
  server) echo "Deploy tests: server checks only (the app-test shards are skipped)" ;;
  none) echo "Deploy tests: NONE (skipped on request)" ;;
esac
echo "$choice"
