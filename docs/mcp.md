# MetaMining MCP interface

Drive MetaMining from an AI assistant. The running server is a **Model
Context Protocol** server (Streamable HTTP, spec 2025-06-18, tools-only)
at `POST /mcp` — no extra process, no extra port. Point any MCP client
at it and the assistant can start expeditions, poll status, read
findings, search claims, pull topology, and manage journals.

The MCP surface and the dashboard share one server and one run: an
assistant can drive while you watch the claim map update live in the
browser (or vice versa).

## Setup

Start the server normally:

```bash
./metamining.sh          # full stack, or:
./serve.sh --port 8000   # server only
```

Attach from Claude Code:

```bash
Muse mcp add --transport http metamining http://127.0.0.1:8000/mcp
```

Raw client config (`mcpServers` block, Codex and others):

```json
{ "metamining": { "url": "http://127.0.0.1:8000/mcp" } }
```

If the server runs with `--auth-token T`, every `/mcp` call needs the
header (else HTTP 401 `{"error":"auth required"}`):

```json
{ "metamining": {
    "url": "http://127.0.0.1:8000/mcp",
    "headers": { "X-MM-Token": "T" }
} }
```

Verify with curl (no MCP client needed):

```bash
curl -s http://127.0.0.1:8000/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | head -c 300
```

## Concepts an agent needs

Five facts cover 90% of correct usage:

1. **One run at a time.** Starting an expedition kills the previous
   run's workers and supersedes it. There is no queue over MCP —
   `stop_expedition` first if you want a clean stop reason.
2. **Sim vs live is a three-key lock.** A run is live only when
   `endpoint` + `model` + `api_key` are ALL set (a blank `api_key`
   falls back to the server's key). Any subset bills nothing and runs
   the free deterministic sim — and the server says so out loud
   (`Expedition started (sim; live config incomplete)` plus a log
   line naming the missing pieces). Never assume a run is live:
   the reply tags it `(run N, sim|live)`.
3. **`concept` is required.** Every start needs a seed concept (a
   repeat start without one reuses the previous run's).
4. **Start returns immediately; poll for the rest.**
   `start_expedition` answers in milliseconds. Poll
   `expedition_status` until `running` is false, then read findings.
   Sim runs finish in tens of seconds; live points take
   ~15–60 s each and fanout multiplies that.
5. **Stops are shared with the dashboard.** Budgets, plateau / dry /
   weeds detectors, and `call_budget` behave exactly as in the manual
   (§7); `stop_reason` tells you which one fired.

What MCP cannot do in v1: live orders (pause, resume, warp, teleport,
lens, tune, boost) are dashboard-only, and there are no
resources/prompts/sampling — everything is a tool.

## Tool reference

All tools answer with one text block containing JSON (or a short
message). Tool-level failures come back as `isError` results, never
bare HTTP 500s, so the JSON-RPC envelope always survives.

### start_expedition

Start a run. Same field names, ranges, and defaults as the web start
form (manual §3); all optional except `concept`:

| Field | Meaning |
| ----- | ------- |
| `concept` | Seed concept (**required** unless carried over) |
| `model` / `models` | Live model id / comma-separated per-branch ids (blank = sim) |
| `endpoint` | Model API base, e.g. `https://api.meta.ai/v1` (blank = sim) |
| `api_key` | Bearer [REDACTED] blank = server key) |
| `embed_model` / `embed_endpoint` | Embedding backend (blank = hash vectors) |
| `seed` | Run seed (sim only; live ignores it) |
| `branches` / `steps` / `fanout` / `judges` | 1–16 / 1–5000 / 1–8 / 1–5 |
| `gold` / `temp` / `repulse` / `push` | 0–1 (auto: 0.5 sim, 0.8 live) / 0–2 / 0–40 / 0–2 |
| `call_budget` | Max calls per branch, 0 = unlimited |
| `plateau_k` / `plateau_eps` / `nogold_m` | Plateau / dry-run stops |
| `min_coh` / `coh_c` / `global_stall` | Coherence floor / count / whole-run stall stop |

Reply: `Expedition started (live|sim[; live config incomplete])
(run N, live|sim).`

### expedition_status

No arguments. The full run state: `run`, `running`, `stop_reason`,
`findings` / `gold` counts, `streak` (steps since gold), `paused`,
`run_secs`, `live`, `auto_pop`, spawn counters, the effective `cfg`,
per-branch `workers` (step, best, reason, temp, …), the `topo` radar
(b0/b1/b2, cd, sheaf, entropy), and `api` totals (`calls`, `ecalls`,
`ms`, `ems`, `tok_in`, `tok_out`, `cost`, `cost_ok`). Poll this.

### get_findings

Claim window. `since` (default 0) is an absolute findings index,
`limit` (default 500, clamped 1–2000) bounds the window,
`gold_only` filters to gold. Reply: `{"t":"findings","next":TOTAL,
"items":[...]}` where `next` is the total — page with
`since = previous since + len(items)`. Memory keeps the newest 8000
findings; `next` stays an absolute total and a stale `since` clamps
to the oldest retained row.

Each item carries `branch`, `step`, `novelty`, `coherence`, `x`/`y`/`z`
(PCA map coords), `gold`, full `text`, topology (`b0`, `b1`, `b2`,
`cd`), `persona`, `temp`, `loc`, and `src`.

### search_claims

Vector search over live findings, the vein library, and the 20 newest
journals. `q` (**required**), `limit` (default 20, clamped 1–50).
Reply: `{"items":[{branch, step, text, novelty, coherence, gold, src,
score}], "skipped":N, "space":"embed"|"hash", "dim_skipped":N}`.

`space` names what actually ran: `embed` is true semantic search
(works in sim too with a local embed endpoint); `hash` is lexical
overlap only — paraphrases score low there.

### stop_expedition

No arguments. Stops now (reason `stopped`). Safe when idle.

### list_journals / get_journal

`list_journals` (no arguments) lists saved journals newest-first with
concept, model, endpoint, size, and step counts. `get_journal`
(`filename`, **required**) returns one journal with provenance and
entry vectors — large runs return large payloads, so slice
client-side.

### save_journal / load_journal

`save_journal` (no arguments) persists the live findings and flushes
veins; replies `Saved <filename>`. `load_journal` loads an archive
into memory so search and shape views cover old runs: pass `filename`
or inline `custom_json`, with `mode` `replace` (default) or `merge`.

### get_topology

Topological surfaces over the finding cloud. `surface` (**required**):
`merge` (tree + basins), `bars` (barcode + Betti), `conf`
(resampling confidence), `loops` (H1 rings + void), `mapper` (nerve
graph), `time` (run timeline). `metric` defaults to `cosine`
(`cosine`|`euclid`, applies to `bars`/`conf`); `loops` takes
`max_loops` (default 6); `mapper` takes `bins` (default 8) and
`overlap` (default 0.4).

### list_models

No arguments. Model ids the live endpoint offers (for the `model`
field). Empty in sim.

## Guided examples

Each example shows the tool calls and what to look at. Prompts are
suggestions — any wording that names the goal works.

### 1. First contact (free, 30 seconds)

> "Check the MetaMining server: list its tools and tell me whether a
> run is active."

The assistant calls `tools/list` (via the client), then
`expedition_status`. If `running` is true, the `cfg` block says what
is running and `api.cost` says what it has spent so far. Raw curl
equivalent:

```bash
curl -s http://127.0.0.1:8000/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"expedition_status","arguments":{}}}'
```

### 2. Free sim survey, then read the gold

> "Run a small sim survey on 'why do coral reefs bleach' — 2 branches,
> 8 steps — wait for it to finish, then show me the gold findings."

1. `start_expedition` with
   `{"concept": "why do coral reefs bleach", "branches": 2,
   "steps": 8}`. No model/endpoint/key → sim, free. Reply tags
   `(run N, sim)`.
2. Poll `expedition_status` every few seconds until `running` is
   false. Note `stop_reason` (`steps` here) and the counts.
3. `get_findings` with `{"gold_only": true, "limit": 50}`. Each gold
   item has the full claim `text` plus novelty/coherence scores.
4. (Optional) `save_journal` to keep the run; the reply names the
   file for later (`list_journals`).

Sim is deterministic per seed: re-running the same concept + seed
reproduces the survey.

### 3. Capped live survey (billed)

> "Survey 'solid-state battery failure modes' live on muse-spark,
> max 20 calls, and stop early if it stalls."

1. `list_models` first if unsure of the model id.
2. `start_expedition` with `{"concept": "solid-state battery
   failure modes", "model": "muse-spark-1.2", "endpoint":
   "https://api.meta.ai/v1", "branches": 2, "steps": 5,
   "call_budget": 20}` (`api_key` omitted → server key). The reply
   must say `(run N, live)` — if it says `sim; live config
   incomplete`, a key is missing; fix it, don't re-run blind.
3. Poll `expedition_status`: watch `api.cost` climb and `streak`
   for stalls. Twenty calls ≈ $0.20 typical.
4. If the run looks stuck (high `streak`, `paused`, or a weeds
   `stop_reason` on every worker), `stop_expedition` and read what
   landed with `get_findings`.

Keep the dashboard open during a live run: the map, threads, and
API tiles show the same state the agent sees.

### 4. Search the hive, then read its shape

> "What does MetaMining already know about 'truth and
> confabulation'? Search everything, then pull the loop structure."

1. `search_claims` with `{"q": "truth and confabulation",
   "limit": 10}`. Check `space`: `embed` means semantic ranking;
   `hash` means only shared words matched — rephrase with the
   corpus's own vocabulary (the `loc` fields show it).
2. `get_topology` with `{"surface": "loops", "max_loops": 6}`:
   H1 rings are competing framings of the same ground; the `void`
   flag marks an unsurveyed pocket. `{"surface": "bars"}`
   shows which features persist across scales.
3. To act on a loop (teleport a branch into it, corroborate it),
   use the dashboard's close-loop buttons — loop-closing orders
   are dashboard-only in v1.

### 5. Archive archaeology across runs

> "Merge last week's journals into memory and find every gold claim
> about mycelial networks."

1. `list_journals`: pick filenames by concept/date (newest first).
2. `load_journal` with `{"filename": "<each>", "mode": "merge"}`
   (or `replace` to start from exactly one run).
3. `search_claims` with `{"q": "mycelial networks", "limit": 20}`
   now ranks merged memory too; `get_findings` with
   `{"gold_only": true}` pages the merged gold.
4. Current-run files stay untouched — `save_journal` writes a new
   file, and the archive holds 100 journals with pruning.

## Protocol notes

- **Transport:** `POST /mcp` takes exactly one JSON-RPC message and
  answers one JSON response (HTTP 200). There is no SSE fan-out —
  the server never initiates.
- **Methods:** `initialize` (negotiates `2025-06-18`, `2025-03-26`,
  `2024-11-05`; unknown clients get `2025-06-18`; capabilities
  `{tools:{}}`, `serverInfo` `metamining/<version>`), `ping` (`{}`),
  `tools/list`, `tools/call`. Anything else → `-32601`.
- **Sessions:** every response carries `Mcp-Session-Id: mm-N`
  (bumped on `initialize`); clients may echo it, the server never
  enforces it. `GET /mcp` holds an SSE stream open (`: connected`
  prelude, then silence) for clients that insist; `DELETE /mcp`
  answers 204.
- **Notifications** (no `id`, including
  `notifications/initialized`) → HTTP 202 with an empty body.
- **Errors:** `-32700` parse error (HTTP 400), `-32600` invalid
  request (HTTP 400), `-32601` method not found, `-32602` unknown
  tool or bad params (missing tool name, non-object params /
  arguments). Tool failures (missing `q`/`filename`, bad `metric`,
  `concept required`, start/stop faults) return `isError` text, not
  error codes.
- **Origin guard (DNS rebinding):** non-browser clients send no
  `Origin` and pass; a present `Origin` must be loopback
  (`localhost`, `127.0.0.1`, `::1`) or match `Host` exactly, else
  HTTP 403 `-32000`. `Origin: null` is rejected.

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| 401 `{"error":"auth required"}` | Server runs `--auth-token`; add `"headers": {"X-MM-Token": "T"}` |
| 403 `origin not allowed` | Browser-style `Origin` reached the server from a foreign host; call from loopback or matching `Host` |
| `Expedition started (sim; live config incomplete)` | A live field is missing; the log names it (`model`/`endpoint`/`key`) |
| `concept required` (isError) | First-ever start with no concept; pass `concept` |
| `list_models` empty | Sim backend (or no endpoint); live ids need endpoint + key |
| `get_journal` huge/slow | Large run with vectors; fetch once, slice client-side |
| Run vanished mid-poll | A newer start superseded it (`run` id changed); re-read status |
| Client hangs on handshake | Use Streamable HTTP transport (`--transport http`), not stdio/SSE |

Limits to keep in mind: MCP exposes the expedition lifecycle, not
the cockpit — pause/resume/warp/teleport/lens/tune/boost stay on the
dashboard, journals cap at 100 files, and the server is HTTP-only
(loopback-safe; put it behind a reverse proxy with TLS before
exposing it).
