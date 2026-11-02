"""Small dense linear algebra over List vectors: pure Mojo, no deps.

Vectors are List[Float64]; matrices are row-major List[List[Float64]].
Out-params use append semantics: pass a fresh list. Deterministic:
no RNG anywhere (fixed iteration counts, fixed start vectors).
"""

from std.math import abs, sqrt


def vdot(a: List[Float64], b: List[Float64]) -> Float64:
    var n = len(a)
    if len(b) < n:
        n = len(b)
    var s = 0.0
    for i in range(n):
        s += a[i] * b[i]
    return s


def vnorm(a: List[Float64]) -> Float64:
    return sqrt(vdot(a, a))


def vcos(a: List[Float64], b: List[Float64]) -> Float64:
    var na = vnorm(a)
    var nb = vnorm(b)
    if na <= 1e-18 or nb <= 1e-18:
        return 0.0
    var c = vdot(a, b) / (na * nb)
    if c > 1.0:
        c = 1.0
    if c < -1.0:
        c = -1.0
    return c


def vdist(a: List[Float64], b: List[Float64]) -> Float64:
    var n = len(a)
    if len(b) < n:
        n = len(b)
    var s = 0.0
    for i in range(n):
        var d = a[i] - b[i]
        s += d * d
    return sqrt(s)


def vnormalize(a: List[Float64], mut out: List[Float64]):
    var n = vnorm(a)
    if n <= 1e-18:
        for _ in range(len(a)):
            out.append(0.0)
        return
    for i in range(len(a)):
        out.append(a[i] / n)


def vsub(a: List[Float64], b: List[Float64], mut out: List[Float64]):
    var n = len(a)
    if len(b) < n:
        n = len(b)
    for i in range(n):
        out.append(a[i] - b[i])


def vmean(vecs: List[List[Float64]], mut out: List[Float64]):
    if len(vecs) == 0:
        return
    var d = len(vecs[0])
    for j in range(d):
        var s = 0.0
        for i in range(len(vecs)):
            if j < len(vecs[i]):
                s += vecs[i][j]
        out.append(s / Float64(len(vecs)))


def _normalize_ip(mut v: List[Float64]):
    var n = vnorm(v)
    if n <= 1e-18:
        return
    for j in range(len(v)):
        v[j] = v[j] / n


def cov_apply(
    pts: List[List[Float64]], mean: List[Float64], v: List[Float64], mut out: List[Float64]
):
    """out = A v with A the implicit sample covariance (no d×d matrix)."""
    var n = len(pts)
    var d = len(v)
    var t = List[Float64]()
    for i in range(n):
        var s = 0.0
        for j in range(d):
            if j < len(pts[i]) and j < len(mean):
                s += (pts[i][j] - mean[j]) * v[j]
        t.append(s)
    var denom = Float64(n - 1)
    if denom < 1.0:
        denom = 1.0
    for j in range(d):
        var s = 0.0
        for i in range(n):
            if j < len(pts[i]) and j < len(mean):
                s += (pts[i][j] - mean[j]) * t[i]
        out.append(s / denom)


def cov_qf(pts: List[List[Float64]], mean: List[Float64], v: List[Float64]) -> Float64:
    """Quadratic form v^T A v under the implicit covariance (Rayleigh)."""
    var av = List[Float64]()
    cov_apply(pts, mean, v, av)
    return vdot(v, av)


def pca_fit(
    pts: List[List[Float64]], k: Int, mut comps: List[List[Float64]], mut mean: List[Float64]
):
    """Top-k PCA components via power iteration + Hotelling deflation.

    Appends k orthonormal components (fewer/zero when degenerate) and
    the mean vector. Fixed 150 iterations: fully deterministic.
    """
    var n = len(pts)
    if n < 2 or k < 1:
        return
    var d = len(pts[0])
    if d < 1:
        return
    vmean(pts, mean)
    var tot = 0.0
    for i in range(n):
        for j in range(d):
            if j < len(pts[i]):
                var c = pts[i][j] - mean[j]
                tot += c * c
    if tot <= 1e-18:
        return
    var lams = List[Float64]()
    for _ in range(k):
        var v = List[Float64]()
        for j in range(d):
            v.append(Float64(j + 1))
        _normalize_ip(v)
        for q in range(len(comps)):
            var cq = comps[q].copy()
            var dp = vdot(v, cq)
            for j in range(d):
                v[j] = v[j] - dp * cq[j]
        _normalize_ip(v)
        # Scale-relative breakdown: cancellation dust sits ~1e-15 for
        # unit-scale data, so an absolute 1e-18 never trips. Scale by
        # the top eigenvalue (exact from round 1 on, estimated at 0).
        var pscale = cov_qf(pts, mean, v)
        if len(lams) > 0 and lams[0] > pscale:
            pscale = lams[0]
        var wtol = 1e-12 * pscale
        if wtol < 1e-30:
            wtol = 1e-30
        for _ in range(150):
            var w = List[Float64]()
            cov_apply(pts, mean, v, w)
            for q in range(len(comps)):
                var cq = comps[q].copy()
                var dp = vdot(v, cq)
                var lq = lams[q]
                for j in range(d):
                    w[j] = w[j] - lq * dp * cq[j]
            var nw = vnorm(w)
            if nw <= wtol:
                break
            for j in range(d):
                v[j] = w[j] / nw
        lams.append(cov_qf(pts, mean, v))
        comps.append(v^)


struct P2(ImplicitlyCopyable):
    var x: Float64
    var y: Float64

    def __init__(out self, x: Float64, y: Float64):
        self.x = x
        self.y = y


def pca_project(
    pt: List[Float64], mean: List[Float64], comps: List[List[Float64]]
) -> P2:
    var x = 0.0
    var y = 0.0
    if len(comps) > 0:
        var c0 = comps[0].copy()
        for j in range(len(c0)):
            if j < len(pt) and j < len(mean):
                x += (pt[j] - mean[j]) * c0[j]
    if len(comps) > 1:
        var c1 = comps[1].copy()
        for j in range(len(c1)):
            if j < len(pt) and j < len(mean):
                y += (pt[j] - mean[j]) * c1[j]
    return P2(x, y)


def pca_z(pt: List[Float64], mean: List[Float64], comps: List[List[Float64]]) -> Float64:
    var z = 0.0
    if len(comps) > 2:
        var c2 = comps[2].copy()
        for j in range(len(c2)):
            if j < len(pt) and j < len(mean):
                z += (pt[j] - mean[j]) * c2[j]
    return z


def _copy_mat(a: List[List[Float64]], mut out: List[List[Float64]]):
    for i in range(len(a)):
        var row = List[Float64]()
        for j in range(len(a[i])):
            row.append(a[i][j])
        out.append(row^)


def mat_rank(a: List[List[Float64]], tol: Float64) -> Int:
    """Rank via Gaussian elimination with partial pivoting."""
    var m = List[List[Float64]]()
    _copy_mat(a, m)
    var rows = len(m)
    if rows == 0:
        return 0
    var cols = len(m[0])
    var rank = 0
    var r = 0
    for c in range(cols):
        var piv = r
        var best = 0.0
        for p in range(r, rows):
            var srow = m[p].copy()
            var av = abs(srow[c])
            if av > best:
                best = av
                piv = p
        if best <= tol:
            continue
        if piv != r:
            var ra = m[r].copy()
            var rb = m[piv].copy()
            m[r] = rb^
            m[piv] = ra^
        var prow = m[r].copy()
        var pivv = prow[c]
        for p in range(r + 1, rows):
            var erow = m[p].copy()
            var f = erow[c] / pivv
            if f != 0.0:
                for q in range(c, cols):
                    erow[q] = erow[q] - f * prow[q]
                m[p] = erow^
        r += 1
        rank += 1
        if r >= rows:
            break
    return rank


def mat_null_vector(
    a: List[List[Float64]], tol: Float64, mut out: List[Float64]
) -> Bool:
    """One nullspace vector via RREF + back-substitution.

    Returns False when the nullspace is trivial (full column rank).
    """
    var m = List[List[Float64]]()
    _copy_mat(a, m)
    var rows = len(m)
    if rows == 0:
        return False
    var cols = len(m[0])
    if cols == 0:
        return False
    var pivcol = List[Int]()
    var r = 0
    for c in range(cols):
        var piv = r
        var best = 0.0
        for p in range(r, rows):
            var srow = m[p].copy()
            var av = abs(srow[c])
            if av > best:
                best = av
                piv = p
        if best <= tol:
            continue
        if piv != r:
            var ra = m[r].copy()
            var rb = m[piv].copy()
            m[r] = rb^
            m[piv] = ra^
        var prow = m[r].copy()
        var pivv = prow[c]
        for p in range(r + 1, rows):
            var erow = m[p].copy()
            var f = erow[c] / pivv
            if f != 0.0:
                for q in range(c, cols):
                    erow[q] = erow[q] - f * prow[q]
                m[p] = erow^
        pivcol.append(c)
        r += 1
        if r >= rows:
            break
    var rank = len(pivcol)
    if rank >= cols:
        return False
    var is_piv = List[Bool]()
    for _ in range(cols):
        is_piv.append(False)
    for k in range(rank):
        is_piv[pivcol[k]] = True
    var free = 0
    for c in range(cols):
        if not is_piv[c]:
            free = c
    var x = List[Float64]()
    for _ in range(cols):
        x.append(0.0)
    x[free] = 1.0
    for ri in range(rank):
        var row = rank - 1 - ri
        var pc = pivcol[row]
        var grow = m[row].copy()
        var s = 0.0
        for j in range(pc + 1, cols):
            s += grow[j] * x[j]
        x[pc] = -s / grow[pc]
    for c in range(cols):
        out.append(x[c])
    return True


def percentile(vals: List[Float64], p: Float64) -> Float64:
    var n = len(vals)
    if n == 0:
        return 0.0
    var s = List[Float64]()
    for i in range(n):
        s.append(vals[i])
    for i in range(1, n):
        var key = s[i]
        var j = i - 1
        while j >= 0 and s[j] > key:
            s[j + 1] = s[j]
            j -= 1
        s[j + 1] = key
    var rank = p / 100.0 * Float64(n - 1)
    var lo = Int(rank)
    if lo < 0:
        lo = 0
    if lo >= n - 1:
        return s[n - 1]
    var frac = rank - Float64(lo)
    return s[lo] + frac * (s[lo + 1] - s[lo])
