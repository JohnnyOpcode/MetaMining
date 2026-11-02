# Topology in MetaMining: why, what, where

> **One paragraph.** An expedition visits hundreds of points in a high-dimensional
> claim space. Coordinates tell you *where* each point is; topology tells you
> *what the visited set is shaped like* — one landmass or scattered islands,
> laced with repetition rings, wrapped around unexplored chambers. That shape is
> what steering acts on and what the Shape views draw. This doc covers why shape
> matters more than position, what each invariant and surface means, and where
> each one lives in the app and the code.

For the button-by-button guide, see [manual.md](manual.md); for the big picture,
see [concept.md](concept.md).

## 1. Why topology: coordinates lie, shape persists

Every finding gets coordinates twice: a 64-dimensional hash vector (vec space)
and a 2D PCA projection (the claim map). Both are lossy in different ways —
hash vectors blur semantics into word overlap, PCA crumples 64 dimensions into 2
and invents neighbors that were never close. If you steer by coordinates alone,
you chase projection artifacts.

Topological features survive this abuse better than coordinates do, because they
are statements about *relationships*, not positions:

- "these two regions are disconnected" (components),
- "this walk returned to where it started" (loops),
- "this shell of points surrounds something empty" (voids).

Stretch, rotate, or mildly scramble the space and those statements stay true.
That robustness is the whole bet: **topology reads the expedition's situation
through the noise of any particular embedding or projection.**

Four questions every researcher asks mid-run, translated:

| Researcher question | Topological translation | Answered by |
|---|---|---|
| Am I covering new ground or re-treading? | Is the visited set one piece or many? Are loops forming? | b0, b1, merge tree, density |
| Is a branch stuck going in circles? | Is b1 rising on its history? | radar loops cell, loops view |
| Where should I push next? | Where are the voids — chambers the visited set surrounds but never entered? | b2, void ring, density gaps |
| Is the run converging or still opening up? | Do features persist across scales, or die young? | barcode, Betti curves, entropy |

A fifth use is less obvious: topology **steers**. The void representative (a
direction toward the middle of empty chambers) feeds the Push control, and the
per-branch stop rules watch loop counts to call `plateau`. Shape is not a
dashboard ornament; it flies the expedition.

## 2. The two geometries (read this before trusting any view)

MetaMining computes shape in **two different spaces**, and mixing them up is the
#1 way to misread the dashboard:

- **Vec space**: the raw 64-dim hash vectors, cosine distance. True to the
  archive geometry; invisible to humans.
- **Map space**: the 2D PCA projection scaled 0–100 — exactly what you see on
  the claim map. Human-readable; inherits all of PCA's distortion.

| View | Space | Lines up with the map? |
|---|---|---|
| Radar (b0/b1/b2/cd/sheaf/entropy) | vec | No — deeper truth, different picture |
| Merge tree + basins | map | Yes, point for point |
| Barcode + Betti curves | vec | No — shape of the neighborhood itself |
| Loops + void | map | Yes — loops thread visible points |
| Density + contours | map | Yes — heat over the map |
| Mapper graph | map | Yes — nodes sit at cluster centroids |

Rule of thumb: map-space views explain *what you are looking at*; vec-space
views explain *what is actually there*. When they disagree (loops on the map,
none in the barcode), suspect a PCA artifact — the projection folded distant
points together.

## 3. The radar invariants (vec space, live)

Each new finding extends its branch's vector history; `topo_compute` reads the
last **24** vectors, builds Vietoris–Rips complexes (edges, triangles,
tetrahedra, capped at 1200 tris / 800 quads), and reports Betti numbers at the
**median pair-distance scale**, plus signatures at the 25th/50th/75th percentile
scales. Ranks are exact integer ranks of the boundary matrices over Float64
with tolerance 1e-9. The radar always shows the latest reading and its
branch/step source.

### b0 — connected components

The number of disconnected islands in the visited set at median scale. A fresh
branch starts near its seed (b0 = 1); a branch teleporting between far-apart
regions, or two branches pooled together, shows higher b0.
**Act when:** b0 fragments unexpectedly — coverage is splitting instead of
spreading. Warp a fragment back or let it seed a new front deliberately.

### b1 — loops (repetition rings)

Independent cycles: ways to walk from a point back to itself without retracing.
In a branch history, a loop means the walk circled old ground — the geometric
signature of repetition. Rising b1 is the earliest honest signal of `plateau`.
**Act when:** b1 climbs — warp the branch to the frontier, teleport it, or
switch its persona lens. b1 = 0 with b2 > 0 is the good shape (see below).

### b2 — voids (unexplored chambers)

Enclosed cavities: shells of visited points surrounding something empty. A void
is a *located* unknown — the math hands steering a direction (the void
representative: mean of up to ten triangle centroids) and the Push control
spends budget walking into it. Note b2 counts chambers, not their size; the
loops view draws the ring so you can judge that yourself.
**Act when:** b2 is high — that is literally where to explore next. Raise Push
or teleport into the gap.

### dim (cd) — complexity index

`cd = b0 + 1.5·b1 + 2·b2`: a single number that grows as the visited set gets
topologically richer. Components count least (mere spread), voids most
(genuine structure). Use it as a trend, not a threshold — a climbing cd means
the expedition is finding *shape*, not just points. (Available as **Z:
Cohom dim** in the 3D view to see complexity as terrain.)

### sheaf — trajectory curvature

Sum of squared normalized turning magnitudes over the last ≤10 history points:
how hard the branch is *bending*. A branch wrapping around an obstacle — a void
boundary, a coherence cliff — shows high curvature before any Betti number
moves. Think of it as the steering wheel angle: straight-line exploration reads
near zero; hairpins read high.
**Act when:** sheaf spikes while novelty sags — the branch is bending around
something it can't enter. Teleport past it or warp back.

### entropy — persistence entropy

Shannon entropy (bits, max 2) over the multiset of Betti signatures at the four
probe scales. Same signature at every scale → 0: the shape is *decided*.
Different signature per scale → high: the shape is still *forming*.
**Act when:** entropy collapses toward 0 across all branches — the run has said
what it will say; stop or re-seed. Entropy stuck high late in a run means the
scale structure never settled (often: too few points for the dimension).

### The topo novelty blend

Topology feeds back into scoring. Each finding carries a topological novelty
component: `0.20·(b0/5) + 0.35·(b1/3) + 0.25·(b2/2) + 0.20·(sheaf/2)` (each term
capped at 1). Loops weigh most — a claim that closes a new ring is doing
structural work. This is one signal among several in the final novelty number,
not the whole of it.

## 4. The six Shape views (on demand)

The radar is a live ticker; the Shape panel is the microscope. Views compute on
**Refresh** (or view switch), go `stale` as new findings land, and each carries
a caption explaining what it found — plus a data table under every view for
screen readers. Five are server-computed in Mojo; density is client-side (a
view transform of already-fetched points). **Live** auto-refreshes the current
view every 12 seconds during a run.

### Merge tree + basin tint (map space, ≤400 points)

**Construction.** Sweep novelty from high to low over the displayed map (4-NN
graph). Each new point joins the active components of its neighbors; when
distinct components meet, a merge node records the saddle. The result is the
join tree of the novelty field: leaves are findings, internal nodes are the
saddles where hills join, peaks are local maxima. Every point's **basin** is the
peak of the component it ends in — "which hill does this point drain to."

**Reading it.** Vertical axis is novelty, horizontal spreads leaves by map
x-rank. Gold rings mark peaks; node size grows with subtree size. Each peak is a
distinct paydirt hill; long lone trunks are hills nobody connected to anything.
**Basin tint** recolors the main map by basin so you can see each hill's
territory.

**Limits.** kNN (k=4) approximates the true neighborhood; a different k can
merge or split marginal hills. Stride-sampled past 400 points (flagged
`sampled`).

### Barcode + Betti curves (vec space, 20-point window)

**Construction.** Full Rips filtration over a 20-point stride window with
cosine distance, simplices ordered by (weight, dimension), standard column
reduction. Bars are grouped H0 (teal), H1 (amber), H2 (violet); `∞` marks
classes that never die (exactly one infinite H0 — the final component). The
Betti-curve strip below replays b0/b1/b2 at 12 evenly spaced scales.

**Reading it.** Bar *length* is significance: long H1 bars are real repetition
rings, short ones are sampling noise. Compare barcode H1 against the map-space
loops view — features in both are trustworthy; features only on the map are
suspect PCA folds. The curves show *where in scale* loops and voids live, which
tells you whether the radar's median-scale reading sits in a stable regime or
on a knife-edge.

**Limits.** The 20-point window keeps reduction fast; it is a sample, not the
run. Triangle/tetrahedron caps (2000/1000) trigger a `caps hit` note — bars are
then a sparsified approximation. The approximation is honest about big, obvious
features and may invent or drop marginal ones.

**Metric.** Cosine is the default (direction of the hash vector, robust to
length quirks); switch to **euclid** to test whether a feature survives the
distance change. Features present under both metrics are trustworthy;
single-metric features are suspects.

**Confidence.** Tick **Confidence** to resample: 8 deterministic folds (each
drops a rotated fifth of the window), matched back to the full-window bars
within 5% of max distance. Bars with support ≥ 0.5 draw bold and the caption
counts stable H1 bars. Treat low-support long bars as sampling artifacts, not
discoveries.

### Loops + void overlay (map space, ≤400 points)

**Construction.** VR complex over displayed map points at the median pair
distance; a harmonic cycle representative (boundary-matrix nullspace) weighted
by edge support, split into connected components, each walked into a member
cycle (default max 6, largest first). If H2 > 0, the void ball centers on the
mean of up to ten triangle centroids with radius half the RMS spread.

**Reading it.** Closed polylines threading visible points are branches circling
the same ground — warp or teleport them. The dashed violet ring marks an
unexplored chamber; its center is a teleport target. "b1=0, no rings" is itself
information: the map has no repetition structure at median scale.

**Limits.** One scale only (the median); rings living far above or below it are
invisible here — check the Betti curves. Walks are greedy representatives, not
canonical shortest cycles.

### Density + contours (map space, client-side)

**Construction.** Gaussian KDE over map coordinates (bandwidth 5 map units,
56×56 grid, normalized), iso-contours by marching squares at even levels
(default 5), plus per-point density that also feeds **Z: Density** in 3D.

**Reading it.** Contour nests are over-dug ground — many visits, little new
area. Sparse gaps *between* nests, especially near high-novelty points, are
where to push next. In 3D, Z: Density turns coverage into terrain: plateaus are
dug-out regions, slopes are fronts.

**Limits.** Bandwidth 5 is a fixed choice: smaller would fragment, larger would
merge. KDE sees point *positions*, not quality — a dense nest of gold and a
dense nest of weeds look identical until you check the gold overlay.

### Mapper graph (map space, ≤400 points)

**Construction.** The Mapper algorithm with novelty as the lens: cover the lens
range with overlapping intervals (default 8 bins, 0.4 overlap), cluster each
bin's points by map proximity (union-find, eps auto = half the median pair
distance), and link clusters that share members. Nodes sit at cluster
centroids; size is cluster size; color is mean lens.

**Reading it.** The nerve compresses the map to its skeleton: flares (chains
ending in high-novelty tips) are exploration fronts; branches are genuinely
different directions; isolated nodes are loners. If the nerve is one blob,
raise bins; if it shatters into dust, lower them or raise overlap. Bins/overlap
changes refetch live, so sweep them.

**Limits.** Mapper is a lens-and-cover *sketch*, not a measurement — its
branches move as bins/overlap move. Treat persistent-across-settings features
as real, single-setting features as suggestions. Clumped lens values can starve
the nerve of links (no shared members); spread in the lens is what makes links.

### Timeline (vec space, vineyard-lite)

**Construction.** Median-scale Betti numbers over cumulative run deciles:
decile d covers the first (d+1)×10% of vec-backed findings (stride-capped at
24 points). Drawn as three ribbons (b0 teal, b1 amber, b2 violet) across run
time.

**Reading it.** Rising amber = loops forming as the run proceeds (a branch
starting to circle); violet humps = voids opening then closing (chambers
found, then entered — the ideal expedition arc); b0 climbing late = coverage
fragmenting instead of spreading. Read alongside the **Betti history strip**
under Telemetry, which plots the same three numbers per finding as they land:
the strip is the live feed, the timeline is the decile summary.

**Limits.** Deciles are coarse (10 bins) and each is stride-capped — fine
structure inside a decile is invisible. Cumulative (not windowed), so late
changes dilute into early mass; the per-finding strip catches what the
timeline smooths.

## 5. Where everything lives

### In the app

- **Topology radar** (center panel): live b0/b1/b2/dim/sheaf/entropy + source.
  Highlighted cells need attention.
- **Shape panel** (center panel, below the radar): the six views, Refresh,
  per-view controls, captions, data tables. Loops/contours/basin-tint overlay
  the main map; loops/void/peaks overlay the 3D view too.
- **Close-loop controls** (Shape panel): basin picker + Teleport here,
  Corroborate peak (multi-branch × spread lenses), Suggest probe + Probe it.
- **Betti history strip** (under Telemetry): b0/b1/b2 per finding as they land.
- **3D controls**: Z can be Novelty, PCA-Z, Cohom dim, Coherence, or Density —
  shape as terrain.
- **In-app Guide** (card 3): the 30-second version of the radar.

### HTTP endpoints (for scripts)

All responses carry `n` (points computed over) and, for sampled views,
`total`/`sampled`. Map coordinates are 0–100 PCA space; vec distances are
cosine (`1 − cos`) unless `metric=euclid`.

**`GET /api/topo_merge`** — join tree + basins (leaves `0..n-1`, then merge
nodes):

| Field | Type | Meaning |
|---|---|---|
| `nov,x,y` | float[] | novelty + map coords per node (merges: subtree centroid) |
| `tx` | float[] | layout x 0–1 (leaves by x-rank, merges centered on children) |
| `size` | int[] | subtree leaf count |
| `peak` | int[] | 1 on leaf peaks |
| `bi,si` | int[] | branch/step identity (merges inherit their peak's) |
| `la,lb` | int[] | links child → parent |
| `basin` | int[] | leaf i's peak leaf index |

**`GET /api/topo_bars?metric=`** — barcode + Betti curves (`metric` cosine
default, or euclid; anything else is 400):

| Field | Type | Meaning |
|---|---|---|
| `metric` | string | echo of the distance used |
| `capped` | bool | tri/tet caps trimmed the filtration |
| `dim,birth,death` | int[],float[],float[] | per bar; death < 0 = infinite |
| `scales,b0,b1,b2` | float[],int[]… | 12-scale Betti curves |

**`GET /api/topo_conf?metric=`** — same shape as bars, plus `support`
(float[]: resampling fraction per bar, 8 deterministic folds) and
`resamples: 8`. Bars with support ≥ 0.5 draw bold.

**`GET /api/topo_loops?max=`** — loop members + void ball:

| Field | Type | Meaning |
|---|---|---|
| `b1` | int | cycle rank at median scale |
| `loops` | int[][] | member cycles as indices into the sampled set |
| `bi,si` | int[] | branch/step identity per sampled point |
| `has_void,void_x,void_y,void_r` | bool,float… | void ball (map units) |

**`GET /api/topo_mapper?bins=&overlap=`** — Mapper nerve:

| Field | Type | Meaning |
|---|---|---|
| `x,y,size,lens` | arrays | centroid, cluster size, mean lens per node |
| `la,lb` | int[] | links (shared members) |
| `bins,overlap` | int,float | echo of the cover parameters |

**`GET /api/topo_time`** — vineyard-lite: `total` findings; `frac` (decile
0.1–1.0), `n`, `b0`, `b1`, `b2` (10 entries each, cumulative prefixes,
stride-capped at 24 points).

### In the code

- `src/metamining/topo.mojo` — everything mathematical: `vr_complex`,
  `vr_betti` (boundary-matrix ranks), `topo_compute` (radar pipeline),
  `persistence_bars` (filtration + column reduction), `betti_curve`,
  `merge_tree`, `topo_loops`, `mapper_graph`, `traj_curvature`.
- `src/metamining/linalg.mojo` — `mat_rank`, `mat_null_vector`, `percentile`,
  PCA; the rank/nullspace engine under all homology.
- `src/metamining/server.mojo` — `srv_topo_*_json` builders, stride sampling
  (`_topo_idx`), routes in `srv_route`.
- `web/app.js` — Shape panel module (`shapeFetch`, `drawShape*` renderers),
  KDE + marching squares, map overlays, Z: Density.
- `tests/test_topo.mojo` — exact-value tests: square H1 bar at (1,2), filled
  triangle, capped well-formedness, two-peak basins, Mapper chain, Betti curve
  scale, pentagon loop.

## 6. Workflows: shape-driven expedition craft

**Diagnosing a plateau.** Radar loops rising on a branch → open Loops view,
Refresh: if a ring threads that branch's recent points, it is circling. Warp it
to the Pareto frontier (`warp`), or teleport it into the void ring if one
exists. Confirm on the next radar tick: b1 should fall.

**Finding the next push.** Press **Suggest probe** (Density view): it names
the void chamber if one exists, else the sparsest surveyed gap, marks it `P?`
on the map, and names the nearest claim. Pick a branch and **Probe it** — one
click teleports it to the candidate's neighborhood. Raise Push and steering
spends budget along the void direction.

**Corroborating a peak.** Select the basin in the merge view, list two or three
branches, press **Corroborate peak**: each branch teleports to the peak claim
under a spread persona lens (0/5/10). Re-Refresh the merge tree afterwards —
one basin means the model tells one story; several means confabulation (see
§7).

**Deciding to stop.** Entropy near 0 on all branches + barcode showing only
short H1 bars + density fully nested: the run has converged. Save the journal
and re-seed rather than burning budget. Conversely, long H1 bars with high
entropy mean structure is still forming — let it run.

**Comparing two runs.** Load journal A, screenshot the barcode and Mapper nerve;
load journal B, same. Differing long bars = genuinely different territory
surveyed; identical nerves with different maps = same shape, different
projection luck. The run-diff overlay shows point-level differences; topology
shows structural ones.

**Sweeping Mapper honestly.** Step bins 4→12 at fixed overlap, then overlap
0.2→0.6 at fixed bins. Features present in most settings (a persistent flare, a
stable split) are expedition facts; features in one setting are cover
artifacts. Screenshot the stable ones for the logbook.

## 7. 3D terrain for confabulation exploration and confirmation

The 2D map shows *where* claims sit. The 3D views show where they sit *and how
they stand* — position plus a quality or structural axis as elevation. That
second channel is what makes 3D the confabulation instrument: confabulation is
exactly a claim whose position looks fine but whose standing is wrong, and
elevation makes standing visible at a glance.

### The confabulation signature in terrain terms

A confabulating model produces claims that are fluent but ungrounded. In
expedition geometry that tends to look like this:

- **Far from settled ground, low coherence:** high novelty (remote map
  position) with low coherence scores. On **Surface + Novelty** these are lone
  spikes off the main mass; flip to **Z: Coherence** and they become pits.
  Spike-plus-pit at the same (x, y) is the first thing to inspect.
- **Low density, near a void boundary:** confabulation breeds at knowledge
  frontiers — the model has no settled attractors there, so each sample
  wanders. On **Z: Density** these zones are the low plains bordering dug-out
  plateaus; the void ring from the loops view often sits in the same
  neighborhood. Sparse + incoherent + chamber-adjacent = confabulation-prone
  territory, worth a deliberate push (cheap in sim) to map its extent.
- **High curvature approaches:** branches bending hard (sheaf spikes) around a
  region they never enter are often wrapping a coherence cliff — generation
  quality collapses past some boundary. In 3D you can see the cliff face:
  rotate to a side preset and look for the coherence escarpment.

None of these *proves* falsehood — coherence is judged fluency/structure, not
fact-checking, and a true-but-strange claim can spike too. They triage: out of
hundreds of findings, the terrain tells you which dozen deserve human assay.

### Confirmation as convergence across branches

Exploration finds candidates; confirmation corroborates them. The tool's
honest form of confirmation is **multi-branch convergence**:

1. Teleport two or three quiet branches at the same region from different
   persona lenses (different angles of attack on the same question).
2. Let them run, then open the **merge tree**: if all branches' claims drain
   into **one basin** (one peak's territory), the model tells the same story
   from every angle — corroborated *within the model*.
3. If the claims scatter across **several basins** or the region grows fresh
   H1 loops (branches circling without settling), the model is telling
   different stories per angle — a confabulation flag. The barcode
   cross-check applies: rings in vec space, not just the map, mean the
   inconsistency survives projection.

In 3D, convergence looks like claims piling into one coherence highland from
several trail directions; divergence looks like trails ending on disconnected
spikes. The **Top** preset gives the basin layout, **Side/Front** give the
elevation story, and **auto-orbit** plus the time scrubber replay *how* the
structure formed — a highland that grew steadily from many branches reads very
differently from one that appeared in a single burst.

### Practical 3D recipes

| Question | Mode + Z | Look for |
|---|---|---|
| Where might confabulations hide? | Surface + Novelty, then Z: Coherence | lone spikes that become pits |
| Is this region settled or frontier? | Scatter + Density | plateau (dug, many visits) vs low plain near a void |
| Do branches agree here? | Surface + Coherence, Top then Side | one highland fed by many trails vs disconnected spikes |
| Where is the coherence cliff? | Manifold + Coherence, Side preset | the escarpment face; teleport just past it to map the far side |
| Is that loop real or a fold? | Any 3D + PCA-Z | rotate: true rings stay ringed from all angles; folds collapse from the side |

That last recipe is the quiet superpower of 3D here: **rotation disambiguates
projection artifacts.** A repetition ring that survives orbiting is structure;
one that flattens into a line from the side was a PCA fold all along.

### Bounds of the instrument (read twice)

- **Consistency ≠ correctness.** Branches can converge on a shared falsehood —
  training biases and popular misconceptions are attractors too. In-model
  corroboration raises confidence; only external sources confirm truth.
- **Coherence ≠ truth, again, with feeling.** The pits and highlands are built
  from judged fluency. A fluent falsehood builds highlands.
- **Absence of flags ≠ verified.** A claim in a dense, coherent, single-basin
  highland with no rings is *unremarkable*, not *true*. The instrument finds
  suspects; the human still assays the ore.

## 8. Honest limits (read before citing a Betti number)

- **Hash vectors see words, not meaning.** Until a real embeddings backend is
  configured (one command: `./metamining.sh` — see [manual §9](manual.md)),
  vec-space topology is *lexical* topology: two claims sharing
  rare words look close however unrelated their content. Loops may be
  phrasing rings, not idea rings. Treat vec-space features as hypotheses
  about the archive, not measurements of idea space.
- **Map-space views inherit PCA distortion.** PCA preserves large-scale layout
  and mangles the rest. A loop on the map with no barcode H1 twin is guilty
  until proven innocent. The barcode exists partly to cross-examine the map.
- **Everything is sampled.** Radar: last 24 vectors. Barcode: 20-point window.
  Map views: ≤400 stride-sampled points. Sampling is flagged, not hidden —
  check `n`/`total`/`sampled` before concluding anything about a big run.
- **Caps approximate.** VR tri/quad caps (1200/800) and persistence tri/tet
  caps (2000/1000) trim the complexes that would otherwise explode
  combinatorially. Big features survive; marginal ones may flip. `capped`
  flags say when trimming happened.
- **Scales are choices.** Median-distance VR, percentile probe scales, KDE
  bandwidth 5, Mapper eps auto — each is a reasonable default, none is
  canonical law. The Betti curves exist so you can see what the radar's
  single scale is standing on.
- **Sim shape ≠ live shape.** The sim backend's deterministic generator makes
  tidy, legible topology (great for learning the views). Live runs are
  messier: noisier bars, ragged nerves. Learn on sim, decide on live, and
  re-check any sim-derived threshold against live data.

## 9. Glossary (one line each)

- **Betti numbers (b0/b1/b2):** counts of components / independent loops /
  enclosed voids.
- **Vietoris–Rips complex:** the clique complex at a distance scale — points
  within eps connect, cliques fill in; the scaffold homology is computed on.
- **Boundary matrix / rank:** the linear algebra under Betti numbers; rank
  differences count holes exactly.
- **Persistence / barcode:** each feature's (birth, death) across all scales;
  long bars are signal, short bars noise.
- **Betti curves:** b0/b1/b2 replayed across scales; shows where features live.
- **Persistence entropy:** spread of feature lifetimes; collapsing means
  converging.
- **Join (merge) tree:** how superlevel-set components of the novelty field
  merge as the level drops; peaks, saddles, basins.
- **Mapper:** lens + overlapping cover + per-bin clustering + nerve; a
  skeleton sketch of the data.
- **Nerve:** the graph recording which cover clusters overlap.
- **KDE:** kernel density estimate; smooth heat from discrete points.
- **Marching squares:** the contour-tracing algorithm turning a grid into
  iso-lines.
- **Harmonic representative:** the nullspace-weighted cycle/void the math
  hands to steering as a direction.
- **Sheaf obstruction (here):** trajectory curvature — how hard the walk is
  bending; high means wrapping around something.
- **Cohomological dimension (here):** the app's complexity index
  b0 + 1.5·b1 + 2·b2; trend it, don't threshold it.
