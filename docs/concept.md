# MetaMining: the big idea

> **One paragraph.** A large language model "knows" far more than any single
> conversation can surface. MetaMining treats the model's output space as a
> landscape and sends out parallel explorer branches to survey it: each branch
> proposes claims, scores them for novelty and coherence, steers away from
> already-visited ground, and stops when it wanders into the weeds. High-value
> finds ("gold") are kept on a Pareto frontier, mapped, and saved as journals
> you can reload, compare, and share. The web dashboard is the expedition
> control room.

For the button-by-button guide, see [manual.md](manual.md).

## The problem: models are oceans, prompts are thimbles

A frontier LLM compresses a sizable fraction of recorded human knowledge into
its weights. A normal chat session samples a thin line through that space:
one question, one answer, follow-ups drifting wherever attention goes. Two
things get lost:

1. **Breadth.** Most of what the model could say about a topic never gets
   said, because nobody asked from the right angle.
2. **Memory of the search.** Even when you do wander productively, there is no
   map — no record of which regions were covered, which repetitions crept in,
   or which half-formed ideas deserved a second pass.

MetaMining automates the wandering *and* keeps the map.

## The core loop (one expedition)

1. **Seed.** You give the run a starting concept ("the relationship between
   truth and confabulation") and parameters (branches, steps, temperature).
2. **Branch.** N independent explorer branches (worker processes) each walk
   the space step by step, generating candidate claims from the model (live
   backend) or from a deterministic generator (sim backend, for practice and
   UI testing).
3. **Score.** Every claim gets two numbers:
   - **Novelty** — how far it sits from everything visited so far (embedding
     or hash-vector distance to the archive).
   - **Coherence** — how well it holds together (judge scores / structural
     checks).
   Claims clearing the gold bar on both axes are flagged **gold**.
4. **Steer.** The next prompt is pushed away from visited regions (repulsion),
   toward unexplored chambers (topological "push"), and occasionally
   re-anchored to the best finds so far (warp-back to the Pareto frontier).
5. **Stop.** Each branch carries its own stop rules: step budget exhausted
   (`max-steps`), circling old ground (`plateau`), nothing valuable lately
   (`dry`), quality collapsing (`weeds`, `incoherent`). A global rule
   (`global-weeds`) ends the whole run when *all* branches go quiet. Stopping
   is a feature: it is what keeps the expedition out of the weeds instead of
   burning budget in them.
6. **Keep.** Findings stream to the dashboard (map, log, threads, frontier),
   and the full expedition is saved as a **journal** — reloadable,
   comparable, archivable.

## Why multiple threads?

A single chain of thought converges: it picks a direction and digs. Parallel
branches *diverge*: different sampling noise, different steering, different
persona lenses, even different models per branch. Diversity is the point —
the frontier at the end is the union of what N different walks discovered,
and the genealogy view shows how they split and merged. This is also why the
project is written in Mojo: many parallel workers with shared-nothing message
passing, one fat binary, no interpreter overhead in the hot path.

## Why the map? (novelty, topology, Pareto)

- **Novelty vs. coherence** is the classic exploration tension. Pure novelty
  drifts into nonsense; pure coherence repeats the seed. Scoring both and
  keeping only non-dominated finds (the **Pareto frontier**: nothing else
  beats them on *both* axes) is how the run separates signal from wander.
- **Topology** (Betti numbers b0/b1/b2, persistence) reads the *shape* of the
  visited set: connected components, repetition loops, unexplored voids. A
  branch with rising b1 is going in circles; a region with b2 voids has
  chambers nobody entered. The dashboard's topology radar turns those numbers
  into steering cues. The full why/what/where is [topology.md](topology.md).
- **The claim map** (2D PCA scatter, plus 3D terrain/scatter views) is the
  expedition's memory made visible: branch trails, gold strikes, coverage
  holes. The time scrubber replays how the territory filled in.

## Is this a real thing, or made up?

It is a real family of ideas; MetaMining is one particular machine in that
family. Honest placement:

- **Quality-Diversity / MAP-Elites** (Mouret & Clune 2015) is the intellectual
  home: keep an archive indexed by *behavior*, optimize quality *within* each
  niche instead of collapsing to one optimum. Recent work applies exactly this
  to LLM red-teaming — evolving diverse attack strategies across a behavioral
  archive rather than one best jailbreak (e.g. QD red-teaming papers, ICLR
  2026 workshops). MetaMining's branch archive + Pareto frontier + novelty
  steering is the same instinct pointed at *idea discovery* instead of
  vulnerability discovery.
- **Automated scientists** (Sakana AI's AI Scientist v1–v3, Google's AI
  co-scientist) generate research ideas with novelty checks, run experiments,
  and write papers — the first AI-generated papers passed workshop peer review
  in 2025. MetaMining is narrower (survey and map claims, don't run lab
  experiments) but deeper on the *search itself*: parallel branches, topology,
  live steering, replayable journals.
- **Novelty judging is genuinely hard.** AllenAI's Novelty Bench (2026) shows
  LLM novelty verdicts flip with prompt wording and transfer poorly from human
  to AI-generated ideas. MetaMining hedges this by grounding novelty in
  *distances to the visited archive* (geometry, not vibes) and using judges
  as one blended signal among several — but treat gold flags as "worth your
  attention", not "certified original". The human still assays the ore.

What MetaMining adds that is uncommon in one package: parallel threaded
frontier search with per-thread and global stop rules, live topological
steering, multi-model branches, a replayable visual control room, and
everything (server, math, TLS, JSON) in one dependency-free Mojo binary.

## What comes out of it

- **Gold claims**: surprising, coherent statements worth following up.
- **A map** of what was covered and what wasn't (voids are future expeditions).
- **A journal**: the full reproducible record — every finding, score, stop
  reason, cost — downloadable, archivable, diffable against other runs.
- **A frontier**: the Pareto-best set, one click from a shareable thread.

## Honest limits (read before trusting a run)

- **Gold ≠ true.** Coherence scoring is not fact-checking. A fluent falsehood
  can assay as gold. Verify consequential claims independently.
- **Novelty is relative to the run**, not to human knowledge. A claim can be
  "novel" (far from visited points) yet well-known in the literature.
- **Live runs cost real money** (Meta API list prices; the dashboard shows
  running cost). Sim runs are free and deterministic — rehearse there.
- **Sim determinism needs clean state**: same seed reproduces byte-exactly
  only with identical `veins/veins.json` (vein memory steers novelty). Reset
  veins for exact replication; see `data/benchmarks/README.md`.
- **Live output is nondeterministic**: the endpoint currently takes no seed,
  so live runs don't reproduce exactly. Sim runs reproduce from the seed.
- **Embeddings are hash vectors** until a working embeddings model is
  configured, which makes similarity geometry coarser than true embeddings.
