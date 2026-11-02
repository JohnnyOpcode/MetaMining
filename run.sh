#!/usr/bin/env bash
# Run MetaMining (builds first if needed). Pass-through args, e.g.:
#   ./run.sh --concept "lattice memory" --branches 8
#   ./run.sh --endpoint https://api.meta.ai/v1 --model muse-spark
set -euo pipefail
cd "$(dirname "$0")"
# Rebuild when sources are newer than the binary: never serve stale code
# after an edit. (web/ is read from disk at runtime, so it needs no rebuild.)
if [ ! -x bin/metamining ] || [ -n "$(find src build.sh -newer bin/metamining -print -quit 2>/dev/null)" ]; then
  ./build.sh
fi
exec bin/metamining "$@"
