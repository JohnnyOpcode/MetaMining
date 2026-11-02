"""Vector steering for expedition branches.

PCA-subspace orthogonal projection, topological push (harmonic
loop repulsion + void attraction), gold-momentum blending, and
semantic contrast themes that bridge steered vectors back into
prompt space.
"""

from metamining.linalg import pca_fit, vdot, vmean, vnorm


def pca_subspace(hist: List[List[Float64]], k: Int, mut comps: List[List[Float64]]):
    """PCA subspace of the last 25 vectors; empty below k+1 points."""
    if len(hist) < k + 1 or k < 1:
        return
    var start = 0
    if len(hist) > 25:
        start = len(hist) - 25
    var tail = List[List[Float64]]()
    for i in range(start, len(hist)):
        tail.append(hist[i].copy())
    var n_comp = k
    if len(tail) < n_comp:
        n_comp = len(tail)
    if len(tail[0]) < n_comp:
        n_comp = len(tail[0])
    if n_comp < 1:
        return
    var mean = List[Float64]()
    pca_fit(tail, n_comp, comps, mean)


def ortho_project(
    cand: List[Float64], comps: List[List[Float64]], mut out: List[Float64]
):
    """Remove every subspace component; normalize unless degenerate."""
    for i in range(len(cand)):
        out.append(cand[i])
    for q in range(len(comps)):
        var c = comps[q].copy()
        var p = vdot(out, c)
        for j in range(len(out)):
            if j < len(c):
                out[j] = out[j] - p * c[j]
    var n = vnorm(out)
    if n > 1e-6:
        for j in range(len(out)):
            out[j] = out[j] / n


def topo_steer(
    cand: List[Float64],
    cycle: List[Float64],
    has_cycle: Bool,
    voidc: List[Float64],
    has_void: Bool,
    push: Float64,
    mut out: List[Float64],
):
    """Push off 1-cycle loops, pull toward the 2-void centroid."""
    for i in range(len(cand)):
        out.append(cand[i])
    if has_cycle and len(cycle) == len(out):
        var p = vdot(out, cycle)
        for j in range(len(out)):
            out[j] = out[j] - push * p * cycle[j]
    if has_void and len(voidc) == len(out):
        var d = List[Float64]()
        for j in range(len(out)):
            d.append(voidc[j] - out[j])
        var n = vnorm(d)
        if n > 1e-6:
            for j in range(len(out)):
                out[j] = out[j] + (push * 0.4) * (d[j] / n)
    var m = vnorm(out)
    if m > 1e-6:
        for j in range(len(out)):
            out[j] = out[j] / m


def momentum_dir(
    golds: List[List[Float64]], baseline: List[Float64], mut out: List[Float64]
) -> Bool:
    """Unit direction from baseline toward the gold mean. False if none."""
    if len(golds) == 0:
        return False
    var mean = List[Float64]()
    vmean(golds, mean)
    if len(mean) != len(baseline):
        return False
    for j in range(len(mean)):
        out.append(mean[j] - baseline[j])
    var n = vnorm(out)
    if n > 1e-6:
        for j in range(len(out)):
            out[j] = out[j] / n
    return True


def momentum_blend(
    cand: List[Float64], golds: List[List[Float64]], w: Float64, mut out: List[Float64]
):
    """Blend gold-trail momentum into the candidate (default w=0.25)."""
    var m = List[Float64]()
    if len(golds) == 0 or w <= 0.0 or not momentum_dir(golds, cand, m):
        for i in range(len(cand)):
            out.append(cand[i])
        return
    var bl = List[Float64]()
    for j in range(len(cand)):
        bl.append((1.0 - w) * cand[j] + w * m[j])
    var n = vnorm(bl)
    if n > 1e-6:
        for j in range(len(bl)):
            out.append(bl[j] / n)
    else:
        for j in range(len(cand)):
            out.append(cand[j])


def contrast_themes(
    steered: List[Float64],
    hist_vecs: List[List[Float64]],
    hist_concepts: List[String],
    top_k: Int,
    mut out: List[String],
):
    """Concepts least similar to the steered vector (most orthogonal)."""
    if len(hist_vecs) == 0 or len(hist_concepts) == 0:
        return
    var n = len(hist_vecs)
    var start = 0
    if n > 15:
        start = n - 15
    var ns = vnorm(steered) + 1e-9
    var picked = List[Int]()
    for _ in range(start, n):
        picked.append(0)
    for _ in range(top_k):
        var bi = -1
        var bs = 1e30
        for i in range(start, n):
            if picked[i - start] != 0:
                continue
            var h = hist_vecs[i].copy()
            var s = vdot(h, steered) / ((vnorm(h) + 1e-9) * ns)
            if s < bs:
                bs = s
                bi = i
        if bi < 0:
            break
        picked[bi - start] = 1
        if bi < len(hist_concepts):
            out.append(hist_concepts[bi])
