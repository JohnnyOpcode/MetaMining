# Benchmark runs (seeded sim, reproducible)

Reload via the journals list (copy into `journals/`), or diff with
`diff-journal` in the dashboard. Regenerate: sim backend, protocol below.

Reproducibility note (verified 2026-10-31: byte-identical journals across
two clean runs): the seed fixes sampling, but `veins/veins.json` on disk is
also live state — vein memory steers novelty run to run. For bit-exact
replication, reset veins to `{"veins":[]}` first (back yours up). Compare
shape signatures qualitatively across states, exactly within one.

## bm1-cartography.json — frontier-cartography pilot: broad seed, 3 lenses

- seed concept: `why explanations persuade even when wrong`
- branches=3 steps=12 seed=7 (all else default)
- observed shape @0.9.0: findings=48 gold=3 peaks=1 h1bars=13 loops=1 b1=7 void=True mapper=16n/5l

## bm2-corroboration.json — corroboration pilot: narrow factual question

- seed concept: `what caused the 1847 Ten Hours Act amendments to fail`
- branches=3 steps=8 seed=21 (all else default)
- observed shape @0.9.0: findings=32 gold=2 peaks=2 h1bars=6 loops=0 b1=0 void=True mapper=6n/2l

