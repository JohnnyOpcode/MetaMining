# MetaMining for research: features, uses, use-cases

> **One paragraph.** MetaMining is a survey instrument for language-model
> output space: it sends parallel explorer branches into a model's responses,
> scores what comes back for novelty and coherence, maps the territory
> topologically, and exports everything for analysis. This doc lists concrete
> research use-cases as runnable protocols — question, steps, outputs, what to
> report — so a researcher can go from "what is this for" to a methods section
> in one sitting.

Background: [concept.md](concept.md) (the big idea),
[topology.md](topology.md) (the shape math),
[manual.md](manual.md) (button-by-button),
[tutorial.md](tutorial.md) (worked example).

## The export surface (what leaves the lab)

Every use-case below ends in artifacts. The Shape panel's **Export** row
produces, per run:

- **Bundle JSON** — one file: manifest (app, version, timestamp, run, view
  state), full journal, run state, and all six topo surfaces (merge tree,
  barcode + curves, confidence, loops + void, Mapper nerve, timeline) plus
  density parameters. This is the citable record of *what shape was found*.
- **Findings CSV** — branch, step, novelty, coherence, gold, x/y/z, b0/b1/b2,
  text. For statistics, plots, and feeding other tools.
- **Map / Shape PNGs, Shape SVG** — raster and vector figures for papers,
  posters, talks.
- **Methods button** — one click copies a pre-filled methods paragraph
  (protocol, yield, shape summary, cost) to the clipboard.

Filenames carry run id and timestamp
(`metamining-run3-20261031-120405-bundle.json`). Archive the bundle with the
paper; it contains everything needed to re-read the run's conclusions.

## Use-case 1: knowledge-frontier cartography

**Question.** Where does model M's reliable knowledge end and confabulation
begin on topic T?

**Protocol.**

1. Sim rehearsal: seed T, 2 branches × 10 steps. Learn the views on free,
   deterministic output.
2. Live run: seed T, 3–4 branches × 30–60 steps, default steering, Push ≥ 1
   so voids get explored rather than admired.
3. Mid-run, watch the radar: note where b2 (voids) appear and where coherence
   sags. Open Density + contours: mark sparse gaps adjacent to high novelty.
4. Post-run: Refresh all five Shape views. Record void centers, coherence
   pits (3D Surface + Coherence), and the barcode's long H1 bars.
5. Export the bundle + map PNG. Human-assay the flagged dozen: each
   spike-plus-pit, each void-adjacent sparse claim.

**Outputs.** A frontier map: settled highlands vs confabulation-prone
territory, with located unknowns (void centers as coordinates for follow-up
probes).

**Report.** Seed, branches × steps, model id, void count and centers, the
assayed verdicts (confirmed / refuted / unclear) with external sources.
Never report flags as findings — report *assayed* flags.

**Limits.** Coherence is judged fluency, not truth; hash-vector geometry is
lexical until real embeddings land. Frontiers move with temperature and
persona mix — fix those in the methods.

## Use-case 2: self-consistency corroboration

**Question.** Does M give the same answer to question Q from independent
angles, or does it confabulate per angle?

**Protocol.**

1. Seed Q narrowly ("What caused the 1847 Ten Hours Act amendments to fail?"
   beats "tell me about labor history").
2. Teleport 3+ idle branches at Q's region, each under a **different persona
   lens** — independent angles of attack.
3. Run to branch stops. Open the merge tree: one basin = same story from
   every angle (in-model corroboration); several basins or fresh H1 loops =
   per-angle stories (confabulation flag).
4. Cross-check the barcode: vec-space H1 twins of map rings mean the
   inconsistency survives projection.
5. Export the bundle (basins + bars are the evidence).

**Outputs.** A corroboration verdict per question: converged (basin count 1)
or divergent (basin count > 1, loop inventory), with the persona lenses used.

**Report.** Q verbatim, lenses, basin count, barcodes, and the external
verdict. In-model convergence raises confidence; only sources confirm truth
(shared training biases converge too).

## Use-case 3: red-team strategy archive (quality-diversity)

**Question.** What *diverse* jailbreak / misuse strategies exist against M,
not just one best exploit?

**Protocol.**

1. Seed with the misuse-adjacent goal plus explicit authorization context
   (this is defensive research; keep the authorization with the journal).
2. Run wide: many branches (6–10), high Push, fanout on promising
   runners-up — diversity is the objective, not a side effect.
3. Use the Pareto frontier (novelty × coherence) as the archive: non-dominated
   strategies are the keepers. The vein library accumulates them across runs.
4. Topology reads the archive's shape: b0 counts distinct strategy families,
   the Mapper nerve shows flares (fronts still yielding variants) vs settled
   blobs.
5. Export bundles per campaign; diff journals across model versions to see
   which families a patch killed.

**Outputs.** A strategy archive (journal + veins), its shape summary, and
version-to-version diffs.

**Report.** Authorization, seed, archive size, family count (b0 / Mapper
branches), and per-family representative prompts — responsibly disclosed per
your institution's policy.

## Use-case 4: idea discovery for science

**Question.** What non-obvious hypotheses about phenomenon P can M generate
that survive a coherence bar?

**Protocol.**

1. Seed P as a mechanism question ("what mechanisms could explain X?").
2. Run 4+ branches × 50+ steps with persona lenses spanning adjacent fields
   (the lens list is built for this: network medicine, info theory,
   thermodynamics of adaptation, …).
3. Mine the Gold panel and Pareto frontier; warp strong branches back to the
   frontier to deepen veins rather than widen puddles.
4. Merge tree per vein: one peak per distinct hypothesis family. Density gaps
   near gold = follow-up expeditions.
5. Export bundle + CSV; the CSV's gold rows are the hypothesis shortlist.

**Outputs.** A ranked hypothesis shortlist with novelty/coherence scores,
family structure, and full provenance (branch/step/text).

**Report.** Seed, lenses, frontier size, shortlist with scores, and — this is
the science — which hypotheses survived *your* domain evaluation and which
died, with reasons. A dead hypothesis with a reason is a result.

## Use-case 5: model comparison

**Question.** Do models A and B survey the same territory, or does one see
shape the other misses?

**Protocol.**

1. Fix a protocol: same seed, branches, steps, Push, persona lenses. Run it
   on A (set per-branch or run model explicitly).
2. Run the identical protocol on B. Same everything except the model id.
3. Compare structurally, not anecdotally: barcode long-bar inventories, void
   counts, Mapper nerve shape, frontier sizes. The run-diff overlay shows
   point-level differences; topology shows whether the *shapes* differ.
4. Export both bundles; the comparison is then data, not screenshots.

**Outputs.** A paired comparison: per-model shape summaries + diffs.

**Report.** The fixed protocol verbatim, both model ids, per-model shape
numbers, and cost/latency (the API tiles meter both runs). Note live
nondeterminism: one run per model is a pilot; replicate before claiming.

## Use-case 6: novelty-metric research

**Question.** Which novelty signals actually predict "worth a human's
attention" — distance-to-archive, judges, topological blend?

**Protocol.**

1. Run several seeds in sim (free, deterministic) and live; export the CSVs.
2. The CSV carries novelty, coherence, gold, b0/b1/b2, and text per finding —
   join with your own human or LLM-as-judge labels.
3. Ablate: correlate each signal (and the topo blend components) against
   labels. The topo blend weights (0.20/0.35/0.25/0.20 over
   b0/b1/b2/sheaf) are documented in topology.md §3 — test alternatives
   offline against the exported columns.
4. Publish the labeled CSVs alongside the paper: they are the benchmark.

**Outputs.** Signal-vs-label correlations, ablated weights, a labeled dataset.

**Report.** Seeds, labeling rubric + agreement stats, correlations with
confidence intervals, and the dataset. This is how the tool's own scoring
gets better — send improvements back.

## Use-case 7: knowledge probing (does M know X?)

**Question.** Narrower than cartography: for specific claim X, does M hold it
steadily?

**Protocol.**

1. Seed the negation and the affirmation in separate short runs (or two
   branch groups): "defend X" vs "attack X".
2. Watch which side accumulates coherence: steady knowledge defends easily
   and attacks incoherently; confabulated ground argues both sides fluently.
3. Corroborate per use-case 2 from multiple lenses.
4. Export both bundles; the pair is the probe record.

**Outputs.** A per-claim steadiness verdict with the pro/contra shape
evidence.

**Report.** X verbatim, both seeds, coherence distributions per side,
corroboration verdict, external verdict. "Argues both sides fluently" is
itself a publishable observation about a model.

## Use-case 8: classroom and demo (reproducible)

**Question.** How do I teach latent-space search without spending budget or
fighting nondeterminism?

**Protocol.**

1. Sim backend, fixed seed, 2 × 10. Every student gets identical output —
   deterministic, free, instant.
2. Walk the dashboard live: map fills, radar ticks, Shape views Refresh.
   Scrub time backwards; ask "where would you push next?" before revealing
   density.
3. Exercise: each student predicts the merge-tree peak count from the map
   alone, then Refreshes to check. Prediction error *is* the lesson about
   projection vs structure.
4. Export the bundle; homework is a one-paragraph assay of one gold claim.

**Outputs.** Identical runs for all students, predictions vs revealed shape,
assayed claims.

**Report (for instructors).** Seed + protocol doubles as the answer key;
bundle archives the session.

## Methods checklist (copy into your paper)

- App + export: MetaMining, bundle filename, export timestamp.
- Run protocol: seed concept verbatim, backend (sim/live), model id(s),
  branches × steps, Push, fanout, persona lenses, temperature, stop rules
  touched, budget caps.
- Data: findings count, gold count, journal + bundle archived where.
- Shape: radar source (branch/step), barcode metric + window/caps flags +
  confidence support, map-view sampling flags, Mapper bins/overlap, density
  bandwidth.
- Cost (live): calls, tokens in/out, listed-price estimate from the API tiles.
- Reproducibility: sim seed (reproduces) vs live (does not — endpoint takes
  no seed; report replicates).

## What the tool will not do for you

- **Fact-check.** Nothing here verifies truth. Every use-case ends in human
  assay or external sources by design.
- **Certify novelty against the literature.** Novelty is distance to the
  *run's* archive, not to human knowledge. A literature check is still yours.
- **Stay still.** Live runs are nondeterministic; replicate, then claim.
- **Replace preregistration.** Fix seeds, protocols, and verdict criteria
  before running, especially for comparison and corroboration claims.
