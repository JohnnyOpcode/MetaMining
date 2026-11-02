# MetaMining contributor setup

From a fresh clone to a green gate. Users who only run the app need
just [quickstart.md](quickstart.md); this page is for building,
testing, and changing code.

## Prerequisites

- Linux x86_64 (bare metal or WSL2).
- Python 3.10+ with `venv` (3.12 used here).
- OpenSSL 3 runtime: `libssl.so.3` + `libcrypto.so.3`
  (Debian/Ubuntu: `sudo apt install libssl3`). Both `build.sh` and
  `test.sh` fail fast with `libssl.so.3 not found` without it.
- A few GB free if you run `./embed-setup.sh` (llama.cpp server +
  GGUF weights); the core build needs only tens of MB.

## Setup

```bash
git clone https://github.com/JohnnyOpcode/MetaMining
cd MetaMining
python3 -m venv .venv
.venv/bin/pip install "mojo==1.2.0"   # the tested toolchain
./build.sh    # -> bin/metamining
./test.sh     # 13 suites + self-test, a few minutes
```

Notes:

- The repo pins nothing itself — `.venv/` is git-ignored, so the
  `mojo==1.2.0` pin above is this checkout's tested version, not a
  lockfile. Newer Mojo may work; if the gate breaks on a newer
  toolchain, that pin is the known-good one.
- Every script exports `.venv/bin` onto `PATH`, so plain `./test.sh`
  finds `mojo` with no activation step.
- Browser probes (`/tmp/*probe.py` during development) additionally
  want `.venv/bin/pip install playwright` plus a Playwright
  Chromium (`PLAYWRIGHT_BROWSERS_PATH=/tmp/mspw ... -m playwright
  install chromium`). Not needed for the gate.
- `MODULAR_CACHE_DIR` warnings (read-only home/cache) are harmless;
  point the variable at a writable dir to silence them.

## Scripts

| Script | Does |
| ------ | ---- |
| `./build.sh` | `mojo build` → `bin/metamining` (links system libssl) |
| `./test.sh` | Full gate: 13 `mojo run` suites + `--self-test` e2e |
| `./run.sh` | Rebuild-if-stale, then run the binary in the foreground (args pass through) |
| `./serve.sh` | Detached server + health proof (`--port N` supported) |
| `./metamining.sh` | Full stack: embed server + MetaMining; `stop`, `--no-embed` |
| `./embed-setup.sh` | Download llama.cpp + Nomic Q8_0 GGUF; `serve` runs `:8080` |

`web/` is read from disk at runtime — dashboard edits need no
rebuild, but the binary only rebuilds at startup, so restart the
server after touching `src/` or `tests/`.

## Layout for developers

```text
src/main.mojo            CLI entry, flags, --self-test e2e
src/metamining/libc.mojo   sockets, processes, files (FFI, no stdlib net)
src/metamining/json.mojo   JSON parser/renderer (no dependency)
src/metamining/tls.mojo    TLS 1.3 client over system OpenSSL
src/metamining/http.mojo   HTTP server + client primitives
src/metamining/endpoint.mojo  Meta Responses/chat/embed calls
src/metamining/explorer.mojo  expedition math (KDE, entropy, stops)
src/metamining/linalg.mojo    PCA + vector ops
src/metamining/topo.mojo      Vietoris-Rips, Mapper, merge tree
src/metamining/scoring.mojo   novelty x coherence, Pareto, judges
src/metamining/steering.mojo  warp/teleport/push, vein lock
src/metamining/sim.mojo       deterministic sim backend
src/metamining/worker.mojo    forked branch workers, journals, veins
src/metamining/server.mojo    routes, SSE, control, MCP dispatch
src/metamining/mcp.mojo       MCP JSON-RPC helpers + tool catalog
tests/test_*.mojo        one suite per module (run via ./test.sh)
web/                     dashboard: index.html + app.js + app.css
data/benchmarks/         seeded reference journals + signatures
```

Housekeeping state (git-ignored, directory-local): `journals/`,
`veins/`, `bin/`, `.venv/`, `tools/`, `models/`. See manual §17
before deleting any of it.

## Conventions

- **Pure Mojo in the product.** HTTP, JSON, TLS client, PCA,
  topology — all Mojo; only libc and system OpenSSL via FFI. Python
  appears solely as `/tmp` throwaway tooling, never in the repo.
- **Gate before done.** `./test.sh` must exit 0 after any `src/`,
  `tests/`, or `web/` change. Focused runs look like
  `mojo run -Xlinker <ssl> -Xlinker <cry> -I src tests/test_web.mojo`
  (see `test.sh` for the exact flags); `META_OFFLINE=1` skips the
  live-TLS probe.
- **Tests live with the code.** Bug fixes add or extend the matching
  `tests/test_*.mojo` suite first (fail observed, then fixed);
  `tests/test_web.mojo` covers the dashboard statically
  (id cross-references, route wiring).
- **Behavior changes update docs.** User-visible changes land in
  `docs/manual.md` (or the topical doc), `README.md` where it
  summarizes, and `CHANGELOG.md` under `[Unreleased]`.
