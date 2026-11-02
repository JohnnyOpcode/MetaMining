#!/usr/bin/env bash
# Start the whole party: local embedding server + MetaMining wired to it.
# Usage: ./metamining.sh [--port 8000] [extra metamining args...]
#        ./metamining.sh --no-embed [--port 8000] [args...]  (hash vectors only)
#        ./metamining.sh stop [--port 8000]                  (stop both servers)
# Env: EMBED_PORT (default 8080), EMBED_FLAVOR=cpu|cuda (see embed-setup.sh).
set -u
cd "$(dirname "$0")"
export no_proxy="127.0.0.1,localhost,${no_proxy:-}"
export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"

PORT=8000
EMB_PORT="${EMBED_PORT:-8080}"
NOEMB=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --no-embed) NOEMB=1; shift ;;
    stop) ACTION_STOP=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

our_proc() {
  # $1 = pgrep pattern. True when one of our binaries runs with it.
  pgrep -f "$1" >/dev/null 2>&1
}

if [ "${ACTION_STOP:-0}" = "1" ]; then
  [ "$NOEMB" = "0" ] && [ "$EMB_PORT" != "$PORT" ] && {
    if our_proc "llama-server.*--port $EMB_PORT"; then
      fuser -k "$EMB_PORT/tcp" >/dev/null 2>&1 || true
      echo "stopped embed server ($EMB_PORT)"
    else
      echo "nothing of ours on $EMB_PORT"
    fi
  }
  if our_proc "bin/metamining.*--port $PORT" \
    || our_proc "bin/metamining$"; then
    fuser -k "$PORT/tcp" >/dev/null 2>&1 || true
    echo "stopped metamining ($PORT)"
  else
    echo "nothing of ours on $PORT"
  fi
  exit 0
fi

if [ "$NOEMB" = "0" ]; then
  if [ ! -x tools/llama.cpp/llama-server ] || [ ! -s models/nomic-embed-text-v1.5.Q8_0.gguf ]; then
    echo "--- embed backend missing, installing first"
    ./embed-setup.sh || exit 1
  fi
  if curl -sf -m 3 "http://127.0.0.1:$EMB_PORT/health" >/dev/null 2>&1; then
    echo "--- reusing healthy embed server on $EMB_PORT"
  else
    if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":$EMB_PORT "; then
      echo "port $EMB_PORT is busy with something unhealthy - refusing" >&2
      exit 1
    fi
    echo "--- starting embed server on $EMB_PORT"
    setsid -f ./embed-setup.sh serve >>/tmp/embed.log 2>&1 < /dev/null
    ok=0
    for _ in $(seq 1 45); do
      sleep 2
      if curl -sf -m 3 "http://127.0.0.1:$EMB_PORT/health" >/dev/null 2>&1; then
        ok=1
        break
      fi
    done
    [ "$ok" = "1" ] || { echo "embed server failed to come up - see /tmp/embed.log" >&2; exit 1; }
  fi
  # Wire MetaMining to the embed server unless the user supplied their own.
  have() { for a in "${ARGS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
  have --embed-model || ARGS=(--embed-model nomic-embed-text-v1.5 "${ARGS[@]}")
  have --embed-endpoint || ARGS=(--embed-endpoint "http://127.0.0.1:$EMB_PORT/v1" "${ARGS[@]}")
  have --embed-doc-prefix || ARGS=(--embed-doc-prefix "search_document: " "${ARGS[@]}")
  have --embed-query-prefix || ARGS=(--embed-query-prefix "search_query: " "${ARGS[@]}")
fi

exec ./serve.sh --port "$PORT" "${ARGS[@]}"
