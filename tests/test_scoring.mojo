"""Tests for metamining.scoring: KDE, lexical, composite, coherence."""

from std.testing import assert_equal, assert_true

from metamining.scoring import (
    blend_judge,
    clamp_coh,
    coherence_base,
    composite_novelty,
    is_gold,
    kde_novelty,
    lex_words,
    lexical_novelty,
    median_vote,
    novelty_stationary,
    parse_judge,
    round1,
    vein_best_cos,
    vein_nearest,
    vein_repulse_factor,
)


def v2(x: Float64, y: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(x)
    v.append(y)
    return v.copy()


def close(a: Float64, b: Float64, tol: Float64) raises:
    var d = a - b
    if d < 0.0:
        d = -d
    assert_true(d <= tol)


def test_lex_words() raises:
    var out = List[String]()
    lex_words("Hello, WORLD! a ab abcde123 xy", 3, out)
    assert_equal(len(out), 3)
    assert_equal(out[0], "hello")
    assert_equal(out[1], "world")
    assert_equal(out[2], "abcde")
    var out2 = List[String]()
    lex_words("a ab abc", 2, out2)
    assert_equal(len(out2), 2)
    print("lex_words ok")


def test_kde() raises:
    var empty = List[List[Float64]]()
    assert_equal(kde_novelty(v2(1.0, 0.0), empty), 1.0)
    var same = List[List[Float64]]()
    same.append(v2(1.0, 0.0))
    assert_true(kde_novelty(v2(1.0, 0.0), same) < 0.001)
    var orth = List[List[Float64]]()
    orth.append(v2(0.0, 1.0))
    close(kde_novelty(v2(1.0, 0.0), orth), 0.99326, 0.001)
    var mix = List[List[Float64]]()
    mix.append(v2(0.0, 1.0))
    mix.append(v2(1.0, 0.0))
    close(kde_novelty(v2(1.0, 0.0), mix), 0.48907, 0.002)
    print("kde ok")


def test_lexical() raises:
    var empty = List[String]()
    assert_equal(lexical_novelty("anything here", empty), 1.0)
    var hist = List[String]()
    hist.append("the quick brown fox")
    assert_equal(lexical_novelty("a b c 12 !", hist), 0.5)
    var rep = List[String]()
    for _ in range(15):
        rep.append("the quick brown fox")
    assert_true(lexical_novelty("the quick brown fox", rep) < 0.01)
    assert_true(lexical_novelty("xylophone zebras quantum", rep) > 0.99)
    print("lexical ok")


def test_composite() raises:
    assert_equal(composite_novelty(1.0, 1.0, 1.0), 1.0)
    assert_equal(composite_novelty(0.0, 0.0, 0.0), 0.0)
    close(composite_novelty(1.0, 0.0, 0.0), 0.6, 1e-12)
    close(composite_novelty(0.5, 0.5, 0.5), 0.5, 1e-12)
    print("composite ok")


def test_coherence() raises:
    var words = String()
    for a in range(3):
        for b in range(26):
            words += chr(97 + a) + chr(97 + b) + " "
    close(coherence_base(words, 0.7), 10.0, 1e-9)
    assert_equal(coherence_base(words, 0.15), 4.0)
    assert_equal(coherence_base(words, 0.0), 4.0)
    close(coherence_base("alpha beta gamma delta", 0.7), 4.0, 1e-9)
    assert_equal(blend_judge(10.0, 10.0), 10.0)
    assert_equal(blend_judge(4.0, 10.0), 7.9)
    assert_equal(round1(7.94), 7.9)
    assert_equal(round1(7.96), 8.0)
    assert_equal(clamp_coh(99.0), 10.0)
    assert_equal(clamp_coh(-3.0), 1.0)
    assert_true(is_gold(0.9, 7.0, 0.9))
    assert_true(not is_gold(0.9, 6.0, 0.9))
    assert_true(not is_gold(0.85, 9.0, 0.9))
    print("coherence ok")


def test_judge_parse() raises:
    assert_equal(parse_judge("Score: 8"), 8.0)
    assert_equal(parse_judge("99 bottles"), 10.0)
    assert_equal(parse_judge("no digits here"), 6.0)
    assert_equal(parse_judge("100"), 6.0)
    assert_equal(parse_judge("Score is 7 out of 10"), 7.0)
    assert_equal(parse_judge("v2.0"), 1.0)
    print("judge_parse ok")


def test_median() raises:
    var one = List[Float64]()
    one.append(7.0)
    assert_equal(median_vote(one), 7.0)
    var three = List[Float64]()
    three.append(9.0)
    three.append(4.0)
    three.append(7.0)
    assert_equal(median_vote(three), 7.0)
    var four = List[Float64]()
    four.append(2.0)
    four.append(8.0)
    four.append(4.0)
    four.append(6.0)
    assert_equal(median_vote(four), 5.0)
    var five = List[Float64]()
    five.append(1.0)
    five.append(10.0)
    five.append(6.0)
    five.append(7.0)
    five.append(8.0)
    assert_equal(median_vote(five), 7.0)
    print("median ok")


def test_stationary() raises:
    var flat = List[Float64]()
    for _ in range(20):
        flat.append(0.5)
    assert_true(novelty_stationary(flat))
    var rising = List[Float64]()
    for i in range(20):
        rising.append(0.1 + Float64(i) * 0.03)
    assert_true(not novelty_stationary(rising))
    var short = List[Float64]()
    for _ in range(15):
        short.append(0.5)
    assert_true(not novelty_stationary(short))
    var jump = List[Float64]()
    for _ in range(8):
        jump.append(0.3)
    for _ in range(8):
        jump.append(0.6)
    assert_true(not novelty_stationary(jump))
    var drift = List[Float64]()
    for i in range(16):
        drift.append(0.5 + Float64(i) * 0.005)
    assert_true(not novelty_stationary(drift))
    print("stationary ok")


def test_veins() raises:
    var v = v2(1.0, 0.0)
    var empty = List[List[Float64]]()
    assert_equal(vein_repulse_factor(v, empty), 1.0)
    assert_equal(vein_best_cos(v, empty), -1.0)
    var same = List[List[Float64]]()
    same.append(v2(1.0, 0.0))
    assert_equal(vein_repulse_factor(v, same), 0.5)
    close(vein_best_cos(v, same), 1.0, 1e-9)
    var orth = List[List[Float64]]()
    orth.append(v2(0.0, 1.0))
    assert_equal(vein_repulse_factor(v, orth), 1.0)
    var far = List[List[Float64]]()
    far.append(v2(0.96, (1.0 - 0.96 * 0.96) ** 0.5))
    assert_equal(vein_repulse_factor(v, far), 1.0)
    var near = List[List[Float64]]()
    near.append(v2(0.98, (1.0 - 0.98 * 0.98) ** 0.5))
    assert_equal(vein_repulse_factor(v, near), 0.5)
    var mix = List[List[Float64]]()
    var w3 = List[Float64]()
    w3.append(1.0)
    w3.append(0.0)
    w3.append(0.0)
    mix.append(w3.copy())
    mix.append(v2(0.0, 1.0))
    mix.append(v2(0.99, (1.0 - 0.99 * 0.99) ** 0.5))
    var out = List[Float64]()
    assert_true(vein_nearest(v, mix, out))
    assert_equal(len(out), 2)
    close(out[0], 0.99, 1e-9)
    var out2 = List[Float64]()
    assert_true(not vein_nearest(v, empty, out2))
    assert_equal(len(out2), 0)
    print("veins ok")


def main() raises:
    test_lex_words()
    test_kde()
    test_lexical()
    test_composite()
    test_coherence()
    test_judge_parse()
    test_median()
    test_stationary()
    test_veins()
    print("ALL SCORING TESTS PASSED")
