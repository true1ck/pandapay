#!/usr/bin/env bash
# On-device UI-thread smoke test. Run it on a real phone, with a PROFILE or
# RELEASE build of the app installed and signed in, before merging anything
# that touches SMS, sync, the local database, providers or startup.
#
#   scripts/perf_smoke_android.sh [-s SERIAL] [-p PACKAGE]
#
# What it checks (thresholds are env-overridable):
#   1. Cold start: the Flutter UI thread (= Android main thread, tid == pid)
#      must not stay saturated. Longest run of busy 2-second windows
#      <= MAX_BUSY_RUN_S (default 16) and the final 10 s average <= MAX_IDLE_PCT
#      (default 15 %) once the app has been up 30 s.
#   2. Scrolling: the app's own frame summaries (profile builds log
#      "PandaPay frames ... ui_p95_us=") must have a median UI p95 <=
#      MAX_UI_P95_US (default 8000) while Home is swiped.
#
# Background: see docs/PERFORMANCE_RULEBOOK.md. The numbers come from the
# 7 Nov 2026 incident, where the UI thread sat at 100 % CPU for 30+ s after
# launch because of synchronous, quadratic SQLite/JSON work.
set -euo pipefail

SERIAL=""
PACKAGE="app.pandapay.pandapay.dev2"
while getopts "s:p:" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) PACKAGE="$OPTARG" ;;
    *) echo "usage: $0 [-s serial] [-p package]"; exit 2 ;;
  esac
done

ADB="${ADB:-adb}"
if [ -n "$SERIAL" ]; then ADB="$ADB -s $SERIAL"; fi

MAX_BUSY_RUN_S="${MAX_BUSY_RUN_S:-16}"
MAX_IDLE_PCT="${MAX_IDLE_PCT:-15}"
MAX_UI_P95_US="${MAX_UI_P95_US:-8000}"
WINDOW_S=2
SAMPLES=22            # 44 s of samples
BUSY_TICKS=150        # of 200 ticks per 2 s window (clock ticks are 100 Hz)

ticks() {
  $ADB shell "awk '{print \$14+\$15}' /proc/$1/task/$1/stat" | tr -d '\r'
}

echo "== cold start: $PACKAGE"
$ADB shell am force-stop "$PACKAGE"
$ADB logcat -c
$ADB shell am start -n "$PACKAGE/app.pandapay.pandapay.MainActivity" >/dev/null
sleep 4
PID="$($ADB shell pidof "$PACKAGE" | tr -d '\r')"
[ -n "$PID" ] || { echo "FAIL: app did not start"; exit 1; }

prev="$(ticks "$PID")"
deltas=()
for _ in $(seq 1 "$SAMPLES"); do
  sleep "$WINDOW_S"
  now="$(ticks "$PID")"
  deltas+=($((now - prev)))
  prev="$now"
done
echo "main-thread ticks per ${WINDOW_S}s window: ${deltas[*]}"

# The first window includes process start-up, which is unavoidable.
longest=0; run=0
for d in "${deltas[@]:1}"; do
  if [ "$d" -ge "$BUSY_TICKS" ]; then run=$((run + 1)); else run=0; fi
  [ "$run" -gt "$longest" ] && longest="$run"
done
longest_s=$((longest * WINDOW_S))
tail_sum=0
for d in "${deltas[@]: -5}"; do tail_sum=$((tail_sum + d)); done
idle_pct=$((tail_sum / (5 * WINDOW_S)))   # ticks are 1/100 s -> % of one core
echo "longest saturated run: ${longest_s}s (limit ${MAX_BUSY_RUN_S}s)"
echo "last 10s average: ${idle_pct}% of one core (limit ${MAX_IDLE_PCT}%)"

fail=0
[ "$longest_s" -le "$MAX_BUSY_RUN_S" ] || { echo "FAIL: UI thread saturated too long after launch"; fail=1; }
[ "$idle_pct" -le "$MAX_IDLE_PCT" ] || { echo "FAIL: UI thread still busy when the app should be idle"; fail=1; }

echo "== scrolling Home"
$ADB logcat -c
for _ in 1 2 3 4 5 6; do $ADB shell input swipe 540 1700 540 600 250; sleep 0.4; done
for _ in 1 2 3 4 5 6; do $ADB shell input swipe 540 600 540 1700 250; sleep 0.4; done
sleep 1
p95s=($($ADB logcat -d | { grep -o "ui_p95_us=[0-9]*" || true; } | cut -d= -f2 | sort -n))
if [ "${#p95s[@]}" -eq 0 ]; then
  echo "WARN: no frame summaries logged (needs a PROFILE build); skipping scroll check"
else
  median="${p95s[$(( ${#p95s[@]} / 2 ))]}"
  echo "median UI p95 while scrolling: ${median}us over ${#p95s[@]} summaries (limit ${MAX_UI_P95_US}us)"
  [ "$median" -le "$MAX_UI_P95_US" ] || { echo "FAIL: scrolling UI frames too slow"; fail=1; }
fi

if [ "$fail" -eq 0 ]; then echo "PASS"; else exit 1; fi
