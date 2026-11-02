# MetaMining quickstart: first dig in 5 minutes

MetaMining sends parallel explorer branches into an LLM's latent space,
scores every finding for novelty × coherence, and plots the dig live.
This guide takes you from zero to a billed live run. (For the why, read
[concept.md](concept.md); for every knob, read [manual.md](manual.md).)

## 1. Start the server

```bash
cd ~/MetaMining
./metamining.sh                # embed server + MetaMining on http://127.0.0.1:8000
```

One command starts everything, detached: the local embedding server
(downloaded on first run) and MetaMining wired to it. `./metamining.sh stop`
stops both; `./metamining.sh --no-embed` skips embeddings (hash vectors).

Open [http://127.0.0.1:8000](http://127.0.0.1:8000) in a browser.

## 2. First expedition: sim (free, ~30 seconds)

Sim needs nothing but a concept — no key, no network.

1. Press **Demo run (SIM)** — one click fills 10x-relaxed stops and a
   fresh seed, then starts: minutes of free action that end on their own
   (sim backend, local embeddings when launched via `./metamining.sh`).
   Or press **Start expedition** with the prefilled defaults for a
   shorter scout. Optionally type your own **Seed concept** first.

Watch: the claim map fills with colored branch dots, **Threads**
shows each branch's step/best/reason, **Gold** collects high-novelty
hits, and the **Log** narrates stops. A toast says
`Expedition started (sim)`; the run pill ends with a stop reason like
`max-steps` or `plateau` — stopping is success (see manual §7).

## 3. First live expedition (~$0.20, ~3 minutes)

You need a Meta API key in the server's environment:

```bash
export META_API_KEY=...   # then (re)start ./metamining.sh in that shell
```

or paste the key into the form's **API key** field per run.

1. **Model**: pick from the autocomplete — e.g.
   `muse-spark-1.3-contributor` (cheapest text model). The id must
   match exactly; a typo'd id is rejected before anything is spent.
2. Press **Demo run (LIVE)** — fills the endpoint, 2 branches × 5
   steps, standard stops, and a 20-call budget cap, then starts.
   Expect roughly one finding per 20–40 seconds on live; the
   **API** panel meters spend as it happens.

## 4. Read the shape of your dig

Scroll to **Shape** (center panel) and press **Refresh**:

- **Merge tree** shows the novelty peaks — each gold-ringed peak is
  a distinct paydirt hill. Tick **Basin tint** to color the map by
  which peak each point belongs to.
- **Loops + void** draws repetition rings straight onto your map:
  closed loops are branches circling old ground.
- **Density + contours** shows where you have over-dug (contour
  nests) and where the gaps are — push into the gaps next.

Views go `stale` as new findings land; Refresh recomputes. See manual
§4 for the barcode and Mapper graph,
[topology.md](topology.md) for the full why/what/where, and
[tutorial.md](tutorial.md) for a worked example with real numbers.

## 5. Keep what you found

- **Gold** panel: click a vein's `read insight` to expand it.
- **Download journal** (left panel): saves the run as JSON so you
  never pay to re-survey the same ground; reload it any time from
  the journals list.
- **Tree** (advanced): the branch genealogy, including `fanout`
  children and `continue` legs.

## 6. Real semantic vectors (free, local, 2 minutes)

Without embeddings the map runs on hash vectors (shared words, not
meaning). `./metamining.sh` already fixed that for you: it starts the local
embedding server and wires MetaMining to it, so every run gets true
semantic geometry free — even sim runs. Search turns semantic
(`space: "embed"`), and journals record the vector space for
reproducibility. (Manual setup: `./embed-setup.sh` +
`./embed-setup.sh serve`, then set **Embed model** and **Embed endpoint**
in the start form.)

## 7. Five gotchas that bite newbies

1. **Model ids are exact.** `muse-spark` alone is not an id;
   `meta-contributor-1.2` does not exist. Use the autocomplete, or
   copy from the rejection message — it lists every valid id.
2. **Blank key means server env key.** If live starts say `(sim)`
   when you expected `(live)`, the server has no `META_API_KEY`.
3. **Fanout multiplies cost.** Fanout N samples N candidates per
   step *and* forks strong runners-up into pursued branches: spend
   grows as branches × steps × fanout. Scout at 1; raise it on paydirt.
4. **Red toasts stick, grey ones fade.** Errors stay until clicked;
   success notes vanish after a few seconds.
5. **Restart the server after updating code.** The GUI files reload
   from disk automatically, but the binary only rebuilds at startup.
   If a new feature seems missing, your server process predates it:
   `./metamining.sh stop` and start again (rebuild is automatic).

Next: [manual.md](manual.md) §3–§7 for controls, stop reasons, and
cost management, and [concept.md](concept.md) for what this is all about.
