#!/usr/bin/env bash
# Start (or restart) the MetaMining server detached, then prove it is up.
# Usage: ./serve.sh            (serves http://127.0.0.1:8000)
#        ./serve.sh --port 8001 (any extra args pass through to run.sh)
set -u
cd "$(dirname "$0")"
# Health check must hit localhost directly even when a proxy is configured
# (a proxy cannot reach back into this loopback server).
export no_proxy="127.0.0.1,localhost,${no_proxy:-}"
export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
PORT=8000
ARGS=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--port" ]; then PORT="$2"; shift 2; else ARGS+=("$1"); shift; fi
done
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":$PORT "; then
  if pgrep -f "bin/metamining.*--port $PORT" >/dev/null 2>&1 || pgrep -f "bin/metamining$" >/dev/null 2>&1; then
    echo "stale metamining on $PORT - stopping it first"
    fuser -k "$PORT/tcp" >/dev/null 2>&1 || true
    sleep 1
  else
    echo "port $PORT is busy with something else - refusing to kill it" >&2
    ss -tlnp 2>/dev/null | grep ":$PORT " >&2 || true
    exit 1
  fi
fi
LOG=/tmp/mm.log
setsid -f ./run.sh --host 127.0.0.1 --port "$PORT" "${ARGS[@]}" >>"$LOG" 2>&1 < /dev/null
for _ in $(seq 1 15); do
  sleep 1
  if curl -s -m 3 "http://127.0.0.1:$PORT/api/state" 2>/dev/null | grep -q '"t":"state"'; then
    echo "up: http://127.0.0.1:$PORT  (log: $LOG)"
    exit 0
  fi
done
echo "FAILED to come up on $PORT - last log lines:" >&2
tail -15 "$LOG" >&2 || true
exit 1
