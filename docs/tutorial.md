# MetaMining tutorial: one benchmark, end to end (~20 minutes)

> Worked example with real numbers. You load a shipped benchmark journal,
> read its map and shape views, act on what you see, and export
> paper-ready artifacts. All numbers below were observed at v0.9.0; expect
> small shifts if your `veins/veins.json` differs (see
> `data/benchmarks/README.md`).

## 0. Start the server

```bash
./metamining.sh   # embed server + MetaMining on http://127.0.0.1:8000
```

Open the dashboard. No key needed — everything here is sim.

## 1. Load the benchmark

```bash
cp data/benchmarks/bm1-cartography.json journals/
```

In the dashboard: **Load Journal JSONs** → pick the file → **replace**.
The map fills with 48 findings from seed
`why explanations persuade even when wrong` (3 branches × 12 steps, seed 7);
gold count varies with vein state (see the README signature).

## 2. Read the map, radar, and strip

- **Map**: three branch colors with trails. Note where trails tangle —
  you will check those spots against the loops view.
- **Radar**: latest reading plus its branch/step source. b1 > 0 means the
  latest window circled old ground.
- **Telemetry + Betti strip**: novelty/coherence vital signs, then the
  b0/b1/b2-per-finding ribbon. Amber (b1) activity mid-run with violet
  (b2) humps = loops forming while chambers opened — the classic
  explore-then-circle signature.

## 3. Walk the six Shape views

Press **Refresh** on each view (or tick **Live**). Current bm1 signatures
live in `data/benchmarks/README.md` (regenerated per release; compare
yours — drift means your vein state differs, which is itself lesson 1
about reproducibility). Read them qualitatively:

| View | What to look for |
|---|---|
| Merge tree | peak count = distinct paydirt hills (bm1: one) |
| Barcode | finite H1 bars = repetition rings; tick **Confidence** — stable ones draw bold |
| Loops | drawn loops + b1 rank = circling intensity; dashed ring = chamber nobody entered |
| Density | contour nests = over-dug ground; gaps = follow-up expeditions |
| Mapper | one connected skeleton with flares vs scattered fragments |
| Timeline | amber rising late = loops forming with age; violet humps = voids opening, then entered |

Try **Metric euclid** on the barcode: features surviving both metrics are
trustworthy. Open the **Data table** under any view — same numbers, no
canvas. Switch the map to **3D**: loops, void ring, and (with **Basin
tint**) peak diamonds all overlay the terrain; rotate to check whether a
ring survives orbiting (structure) or flattens (PCA fold).

## 4. Act on the shape

Shape is for steering, not admiring:

1. **Basin tint** the map. bm1 has one peak, so everything shares a
   basin; on multi-hill runs each hill gets its own territory color.
2. **Suggest probe** (Density view): it names the void chamber first
   (`P?` marker), else the sparsest surveyed gap.
3. Orders need live workers, so start a short run (2 branches × 50 steps),
   then while it runs: pick a basin, set a branch, **Teleport here**;
   list `0,1` and **Corroborate peak**. Watch the radar: teleported
   branches should drop b1 as they leave the ring.

## 5. Export the science

In the Shape panel's **Export** row:

- **Bundle JSON** — manifest + journal + state + all six surfaces. Archive
  this with any write-up.
- **Findings CSV** — one row per finding for statistics.
- **Shape SVG** — vector figure of the current view (papers, posters).
- **Methods** — one click copies a pre-filled methods paragraph; paste it
  into your notes and check every field.

## 6. Compare against bm2

Load `bm2-corroboration.json` (narrow factual seed, 32 findings) and
re-Refresh, then compare against its README signature. Same tool,
different territory: bm1 circled (high b1, drawn loops), bm2 scattered
without closing rings (b1=0 with a void). Use **Compare journal** (Run
diff) for point-level overlay; the shape deltas are the structural
comparison.

## 7. Exercises

1. Predict the merge-tree peak count from the bm1 map alone, then Refresh
   to check. Where did the projection mislead you?
2. Sweep Mapper bins 4→12 on bm1. Which features persist across settings
   (real) vs appear once (cover artifacts)?
3. Find the void-ring center in bm1. Which three findings border it, and
   what question would you seed to push into it?
4. Export both bundles and write the two methods paragraphs. What differs
   besides the seed?

Next: [research.md](research.md) turns these moves into citable protocols;
[topology.md](topology.md) explains the math behind every view.
