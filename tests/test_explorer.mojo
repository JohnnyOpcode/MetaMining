"""Tests for metamining.sim + metamining.explorer."""

from std.math import isinf
from std.testing import assert_equal, assert_true

from metamining.explorer import (
    BranchState,
    ExpCfg,
    Finding,
    branch_note,
    branch_should_stop,
    buf_find_nl,
    done_json,
    finding_json,
    global_should_stop,
    msg_int,
    msg_kind,
    msg_num,
    msg_str,
    pareto,
    parse_finding,
    parse_tele,
    parse_vec,
    status_json,
    tele_int,
    tele_json,
    vec_json,
)
from metamining.scoring import lex_words
from metamining.sim import SimRng, sim_embed, sim_gen_text


def test_cfg() -> ExpCfg:
    return ExpCfg(
        "truth and confabulation",
        "sim",
        "",
        "",
        "",
        7,
        2,
        100,
        0.9,
        0.9,
    ).copy()


def test_rng() raises:
    var a = SimRng(1234)
    var b = SimRng(1234)
    for _ in range(8):
        assert_equal(a.next_u64(), b.next_u64())
    var c = SimRng(999)
    var d = SimRng(1)
    assert_true(d.next_u64() != c.next_u64())
    var e = SimRng(5)
    var u = e.next_unit()
    assert_true(u >= 0.0 and u < 1.0)
    print("rng ok")


def test_gen_text() raises:
    var t1 = sim_gen_text("truth", "truth", 0, 0, 3, 0.9, 7)
    var t2 = sim_gen_text("truth", "truth", 0, 0, 3, 0.9, 7)
    assert_equal(t1, t2)
    assert_true(t1.find("truth") >= 0)
    assert_true(t1.find("Current front: truth") >= 0)
    var t3 = sim_gen_text("truth", "truth", 0, 1, 3, 0.9, 7)
    assert_true(t3 != t1)
    var t4 = sim_gen_text("truth", "truth", 5, 0, 3, 0.9, 7)
    assert_true(t4 != t1)
    var t5 = sim_gen_text("truth", "elsewhere", 0, 0, 3, 0.9, 7)
    assert_true(t5.find("Current front: elsewhere") >= 0)
    var words = List[String]()
    lex_words(t1, 2, words)
    assert_true(len(words) >= 50)
    print("gen ok: " + t1)


def test_scores() raises:
    var fp = List[Float64]()
    sim_embed("some vein text with several terms", fp)
    assert_equal(len(fp), 64)
    var norm = 0.0
    for i in range(64):
        norm += fp[i] * fp[i]
    assert_true(norm > 0.99 and norm < 1.01)
    var fp2 = List[Float64]()
    sim_embed("some vein text with several terms", fp2)
    for i in range(64):
        assert_equal(fp[i], fp2[i])
    var other = List[Float64]()
    sim_embed("totally different words here", other)
    var diff = False
    for i in range(64):
        if fp[i] != other[i]:
            diff = True
    assert_true(diff)
    print("scores ok")


def test_branch_stops() raises:
    var cfg = test_cfg()
    var fp = List[Float64]()
    sim_embed("x", fp)
    # plateau: best never improves
    var p = BranchState(0)
    for _ in range(13):
        branch_note(p, cfg, 0.5, 0.9, False, fp, "t", 1.0, 1.0)
    assert_equal(branch_should_stop(p, cfg), "plateau")
    # dry: improving but never gold
    var d = BranchState(1)
    for i in range(25):
        branch_note(d, cfg, 0.5 + Float64(i) * 0.01, 0.9, False, fp, "t", 1.0, 1.0)
    assert_equal(branch_should_stop(d, cfg), "dry")
    # weeds: incoherent + half-plateau
    var w = BranchState(2)
    for _ in range(7):
        branch_note(w, cfg, 0.5, 0.1, False, fp, "t", 1.0, 1.0)
    assert_equal(branch_should_stop(w, cfg), "weeds")
    # incoherent but improving fast
    var q = BranchState(3)
    for i in range(6):
        branch_note(q, cfg, 0.1 + Float64(i) * 0.2, 0.1, False, fp, "t", 1.0, 1.0)
    assert_equal(branch_should_stop(q, cfg), "incoherent")
    # max steps
    var m = BranchState(4)
    for _ in range(100):
        branch_note(m, cfg, 0.95, 0.9, True, fp, "t", 1.0, 1.0)
    assert_equal(branch_should_stop(m, cfg), "max-steps")
    # healthy run continues
    var h = BranchState(5)
    branch_note(h, cfg, 0.95, 0.9, True, fp, "t", 1.0, 1.0)
    assert_equal(branch_should_stop(h, cfg), "")
    assert_equal(global_should_stop(39, cfg), "")
    assert_equal(global_should_stop(40, cfg), "global-weeds")
    print("stops ok")


def test_pareto() raises:
    var pool = List[Finding]()
    pool.append(Finding(0, 0, 0.9, 0.9, 0.0, 0.0, 0.0, True, "a", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(0, 1, 0.5, 0.5, 0.0, 0.0, 0.0, False, "b", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(1, 0, 0.95, 0.4, 0.0, 0.0, 0.0, True, "c", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(1, 1, 0.4, 0.95, 0.0, 0.0, 0.0, False, "d", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    var out = List[Int]()
    pareto(pool, out)
    assert_equal(len(out), 3)
    assert_equal(out[0], 0)
    assert_equal(out[1], 2)
    assert_equal(out[2], 3)
    print("pareto ok")


def test_wire() raises:
    assert_equal(test_cfg().repulse, 30)
    assert_equal(test_cfg().push, 0.90)
    assert_equal(test_cfg().plateau_k, 12)
    assert_equal(test_cfg().plateau_eps, 0.005)
    assert_equal(test_cfg().nogold_m, 25)
    assert_equal(test_cfg().min_coh, 0.25)
    assert_equal(test_cfg().coh_c, 6)
    assert_equal(test_cfg().global_stall, 40)
    var f = Finding(
        2, 9, 0.93, 0.88, 12.5, 77.0, 33.0, True, 'say "hi"',
        3, 1, 0, 1.25, 5, 0.95, "front X", "journal_x.json", 4,
    )
    var line = finding_json(f, 4)
    assert_equal(msg_kind(line), "finding")
    var g = parse_finding(line)
    assert_equal(g.branch, 2)
    assert_equal(g.step, 9)
    assert_equal(g.nov, 0.93)
    assert_true(g.gold)
    assert_equal(g.z, 33.0)
    assert_equal(g.text, 'say "hi"')
    assert_equal(g.b0, 3)
    assert_equal(g.b1, 1)
    assert_equal(g.b2, 0)
    assert_equal(g.cd, 1.25)
    assert_equal(g.persona, 5)
    assert_equal(g.temp, 0.95)
    assert_equal(g.loc, "front X")
    assert_equal(g.src, "journal_x.json")
    assert_equal(g.run, 4)
    var old = String(
        '{"t":"finding","run":4,"branch":1,"step":2,"novelty":0.5,'
        '"coherence":7.5,"x":1.0,"y":2.0,"z":3.0,"gold":false,"text":"legacy"}'
    )
    var h = parse_finding(old)
    assert_equal(h.branch, 1)
    assert_equal(h.run, 4)
    assert_equal(h.text, "legacy")
    assert_equal(h.b0, 0)
    assert_equal(h.b1, 0)
    assert_equal(h.b2, 0)
    assert_equal(h.cd, 0.0)
    assert_equal(h.persona, 0)
    assert_equal(h.temp, 0.0)
    assert_equal(h.loc, "")
    assert_equal(h.src, "")
    var st = status_json(1, 5, 0.7, "")
    assert_equal(msg_kind(st), "status")
    assert_equal(msg_num(st, "best"), 0.7)
    var dn = done_json(1, 30, 0.95, "plateau")
    assert_equal(msg_kind(dn), "done")
    assert_equal(msg_str(dn, "reason"), "plateau")
    print("wire ok")


def test_wire2() raises:
    var v = List[Float64]()
    v.append(0.5)
    v.append(-0.25)
    var line = vec_json(2, 9, 4, v)
    assert_equal(msg_kind(line), "vec")
    var back = List[Float64]()
    var m = parse_vec(line, back)
    assert_equal(m.branch, 2)
    assert_equal(m.step, 9)
    assert_equal(m.run, 4)
    assert_equal(len(back), 2)
    assert_equal(back[0], 0.5)
    assert_equal(back[1], -0.25)
    var t = tele_json(1, 4, 7, 0.9, 2, 3, 66, 1, 2, 0, 1.5, 0.25, 3.75, 4, 10, 2, 3450, 120, 800, 150, 1.1)
    assert_equal(msg_kind(t), "tele")
    assert_equal(msg_num(t, "run"), 4.0)
    assert_equal(msg_num(t, "temp"), 0.9)
    assert_equal(msg_num(t, "streak"), 2.0)
    assert_equal(msg_num(t, "persona"), 3.0)
    assert_equal(msg_num(t, "b1"), 2.0)
    assert_equal(msg_num(t, "cd"), 1.5)
    assert_equal(msg_num(t, "judges"), 4.0)
    assert_equal(msg_num(t, "r_calls"), 10.0)
    assert_equal(msg_num(t, "e_calls"), 2.0)
    assert_equal(msg_num(t, "r_ms"), 3450.0)
    assert_equal(msg_num(t, "e_ms"), 120.0)
    assert_equal(msg_num(t, "tok_in"), 800.0)
    assert_equal(msg_num(t, "tok_out"), 150.0)
    assert_equal(msg_num(t, "push"), 1.1)
    assert_equal(msg_num('{"t":"tele","temp":0.9}', "push"), 0.0)
    print("wire2 ok")


def test_msg_int() raises:
    assert_equal(msg_int('{"t":"tele","streak":2}', "streak"), 2)
    assert_equal(msg_int('{"t":"tele"}', "streak"), 0)
    assert_equal(msg_int('{"t":"tele","streak":1e999}', "streak"), 0)
    assert_equal(msg_int('{"t":"tele","streak":-1e999}', "streak"), 0)
    print("msg_int ok")


def test_parse_finite() raises:
    var f = parse_finding(
        '{"t":"finding","branch":1e999,"step":2,"novelty":1e999,'
        '"coherence":7.5,"text":"x"}'
    )
    assert_equal(f.branch, 0)
    assert_equal(f.step, 2)
    assert_equal(f.nov, 0.0)
    assert_equal(f.coh, 7.5)
    var vv = List[Float64]()
    var m = parse_vec('{"t":"vec","branch":1,"step":2,"vec":[1e999,0.5]}', vv)
    assert_equal(m.branch, 1)
    assert_equal(m.run, 0)
    assert_equal(len(vv), 2)
    assert_equal(vv[0], 0.0)
    assert_equal(vv[1], 0.5)
    print("parse finite ok")


def test_buf_find_nl() raises:
    assert_equal(buf_find_nl("aaa\nbbb\nccc", 0), 3)
    assert_equal(buf_find_nl("aaa\nbbb\nccc", 4), 7)
    assert_equal(buf_find_nl("aaa\nbbb\nccc", 8), -1)
    assert_equal(buf_find_nl("aaa\nbbb\nccc", 100), -1)
    assert_equal(buf_find_nl("no newlines", 0), -1)
    assert_equal(buf_find_nl("", 0), -1)
    assert_equal(buf_find_nl("\n", 0), 0)
    assert_equal(buf_find_nl("a\n", 2), -1)
    assert_equal(buf_find_nl("héllo wörld\nsecond ✓ line\n", 0), 13)
    assert_equal(buf_find_nl("héllo wörld\nsecond ✓ line\n", 14), 29)
    assert_equal(buf_find_nl("— em dash, ✓ check, café", 0), -1)
    print("buf find nl ok")


def test_parse_tele() raises:
    var t = tele_json(1, 4, 7, 0.9, 2, 3, 66, 1, 2, 0, 1.5, 0.25, 3.75, 4, 10, 2, 3450, 120, 800, 150, 1.1)
    var m = parse_tele(t)
    assert_equal(m.run, 4)
    assert_equal(m.temp, 0.9)
    assert_equal(m.streak, 2.0)
    assert_equal(m.persona, 3.0)
    assert_equal(m.energy, 66.0)
    assert_equal(m.b0, 1.0)
    assert_equal(m.b1, 2.0)
    assert_equal(m.b2, 0.0)
    assert_equal(m.cd, 1.5)
    assert_equal(m.sheaf, 0.25)
    assert_equal(m.entropy, 3.75)
    assert_equal(m.judges, 4.0)
    assert_equal(m.r_calls, 10.0)
    assert_equal(m.e_calls, 2.0)
    assert_equal(m.r_ms, 3450.0)
    assert_equal(m.e_ms, 120.0)
    assert_equal(m.tok_in, 800.0)
    assert_equal(m.tok_out, 150.0)
    assert_equal(m.push, 1.1)
    assert_equal(m.step, 7.0)
    # Missing keys read 0, matching msg_num/msg_int on the same line.
    var sparse = parse_tele('{"t":"tele","temp":0.9}')
    assert_equal(sparse.temp, 0.9)
    assert_equal(sparse.push, 0.0)
    assert_equal(sparse.run, 0)
    assert_equal(tele_int(sparse.streak), 0)
    # Non-finite stays raw so the caller can report and clamp it.
    var poison = parse_tele('{"t":"tele","run":1,"temp":1e999,"streak":1e999}')
    assert_true(isinf(poison.temp))
    assert_true(isinf(poison.streak))
    assert_equal(tele_int(poison.streak), 0)
    assert_equal(tele_int(2.0), 2)
    assert_equal(tele_int(-1e999), 0)
    var raised = False
    try:
        _ = parse_tele("garbage{{{")
    except:
        raised = True
    assert_true(raised)
    print("parse tele ok")


def main() raises:
    test_rng()
    test_gen_text()
    test_scores()
    test_branch_stops()
    test_pareto()
    test_wire()
    test_wire2()
    test_msg_int()
    test_parse_finite()
    test_buf_find_nl()
    test_parse_tele()
    print("ALL EXPLORER TESTS PASSED")
