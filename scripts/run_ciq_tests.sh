#!/usr/bin/env bash
# Headless Connect IQ unit-test runner.
#
#   scripts/run_ciq_tests.sh <test.prg> <device> [display] [timeout_secs]
#
# Runs a --unit-test .prg under the Connect IQ simulator with NO physical
# display, teeing everything to sim-run.log. It is deliberately paranoid about
# the classic CIQ-CI failure mode - the simulator hanging forever - so every
# blocking step is bounded and the sim is probed for readiness before use.
#
# This script does NOT decide pass/fail from the runner exit code (the sim can
# exit 0 on a broken run). Parse sim-run.log with scripts/check_ciq_tests.py.
#
# The repo ships (:test) functions in source/CarbBurnTest.mc; see docs/ci.md for
# the CI wiring status of the run-tests job.
set -uo pipefail

PRG=${1:?usage: run_ciq_tests.sh <test.prg> <device> [display] [timeout_secs]}
DEVICE=${2:?usage: run_ciq_tests.sh <test.prg> <device> [display] [timeout_secs]}
DISPLAY_NUM=${3:-:99}
RUN_TIMEOUT=${4:-180}
LOG=sim-run.log

: > "$LOG"

log() { echo "[run_ciq_tests] $*" | tee -a "$LOG"; }

# ---- resolve the SDK binaries (PATH, then the connectiq-tester layout) ----
find_bin() {
  local name=$1 p
  p=$(command -v "$name" 2>/dev/null) && { echo "$p"; return; }
  [ -x "/connectiq/bin/$name" ] && { echo "/connectiq/bin/$name"; return; }
  p=$(find / -type f -name "$name" 2>/dev/null | head -1) && [ -n "$p" ] && { echo "$p"; return; }
  return 1
}

CONNECTIQ=$(find_bin connectiq) || { log "FATAL: 'connectiq' launcher not found"; exit 3; }
MONKEYDO=$(find_bin monkeydo)   || { log "FATAL: 'monkeydo' not found"; exit 3; }
log "connectiq=$CONNECTIQ monkeydo=$MONKEYDO device=$DEVICE prg=$PRG"

# ---- cleanup handlers ----
SIM_PID=""
XVFB_PID=""
cleanup() {
  log "cleanup: stopping simulator / Xvfb"
  [ -n "$SIM_PID" ]  && kill "$SIM_PID"  2>/dev/null || true
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
  pkill -f "/connectiq/bin/simulator" 2>/dev/null || true
  pkill -x simulator 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- belt-and-suspenders: kill any pre-existing simulator ----
log "pre-kill any stale simulator"
pkill -f "/connectiq/bin/simulator" 2>/dev/null || true
pkill -x simulator 2>/dev/null || true

# ---- start a virtual framebuffer ----
log "starting Xvfb on $DISPLAY_NUM"
Xvfb "$DISPLAY_NUM" -screen 0 1280x1024x24 >>"$LOG" 2>&1 &
XVFB_PID=$!
export DISPLAY="$DISPLAY_NUM"
# give Xvfb a beat, then confirm it is actually up
for _ in $(seq 1 20); do
  if xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
  log "FATAL: Xvfb did not come up on $DISPLAY_NUM"
  exit 3
fi
log "Xvfb up (pid $XVFB_PID)"

# ---- launch the simulator ONCE ----
# The 'connectiq' launcher forks /connectiq/bin/simulator, which LISTENs on
# 0.0.0.0:1234. monkeydo then connects to that port.
log "launching simulator"
"$CONNECTIQ" >>"$LOG" 2>&1 &
SIM_PID=$!

# ---- READINESS PROBE: wait for port 1234 before doing anything ----
log "waiting for simulator to LISTEN on :1234"
ready=0
for _ in $(seq 1 60); do
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':1234'; then ready=1; break; fi
  if pgrep -f "/connectiq/bin/simulator" >/dev/null 2>&1 \
     && command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':1234'; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  log "FATAL: simulator never opened :1234 (would have hung) - giving up"
  exit 3
fi
log "simulator ready (pid $SIM_PID)"

# ---- run the tests under a HARD timeout so a hang fails fast ----
#
# Evidence preservation matters more than speed of death here. The previous
# form (`timeout --signal=KILL ... | tee`) block-buffered ~4 KB - larger than a
# whole test transcript - so SIGKILL discarded every line even when tests HAD
# run, which is why the first hang produced zero bytes and told us nothing.
# Now: line-buffer with stdbuf so each line reaches the log as it is produced,
# and send TERM first (with --kill-after as the backstop) so the process gets a
# chance to flush.
log "running: monkeydo $PRG $DEVICE -t  (timeout ${RUN_TIMEOUT}s)"
set -o pipefail
timeout --signal=TERM --kill-after=15s "$RUN_TIMEOUT" \
  stdbuf -oL -eL "$MONKEYDO" "$PRG" "$DEVICE" -t 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
log "monkeydo raw exit code = $rc (NOT trusted for pass/fail; parse $LOG)"

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
  # 124 = timeout fired, 143 = child took SIGTERM, 137 = --kill-after SIGKILL.
  log "FATAL: monkeydo TIMED OUT after ${RUN_TIMEOUT}s (rc=$rc)"
  log "any output captured before the timeout is above / in $LOG"
  exit 4
fi

log "run complete - parse $LOG with scripts/check_ciq_tests.py"
exit 0
