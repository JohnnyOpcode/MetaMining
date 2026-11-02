"""Tests for metamining.json: parse, render, accessors."""

from std.math import isinf
from std.testing import assert_equal, assert_true

from metamining.json import (
    J_ARR,
    J_BOOL,
    J_NULL,
    J_NUM,
    J_OBJ,
    J_STR,
    doc_at,
    doc_bool,
    doc_find,
    doc_kind,
    doc_len,
    doc_num,
    doc_obool,
    doc_onum,
    doc_ostr,
    doc_render,
    doc_root,
    doc_str,
    j_escape,
    j_render_num,
    parse_json,
)


def test_flat_object() raises:
    var d = parse_json(String('{"a":1,"b":true,"c":null,"d":"x"}'))
    var r = doc_root(d)
    assert_equal(doc_kind(d, r), J_OBJ)
    assert_equal(doc_onum(d, r, "a"), 1.0)
    assert_true(doc_obool(d, r, "b"))
    assert_equal(doc_kind(d, doc_find(d, r, "c")), J_NULL)
    assert_equal(doc_ostr(d, r, "d"), "x")
    assert_equal(doc_find(d, r, "zzz"), -1)
    assert_equal(doc_ostr(d, r, "zzz"), "")
    print("flat_object ok")


def test_nested() raises:
    var d = parse_json(String('{"choices":[{"message":{"content":"hi"}}],"n":2}'))
    var r = doc_root(d)
    var ch = doc_find(d, r, "choices")
    assert_equal(doc_kind(d, ch), J_ARR)
    assert_equal(doc_len(d, ch), 1)
    assert_equal(doc_onum(d, r, "n"), 2.0)
    var first = doc_at(d, ch, 0)
    var msg = doc_find(d, first, "message")
    assert_equal(doc_ostr(d, msg, "content"), "hi")
    assert_equal(doc_at(d, ch, 9), -1)
    assert_equal(doc_kind(d, 9999), J_NULL)
    print("nested ok")


def test_numbers() raises:
    var d = parse_json(String("[1,-2,0.5,-0.25,1e3,2E-2]"))
    var r = doc_root(d)
    assert_equal(doc_kind(d, r), J_ARR)
    assert_equal(doc_num(d, doc_at(d, r, 0)), 1.0)
    assert_equal(doc_num(d, doc_at(d, r, 1)), -2.0)
    assert_equal(doc_num(d, doc_at(d, r, 2)), 0.5)
    assert_equal(doc_num(d, doc_at(d, r, 3)), -0.25)
    assert_equal(doc_num(d, doc_at(d, r, 4)), 1000.0)
    assert_equal(doc_num(d, doc_at(d, r, 5)), 0.02)
    print("numbers ok")


def test_escapes() raises:
    var d = parse_json(String('{"s":"a\\"b\\\\c\\/d\\n\\t\\u00e9"}'))
    assert_equal(doc_ostr(d, doc_root(d), "s"), String("a\"b\\c/d\n\té"))
    var w = parse_json(String('{"e":"\\ud83d\\ude00"}'))
    assert_equal(doc_kind(w, doc_root(w)), J_OBJ)
    assert_equal(doc_kind(w, doc_find(w, doc_root(w), "e")), J_STR)
    print("escapes ok")


def test_render_roundtrip() raises:
    var raw = String(
        '{"t":"finding","branch":3,"novelty":0.95,"gold":true,'
        '"tags":["a","b"],"n":null,"neg":-12}'
    )
    var d = parse_json(raw)
    var out = doc_render(d)
    var d2 = parse_json(out)
    assert_equal(doc_render(d2), out)
    print("roundtrip ok: " + out)


def test_emit_helpers() raises:
    assert_equal(j_escape(String("q\"z")), String('q\\"z'))
    assert_equal(j_render_num(42.0), "42")
    assert_equal(j_render_num(-12.0), "-12")
    assert_equal(j_render_num(0.5), "0.5")
    var r = doc_render(parse_json(String("[1,2]")))
    assert_equal(r, "[1,2]")
    assert_equal(doc_str(parse_json(String('"hi"')), 0), "hi")
    assert_true(doc_bool(parse_json(String("true")), 0))
    print("emit ok")


def test_rejects_garbage() raises:
    var bad = List[String]()
    bad.append("{")
    bad.append("[1,]")
    bad.append('{"a":}')
    bad.append("tru")
    bad.append('{"a":1}trailing')
    bad.append("[1 2]")
    for i in range(len(bad)):
        var failed = False
        try:
            var v = parse_json(bad[i])
        except:
            failed = True
        assert_true(failed)
    print("rejects ok")


def test_huge_exponent_fast() raises:
    # Pre-fix these hung in billion-iteration scale loops; completion is the check.
    var big = parse_json(String("1e1000000000"))
    assert_true(isinf(doc_num(big, doc_root(big))))
    var small = parse_json(String("1e-1000000000"))
    assert_equal(doc_num(small, doc_root(small)), 0.0)
    var s = String("1e")
    for _ in range(100000):
        s += "9"
    var wide = parse_json(s)
    assert_true(isinf(doc_num(wide, doc_root(wide))))
    var neg = parse_json(String("-1e1000000000"))
    assert_true(isinf(doc_num(neg, doc_root(neg))))
    assert_true(doc_num(neg, doc_root(neg)) < 0.0)
    print("huge_exponent ok")


def test_deep_nesting_rejects() raises:
    var deep = String()
    for _ in range(2000):
        deep += "["
    for _ in range(2000):
        deep += "]"
    var failed = False
    try:
        var v = parse_json(deep)
    except:
        failed = True
    assert_true(failed)
    var ok = String()
    for _ in range(200):
        ok += "["
    ok += "1"
    for _ in range(200):
        ok += "]"
    var d = parse_json(ok)
    assert_equal(doc_kind(d, doc_root(d)), J_ARR)
    print("deep_nesting ok")


def test_nonfinite_render_reparses() raises:
    var inf = Float64(1e308) * 10.0
    var nan = inf - inf
    assert_equal(j_render_num(inf), "0")
    assert_equal(j_render_num(-inf), "0")
    assert_equal(j_render_num(nan), "0")
    var d = parse_json(j_render_num(inf))
    assert_equal(doc_num(d, doc_root(d)), 0.0)
    # Mantissa-smuggle: inf mantissa with negative exponent was inf/inf = NaN.
    var mant = String()
    for _ in range(400):
        mant += "9"
    mant += "e-400"
    var m = parse_json(mant)
    assert_true(isinf(doc_num(m, doc_root(m))))
    var out = doc_render(m)
    assert_equal(out, "0")
    var m2 = parse_json(out)
    assert_equal(doc_render(m2), "0")
    var tiny = parse_json(String("1e-400"))
    assert_equal(doc_render(tiny), "0")
    print("nonfinite ok")


def main() raises:
    test_flat_object()
    test_nested()
    test_numbers()
    test_escapes()
    test_render_roundtrip()
    test_emit_helpers()
    test_rejects_garbage()
    test_huge_exponent_fast()
    test_deep_nesting_rejects()
    test_nonfinite_render_reparses()
    print("ALL JSON TESTS PASSED")
