"""Tests for metamining.topo: exact Betti numbers + pipeline invariants."""

from std.testing import assert_equal, assert_true

from metamining.topo import (
    betti_curve,
    mapper_graph,
    merge_tree,
    persistence_bars,
    topo_compute,
    topo_loops,
    traj_curvature,
)


def pt2(x: Float64, y: Float64) -> List[Float64]:
    var p = List[Float64]()
    p.append(x)
    p.append(y)
    return p.copy()


def pt3(x: Float64, y: Float64, z: Float64) -> List[Float64]:
    var p = List[Float64]()
    p.append(x)
    p.append(y)
    p.append(z)
    return p.copy()


def square() -> List[List[Float64]]:
    var pts = List[List[Float64]]()
    pts.append(pt2(0.0, 0.0))
    pts.append(pt2(1.0, 0.0))
    pts.append(pt2(1.0, 1.0))
    pts.append(pt2(0.0, 1.0))
    return pts.copy()


def octahedron() -> List[List[Float64]]:
    var pts = List[List[Float64]]()
    pts.append(pt3(1.0, 0.0, 0.0))
    pts.append(pt3(-1.0, 0.0, 0.0))
    pts.append(pt3(0.0, 1.0, 0.0))
    pts.append(pt3(0.0, -1.0, 0.0))
    pts.append(pt3(0.0, 0.0, 1.0))
    pts.append(pt3(0.0, 0.0, -1.0))
    return pts.copy()


def test_pipeline_square() raises:
    var r = topo_compute(square())
    assert_equal(r.b0, 1)
    assert_equal(r.b1, 1)
    assert_equal(r.b2, 0)
    # Closed loops telescope: sum_e w_e (p_j - p_i) = sum_i p_i (B1 w)_i = 0
    # for any w in ker B1, so the harmonic cycle direction is ~always
    # empty: closed-loop harmonic weights telescope to ~0 (1e-9 guard).
    assert_equal(len(r.cycle), 0)
    assert_equal(len(r.void), 0)
    assert_true(r.cd > 2.0 and r.cd < 3.0)
    assert_true(r.nov >= 0.0 and r.nov <= 1.0)
    print("pipeline_square ok")


def test_pipeline_octahedron() raises:
    var r = topo_compute(octahedron())
    assert_equal(r.b0, 1)
    assert_equal(r.b1, 0)
    assert_equal(r.b2, 1)
    assert_equal(len(r.void), 3)
    assert_true(r.entropy >= 0.0 and r.entropy <= 2.0001)
    print("pipeline_octahedron ok")


def test_degenerate() raises:
    var two = List[List[Float64]]()
    two.append(pt2(0.0, 0.0))
    two.append(pt2(5.0, 5.0))
    var r = topo_compute(two)
    assert_equal(r.b0, 2)
    assert_equal(r.b1, 0)
    var same = List[List[Float64]]()
    for _ in range(5):
        same.append(pt2(1.0, 1.0))
    var r2 = topo_compute(same)
    assert_equal(r2.b0, 1)
    assert_equal(r2.b1, 0)
    assert_equal(r2.b2, 0)
    assert_equal(r2.entropy, 0.0)
    assert_true(r2.nov < 0.05)
    print("degenerate ok")


def test_curvature() raises:
    var line = List[List[Float64]]()
    line.append(pt2(0.0, 0.0))
    line.append(pt2(1.0, 0.0))
    line.append(pt2(2.0, 0.0))
    line.append(pt2(3.0, 0.0))
    assert_true(traj_curvature(line) < 1e-9)
    var zig = List[List[Float64]]()
    zig.append(pt2(0.0, 0.0))
    zig.append(pt2(1.0, 1.0))
    zig.append(pt2(2.0, 0.0))
    zig.append(pt2(3.0, 1.0))
    var c = traj_curvature(zig)
    assert_true(c > 0.999 and c < 1.001)
    print("curvature ok")


def sq_dm(pts: List[List[Float64]]) -> List[List[Float64]]:
    var n = len(pts)
    var dm = List[List[Float64]]()
    for i in range(n):
        var row = List[Float64]()
        for j in range(n):
            var acc = 0.0
            for d in range(len(pts[i])):
                var dd = pts[i][d] - pts[j][d]
                acc += dd * dd
            row.append(acc)
        dm.append(row^)
    return dm.copy()


def test_persistence_square() raises:
    # Square: sides d2=1, diagonals d2=2. One H1 bar (1, 2).
    var dm = sq_dm(square())
    var bars = persistence_bars(dm, 4)
    assert_true(not bars.capped)
    var h1 = 0
    var h1b = 0.0
    var h1d = 0.0
    var h0inf = 0
    var h0fin = 0
    for i in range(len(bars.dim)):
        if bars.dim[i] == 1 and bars.death[i] >= 0.0:
            h1 += 1
            h1b = bars.birth[i]
            h1d = bars.death[i]
        if bars.dim[i] == 0 and bars.death[i] < 0.0:
            h0inf += 1
        if bars.dim[i] == 0 and bars.death[i] >= 0.0:
            h0fin += 1
    assert_equal(h1, 1)
    assert_true(h1b > 0.999 and h1b < 1.001)
    assert_true(h1d > 1.999 and h1d < 2.001)
    assert_equal(h0inf, 1)
    assert_equal(h0fin, 3)
    print("persistence square ok")


def test_persistence_triangle() raises:
    # Filled triangle: no H1, two finite H0 + one infinite H0.
    var pts = List[List[Float64]]()
    pts.append(pt2(0.0, 0.0))
    pts.append(pt2(1.0, 0.0))
    pts.append(pt2(0.5, 0.8660254))
    var bars = persistence_bars(sq_dm(pts), 3)
    assert_true(not bars.capped)
    var h1 = 0
    var h0inf = 0
    var h0fin = 0
    for i in range(len(bars.dim)):
        if bars.dim[i] == 1:
            h1 += 1
        if bars.dim[i] == 0 and bars.death[i] < 0.0:
            h0inf += 1
        if bars.dim[i] == 0 and bars.death[i] >= 0.0:
            h0fin += 1
    assert_equal(h1, 0)
    assert_equal(h0inf, 1)
    assert_equal(h0fin, 2)
    print("persistence triangle ok")


def test_persistence_capped() raises:
    # 30 points: 4060 tris exceed the cap; bars still well-formed.
    var pts = List[List[Float64]]()
    for i in range(30):
        pts.append(pt2(Float64(i) * 0.37, Float64(i % 5) * 0.11))
    var bars = persistence_bars(sq_dm(pts), 30)
    assert_true(bars.capped)
    var h0inf = 0
    for i in range(len(bars.dim)):
        if bars.dim[i] == 0 and bars.death[i] < 0.0:
            h0inf += 1
        if bars.death[i] >= 0.0:
            assert_true(bars.death[i] >= bars.birth[i])
    assert_equal(h0inf, 1)
    print("persistence capped ok")


def test_merge_tree_two_peaks() raises:
    var xs = List[Float64]()
    var ys = List[Float64]()
    var novs = List[Float64]()
    var bi = List[Int]()
    var si = List[Int]()
    var px = List[Float64]()
    px.append(0.0)
    px.append(0.1)
    px.append(0.0)
    px.append(10.0)
    px.append(10.1)
    px.append(10.0)
    var py = List[Float64]()
    py.append(0.0)
    py.append(0.0)
    py.append(0.1)
    py.append(10.0)
    py.append(10.0)
    py.append(10.1)
    var nv = List[Float64]()
    nv.append(0.9)
    nv.append(0.8)
    nv.append(0.7)
    nv.append(0.85)
    nv.append(0.75)
    nv.append(0.65)
    for i in range(6):
        xs.append(px[i])
        ys.append(py[i])
        novs.append(nv[i])
        bi.append(0)
        si.append(i)
    var t = merge_tree(xs, ys, novs, bi, si, 2)
    assert_equal(t.basin[0], t.basin[1])
    assert_equal(t.basin[1], t.basin[2])
    assert_equal(t.basin[3], t.basin[4])
    assert_equal(t.basin[4], t.basin[5])
    assert_true(t.basin[0] != t.basin[3])
    var npeaks = 0
    for i in range(6):
        npeaks += t.peak[i]
    assert_equal(npeaks, 2)
    assert_true(len(t.la) > 0)
    assert_equal(len(t.la), len(t.lb))
    print("merge tree ok")


def test_mapper_chain() raises:
    var xs = List[Float64]()
    var ys = List[Float64]()
    var lens = List[Float64]()
    for i in range(6):
        xs.append(Float64(i))
        ys.append(0.0)
        lens.append(Float64(i) / 5.0)
    var g = mapper_graph(xs, ys, lens, 3, 0.5, 1.5)
    assert_equal(len(g.x), 3)
    assert_equal(len(g.la), 2)
    assert_equal(len(g.la), len(g.lb))
    print("mapper ok")


def test_betti_curve_square() raises:
    # Scales 0, 2/3, 4/3, 2+: square cycle lives at scale index 2.
    var bc = betti_curve(sq_dm(square()), 4, 4)
    assert_equal(bc.b0[0], 4)
    assert_equal(bc.b0[3], 1)
    assert_equal(bc.b1[2], 1)
    assert_equal(bc.b1[3], 0)
    assert_equal(len(bc.scales), 4)
    print("betti curve ok")


def test_topo_loops_pentagon() raises:
    # Regular pentagon: median scale keeps the 5-cycle, drops diagonals.
    var xs = List[Float64]()
    var ys = List[Float64]()
    xs.append(1.0)
    ys.append(0.0)
    xs.append(0.309017)
    ys.append(0.9510565)
    xs.append(-0.809017)
    ys.append(0.5877853)
    xs.append(-0.809017)
    ys.append(-0.5877853)
    xs.append(0.309017)
    ys.append(-0.9510565)
    var lp = topo_loops(xs, ys, 4)
    assert_equal(lp.b1, 1)
    assert_true(len(lp.loops) >= 1)
    assert_true(len(lp.loops[0]) >= 3)
    assert_true(not lp.has_void)
    print("loops pentagon ok")


def main() raises:
    test_pipeline_square()
    test_pipeline_octahedron()
    test_degenerate()
    test_curvature()
    test_persistence_square()
    test_persistence_triangle()
    test_persistence_capped()
    test_merge_tree_two_peaks()
    test_mapper_chain()
    test_betti_curve_square()
    test_topo_loops_pentagon()
    print("ALL TOPO TESTS PASSED")
