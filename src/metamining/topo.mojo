"""Vietoris-Rips persistent homology over finding vectors: pure Mojo.

Cohomology engine: exact Betti numbers from boundary
matrices + Gaussian elimination, multi-scale persistence signatures,
trajectory curvature ("sheaf obstruction"), and cycle/void extraction.

Design notes:
- Window N=24 (not 30): elimination cost is cubic; ranks stay exact.
- Full Betti (with B3) at the median scale only; percentile scales get
  b0/b1 plus a b2 upper bound (rankB3 skipped). Signatures stay honest.
- C2/C3 enumeration caps (1200/800) with a capped flag; beyond the cap
  b2 degrades to its upper bound instead of hanging.
- Reported numbers come from the median scale (their stated intent;
  their loop actually leaves the 75th-percentile values in place).
- The ad-hoc b2 bump for quad-less complexes is skipped: exact ranks
  don't need it (a lone triangle correctly reports b2=0).
- All-identical point sets short-circuit to (1,0,0): a full simplex,
  mathematically exact, and it dodges the dense worst case.
"""

from std.math import log2, sqrt

from metamining.linalg import (
    mat_null_vector,
    mat_rank,
    percentile,
    vdist,
    vmean,
    vnorm,
)

comptime TOPO_N = 24
comptime TOPO_C2_CAP = 1200
comptime TOPO_C3_CAP = 800


struct Betti(ImplicitlyCopyable):
    var b0: Int
    var b1: Int
    var b2: Int
    var capped: Bool

    def __init__(out self, b0: Int, b1: Int, b2: Int, capped: Bool):
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.capped = capped


struct TopoRes(Copyable, Movable):
    var b0: Int
    var b1: Int
    var b2: Int
    var cd: Float64
    var sheaf: Float64
    var nov: Float64
    var entropy: Float64
    var capped: Bool
    var cycle: List[Float64]
    var void: List[Float64]

    def __init__(out self):
        self.b0 = 0
        self.b1 = 0
        self.b2 = 0
        self.cd = 0.0
        self.sheaf = 0.0
        self.nov = 0.0
        self.entropy = 0.0
        self.capped = False
        self.cycle = List[Float64]()
        self.void = List[Float64]()


struct VRComplex(Copyable, Movable):
    var edges: List[List[Int]]
    var tris: List[List[Int]]
    var quads: List[List[Int]]
    var capped: Bool

    def __init__(out self):
        self.edges = List[List[Int]]()
        self.tris = List[List[Int]]()
        self.quads = List[List[Int]]()
        self.capped = False


def _dist_le(dist: List[List[Float64]], i: Int, j: Int, eps: Float64) -> Bool:
    return dist[i][j] <= eps


def vr_complex(dist: List[List[Float64]], n: Int, eps: Float64) -> VRComplex:
    var c = VRComplex()
    for i in range(n):
        for j in range(i + 1, n):
            if _dist_le(dist, i, j, eps):
                var e = List[Int]()
                e.append(i)
                e.append(j)
                c.edges.append(e^)
    for i in range(n):
        for j in range(i + 1, n):
            if not _dist_le(dist, i, j, eps):
                continue
            for k in range(j + 1, n):
                if len(c.tris) >= TOPO_C2_CAP:
                    c.capped = True
                    break
                if _dist_le(dist, i, k, eps) and _dist_le(dist, j, k, eps):
                    var t = List[Int]()
                    t.append(i)
                    t.append(j)
                    t.append(k)
                    c.tris.append(t^)
            if c.capped:
                break
        if c.capped:
            break
    if not c.capped:
        for i in range(n):
            for j in range(i + 1, n):
                if not _dist_le(dist, i, j, eps):
                    continue
                for k in range(j + 1, n):
                    if not _dist_le(dist, i, k, eps) or not _dist_le(dist, j, k, eps):
                        continue
                    for m in range(k + 1, n):
                        if len(c.quads) >= TOPO_C3_CAP:
                            c.capped = True
                            break
                        if (
                            _dist_le(dist, i, m, eps)
                            and _dist_le(dist, j, m, eps)
                            and _dist_le(dist, k, m, eps)
                        ):
                            var q = List[Int]()
                            q.append(i)
                            q.append(j)
                            q.append(k)
                            q.append(m)
                            c.quads.append(q^)
                    if c.capped:
                        break
                if c.capped:
                    break
            if c.capped:
                break
    return c^


def _edge_key(i: Int, j: Int) -> Int:
    return i * 64 + j


def _tri_key(i: Int, j: Int, k: Int) -> Int:
    return (i * 64 + j) * 64 + k


def _zeros(rows: Int, cols: Int, mut out: List[List[Float64]]):
    for _ in range(rows):
        var r = List[Float64]()
        for _ in range(cols):
            r.append(0.0)
        out.append(r^)


def vr_betti(n: Int, c: VRComplex, full: Bool) raises -> Betti:
    var ne = len(c.edges)
    var nt = len(c.tris)
    var nq = len(c.quads)
    var b1m = List[List[Float64]]()
    _zeros(n, ne, b1m)
    for e in range(ne):
        var edge = c.edges[e].copy()
        var i = edge[0]
        var j = edge[1]
        var ri = b1m[i].copy()
        ri[e] = -1.0
        b1m[i] = ri^
        var rj = b1m[j].copy()
        rj[e] = 1.0
        b1m[j] = rj^
    var emap = Dict[Int, Int]()
    for e in range(ne):
        var edge = c.edges[e].copy()
        emap[_edge_key(edge[0], edge[1])] = e
    var b2m = List[List[Float64]]()
    _zeros(ne, nt, b2m)
    for t in range(nt):
        var tri = c.tris[t].copy()
        var i = tri[0]
        var j = tri[1]
        var k = tri[2]
        var eij = emap[_edge_key(i, j)]
        var ejk = emap[_edge_key(j, k)]
        var eik = emap[_edge_key(i, k)]
        var r1 = b2m[eij].copy()
        r1[t] = 1.0
        b2m[eij] = r1^
        var r2 = b2m[ejk].copy()
        r2[t] = 1.0
        b2m[ejk] = r2^
        var r3 = b2m[eik].copy()
        r3[t] = -1.0
        b2m[eik] = r3^
    var r1 = mat_rank(b1m, 1e-9)
    var r2 = mat_rank(b2m, 1e-9)
    var r3 = 0
    if full and nt > 0 and nq > 0:
        var tmap = Dict[Int, Int]()
        for t in range(nt):
            var tri = c.tris[t].copy()
            tmap[_tri_key(tri[0], tri[1], tri[2])] = t
        var b3m = List[List[Float64]]()
        _zeros(nt, nq, b3m)
        for q in range(nq):
            var quad = c.quads[q].copy()
            var i = quad[0]
            var j = quad[1]
            var k = quad[2]
            var m = quad[3]
            var f0 = tmap[_tri_key(j, k, m)]
            var f1 = tmap[_tri_key(i, k, m)]
            var f2 = tmap[_tri_key(i, j, m)]
            var f3 = tmap[_tri_key(i, j, k)]
            var r0 = b3m[f0].copy()
            r0[q] = 1.0
            b3m[f0] = r0^
            var r4 = b3m[f1].copy()
            r4[q] = -1.0
            b3m[f1] = r4^
            var r5 = b3m[f2].copy()
            r5[q] = 1.0
            b3m[f2] = r5^
            var r6 = b3m[f3].copy()
            r6[q] = -1.0
            b3m[f3] = r6^
        r3 = mat_rank(b3m, 1e-9)
    var b0 = n - r1
    if b0 < 1:
        b0 = 1
    var b1 = ne - r1 - r2
    if b1 < 0:
        b1 = 0
    var b2 = nt - r2 - r3
    if b2 < 0:
        b2 = 0
    return Betti(b0, b1, b2, c.capped)


def _pair_dists(pts: List[List[Float64]], mut out: List[Float64]):
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            out.append(vdist(pts[i], pts[j]))


def _dmat(pts: List[List[Float64]], mut out: List[List[Float64]]):
    for i in range(len(pts)):
        var row = List[Float64]()
        for j in range(len(pts)):
            if i == j:
                row.append(0.0)
            elif j > i:
                row.append(vdist(pts[i], pts[j]))
            else:
                row.append(out[j][i])
        out.append(row^)


def traj_curvature(hist: List[List[Float64]]) -> Float64:
    var n = len(hist)
    if n < 3:
        return 0.0
    var start = n - 10
    if start < 0:
        start = 0
    var curv = 0.0
    var i = start + 1
    while i + 1 < n:
        var a = hist[i - 1].copy()
        var b = hist[i].copy()
        var cc = hist[i + 1].copy()
        var v1 = List[Float64]()
        var v2 = List[Float64]()
        var d = len(a)
        for j in range(d):
            v1.append(b[j] - a[j])
            v2.append(cc[j] - b[j])
        var num = 0.0
        var dn1 = 0.0
        var dn2 = 0.0
        for j in range(d):
            var dd = v2[j] - v1[j]
            num += dd * dd
            dn1 += v1[j] * v1[j]
            dn2 += v2[j] * v2[j]
        var t = num**0.5 / (dn1**0.5 + dn2**0.5 + 1e-9)
        curv += t * t
        i += 1
    return curv


def _sig_entropy(sigs: List[List[Int]]) -> Float64:
    # Signatures as packed ints; entropy over the multiset (4 draws).
    var keys = List[Int]()
    for i in range(len(sigs)):
        var s = sigs[i].copy()
        keys.append((s[0] * 64 + s[1]) * 64 + s[2])
    var ent = 0.0
    var total = Float64(len(keys))
    if total <= 0.0:
        return 0.0
    for i in range(len(keys)):
        var seen = False
        for j in range(i):
            if keys[j] == keys[i]:
                seen = True
                break
        if seen:
            continue
        var cnt = 0
        for j in range(len(keys)):
            if keys[j] == keys[i]:
                cnt += 1
        var p = Float64(cnt) / total
        ent -= p * log2(p)
    return ent


def topo_compute(hist: List[List[Float64]]) raises -> TopoRes:
    """Full multi-scale signature over a time-ordered vector history."""
    var res = TopoRes()
    var n = len(hist)
    if n < 3:
        res.b0 = n
        return res^
    var pts = List[List[Float64]]()
    var start = n - TOPO_N
    if start < 0:
        start = 0
    for i in range(start, n):
        pts.append(hist[i].copy())
    var dists = List[Float64]()
    _pair_dists(pts, dists)
    var dmax = 0.0
    for i in range(len(dists)):
        if dists[i] > dmax:
            dmax = dists[i]
    if dmax < 1e-9:
        res.b0 = 1
        res.cd = 1.0
        return res^
    var dm = List[List[Float64]]()
    _dmat(pts, dm)
    var scales = List[Float64]()
    scales.append(percentile(dists, 50.0))
    scales.append(percentile(dists, 25.0))
    scales.append(percentile(dists, 50.0))
    scales.append(percentile(dists, 75.0))
    var sigs = List[List[Int]]()
    var cmed = VRComplex()
    for s in range(len(scales)):
        var c = vr_complex(dm, len(pts), scales[s])
        var full = s == 0
        var b = vr_betti(len(pts), c, full)
        if s == 0:
            cmed = c.copy()
            res.b0 = b.b0
            res.b1 = b.b1
            res.b2 = b.b2
            res.capped = b.capped
        var sig = List[Int]()
        sig.append(b.b0)
        sig.append(b.b1)
        sig.append(b.b2)
        sigs.append(sig^)
    res.entropy = _sig_entropy(sigs)
    res.cd = Float64(res.b0) + 1.5 * Float64(res.b1) + 2.0 * Float64(res.b2)
    res.sheaf = traj_curvature(hist)
    var t0 = Float64(res.b0) / 5.0
    if t0 > 1.0:
        t0 = 1.0
    var t1 = Float64(res.b1) / 3.0
    if t1 > 1.0:
        t1 = 1.0
    var t2 = Float64(res.b2) / 2.0
    if t2 > 1.0:
        t2 = 1.0
    var ts = res.sheaf / 2.0
    if ts > 1.0:
        ts = 1.0
    res.nov = 0.20 * t0 + 0.35 * t1 + 0.25 * t2 + 0.20 * ts
    if res.nov > 1.0:
        res.nov = 1.0
    # Harmonic cycle: null(B1) weights push along (p_j - p_i). Note this
    # telescopes to ~0 for any closed loop; kept for completeness,
    # steering leans on void + momentum.
    if res.b1 > 0 and len(cmed.edges) > 0:
        var b1m = List[List[Float64]]()
        _zeros(len(pts), len(cmed.edges), b1m)
        for e in range(len(cmed.edges)):
            var edge = cmed.edges[e].copy()
            var i = edge[0]
            var j = edge[1]
            var ri = b1m[i].copy()
            ri[e] = -1.0
            b1m[i] = ri^
            var rj = b1m[j].copy()
            rj[e] = 1.0
            b1m[j] = rj^
        var w = List[Float64]()
        if mat_null_vector(b1m, 1e-9, w):
            var d = len(pts[0])
            var cyc = List[Float64]()
            for _ in range(d):
                cyc.append(0.0)
            for e in range(len(cmed.edges)):
                var edge = cmed.edges[e].copy()
                var a = pts[edge[0]].copy()
                var b = pts[edge[1]].copy()
                for j in range(d):
                    cyc[j] = cyc[j] + w[e] * (b[j] - a[j])
            if vnorm(cyc) >= 1e-9:
                var unit = List[Float64]()
                var dn = vnorm(cyc)
                for j in range(d):
                    unit.append(cyc[j] / dn)
                res.cycle = unit.copy()
    # Void centroid: mean of the first ten triangle centroids.
    if res.b2 > 0 and len(cmed.tris) > 0:
        var cents = List[List[Float64]]()
        var nt = len(cmed.tris)
        if nt > 10:
            nt = 10
        for t in range(nt):
            var tri = cmed.tris[t].copy()
            var acc = List[Float64]()
            var d = len(pts[0])
            for _ in range(d):
                acc.append(0.0)
            for k in range(3):
                var p = pts[tri[k]].copy()
                for j in range(d):
                    acc[j] = acc[j] + p[j] / 3.0
            cents.append(acc^)
        var vv = List[Float64]()
        vmean(cents, vv)
        res.void = vv.copy()
    return res^


# ---------------------------------------------------------------------------
# Map-space shape views: merge tree, Mapper graph, persistence, loop members.
#
# These run over the DISPLAYED map (x, y + novelty), not embedding space,
# so every overlay lines up with what the researcher sees. The vec-space
# VR engine above stays the source for per-finding homology; only the
# persistence barcode below runs in vec space (shape of the neighborhood).
# ---------------------------------------------------------------------------


def _uf_init(n: Int) -> List[Int]:
    var p = List[Int]()
    for i in range(n):
        p.append(i)
    return p.copy()


def _uf_find(mut parent: List[Int], a: Int) -> Int:
    var r = a
    while parent[r] != r:
        r = parent[r]
    var c = a
    while parent[c] != r:
        var nxt = parent[c]
        parent[c] = r
        c = nxt
    return r


def _uf_union(mut parent: List[Int], a: Int, b: Int) -> Bool:
    var ra = _uf_find(parent, a)
    var rb = _uf_find(parent, b)
    if ra == rb:
        return False
    if ra < rb:
        parent[rb] = ra
    else:
        parent[ra] = rb
    return True


def _argsort_desc(vals: List[Float64]) -> List[Int]:
    """Indices sorting vals descending (stable: ties keep input order)."""
    var idx = List[Int]()
    for i in range(len(vals)):
        idx.append(i)
    for i in range(len(idx)):
        var best = i
        for j in range(i + 1, len(idx)):
            if vals[idx[j]] > vals[idx[best]]:
                best = j
        if best != i:
            var t = idx[i]
            idx[i] = idx[best]
            idx[best] = t
    return idx.copy()


def _argsort_asc(vals: List[Float64]) -> List[Int]:
    var idx = List[Int]()
    for i in range(len(vals)):
        idx.append(i)
    for i in range(len(idx)):
        var best = i
        for j in range(i + 1, len(idx)):
            if vals[idx[j]] < vals[idx[best]]:
                best = j
        if best != i:
            var t = idx[i]
            idx[i] = idx[best]
            idx[best] = t
    return idx.copy()


def _knn_graph(
    xs: List[Float64], ys: List[Float64], k: Int
) -> List[List[Int]]:
    """k nearest neighbors (excluding self) per point, map space."""
    var n = len(xs)
    var out = List[List[Int]]()
    for i in range(n):
        var best = List[Int]()
        var bd = List[Float64]()
        for j in range(n):
            if j == i:
                continue
            var dx = xs[i] - xs[j]
            var dy = ys[i] - ys[j]
            var d2 = dx * dx + dy * dy
            if len(best) < k:
                best.append(j)
                bd.append(d2)
            else:
                var worst = 0
                for t in range(1, len(best)):
                    if bd[t] > bd[worst]:
                        worst = t
                if d2 < bd[worst]:
                    best[worst] = j
                    bd[worst] = d2
        out.append(best^)
    return out.copy()


struct MergeTree(Copyable, Movable):
    """Join (max-merge) tree of the novelty field + basin assignment."""

    var nov: List[Float64]
    var x: List[Float64]
    var y: List[Float64]
    var tx: List[Float64]
    var size: List[Int]
    var peak: List[Int]
    var bi: List[Int]
    var si: List[Int]
    var la: List[Int]
    var lb: List[Int]
    var basin: List[Int]

    def __init__(out self):
        self.nov = List[Float64]()
        self.x = List[Float64]()
        self.y = List[Float64]()
        self.tx = List[Float64]()
        self.size = List[Int]()
        self.peak = List[Int]()
        self.bi = List[Int]()
        self.si = List[Int]()
        self.la = List[Int]()
        self.lb = List[Int]()
        self.basin = List[Int]()


def merge_tree(
    xs: List[Float64],
    ys: List[Float64],
    novs: List[Float64],
    bi: List[Int],
    si: List[Int],
    k: Int,
) -> MergeTree:
    """Merge tree over map points: peaks, saddles, basin per point.

    Sweep novelty descending; each new point joins the active components
    of its kNN neighbors, creating a merge node when distinct components
    meet. Basin of a point = peak of its final component.
    """
    var res = MergeTree()
    var n = len(xs)
    if n == 0 or len(ys) != n or len(novs) != n:
        return res^
    var kk = k
    if kk < 1:
        kk = 1
    if kk > n - 1 and n > 1:
        kk = n - 1
    var nbrs = _knn_graph(xs, ys, kk)
    var order = _argsort_desc(novs)
    var parent = _uf_init(n)
    var active = List[Int]()
    var comp_node = List[Int]()
    var comp_peak = List[Int]()
    var comp_cnt = List[Int]()
    var comp_sx = List[Float64]()
    var comp_sy = List[Float64]()
    for i in range(n):
        active.append(0)
        comp_node.append(-1)
        comp_peak.append(i)
        comp_cnt.append(0)
        comp_sx.append(0.0)
        comp_sy.append(0.0)
        res.nov.append(novs[i])
        res.x.append(xs[i])
        res.y.append(ys[i])
        res.tx.append(0.0)
        res.size.append(1)
        res.peak.append(0)
        var bb = 0
        var ss = 0
        if i < len(bi):
            bb = bi[i]
        if i < len(si):
            ss = si[i]
        res.bi.append(bb)
        res.si.append(ss)
    for oi in range(n):
        var p = order[oi]
        active[p] = 1
        comp_cnt[p] = 1
        comp_sx[p] = xs[p]
        comp_sy[p] = ys[p]
        comp_node[p] = p
        var roots = List[Int]()
        for q in range(len(nbrs[p])):
            var nb = nbrs[p][q]
            if active[nb] == 0:
                continue
            var r = _uf_find(parent, nb)
            var seen = False
            for t in range(len(roots)):
                if roots[t] == r:
                    seen = True
            if not seen:
                roots.append(r)
        if len(roots) == 0:
            continue
        var mid = len(res.nov)
        var sx = xs[p]
        var sy = ys[p]
        var cnt = 1
        var pk = p
        for t in range(len(roots)):
            var r = roots[t]
            sx += comp_sx[r]
            sy += comp_sy[r]
            cnt += comp_cnt[r]
            if novs[comp_peak[r]] > novs[pk]:
                pk = comp_peak[r]
            res.la.append(comp_node[r])
            res.lb.append(mid)
            _ = _uf_union(parent, p, r)
        res.la.append(p)
        res.lb.append(mid)
        var nr = _uf_find(parent, p)
        comp_node[nr] = mid
        comp_peak[nr] = pk
        comp_cnt[nr] = cnt
        comp_sx[nr] = sx
        comp_sy[nr] = sy
        res.nov.append(novs[p])
        res.x.append(sx / Float64(cnt))
        res.y.append(sy / Float64(cnt))
        res.tx.append(0.0)
        res.size.append(cnt)
        res.peak.append(0)
        var pbb = 0
        var pss = 0
        if pk < len(bi):
            pbb = bi[pk]
        if pk < len(si):
            pss = si[pk]
        res.bi.append(pbb)
        res.si.append(pss)
    for i in range(n):
        var r = _uf_find(parent, i)
        var pk = comp_peak[r]
        res.basin.append(pk)
        res.peak[pk] = 1
    # Layout: leaves spread by x-rank, internal nodes centered on children.
    var lx = List[Float64]()
    for i in range(n):
        lx.append(xs[i])
    var lorder = _argsort_asc(lx)
    for r in range(n):
        res.tx[lorder[r]] = (Float64(r) + 0.5) / Float64(n)
    var nn = len(res.nov)
    for m in range(n, nn):
        var acc = 0.0
        var cnt = 0
        for e in range(len(res.la)):
            if res.lb[e] == m:
                acc += res.tx[res.la[e]]
                cnt += 1
        if cnt > 0:
            res.tx[m] = acc / Float64(cnt)
    return res^


struct MapperGraph(Copyable, Movable):
    """Mapper nerve over the novelty lens: nodes + shared-member links."""

    var x: List[Float64]
    var y: List[Float64]
    var size: List[Int]
    var lens: List[Float64]
    var la: List[Int]
    var lb: List[Int]

    def __init__(out self):
        self.x = List[Float64]()
        self.y = List[Float64]()
        self.size = List[Int]()
        self.lens = List[Float64]()
        self.la = List[Int]()
        self.lb = List[Int]()


def mapper_graph(
    xs: List[Float64],
    ys: List[Float64],
    lens: List[Float64],
    n_bins: Int,
    overlap: Float64,
    eps: Float64,
) -> MapperGraph:
    """Mapper over map points: overlapping lens cover, union-find clusters.

    Cover: n_bins intervals over [min, max] lens with fractional overlap.
    Cluster: connected components under map distance < eps (eps <= 0
    auto-picks half the median pair distance). Nerve links share members.
    """
    var res = MapperGraph()
    var n = len(xs)
    if n == 0 or len(ys) != n or len(lens) != n:
        return res^
    var nb = n_bins
    if nb < 1:
        nb = 1
    if nb > 24:
        nb = 24
    var ov = overlap
    if ov < 0.0:
        ov = 0.0
    if ov > 0.9:
        ov = 0.9
    var lo = lens[0]
    var hi = lens[0]
    for i in range(1, n):
        if lens[i] < lo:
            lo = lens[i]
        if lens[i] > hi:
            hi = lens[i]
    var ee = eps
    if ee <= 0.0:
        var pd = List[Float64]()
        for i in range(n):
            for j in range(i + 1, n):
                var dx = xs[i] - xs[j]
                var dy = ys[i] - ys[j]
                pd.append(dx * dx + dy * dy)
        if len(pd) > 0:
            var m = percentile(pd, 50.0)
            ee = 0.0
            if m > 0.0:
                ee = sqrt(m) * 0.5
    var ee2 = ee * ee
    # member -> node ids (built as nodes are created).
    var ptn = List[List[Int]]()
    for i in range(n):
        ptn.append(List[Int]())
    var span = hi - lo
    var width = span / Float64(nb)
    if width <= 0.0:
        width = 1.0
    var step = width * (1.0 - ov)
    if step <= 0.0:
        step = width
    for b in range(nb):
        var bs = lo + Float64(b) * step
        var be = bs + width
        if b == nb - 1:
            be = hi + 1e-9
        var members = List[Int]()
        for i in range(n):
            if lens[i] >= bs and lens[i] <= be:
                members.append(i)
        if len(members) == 0:
            continue
        var parent = _uf_init(n)
        for a in range(len(members)):
            for c in range(a + 1, len(members)):
                var i = members[a]
                var j = members[c]
                var dx = xs[i] - xs[j]
                var dy = ys[i] - ys[j]
                if dx * dx + dy * dy < ee2:
                    _ = _uf_union(parent, i, j)
        var seen = List[Int]()
        for a in range(len(members)):
            var r = _uf_find(parent, members[a])
            var known = False
            for t in range(len(seen)):
                if seen[t] == r:
                    known = True
            if not known:
                seen.append(r)
        for s in range(len(seen)):
            var sx = 0.0
            var sy = 0.0
            var sl = 0.0
            var cnt = 0
            for a in range(len(members)):
                if _uf_find(parent, members[a]) == seen[s]:
                    sx += xs[members[a]]
                    sy += ys[members[a]]
                    sl += lens[members[a]]
                    cnt += 1
            var nid = len(res.x)
            res.x.append(sx / Float64(cnt))
            res.y.append(sy / Float64(cnt))
            res.size.append(cnt)
            res.lens.append(sl / Float64(cnt))
            for a in range(len(members)):
                if _uf_find(parent, members[a]) == seen[s]:
                    var lst = ptn[members[a]].copy()
                    lst.append(nid)
                    ptn[members[a]] = lst^
    var lk = List[Int]()
    for i in range(n):
        var lst = ptn[i].copy()
        for a in range(len(lst)):
            for c in range(a + 1, len(lst)):
                var u = lst[a]
                var v = lst[c]
                if u == v:
                    continue
                var key = u * 4096 + v
                if u > v:
                    key = v * 4096 + u
                var known = False
                for t in range(len(lk)):
                    if lk[t] == key:
                        known = True
                if not known:
                    lk.append(key)
                    res.la.append(u)
                    res.lb.append(v)
    return res^


comptime PERS_TRI_CAP = 2000
comptime PERS_TET_CAP = 1000


def _simp_key(v0: Int, v1: Int, v2: Int, v3: Int, n: Int) -> Int:
    """Unique id (for vertex subsets of size <= 4) from sorted slots."""
    return ((v0 * (n + 1) + v1) * (n + 1) + v2) * (n + 1) + v3


def _xor_desc(a: List[Int], b: List[Int]) -> List[Int]:
    """Symmetric difference of two descending-sorted unique lists."""
    var out = List[Int]()
    var i = 0
    var j = 0
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            i += 1
            j += 1
        elif a[i] > b[j]:
            out.append(a[i])
            i += 1
        else:
            out.append(b[j])
            j += 1
    while i < len(a):
        out.append(a[i])
        i += 1
    while j < len(b):
        out.append(b[j])
        j += 1
    return out.copy()


def _pivot_slot(pivr: List[Int], low: Int) -> Int:
    for t in range(len(pivr)):
        if pivr[t] == low:
            return t
    return -1


struct PersBars(Copyable, Movable):
    """Rips persistence bars over the FULL filtration (H0/H1/H2)."""

    var dim: List[Int]
    var birth: List[Float64]
    var death: List[Float64]
    var capped: Bool

    def __init__(out self):
        self.dim = List[Int]()
        self.birth = List[Float64]()
        self.death = List[Float64]()
        self.capped = False


struct SimplexFiltration(Copyable, Movable):
    var sd: List[Int]
    var sw: List[Float64]
    var sv: List[List[Int]]

    def __init__(out self):
        self.sd = List[Int]()
        self.sw = List[Float64]()
        self.sv = List[List[Int]]()


def _keep_lightest(
    mut tw: List[Float64],
    mut tv: List[List[Int]],
    cap: Int,
) -> Bool:
    """Trim (tw, tv) pairs to the cap lightest weights. Returns trimmed."""
    if len(tw) <= cap:
        return False
    var kept_w = List[Float64]()
    var kept_v = List[List[Int]]()
    var have_max = False
    var maxw = 0.0
    var maxp = 0
    for i in range(len(tw)):
        if len(kept_w) < cap:
            kept_w.append(tw[i])
            kept_v.append(tv[i].copy())
            if not have_max or tw[i] > maxw:
                maxw = tw[i]
                maxp = len(kept_w) - 1
                have_max = True
        elif tw[i] < maxw:
            kept_w[maxp] = tw[i]
            kept_v[maxp] = tv[i].copy()
            maxw = kept_w[0]
            maxp = 0
            for t in range(1, len(kept_w)):
                if kept_w[t] > maxw:
                    maxw = kept_w[t]
                    maxp = t
    tw = kept_w.copy()
    tv = kept_v.copy()
    return True


def _rips_filtration(dm: List[List[Float64]], n: Int) -> SimplexFiltration:
    """All verts + edges, lightest tris/tets (closure-safe for tets)."""
    var f = SimplexFiltration()
    if n < 2 or len(dm) != n:
        return f^
    for i in range(n):
        f.sd.append(0)
        f.sw.append(0.0)
        var v = List[Int]()
        v.append(i)
        f.sv.append(v^)
    for i in range(n):
        for j in range(i + 1, n):
            f.sd.append(1)
            f.sw.append(dm[i][j])
            var v = List[Int]()
            v.append(i)
            v.append(j)
            f.sv.append(v^)
    var tw = List[Float64]()
    var tv = List[List[Int]]()
    for i in range(n):
        for j in range(i + 1, n):
            for k in range(j + 1, n):
                var w = dm[i][j]
                if dm[i][k] > w:
                    w = dm[i][k]
                if dm[j][k] > w:
                    w = dm[j][k]
                tw.append(w)
                var v = List[Int]()
                v.append(i)
                v.append(j)
                v.append(k)
                tv.append(v^)
    _ = _keep_lightest(tw, tv, PERS_TRI_CAP)
    for t in range(len(tw)):
        f.sd.append(2)
        f.sw.append(tw[t])
        f.sv.append(tv[t].copy())
    # Tets only where all 4 faces survived the tri cap (closure).
    var tri_kept = Dict[Int, Bool]()
    for t in range(len(tv)):
        var vv = tv[t].copy()
        var key = _simp_key(vv[0] + 1, vv[1] + 1, vv[2] + 1, 0, n)
        tri_kept[key] = True
    var uw = List[Float64]()
    var uv = List[List[Int]]()
    for i in range(n):
        for j in range(i + 1, n):
            for k in range(j + 1, n):
                for m in range(k + 1, n):
                    var ok = True
                    try:
                        _ = tri_kept[
                            _simp_key(j + 1, k + 1, m + 1, 0, n)
                        ]
                        _ = tri_kept[
                            _simp_key(i + 1, k + 1, m + 1, 0, n)
                        ]
                        _ = tri_kept[
                            _simp_key(i + 1, j + 1, m + 1, 0, n)
                        ]
                        _ = tri_kept[
                            _simp_key(i + 1, j + 1, k + 1, 0, n)
                        ]
                    except:
                        ok = False
                    if not ok:
                        continue
                    var w = dm[i][j]
                    if dm[i][k] > w:
                        w = dm[i][k]
                    if dm[i][m] > w:
                        w = dm[i][m]
                    if dm[j][k] > w:
                        w = dm[j][k]
                    if dm[j][m] > w:
                        w = dm[j][m]
                    if dm[k][m] > w:
                        w = dm[k][m]
                    uw.append(w)
                    var v = List[Int]()
                    v.append(i)
                    v.append(j)
                    v.append(k)
                    v.append(m)
                    uv.append(v^)
    _ = _keep_lightest(uw, uv, PERS_TET_CAP)
    for t in range(len(uw)):
        f.sd.append(3)
        f.sw.append(uw[t])
        f.sv.append(uv[t].copy())
    return f^


def persistence_bars(dm: List[List[Float64]], n: Int) -> PersBars:
    """Rips persistence (H0/H1/H2) via standard column reduction.

    Simplices ordered by (weight, dim); each dim-d column reduces against
    recorded pivots. capped=True when the tri/tet caps dropped simplices
    (bars still valid as a sparsified-filtration approximation).
    """
    var res = PersBars()
    var f = _rips_filtration(dm, n)
    var nsim = len(f.sd)
    if nsim == 0:
        return res^
    var ntri = (n * (n - 1) * (n - 2)) // 6 if n >= 3 else 0
    var ntet = (n * (n - 1) * (n - 2) * (n - 3)) // 24 if n >= 4 else 0
    var ktri = 0
    var ktet = 0
    for s in range(nsim):
        if f.sd[s] == 2:
            ktri += 1
        elif f.sd[s] == 3:
            ktet += 1
    res.capped = ktri < ntri or ktet < ntet
    var order = List[Int]()
    for s in range(nsim):
        order.append(s)
    for i in range(len(order)):
        var best = i
        for j in range(i + 1, len(order)):
            var a = order[j]
            var b = order[best]
            if f.sw[a] < f.sw[b] or (
                f.sw[a] == f.sw[b] and f.sd[a] < f.sd[b]
            ):
                best = j
        if best != i:
            var t = order[i]
            order[i] = order[best]
            order[best] = t
    var pos = List[Int]()
    for s in range(nsim):
        pos.append(0)
    for r in range(nsim):
        pos[order[r]] = r
    var fmap = Dict[Int, Int]()
    for s in range(nsim):
        var vv = f.sv[s].copy()
        var a0 = 0
        var a1 = 0
        var a2 = 0
        var a3 = 0
        if len(vv) > 0:
            a0 = vv[0] + 1
        if len(vv) > 1:
            a1 = vv[1] + 1
        if len(vv) > 2:
            a2 = vv[2] + 1
        if len(vv) > 3:
            a3 = vv[3] + 1
        fmap[_simp_key(a0, a1, a2, a3, n)] = pos[s]
    var bw = List[Float64]()
    var bd = List[Int]()
    for r in range(nsim):
        bw.append(f.sw[order[r]])
        bd.append(f.sd[order[r]])
    var bnd = List[List[Int]]()
    for r in range(nsim):
        var vv = f.sv[order[r]].copy()
        var faces = List[Int]()
        if len(vv) == 2:
            faces.append(pos[vv[0]])
            faces.append(pos[vv[1]])
            # Reorder descending.
            if faces[1] > faces[0]:
                var t = faces[0]
                faces[0] = faces[1]
                faces[1] = t
        elif len(vv) == 3:
            try:
                faces.append(
                    fmap[_simp_key(vv[1] + 1, vv[2] + 1, 0, 0, n)]
                )
                faces.append(
                    fmap[_simp_key(vv[0] + 1, vv[2] + 1, 0, 0, n)]
                )
                faces.append(
                    fmap[_simp_key(vv[0] + 1, vv[1] + 1, 0, 0, n)]
                )
            except:
                res.capped = True
            for i in range(len(faces)):
                for j in range(i + 1, len(faces)):
                    if faces[j] > faces[i]:
                        var t = faces[i]
                        faces[i] = faces[j]
                        faces[j] = t
        elif len(vv) == 4:
            try:
                faces.append(
                    fmap[
                        _simp_key(vv[1] + 1, vv[2] + 1, vv[3] + 1, 0, n)
                    ]
                )
                faces.append(
                    fmap[
                        _simp_key(vv[0] + 1, vv[2] + 1, vv[3] + 1, 0, n)
                    ]
                )
                faces.append(
                    fmap[
                        _simp_key(vv[0] + 1, vv[1] + 1, vv[3] + 1, 0, n)
                    ]
                )
                faces.append(
                    fmap[
                        _simp_key(vv[0] + 1, vv[1] + 1, vv[2] + 1, 0, n)
                    ]
                )
            except:
                res.capped = True
            for i in range(len(faces)):
                for j in range(i + 1, len(faces)):
                    if faces[j] > faces[i]:
                        var t = faces[i]
                        faces[i] = faces[j]
                        faces[j] = t
        bnd.append(faces^)
    # Reduce dim 1..3, collecting pairs, pivot rows, and positives.
    var pair_b = List[Float64]()
    var pair_d = List[Float64]()
    var pair_dim = List[Int]()
    var p1 = List[Int]()
    var p2 = List[Int]()
    var p3 = List[Int]()
    var z1 = List[Int]()
    var z2 = List[Int]()
    for dd in range(1, 4):
        var cols = List[Int]()
        for r in range(nsim):
            if bd[r] == dd:
                cols.append(r)
        var pivr = List[Int]()
        var pivc = List[List[Int]]()
        for c in range(len(cols)):
            var col = bnd[cols[c]].copy()
            while len(col) > 0:
                var slot = _pivot_slot(pivr, col[0])
                if slot < 0:
                    break
                col = _xor_desc(col, pivc[slot]).copy()
            if len(col) > 0:
                pair_b.append(bw[col[0]])
                pair_d.append(bw[cols[c]])
                pair_dim.append(dd - 1)
                pivr.append(col[0])
                pivc.append(col^)
            else:
                if dd == 1:
                    z1.append(cols[c])
                elif dd == 2:
                    z2.append(cols[c])
        if dd == 1:
            p1 = pivr.copy()
        elif dd == 2:
            p2 = pivr.copy()
        else:
            p3 = pivr.copy()
    # Infinite bars: positive dim-d columns never appearing as pivot rows.
    # Positive edges birth H1, positive triangles birth H2.
    for z in range(len(z1)):
        if _pivot_slot(p2, z1[z]) < 0:
            res.dim.append(1)
            res.birth.append(bw[z1[z]])
            res.death.append(-1.0)
    for z in range(len(z2)):
        if _pivot_slot(p3, z2[z]) < 0:
            res.dim.append(2)
            res.birth.append(bw[z2[z]])
            res.death.append(-1.0)
    # H0 infinite: final component (the vertex never killed as a row).
    var killed0 = List[Int]()
    for t in range(len(p1)):
        killed0.append(p1[t])
    var ncomp = 0
    for r in range(nsim):
        if bd[r] == 0 and _pivot_slot(killed0, r) < 0:
            ncomp += 1
            if ncomp == 1:
                res.dim.append(0)
                res.birth.append(bw[r])
                res.death.append(-1.0)
    for p in range(len(pair_b)):
        if pair_d[p] - pair_b[p] < 1e-9:
            continue
        res.dim.append(pair_dim[p])
        res.birth.append(pair_b[p])
        res.death.append(pair_d[p])
    return res^


struct BettiCurve(Copyable, Movable):
    """Betti numbers at k scales from 0 to max distance."""

    var scales: List[Float64]
    var b0: List[Int]
    var b1: List[Int]
    var b2: List[Int]

    def __init__(out self):
        self.scales = List[Float64]()
        self.b0 = List[Int]()
        self.b1 = List[Int]()
        self.b2 = List[Int]()


def betti_curve(dm: List[List[Float64]], n: Int, k: Int) raises -> BettiCurve:
    """VR Betti numbers at k evenly spaced scales (vec space)."""
    var res = BettiCurve()
    if n < 2 or len(dm) != n:
        return res^
    var kk = k
    if kk < 2:
        kk = 2
    if kk > 32:
        kk = 32
    var maxd = 0.0
    for i in range(n):
        for j in range(i + 1, n):
            if dm[i][j] > maxd:
                maxd = dm[i][j]
    for t in range(kk):
        var eps = maxd * Float64(t) / Float64(kk - 1)
        if t == kk - 1:
            eps = maxd * 1.000001
        var c = vr_complex(dm, n, eps)
        var b = vr_betti(n, c, True)
        res.scales.append(eps)
        res.b0.append(b.b0)
        res.b1.append(b.b1)
        res.b2.append(b.b2)
    return res^


struct LoopSet(Copyable, Movable):
    """Loop member cycles (map space) + a void ball."""

    var loops: List[List[Int]]
    var b1: Int
    var void_x: Float64
    var void_y: Float64
    var void_r: Float64
    var has_void: Bool

    def __init__(out self):
        self.loops = List[List[Int]]()
        self.b1 = 0
        self.void_x = 0.0
        self.void_y = 0.0
        self.void_r = 0.0
        self.has_void = False


def topo_loops(
    xs: List[Float64], ys: List[Float64], max_loops: Int
) raises -> LoopSet:
    """Loop members over map points at median pair distance.

    B1 cycle basis via nullspace vector + component walks; void ball
    from H2 triangle centroids when the complex encloses volume.
    """
    var res = LoopSet()
    var n = len(xs)
    if n < 4 or len(ys) != n:
        return res^
    var dm = List[List[Float64]]()
    var dists = List[Float64]()
    for i in range(n):
        var row = List[Float64]()
        for j in range(n):
            var dx = xs[i] - xs[j]
            var dy = ys[i] - ys[j]
            var d2 = dx * dx + dy * dy
            row.append(d2)
            if j > i:
                dists.append(d2)
        dm.append(row^)
    var mse = percentile(dists, 50.0)
    var c = vr_complex(dm, n, mse)
    var b = vr_betti(n, c, True)
    res.b1 = b.b1
    if b.b1 > 0 and len(c.edges) > 0:
        var nrow = n
        var ncol = len(c.edges)
        var b1m = List[List[Float64]]()
        for _ in range(nrow):
            var row = List[Float64]()
            for _ in range(ncol):
                row.append(0.0)
            b1m.append(row^)
        for e in range(ncol):
            var edge = c.edges[e].copy()
            var ri = b1m[edge[0]].copy()
            ri[e] = 1.0
            b1m[edge[0]] = ri^
            var rj = b1m[edge[1]].copy()
            rj[e] = -1.0
            b1m[edge[1]] = rj^
        var w = List[Float64]()
        if mat_null_vector(b1m, 1e-9, w):
            var maxw = 0.0
            for e in range(ncol):
                var a = w[e]
                if a < 0.0:
                    a = -a
                if a > maxw:
                    maxw = a
            var thr = maxw * 1e-6
            var adj = List[List[Int]]()
            var adjw = List[List[Float64]]()
            for _ in range(n):
                adj.append(List[Int]())
                adjw.append(List[Float64]())
            for e in range(ncol):
                var a = w[e]
                if a < 0.0:
                    a = -a
                if a <= thr:
                    continue
                var ev = c.edges[e].copy()
                var u = ev[0]
                var v = ev[1]
                var lu = adj[u].copy()
                var wu = adjw[u].copy()
                lu.append(v)
                wu.append(a)
                adj[u] = lu^
                adjw[u] = wu^
                var lv = adj[v].copy()
                var wv = adjw[v].copy()
                lv.append(u)
                wv.append(a)
                adj[v] = lv^
                adjw[v] = wv^
            var seen = List[Int]()
            for _ in range(n):
                seen.append(0)
            var comps = List[List[Int]]()
            for i in range(n):
                if seen[i] != 0 or len(adj[i]) == 0:
                    continue
                var comp = List[Int]()
                var stack = List[Int]()
                stack.append(i)
                seen[i] = 1
                while len(stack) > 0:
                    var cur = stack[len(stack) - 1]
                    _ = stack.pop()
                    comp.append(cur)
                    for t in range(len(adj[cur])):
                        if seen[adj[cur][t]] == 0:
                            seen[adj[cur][t]] = 1
                            stack.append(adj[cur][t])
                comps.append(comp^)
            for a in range(len(comps)):
                for cc in range(a + 1, len(comps)):
                    if len(comps[cc]) > len(comps[a]):
                        var t = comps[a].copy()
                        comps[a] = comps[cc].copy()
                        comps[cc] = t^
            var ml = max_loops
            if ml < 1:
                ml = 1
            if ml > 12:
                ml = 12
            var taken = 0
            for ci in range(len(comps)):
                if taken >= ml:
                    break
                var comp = comps[ci].copy()
                if len(comp) < 3:
                    continue
                var start = comp[0]
                for t in range(1, len(comp)):
                    if comp[t] < start:
                        start = comp[t]
                var path = List[Int]()
                path.append(start)
                var prev = -1
                var cur = start
                while True:
                    var best = -1
                    var bestw = 0.0
                    for t in range(len(adj[cur])):
                        var nb = adj[cur][t]
                        if nb == prev:
                            continue
                        if nb == start and len(path) > 2:
                            best = nb
                            break
                        var used = False
                        for q in range(len(path)):
                            if path[q] == nb:
                                used = True
                        if used:
                            continue
                        if best < 0 or adjw[cur][t] > bestw:
                            best = nb
                            bestw = adjw[cur][t]
                    if best < 0:
                        break
                    if best == start:
                        break
                    path.append(best)
                    prev = cur
                    cur = best
                    if len(path) > len(comp) + 1:
                        break
                if len(path) >= 3:
                    res.loops.append(path^)
                    taken += 1
    if b.b2 > 0 and len(c.tris) > 0:
        var tcx = 0.0
        var tcy = 0.0
        var tcnt = 0
        var lim = len(c.tris)
        if lim > 10:
            lim = 10
        for t in range(lim):
            var tr = c.tris[t].copy()
            tcx += (xs[tr[0]] + xs[tr[1]] + xs[tr[2]]) / 3.0
            tcy += (ys[tr[0]] + ys[tr[1]] + ys[tr[2]]) / 3.0
            tcnt += 1
        if tcnt > 0:
            var cx = tcx / Float64(tcnt)
            var cy = tcy / Float64(tcnt)
            var rr = 0.0
            for i in range(n):
                var dx = xs[i] - cx
                var dy = ys[i] - cy
                rr += dx * dx + dy * dy
            rr = sqrt(rr / Float64(n)) * 0.5
            res.void_x = cx
            res.void_y = cy
            res.void_r = rr
            res.has_void = True
    return res^
