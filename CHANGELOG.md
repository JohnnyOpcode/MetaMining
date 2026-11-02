# Changelog

All notable changes to MetaMining, in Keep-a-Changelog format.
The live version is `0.9.0` (`./bin/metamining --version`).

## [Unreleased]

### Added

- Local embedding backend: `./embed-setup.sh` downloads llama.cpp plus the
  Nomic v1.5 Q8_0 GGUF and `./embed-setup.sh serve` runs
  OpenAI-compatible `/v1/embeddings` on 127.0.0.1:8080. NVIDIA GPUs are
  auto-detected (CUDA server build, full layer offload, ~1GB VRAM);
  `EMBED_FLAVOR=cpu|cuda` overrides. Setup now checks the driver's max
  CUDA runtime and uses CPU with an explanatory warning when it is
  below 12.8 (a too-old driver would otherwise serve on CPU silently).
- `--embed-endpoint` (and start-form **Embed endpoint**): embeddings ride a
  dedicated base URL instead of the chat endpoint; blank keeps the old
  behavior. `--embed-doc-prefix` / `--embed-query-prefix` set nomic-style
  instruction prefixes (blank by default).
- The embed backend is independent of the chat backend: sim chat with local
  embeddings yields true semantic vectors at zero API cost, and workers
  fall back to hash vectors (labeled) when the backend is unreachable.
- Semantic search: with embeddings live, `/api/search` embeds the query and
  compares in embed space (`space: "embed"`), skipping dim-mismatched rows
  via a reported `dim_skipped` count instead of silently rescoring them; journal
  entries reuse their persisted vecs. Embed failure degrades to hash space.
- Journal heads record `embed_endpoint` next to `embed_model`; `/api/state`
  config echoes it too.
- `./metamining.sh`: one command starts the embed server and MetaMining wired to
  it (`stop` stops both, `--no-embed` runs hash-only).
- One-click starts: the start form prefills empty fields from the server
  config on page load (concept, numbers, embed wiring); Gold, secrets,
  per-branch models, and Auto-tune are never prefilled.
- **Demo run (SIM)** / **Demo run (LIVE)** buttons: SIM fills 10x-relaxed
  stops, a fresh seed, and unlimited budget for minutes of free action
  that end on their own (max stops + fanout measured as runaway);
  LIVE fills a short capped taste (2×5, standard stops, 20-call budget)
  and refuses without a model. Both disable while a run is active.
- Fixed 3D Z-metric gaps for Density: axis label, tick row, and HUD combo
  now update on switch, and the plot computes its own KDE heights on
  demand (cached) instead of silently plotting novelty.
- API panel honesty: `Cache-Control: no-store` on every response (stale
  app.js or frozen state polls are now impossible), and a `sim` badge on
  the API header so sim zeros read as sim, not as broken.
- Partial live config (Model/Endpoint/key/models set without all three)
  now warns at start — toast plus a log line naming the missing fields —
  instead of silently running sim.
- MCP server (Streamable HTTP at `/mcp`, spec 2025-06-18, tools-only):
  11 tools covering expeditions, findings, search, topology, journals,
  and models. Verified against the official MCP SDK; `tests/test_mcp.mojo`
  plus self-test e2e checks; see manual §16.
- `docs/mcp.md`: full MCP interface doc — setup, agent concepts, per-tool
  argument/return reference, five guided examples (first contact, free
  sim survey, capped live survey, search + topology, archive
  archaeology), protocol/error notes, and troubleshooting.
- `docs/dev-setup.md`: contributor setup — toolchain (`mojo==1.2.0` via
  pip, `libssl3`), build/test/serve scripts, repo layout, conventions.
- Manual §17 housekeeping: every retention cap (journals, veins,
  findings, log, queue, complexes, client), safe-delete rules, fresh
  start, and the Windows-side `Backup-MetaMining.ps1` backup.
- Doc fixes: README Docs index lists `mcp.md`/`dev-setup.md`, Tests
  count corrected to 13 suites, `CITATION.cff` gains `repository-code`.
- Zero-toolchain paths: `Dockerfile` (Ubuntu + pip Mojo 1.2 + libssl3,
  builds and serves on 8000), `.github/workflows/gate.yml` CI running
  `./test.sh`, actionable `mojo not found` guards in `build.sh` /
  `test.sh`, and a prerequisites box in the quickstart.
- Portable release bundle: binary + Mojo runtime libs + `web/` + launcher
  (`metamining-0.9.0-linux-x86_64.tar.gz`, boots standalone, verified
  with a sim smoke run).
- `compose.yml` + `Dockerfile.embed`: app with a local llama.cpp
  embedding sidecar (Nomic Q8_0), pre-wired; `EMBED_HOST` support in
  `embed-setup.sh` for container networking.
- `docs/images/social-preview.png`: 1280x640 repo card (upload in About).

## [0.9.0] - 2026-10-31

First public release: pure-Mojo latent space explorer with a topological
shape laboratory and one-click research export.

### Added

- Parallel-branch expeditions (forked workers) with persona lenses, seed
  chaining, repulsion, LLM judges, quantum warp, per-thread stops
  (plateau, dry, incoherent, weeds, converged, budget) and a
  global-weeds stop.
- Hive coordination: shared memory, vein-miner spawns at gold strikes,
  cold-branch respawns, vein lock, run queue with auto-advance.
- HTMX dashboard: 2D/3D claim map with trails, density heat, time
  scrubber, branch filters, gold-only mode, run diff, telemetry, search,
  queue/tree/veins panels, live orders (pause, warp, teleport, persona,
  tune, auto-tune, per-branch models, fanout).
- Vietoris-Rips topology engine: exact Betti numbers, persistence
  barcodes, merge trees, Mapper, curvature, persistence entropy.
- Six Shape views: merge tree + basins, barcode + Betti curves,
  loops + void, density + contours, Mapper graph, run timeline —
  with resampling confidence, cosine/euclid metrics, 2D/3D overlays,
  data tables, and live-follow.
- Close-loop actions: basin teleport, one-click corroborate, probe-next
  suggestions.
- Research export: bundle JSON (manifest + journal + state + all six
  surfaces), findings CSV, map/shape PNG, shape SVG, methods paragraph.
- Provenance: journals and veins self-describe model/endpoint/vec_kind/
  app_version; vecs persist and reload (legacy hash journals recompute
  from text); Betti history strip.
- Version flag, CITATION.cff, `data/benchmarks/` seeded reference runs,
  full docs (concept, quickstart, tutorial, manual, topology, research).
- Test gate: 12 suites + loopback E2E self-test (154 checks), including
  structural web tests (controls wired, fetches routed).

### Known limits

- No embeddings endpoint upstream (`/v1/embeddings` 404s; re-verified
  live 2026-10-31), so vec-space geometry is lexical (hash-BOW) until
  Meta ships the route. The switch is config-only when it lands.
- Live runs are nondeterministic; sim reproduces byte-exactly from the
  same seed *and* vein state.
- Server is open by default (loopback); use `--auth-token` + a TLS proxy
  for shared labs. See manual §15.
