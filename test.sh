#!/usr/bin/env bash
# Full MetaMining gate: unit suites + loopback end-to-end self-test.
# Live-network suites honor META_OFFLINE=1 (TLS handshake test skips).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PWD/.venv/bin:$PATH"
pick() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
SSL=$(pick /lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3) \
  || { echo "libssl.so.3 not found" >&2; exit 1; }
CRY=$(pick /lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3) \
  || { echo "libcrypto.so.3 not found" >&2; exit 1; }
for t in tests/test_libc.mojo tests/test_json.mojo tests/test_tls.mojo \
         tests/test_http.mojo tests/test_explorer.mojo tests/test_endpoint.mojo \
         tests/test_linalg.mojo tests/test_topo.mojo tests/test_scoring.mojo \
         tests/test_steering.mojo tests/test_worker.mojo \
         tests/test_web.mojo tests/test_mcp.mojo; do
  echo "=== $t ==="
  mojo run -Xlinker "$SSL" -Xlinker "$CRY" -I src "$t"
done
echo "=== self-test (JIT) ==="
mojo run -Xlinker "$SSL" -Xlinker "$CRY" -I src src/main.mojo --self-test
