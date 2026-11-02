# MetaMining user manual

Companion to [concept.md](concept.md) (the big idea: what this is and why it
exists). This manual is the button-by-button guide to running expeditions.

**Conventions used here:** *sim backend* = deterministic local generator, free,
reproducible from the seed; *live backend* = Meta API models, billed, not
seed-reproducible. The dashboard always labels which one a run uses — header
badge, per-panel badges, and the completion banner.

## 1. Quickstart

### Start the server

```sh
cd /home/dev/MetaMining
./metamining.sh            # embed server + MetaMining on http://127.0.0.1:8000
```

Or run the binary directly with full control (see §12 for all flags):

```sh
META_API_KEY=... ./bin/metamining --host 0.0.0.0 --port 8000 \
  --endpoint https://api.meta.ai/v1 --model muse-spark-1.3
```

Open `http://127.0.0.1:8000/` in Chromium. You should see the header
(`MetaMining · latent claim survey · pure Mojo`), an `idle` run pill, and
three panels: **Expedition control** (left), **Claim map** (center),
**Threads and gold** (right).

### Your first expedition (sim, ~30 seconds, free)

1. In **Expedition control**, type a seed concept, e.g.
   `The relationship between truth and confabulation`.
2. Leave **Model**, **Endpoint**, **API key** blank — blank means sim backend.
3. Set **Steps** to `20`, leave everything else default.
4. Click **Start expedition**. The button switches to `Running` with a spinner
   and disables; the run pill shows progress with a countdown.
5. Watch the claim map fill in, threads advance, and gold (if any) appear in
   the right panel. When it finishes, a banner reports steps, findings, gold,
   time, tokens, and cost.

### Your first live expedition (billed)

1. Fill **Model** (e.g. `muse-spark-1.3` — the field autocompletes from
   `/v1/models`), **Endpoint** (`https://api.meta.ai/v1`), and **API key**
   (leave blank to use the server's `META_API_KEY`/`MODEL_API_KEY` env key).
2. Keep **Branches** small (2–4) and **Steps** small (10–20) the first time.
3. Click **Start expedition**. The header badge flips to `live backend`, and
   the API tile grid starts counting calls, flight time, tokens, and cost.
4. If the key is dead you'll get a fast explicit error toast instead of a
   hung run; if the network is ambiguous the run starts in a degraded mode and
   says so.

> **Rehearse in sim, spend in live.** Sim reproduces exactly from the seed;
> live does not (the endpoint takes no seed parameter), so treat every live
> run as a one-shot survey and save its journal.

## 2. The screen at a glance

- **Header**: brand, run pill (`idle` / `running N/M` with countdown /
  `paused` / `done`), backend badge (`sim backend` amber vs `live backend`
  green), **Guide** button (in-app field guide), **Archive** button (journal
  archive modal).
- **Completion banner** (hidden until a run ends): title, one-line digest
  (steps · findings · gold · seconds · tokens · cost), backend label, and a
  **Copy digest** button.
- **Left panel — Expedition control** (§3): start form, stop, live orders,
  target branch, auto-population, live tuning sliders, auto-tune, teleport,
  persona lens, per-branch model switch, run stats, journal download.
- **Center panel — Claim map** (§4): 2D/3D map, time scrubber, run diff,
  topology radar, API tiles, telemetry chart, search, expedition log.
- **Right panel — Threads and gold** (§5): per-thread status, gold veins,
  Pareto frontier, vein memory, run queue, genealogy tree.
- **Overlays**: finding-detail modal (click any map point or log entry),
  archive modal, guide modal, toast stack (bottom), selection-to-social popup.

## 3. Expedition control (left panel)

### Start form

| Field | Meaning | Default / blank |
|---|---|---|
| Seed concept | The starting idea the branches survey outward from | blank = server default ("The relationship between truth and confabulations") |
| Model | Live model id, autocompleted from the endpoint | blank = sim; live needs Model + Endpoint + key together — a partial set warns and runs sim |
| Models (per-branch) | Comma list assigning different models to branches, e.g. `muse-spark-1.3, muse-spark-1.3-contributor` (round-robins past the list end) | blank = all branches use Model |
| Endpoint | API base URL, e.g. `https://api.meta.ai/v1` | blank = sim |
| Embed model | Embeddings model id | blank = hash vectors (§9) |
| Embed endpoint | Base URL for `/v1/embeddings` | blank = chat endpoint (§9) |
| API key | Bearer [REDACTED] for the endpoint | blank = server env key |
| Server token | Password for *this dashboard's* server (`--auth-token`); saved in the browser, never sent to the model endpoint | blank = none (open server) |
| Seed | RNG seed — **used by sim runs only**; live ignores it | 7 |
| Branches | Parallel explorer threads, 1–16 | 4 |
| Steps | Max steps per branch before `max-steps` | 100 |
| Gold ≥ | Novelty bar for gold flagging (coherence must pass too) | blank = auto by backend (0.5 sim, 0.8 live); explicit always wins |
| Temp | Sampling temperature | 0.9 |
| Fanout | Beam width: candidates sampled per step; the best stays, strong runners-up fork into pursued branches, 1–8 (1 = best only, no forking) | 1 |
| Judges ⚖️ | Judge votes per step, median-blended, 1–5 (`sim` badge) | 1 |
| Repulse ⚖️ | Overused-term list cap pushed out of prompts, 0–40, 0 = off (`sim` badge) | 30 |
| Budget | Max API calls per branch; the branch stops with `budget` when hit | blank = keep last, 0 = unlimited |
| Auto-tune | Epsilon-greedy live tuning of temp/push during the run | off |

Fields with a `sim` badge only take effect on the sim backend. On page
load the form prefills every empty field from the server config, so what
you see is what **Start expedition** will run — one click, no typing.
Clear any field to restore its blank semantics from the table. Never
prefilled: Gold (blank = backend auto), API key / Server token (secrets),
per-branch Models, Auto-tune. While running, the button shows `Starting…`
then `Running` with an animated spinner and stays disabled until the run
ends, pauses, or errors. **Stop run** ends the run immediately (reason
`stopped`). **Demo run (SIM)** fills 10x-relaxed stops, a fresh seed,
and unlimited budget, then starts immediately — minutes of free action
that end on their own for videos and first looks. **Demo run (LIVE)**
fills a short
capped taste (2 branches × 5 steps, standard stops, 20-call budget) and
refuses without a model rather than guessing one; it bills real money.
Concept and embed wiring stay as shown under both. All start buttons
disable while a run is active.

**Advanced tuning** (collapsed by default) exposes the stop-rule knobs:
Push (topo push weight, 0–2), Plateau K (flat steps before `plateau`,
default 12), Plateau eps (improvement threshold, default 0.005), No-gold M
(steps before `dry`, default 25), Min coh (coherence floor on the 0–1 internal scale, default 0.25),
Coh C (bad steps before `incoherent`/`weeds`, default 6), Global stall
(run-wide no-gold findings before `global-weeds`, default 40). Blank keeps
the server default for each.

### Live orders

**Pause** freezes all branches mid-step; **Resume** continues (the run pill
shows `paused` while held). **Warp** force-backtracks the target branch(es)
to the Pareto frontier — useful when a thread is visibly circling. **Restart**
re-runs the expedition in place with the same configuration. **Target branch**
selects which branch warp/teleport/lens/tune apply to (`all branches` or
0–15); the auto-tune toggle honors it too (targeted bandit per branch).

**Boost & continue** raises the call budget mid-run *and* resumes branches
that already budgeted out: each revived branch continues as a new leg
(genealogy kind `continue`, parented to the dead branch) seeded at the dead
branch's best finding, keeping its model, lens, and temperature. Spent calls
carry over, so the budget stays a branch-total allowance — a branch that
spent 100 of a boosted 200 has 100 calls left, and branches still capped are
skipped with an explicit toast. If the run had ended, boosting resumes it in
place with findings, map, and frontier intact (unlike Restart, which wipes
them); the no-gold streak resets and the intermission is excluded from the
expedition clock. Honors **Target branch** (`all` or one bid); blank is
rejected so a stray click can't silently uncap spend.

### Auto-population, tuning, auto-tune

- **Auto-population** (on by default): spawns vein-miner branches at gold
  strikes and respawns cold branches, so compute follows paydirt.
- **Fanout pursue**: with Fanout > 1 each step samples that many
  candidates; the parent keeps the best and offers strong runners-up as new
  branches (genealogy kind `fanout`, seeded at the runner-up text, keeping
  the parent's model, lens, and temperature). Only healthy parents fork
  (plateau below half of Plateau K), only runners-up scoring ≥50% of the
  best and cosine-dissimilar (>0.92 dup bar) to siblings are offered, and
  the server caps growth at 24 live branches and 4 forks per tick — offers
  past the caps are counted as `spawn_skipped` in `/api/state`, never
  silently billed. Forked children appear in the tree like any branch, so a
  Fanout of 3 pursues roughly the top three routes per step. This
  multiplies coverage *and* cost (branches × steps × fanout), so raise it
  deliberately; the Tune slider adjusts it live mid-run.
- **Tune sliders** apply live, mid-run: Temp (0–2), Gold bar (0–1), Push
  (topological push weight, 0–2), Repulse (0–40, sim), Fanout (1–8),
  Judges (1–5, sim). Only the slider you drag is sent, so untouched
  bars (including auto) are never clobbered. Tune `gold` to −1 via the
  API to reset the default to auto (running workers get the resolved
  value for the current backend).
- **Auto-tune (live)** toggles the epsilon-greedy bandit mid-run; the
  per-worker arm readouts underneath show which temp/push arms are winning.

### Teleport, persona lens, branch model

- **Teleport to**: re-seeds the target branch at a new concept front
  mid-run ("a new front..."). The branch keeps its history; its future steps
  start from the new text.
- **Persona lens**: 16 built-in disciplinary lenses (mechanistic systems
  biology, nonlinear dynamics, information theory, persistent homology, …,
  biomimetic energy dynamics). **Switch lens** re-frames the target branch's
  prompting through that discipline — the cheapest way to force a stuck
  branch onto fresh ground.
- **Switch branch model**: live-switches one branch to another model id
  (blank = back to default). Use it to A/B models inside a single run.

### Run stats, journal download

**Run stats** refreshes on every finding/state event, morph-swapped in place
(steps, findings, gold, warps, stop
reason). **Download journal JSON** downloads the full expedition record at
any time, mid-run or after.

Saved journals self-describe their provenance at the root: `model`,
`endpoint`, `embed_model`, `embed_endpoint`, `vec_kind`, and `app_version`
(`sim`/`sim` for sim runs). The journals list surfaces model + endpoint
per file, and the
vein library carries a root `meta.models[]` naming every model@endpoint
pair that contributed veins, plus per-vein `model`/`endpoint`. Reloads
restore vecs (stored, or recomputed from text for legacy hash journals),
so shape views work on archived runs.

## 4. Claim map (center panel)

### Map, 2D/3D, trails

Each point is one finding, positioned by PCA projection of its vector and
colored by branch. **3D** toggles the 3D renderer; **Trails** toggles branch
trail lines. Click any point (or any log entry) to open the finding-detail
modal (§6). Hover shows a tooltip summary.

3D controls (visible in 3D mode): render style (**Shaded surface + path**,
**Cyber wireframe terrain**, **Iso-novelty manifold**, **3D scatter cloud**),
Z-axis metric (**Novelty**, **PCA-Z**, **Cohom dim**, **Coherence**), **Balls**,
**Gold**, and **Paths** layer toggles (all three off leaves the bare
topological surface; **Paths** mirrors the **Trails** button), camera
presets (**Iso / Top / Side / Front**), **Auto-orbit** toggle, **Reset**.
The HUD reports style · metric, value range, yaw, pitch, zoom, point count.
Drag to orbit, wheel to zoom.

### Scrubber, gold-only, replay

The time scrubber replays the expedition: drag it back to see the territory
as of any step, or press play/pause for an animated replay (`live` = present).
**Gold only** filters the map to gold strikes. Scrubbing never mutates the
run — it's a view over recorded history.

### Run diff

**Compare journal** overlays a saved journal on the live map (**Overlay**
checkbox): current-run points vs. the archived run's points in a contrast
color, with a legend reporting counts. Use it to answer "did this run cover
different ground than last night's?"

### Topology radar

Live Betti readout over the visited set, with the branch/step source of the
reading:

| Cell | Meaning | When to act |
|---|---|---|
| b0 | Connected components | many components = fragmented coverage |
| loops b1 | 1-cycles: repetition rings | rising = a branch is circling old ground (warp it, teleport it, or switch its lens) |
| voids b2 | 2-voids: unexplored chambers | high = push here (raise Push, teleport into the gap) |
| dim | Cohomological dimension | intrinsic complexity of the visited set |
| sheaf | Sheaf obstruction (trajectory curvature) | high = branches bending hard around something |
| entropy | Persistence entropy | spread of feature lifetimes; collapsing = converging |

Highlighted cells need attention; see the in-app Guide's card 3 for the
short version, and [topology.md](topology.md) for the full theory.

### Shape views

Six topological surfaces over the surveyed ground, computed on demand
(**Refresh**; views go `stale` as new findings land, **Live** re-computes
every 12 s). Five are server-computed; density is client-side:

| View | What it shows | How to read it |
|---|---|---|
| Merge tree | Novelty peaks joining downward as the level drops (gold rings = peaks) | each peak is a distinct paydirt hill; **Basin tint** recolors the map by which peak each point drains to; basin picker + **Teleport here** / **Corroborate peak** act on the selected hill |
| Barcode + Betti | Persistence barcode over vec-space distance (H0 teal, H1 amber, H2 violet; `∞` = never dies) plus b0/b1/b2-vs-scale curves | long H1 bars = real repetition rings, short ones = noise; **Metric** switches cosine/euclid; **Confidence** bolds resampling-stable bars |
| Loops + void | Loop member cycles at the median-distance scale, dashed ring for a void | closed polylines are branches circling the same ground — warp or teleport them; the void ring marks an unexplored chamber |
| Density + contours | Gaussian KDE heat + iso-contours (bandwidth 5 map units) | contour nests are over-dug ground; **Suggest probe** marks the next `P?` target (void or sparsest gap), **Probe it** teleports a branch there; also feeds **Z: Density** in 3D |
| Mapper graph | Mapper nerve over the novelty lens (node size = cluster size, color = lens) | flares and branches in the nerve are exploration fronts; **Bins**/**Overlap** reshape the cover (8/0.4 is a good default) |
| Timeline | b0/b1/b2 ribbons over cumulative run deciles | rising amber = loops forming; violet humps = voids opening then closing; complements the Betti strip |

Loops and contours also overlay the main map (toggleable); loops, void
ring, and basin peaks overlay the 3D view too. Every view has a data table
for screen readers. The barcode uses a 20-point stride window; the
map-space views use up to 400 points (stride-sampled, flagged `sampled`).
A `caps hit` note on the barcode means the tri/tet caps trimmed the
filtration — bars are then a sparsified approximation, still honest about
the big features. Construction details, reading guides, exact endpoint
schemas, and limits live in [topology.md](topology.md).

### Exporting research artifacts

The Shape panel's **Export** row downloads paper-ready artifacts for the
current run: **Bundle JSON** (manifest + journal + state + all six topo
surfaces + density parameters — the citable record of what shape was found),
**Findings CSV** (one row per finding for statistics and plots), **Map PNG**
and **Shape PNG** (figures), **Shape SVG** (vector figure of the current
view), and **Methods** (copies a pre-filled methods paragraph to the
clipboard). Filenames carry the run id and timestamp.
Research protocols built on these exports — frontier cartography,
corroboration, red-teaming archives, idea discovery, model comparison,
metric research, knowledge probing, teaching — are documented in
[research.md](research.md).

### API tiles

The run's metering choke, updated live (§10 for cost math):

| Tile | Meaning |
|---|---|
| calls | Responses calls this run |
| avg ms | Mean flight time per call |
| tok/s | Completion tokens per second of flight time |
| in / out | Input / output tokens billed |
| emb | Embedding calls |
| cost | Estimated spend, Meta list prices (`n/a` for unlisted models) |

### Telemetry, search, log

- **Telemetry**: amber = novelty, teal = coherence ÷ 10, dashed line = gold
  bar. Read it as the run's vital signs: novelty sagging toward the bar while
  coherence holds = plateau forming; both sagging = weeds ahead. While
  scrubbed back in time, a playhead line marks the replay position (it sweeps
  during replay). The **Betti history strip** below plots b0/b1/b2 per
  finding (teal/amber/violet) — the shape history as it lands.
- **Search**: full-text + hash-BOW cosine search over findings, vein memory,
  and loaded journals. Type, click **Search** (or Enter), pick a result to
  open it.
- **Expedition log**: every finding as it lands, newest-first, with branch,
  step, scores, and gold flags. **Search findings** filters by text/branch/
  step; **All / Gold / Loops** pills filter by class; **Load Journal JSONs**
  loads saved journals into the log view; the counter shows visible entries.

## 5. Threads and gold (right panel)

- **Threads**: one card per live branch — id, model, step, best scores, state
  (running / paused / stopped + reason). Refreshes on every finding/state
  event. A thread that stops early shows its stop reason (§7), not silence.
- **Gold veins**: every gold strike, newest first (same event-driven refresh;
  expanded insights stay open across refreshes). **Copy
  thread** copies all gold finds as one formatted thread for sharing.
- **Pareto frontier**: the non-dominated set — no other finding beats these
  on *both* novelty and coherence. This is the "best of run" list; start any
  review here.
- **Vein memory**: persistent cross-run memory of productive veins. Search
  (§4) consults it; future runs steer by it. The counter shows stored veins.
- **Run queue**: batch expeditions. Fill concept/model/branches/steps,
  **Enqueue run**; **Auto-start queue** chains runs back-to-back;
  **Clear queue** drops everything pending (with a confirmation step).
  Queued runs inherit the current endpoint/key configuration.
- **Genealogy**: the branch family tree — which branches spawned from which
  (auto-population spawns, vein-miners), and where each stopped. Read it to
  see whether gold came from the seed lineage or a transplant.

## 6. Modals, toasts, selection

- **Finding modal** (click a map point or log entry): full claim text,
  branch/step/scores/gold metrics, **Next** (the steering target the branch
  aimed at after this find), **Related veins** (nearest veins by vector
  similarity), **Copy raw** / **Copy social** (plain text vs. formatted
  share text), **Prev step / Next step** (walk the branch through time).
- **Archive modal** (**Archive** header button, or **Load Journal JSONs**):
  **Save run** writes the live expedition to the archive; the upload row
  brings a local journal JSON into the dashboard in **Replace** or **Merge**
  mode; the list shows archived sessions with load actions. Filenames carry
  the run's timestamp and concept slug. The server keeps the newest 100
  journals on disk and prunes the oldest past that (logged in the run log).
- **Guide modal** (**Guide** header button): the four-card field guide —
  branches, novelty/coherence, topology radar, frontier/sharing. The 60-second
  version of this manual's core loop.
- **Toasts** (bottom stack): every order, error, and completion announces
  itself explicitly and sticks around long enough to read. Errors say what
  failed and which backend was in play — no silent failures.
- **Selection popup**: select any text in the log or a modal and a
  **Copy selection for social** popup offers one-click formatted copying.

## 7. Stop reasons (glossary)

Per-branch stops (shown on thread cards and in the journal):

| Reason | Meaning | Typical response |
|---|---|---|
| `max-steps` | Step budget exhausted | normal ending; raise Steps for deeper surveys |
| `plateau` | Novelty flat for `plateau_k` steps | warp, teleport, new lens, or accept coverage |
| `dry` | No gold for `nogold_m` steps | lower the gold bar, or the vein is barren |
| `weeds` | Low coherence *and* half-plateau: lost *and* stuck | kill it (auto-population respawns); don't raise budget here |
| `incoherent` | Coherence below floor for `coh_c` steps | lower temp, switch model, or abandon the front |
| `budget` | Branch API call budget hit | **Boost & continue** to raise the cap and resume the branch (§3), or narrow fanout/judges |
| `converged` | Branch met its convergence test | success — it finished, not failed |
| `backend-error` | Endpoint call failed terminally | check key/endpoint/model; see §11 |
| `respawned` | Cold branch retired by auto-population and respawned fresh | normal hive churn, not a failure |
| `order-epipe` | Branch died while receiving an order (broken pipe) | retry; report with the journal if it repeats |
| `exit-N` / `signal-N` | Worker process died (exit code / signal) | report as a bug with the journal; sim never does this |

Run-level stops (run pill, banner, journal):

| Reason | Meaning |
|---|---|
| `global-weeds` | No gold anywhere for `global_stall` findings — the whole expedition is in the weeds |
| `stopped` | You clicked Stop (or the queue advanced) |
| `shutdown` | Server process is exiting (workers get ~5 s grace, then SIGKILL) |
| `complete` | All branches stopped with findings banked (dominant branch reason is recorded alongside) |
| `idle` / `running` / `paused` | Run states, not stops |

Design note: stopping is the product working, not failing. A run that ends
`dry` on every branch surveyed the reachable space and told you so — widen
the seed, add branches, or spend the budget elsewhere.

## 8. Sim vs live backends

| | Sim | Live |
|---|---|---|
| Trigger | Model **and** Endpoint blank | Both filled (key blank = env key) |
| Cost | Free | Billed per token (see §10) |
| Seed | **Used** — identical seed + config reproduces the run | **Ignored** — endpoint rejects `seed` with 400 unknown-parameter (verified live); every live run varies |
| Judges / Repulse sliders | Active | Marked `sim`, no effect |
| Speed | Instant (no network) | 15–60 s per finding typical |
| Stop reasons | Same rules, deterministic | Same rules, stochastic |

The preflight probe rejects dead keys fast (explicit 400-class error, no
hung run); genuinely ambiguous transport (proxy? captive portal?) starts the
run degraded and says so in the log rather than refusing. The header badge,
per-finding badges, and completion banner always state which backend produced
what you see.

## 9. Vectors, embeddings, and search quality

Positions on the map, novelty distances, related-veins, and search ranking
all derive from per-finding vectors. With **Embed model** blank these are
**hash-BOW vectors** (bag-of-words hashed into a fixed width): free, local,
good enough for coarse geometry, weak on paraphrase and semantics. Point
**Embed model** at a working embeddings backend and `/v1/embeddings`
supplies real vectors instead (counted in the `emb` tile). PCA, topology,
and search all adapt to the live vector width automatically.

### Local embeddings (recommended)

The stock Meta endpoint has no `/v1/embeddings` route (see recon below),
so MetaMining ships a one-command local backend — free, private, and fast
enough to embed every finding live:

```
./embed-setup.sh          # downloads llama.cpp + Nomic v1.5 Q8_0 (~160MB CPU)
./embed-setup.sh serve    # serves OpenAI-compatible /v1/embeddings on :8080
```

Then set **Embed model** to `nomic-embed-text-v1.5` and **Embed endpoint**
to `http://127.0.0.1:8080/v1` in the start form (or `--embed-model` /
`--embed-endpoint` on the CLI). The embed backend is independent of the
chat backend: sim chat plus local embeddings gives true semantic geometry
at zero API cost. Nomic instruction prefixes are configurable
(`--embed-doc-prefix "search_document: "`,
`--embed-query-prefix "search_query: "`, blank by default for backends
without them).

**GPU.** A working `nvidia-smi` makes `embed-setup.sh` fetch the CUDA
server build and `serve` offload all layers (`-ngl 99`): the 137M-param
model sits in ~1GB VRAM, so an 8GB card such as an RTX 4060 never notices
it while embedding at memory bandwidth. The driver must support CUDA
runtime 12.8+ (the `CUDA Version` in the `nvidia-smi` header — update
the NVIDIA driver if it reads lower; otherwise setup says so and uses
CPU). The CUDA fetch is the binary
tarball (~175MB) plus the CUDA runtime bundle (~566MB), skipped
automatically when the system already provides libcudart/libcublas — no
toolkit install needed either way. `EMBED_FLAVOR=cpu|cuda` overrides the
detection; switching flavors re-downloads the server build automatically.

Search follows the vectors: with embeddings live, queries run in embed
space (true semantic search, `space: "embed"` in the response); rows whose
stored vec dim does not match the query are skipped and counted in
`dim_skipped`, never silently rescored. If the embed backend dies mid-run,
workers fall back to hash vectors after 3 failures (sticky toast + log)
and search degrades to hash space — the run continues, labeled.

Saved journals record `embed_model` and `embed_endpoint` in the root head
next to `vec_kind`, so an archived run's vector space is reproducible.

### Embeddings recon (2026-10-31, live)

Probed with a valid key: `GET /v1/models` lists nine models (muse-wonder-1.0,
sam-3.1, muse-spark-1.3-contributor, muse-voice-transcribe-1.0,
muse-spark-1.3, muse-image-1.0, muse-spark-1.2-contributor, muse-spark-1.2,
muse-spark-1.1) — none embedding-capable. `POST /v1/embeddings` with
OpenAI-style `{"model","input"}` answers empty-body **404** for both a real
text-model id and a guessed embedding id: the route itself is absent, not
just the model. If it ever lands, the switch is config-only — clear
**Embed endpoint** so embeddings ride the chat endpoint again. Until you
configure any backend, treat every vec-space result as *lexical* topology
(see [topology.md](topology.md) §8).

## 10. Cost management

Cost = Σ per model (input tokens × input rate + output tokens × output rate),
metered at the single API-call choke so every tile agrees. Priced models
(Meta list, USD per 1M tokens):

| Model family | Input | Output |
|---|---|---|
| muse-spark | $1.25 | $4.25 |
| any id containing `contributor` (e.g. `muse-spark-1.3-contributor`) | $0.10 | $0.20 |
| muse-wonder-* | $4.00 | $20.00 |
| anything else | n/a (tokens still counted, cost shows `n/a`) | |

Prices go stale: drop a `pricing.json` next to the server to override them
without rebuilding. Shape: a JSON array of `{"model", "in", "out"}` rows
(USD per 1M tokens, exact model-id match wins over the built-ins):

```json
[{"model": "muse-spark-1.3", "in": 1.25, "out": 4.25}]
```

The server logs `pricing overrides: N models` at startup when the file
loads; a missing or broken file silently keeps the compiled table.

Budget hygiene: rehearse in sim; start live runs small (2–4 branches ×
10–20 steps); watch `avg ms` and `tok/s` — a sudden flight-time spike means
the endpoint is struggling, pause rather than burn; keep Fanout/Judges at 1
until the concept proves auriferous (Judges multiplies calls per step;
Fanout multiplies calls per step *and* forks pursued branches, so cost
grows as branches × steps × fanout); save
the journal so you never pay to re-survey the same ground. Worst-case call
volume is budget-capped server-side, but the cap is large — the dashboard
cost tile is your real budget control.

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Start does nothing / instant error toast | Dead API key (live) or no seed concept | Read the toast: it names the cause. Sim needs only a concept; live needs model + endpoint + working key |
| Start rejected: `unknown model 'X'` | Typo'd Model id (or Models entry) — the endpoint doesn't list it | Pick an id from the message's list (the GUI Model field autocompletes live ids). Error toasts stick until clicked, so the list stays visible |
| Run ends `backend-error`, 0 findings | Key rejected, wrong endpoint/model, or network blocked | Verify `GET /v1/models` with the key out-of-band; check proxy env (`no_proxy` must cover the endpoint); retry |
| Findings land but map is empty | All points filtered (gold-only on, scrubber back in time) or a render hiccup | Clear gold-only, drag scrubber to `live`, toggle Trails/3D |
| Threads show `weeds`/`incoherent` early (live) | Temp too high for the concept, or a weak model | Lower Temp live, Switch-lens the branch, or Switch-branch-model |
| Run feels hung, no new findings for minutes | Endpoint slow (see `avg ms`) or all branches plateaued pre-stop | Wait one `avg ms` × branches beat; else Pause, inspect telemetry, Warp/Teleport, or Stop. A truly unreachable endpoint fails fast instead: connects time out after 10 s, each attempt lands in the log (`worker N status: ...`), and the run ends `backend-error` after retries — if you see none of that, the endpoint is answering slowly, not dead |
| `global-weeds` on a concept you believe in | Gold bar too high or coherence floor too strict for the domain | Lower Gold live (applies to future flags, not retroactively), widen the seed, re-run |
| Queue won't advance | Auto-start off, or a run still `running`/`paused` | Enable Auto-start; Stop/Resume the blocking run |
| Journal upload does nothing | Not a MetaMining journal JSON, or Merge with incompatible schema | Check the toast; try Replace mode; download a fresh journal to see the schema |
| Server won't bind / port busy | Stale `metamining` process on 8000 | `./metamining.sh stop`, then start again; the launcher refuses foreign ports, never blanket-kills |
| Page loads but no live updates | SSE stream blocked (proxy buffering `/events`) | Bypass the proxy for localhost; the 12 s HTMX fallback poll still updates even if SSE stalls, and the freshness labels will show the staleness |
| Everything 401s / "Server needs its auth token" | Server was started with `--auth-token` | Enter the token in **Server token** (saved in the browser); API calls retry with it automatically |

## 12. CLI reference

`metamining [options]` — every GUI start-field has a CLI twin for headless runs:

```
--host H        bind host (default 127.0.0.1)
--port N        bind port (default 8000)
--web DIR       web assets dir (default web)
--endpoint URL  model API base, e.g. https://api.meta.ai/v1
                (empty = deterministic sim backend)
--model M       model id for /v1/responses
--embed-model M embeddings model id (blank = hash vectors)
--embed-endpoint URL embeddings base, e.g. http://127.0.0.1:8080/v1
                (blank = chat endpoint; see ./embed-setup.sh)
--embed-doc-prefix S prefix for finding texts (nomic: "search_document: ")
--embed-query-prefix S prefix for search queries (nomic: "search_query: ")
--api-key K     Bearer [REDACTED] (or META_API_KEY / MODEL_API_KEY env)
--concept "..." seed concept for the expedition
--seed N        run seed (default 7)
--branches N    worker branches, 1-16 (default 4)
--steps N       max steps per branch (default 100)
--gold F        novelty threshold for gold (default auto: 0.5 sim, 0.8 live; -1 = auto)
--temp F        sampling temperature (default 0.9)
--repulse N     repulse word cap, 0-40 (default 30, 0 = off)
--fanout N      candidates per step, 1-8 (default 1)
--judges N      judge votes at gold, 1-5 (default 1)
--auto N        bandit auto-tune temp/push, 0|1 (default 0)
--push F        topo push strength, 0-2 (default 0.9)
--models S      comma-separated per-branch models (blank = default)
--call-budget N max API calls per branch, 0 = unlimited (default 0)
--auth-token T  require token for /api/*, /frag/*, /events (default open)
--self-test     run the loopback end-to-end suite and exit
--help          this text
```

CLI flags set the server defaults. Blank-field semantics on `start`: blank
numerics, concept, and key **inherit** the server default (so `--seed 42
--steps 200` pre-fills GUI runs that leave those fields blank); blank
Model / Endpoint / Embed model **clear to empty** (= sim backend) — the GUI
form always sends its fields, so "blank = sim" wins over any CLI default
for those three. JSON API clients that *omit* a field inherit the server
default for every field. `./test.sh` runs the full gate (12 suites +
self-test E2E); `./build.sh` rebuilds; `./run.sh` serves foreground;
`./metamining.sh` starts everything detached (embed server + app).

## 13. HTTP API reference (for scripts)

Reads (GET): `/api/state` (run state + live flag + API totals),
`/api/findings`, `/api/journal` (+ `/api/journal_file`, `/api/journals`),
`/api/models` (endpoint model list), `/api/log`, `/api/veins`, `/api/queue`,
`/api/search?q=`, `/api/tree` (genealogy), `/api/related`, `/api/step`,
`/api/topo_merge`, `/api/topo_bars?metric=`, `/api/topo_conf?metric=`,
`/api/topo_loops?max=`, `/api/topo_mapper?bins=&overlap=`, `/api/topo_time`,
`/events` (SSE stream),
`/frag/stats`, `/frag/threads`, `/frag/gold` (HTMX fragments). Writes (POST `/api/control`, form or JSON `action`):
`start stop pause resume warp restart teleport persona tune boost autopop
setmodel auto enqueue autoque clearqueue save` (`boost` takes
`call_budget` plus optional `bid`). JSON example with the advanced knobs:

```json
{"action":"start","concept":"...","branches":4,"steps":100,
 "push":1.2,"plateau_k":5,"plateau_eps":0.01,"nogold_m":9,
 "min_coh":0.3,"coh_c":3,"global_stall":11,"call_budget":200}
```

Missing/blank fields inherit the server default (which is the previous
run's config — including `call_budget`, so reset it explicitly when
scripting runs back-to-back). With `--auth-token` set, send
`X-MM-Token: ...` (or `?token=...` for `/events`). See
`src/metamining/server.mojo` (`route_*`) for exact shapes — the GUI in
`web/app.js` is the reference client.

## 14. Accessibility and display notes

- Shortcuts: `p` toggles pause/resume mid-run, `/` focuses the feed search.
  Both are ignored while typing or while a modal is open. Every control is
  also a real button/input and tab-reachable; tooltips (`data-tip`) explain
  jargon in place. Open modals trap Tab (Shift+Tab cycles back) and close
  on Esc, returning focus to the opener.
- `prefers-reduced-motion` is respected: spinner, scan sweep, ping rings,
  feed entrances, and toast animations all disable, leaving instant state
  changes.
- Layout is responsive: panels stack on narrow viewports; the map canvas
  fills its card; 3D auto-orbit pauses while you drag.
- Motion (scan sweep ~25 fps, ping rings) runs only while a run is active or
  pings are alive — idle dashboard is static and cheap.

## 15. Security

- The server is **open by default**: anyone who can reach the port can drive
  runs on your configured key. Bind `127.0.0.1` (the default) unless you
  need LAN access.
- `--auth-token T` gates every `/api/*`, `/frag/*`, `/events`, and `/mcp`
  route (the dashboard shell stays public so the token field is
  reachable).
  Enter the token in **Server token** — it persists in the browser's
  localStorage and is sent as the `X-MM-Token` header (`?token=` for the
  SSE stream, which cannot set headers). Wrong/missing token answers 401
  with an explicit toast pointing at the field.
- Tokens and API keys travel in cleartext HTTP: fine on loopback, not on
  hostile networks. The SSE token also sits in the stream URL (visible in
  browser history). There is no TLS listener and no rate limiting — put a
  reverse proxy in front if you expose this beyond localhost.

### Shared-lab checklist

- Run one instance per researcher (separate working directories — `journals/`
  and `veins/` are directory-local state, and vein memory steers novelty).
- Bind the lab interface explicitly (`--host 10.x.y.z`), set a long
  `--auth-token`, and terminate TLS at a reverse proxy (caddy/nginx) with
  basic auth or client certs in front.
- Never bake `META_API_KEY` into shared shell profiles; pass `--api-key`
  per invocation or per-user env files with `0600` permissions.
- Treat exported bundles as lab data: they contain full claim texts and
  API spend — store with the paper, not in chat.

## 16. MCP server (drive MetaMining from an assistant)

The running server is a **Model Context Protocol** server (Streamable
HTTP, spec 2025-06-18, tools-only) at `POST /mcp`. Any MCP client —
Claude Code, Codex, custom agents — can start expeditions, poll status,
search claims, pull topology, and manage journals. No extra process:
start the server normally and point the client at it.

Claude Code:

```bash
Muse mcp add --transport http metamining http://127.0.0.1:8000/mcp
```

Raw client config (`mcpServers` block):

```json
{ "metamining": { "url": "http://127.0.0.1:8000/mcp" } }
```

With `--auth-token T`, add the header `"headers": {"X-MM-Token": "T"}`.
Tools (see `tools/list` for schemas):

| Tool | Does |
| ---- | ---- |
| `start_expedition` | Start a run (same fields as the web form; sim free, live billed); returns immediately |
| `expedition_status` | Running flag, counts, stop reason, backend, API totals — poll while active |
| `get_findings` | Findings window (`since`/`limit`/`gold_only`) |
| `search_claims` | Vector search over findings, veins, journals |
| `stop_expedition` | Stop now (safe when idle) |
| `list_journals` / `get_journal` | Archive listing / one journal with vectors |
| `save_journal` / `load_journal` | Persist live run / load archive into memory |
| `get_topology` | `merge`/`bars`/`conf`/`loops`/`mapper`/`time` surfaces |
| `list_models` | Live model ids (empty in sim) |

Protocol notes: single-message JSON responses (no SSE fan-out — the
server never initiates); `GET /mcp` holds a stream for clients that
insist on one; `DELETE /mcp` answers 204; session ids are issued but
never enforced; browser `Origin` headers must be loopback or match
`Host`. No resources/prompts in v1 — everything is a tool.

