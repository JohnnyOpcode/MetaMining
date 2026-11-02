"""Tests for metamining.linalg: vec ops, PCA, rank, nullspace."""

from std.math import abs
from std.testing import assert_equal, assert_true

from metamining.linalg import (
    cov_apply,
    cov_qf,
    mat_null_vector,
    mat_rank,
    pca_fit,
    pca_project,
    percentile,
    vcos,
    vdist,
    vdot,
    vmean,
    vnorm,
    vnormalize,
    vsub,
)


def close(a: Float64, b: Float64, tol: Float64) raises:
    assert_true(abs(a - b) <= tol)


def test_vec() raises:
    var a = List[Float64]()
    a.append(1.0)
    a.append(2.0)
    a.append(3.0)
    var b = List[Float64]()
    b.append(4.0)
    b.append(5.0)
    b.append(6.0)
    assert_equal(vdot(a, b), 32.0)
    close(vnorm(a), 3.74165738677, 1e-9)
    close(vcos(a, a), 1.0, 1e-12)
    var e1 = List[Float64]()
    e1.append(1.0)
    e1.append(0.0)
    var e2 = List[Float64]()
    e2.append(0.0)
    e2.append(1.0)
    assert_equal(vcos(e1, e2), 0.0)
    close(vdist(e1, e2), 1.41421356237, 1e-9)
    var n = List[Float64]()
    vnormalize(a, n)
    close(vnorm(n), 1.0, 1e-12)
    var d = List[Float64]()
    vsub(b, a, d)
    assert_equal(d[0], 3.0)
    var m = List[Float64]()
    var pts = List[List[Float64]]()
    pts.append(a.copy())
    pts.append(b.copy())
    vmean(pts, m)
    assert_equal(m[0], 2.5)
    print("vec ok")


def line_points() -> List[List[Float64]]:
    var pts = List[List[Float64]]()
    for i in range(4):
        var p = List[Float64]()
        p.append(Float64(i))
        p.append(Float64(i))
        pts.append(p.copy())
    return pts.copy()


def test_pca_line() raises:
    # Points on y=x: top comp ±(0.7071, 0.7071), λ=10/3.
    var pts = line_points()
    var comps = List[List[Float64]]()
    var mean = List[Float64]()
    pca_fit(pts, 2, comps, mean)
    assert_equal(len(comps), 2)
    assert_equal(len(mean), 2)
    close(mean[0], 1.5, 1e-12)
    var c0 = comps[0].copy()
    close(abs(c0[0]), 0.70710678118, 1e-6)
    close(abs(c0[1]), 0.70710678118, 1e-6)
    close(cov_qf(pts, mean, c0), 3.3333333333, 1e-6)
    # Orthogonality + eigen residual.
    var c1 = comps[1].copy()
    close(abs(vdot(c0, c1)), 0.0, 1e-9)
    var av = List[Float64]()
    cov_apply(pts, mean, c0, av)
    var lam = cov_qf(pts, mean, c0)
    close(av[0], lam * c0[0], 1e-6)
    close(av[1], lam * c0[1], 1e-6)
    # Projection spreads along x, ~0 along y.
    var p0 = pca_project(pts[0], mean, comps)
    var p3 = pca_project(pts[3], mean, comps)
    close(abs(p0.x), 2.1213203435, 1e-6)
    close(abs(p0.y), 0.0, 1e-6)
    assert_true(p0.x * p3.x < 0.0)
    print("pca_line ok")


def test_pca_degenerate() raises:
    var pts = List[List[Float64]]()
    for _ in range(5):
        var p = List[Float64]()
        p.append(1.0)
        p.append(1.0)
        pts.append(p.copy())
    var comps = List[List[Float64]]()
    var mean = List[Float64]()
    pca_fit(pts, 2, comps, mean)
    assert_equal(len(comps), 0)
    var one = List[List[Float64]]()
    var q = List[Float64]()
    q.append(3.0)
    one.append(q.copy())
    var c2 = List[List[Float64]]()
    var m2 = List[Float64]()
    pca_fit(one, 2, c2, m2)
    assert_equal(len(c2), 0)
    print("pca_degenerate ok")


def mat(rows: List[List[Float64]]) -> List[List[Float64]]:
    return rows.copy()


def test_rank() raises:
    var eye = List[List[Float64]]()
    for i in range(3):
        var r = List[Float64]()
        for j in range(3):
            r.append(1.0 if i == j else 0.0)
        eye.append(r.copy())
    assert_equal(mat_rank(eye, 1e-9), 3)
    var dep = List[List[Float64]]()
    var r1 = List[Float64]()
    r1.append(1.0)
    r1.append(2.0)
    var r2 = List[Float64]()
    r2.append(2.0)
    r2.append(4.0)
    dep.append(r1.copy())
    dep.append(r2.copy())
    assert_equal(mat_rank(dep, 1e-9), 1)
    var z = List[List[Float64]]()
    var zr = List[Float64]()
    zr.append(0.0)
    zr.append(0.0)
    z.append(zr.copy())
    z.append(zr.copy())
    assert_equal(mat_rank(z, 1e-9), 0)
    # Path-graph B1 (3 nodes, 2 edges): rank 2.
    var b1 = List[List[Float64]]()
    var b1r0 = List[Float64]()
    b1r0.append(-1.0)
    b1r0.append(0.0)
    var b1r1 = List[Float64]()
    b1r1.append(1.0)
    b1r1.append(-1.0)
    var b1r2 = List[Float64]()
    b1r2.append(0.0)
    b1r2.append(1.0)
    b1.append(b1r0.copy())
    b1.append(b1r1.copy())
    b1.append(b1r2.copy())
    assert_equal(mat_rank(b1, 1e-9), 2)
    assert_equal(mat_rank(List[List[Float64]](), 1e-9), 0)
    print("rank ok")


def test_null() raises:
    var dep = List[List[Float64]]()
    var r1 = List[Float64]()
    r1.append(1.0)
    r1.append(2.0)
    var r2 = List[Float64]()
    r2.append(2.0)
    r2.append(4.0)
    dep.append(r1.copy())
    dep.append(r2.copy())
    var out = List[Float64]()
    assert_true(mat_null_vector(dep, 1e-9, out))
    assert_equal(len(out), 2)
    # A @ out == 0 and out != 0.
    close(dep[0][0] * out[0] + dep[0][1] * out[1], 0.0, 1e-9)
    close(dep[1][0] * out[0] + dep[1][1] * out[1], 0.0, 1e-9)
    assert_true(vnorm(out) > 0.5)
    var eye = List[List[Float64]]()
    var er = List[Float64]()
    er.append(1.0)
    er.append(0.0)
    var er2 = List[Float64]()
    er2.append(0.0)
    er2.append(1.0)
    eye.append(er.copy())
    eye.append(er2.copy())
    var out2 = List[Float64]()
    assert_true(not mat_null_vector(eye, 1e-9, out2))
    print("null ok")


def test_percentile() raises:
    var v = List[Float64]()
    v.append(4.0)
    v.append(1.0)
    v.append(3.0)
    v.append(2.0)
    assert_equal(percentile(v, 0.0), 1.0)
    assert_equal(percentile(v, 100.0), 4.0)
    assert_equal(percentile(v, 50.0), 2.5)
    assert_equal(percentile(List[Float64](), 50.0), 0.0)
    print("percentile ok")


def main() raises:
    test_vec()
    test_pca_line()
    test_pca_degenerate()
    test_null()
    test_rank()
    test_percentile()
    print("ALL LINALG TESTS PASSED")
