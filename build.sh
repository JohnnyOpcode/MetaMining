#!/usr/bin/env bash
# Build the MetaMining binary (pure Mojo + system libssl for TLS).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PWD/.venv/bin:$PATH"
command -v mojo >/dev/null 2>&1 \
  || { echo "mojo not found: set up the toolchain first (docs/dev-setup.md):" >&2;
       echo '  python3 -m venv .venv && .venv/bin/pip install "mojo==1.2.0"' >&2; exit 1; }
pick() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
SSL=$(pick /lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3) \
  || { echo "libssl.so.3 not found" >&2; exit 1; }
CRY=$(pick /lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3) \
  || { echo "libcrypto.so.3 not found" >&2; exit 1; }
mkdir -p bin
mojo build -Xlinker "$SSL" -Xlinker "$CRY" -I src src/main.mojo -o bin/metamining
echo "built bin/metamining"
