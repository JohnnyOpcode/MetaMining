"""Tests for metamining.steering."""

from std.testing import assert_equal, assert_true

from metamining.steering import (
    contrast_themes,
    momentum_blend,
    momentum_dir,
    ortho_project,
    pca_subspace,
    topo_steer,
)


def test_subspace() raises:
    var hist = List[List[Float64]]()
    for i in range(20):
        var p = List[Float64]()
        p.append(Float64(i))
        p.append(Float64(i) * 0.01)
        p.append(0.0)
        hist.append(p.copy())
    var comps = List[List[Float64]]()
    pca_subspace(hist, 3, comps)
    assert_equal(len(comps), 3)
    assert_true(comps[0][0] > 0.99 or comps[0][0] < -0.99)
    var short = List[List[Float64]]()
    var one = List[Float64]()
    one.append(1.0)
    one.append(0.0)
    short.append(one.copy())
    short.append(one.copy())
    var none_out = List[List[Float64]]()
    pca_subspace(short, 3, none_out)
    assert_equal(len(none_out), 0)
    print("subspace ok")


def test_ortho() raises:
    var cand = List[Float64]()
    cand.append(1.0)
    cand.append(1.0)
    cand.append(0.0)
    var comps = List[List[Float64]]()
    var c0 = List[Float64]()
    c0.append(1.0)
    c0.append(0.0)
    c0.append(0.0)
    comps.append(c0.copy())
    var out = List[Float64]()
    ortho_project(cand, comps, out)
    assert_true(out[0] < 1e-9 and out[0] > -1e-9)
    assert_true(out[1] > 1.0 - 1e-9 and out[1] < 1.0 + 1e-9)
    print("ortho ok")


def test_topo() raises:
    var cand = List[Float64]()
    cand.append(1.0)
    cand.append(0.0)
    var cyc = List[Float64]()
    cyc.append(0.70710678)
    cyc.append(0.70710678)
    var novec = List[Float64]()
    var out = List[Float64]()
    topo_steer(cand, cyc, True, novec, False, 0.5, out)
    assert_true(out[1] < -0.3)
    var cand2 = List[Float64]()
    cand2.append(1.0)
    cand2.append(0.0)
    var voidc = List[Float64]()
    voidc.append(0.0)
    voidc.append(1.0)
    var out2 = List[Float64]()
    topo_steer(cand2, novec, False, voidc, True, 0.5, out2)
    assert_true(out2[1] > 0.1)
    print("topo ok")


def test_momentum() raises:
    var cand = List[Float64]()
    cand.append(1.0)
    cand.append(0.0)
    cand.append(0.0)
    var golds = List[List[Float64]]()
    var g = List[Float64]()
    g.append(0.0)
    g.append(1.0)
    g.append(0.0)
    golds.append(g.copy())
    golds.append(g.copy())
    var m = List[Float64]()
    assert_true(momentum_dir(golds, cand, m))
    assert_true(m[0] < -0.7 and m[1] > 0.7)
    var out = List[Float64]()
    momentum_blend(cand, golds, 0.25, out)
    assert_true(out[1] > 0.29 and out[1] < 0.30)
    var empty = List[List[Float64]]()
    var m2 = List[Float64]()
    assert_true(not momentum_dir(empty, cand, m2))
    var out2 = List[Float64]()
    momentum_blend(cand, empty, 0.25, out2)
    assert_equal(out2[0], 1.0)
    print("momentum ok")


def test_contrast() raises:
    var s = List[Float64]()
    s.append(1.0)
    s.append(0.0)
    var vecs = List[List[Float64]]()
    var a = List[Float64]()
    a.append(1.0)
    a.append(0.0)
    var b = List[Float64]()
    b.append(0.0)
    b.append(1.0)
    var c = List[Float64]()
    c.append(-1.0)
    c.append(0.0)
    vecs.append(a.copy())
    vecs.append(b.copy())
    vecs.append(c.copy())
    var concepts = List[String]()
    concepts.append("a")
    concepts.append("b")
    concepts.append("c")
    var out = List[String]()
    contrast_themes(s, vecs, concepts, 2, out)
    assert_equal(len(out), 2)
    assert_equal(out[0], "c")
    assert_equal(out[1], "b")
    print("contrast ok")


def main() raises:
    test_subspace()
    test_ortho()
    test_topo()
    test_momentum()
    test_contrast()
    print("ALL STEERING TESTS PASSED")
