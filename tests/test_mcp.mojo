"""Tests for metamining.mcp: pure JSON-RPC helpers and tool catalog.

No sockets: server execution is covered by the self-test e2e checks.
"""

from std.testing import assert_equal, assert_true

from metamining.json import (
    Doc,
    J_OBJ,
    doc_at,
    doc_find,
    doc_kind,
    doc_len,
    doc_ostr,
    doc_root,
    j_render_at,
    parse_json,
)
from metamining.mcp import (
    mcp_err,
    mcp_has_id,
    mcp_id_json,
    mcp_is_object,
    mcp_negotiate,
    mcp_ok,
    mcp_origin_ok,
    mcp_tool_text,
    mcp_tools_json,
)


def test_negotiate() raises:
    assert_equal(mcp_negotiate("2025-06-18"), "2025-06-18")
    assert_equal(mcp_negotiate("2025-03-26"), "2025-03-26")
    assert_equal(mcp_negotiate("2024-11-05"), "2024-11-05")
    assert_equal(mcp_negotiate("1999-01-01"), "2025-06-18")
    assert_equal(mcp_negotiate(""), "2025-06-18")
    print("negotiate ok")


def test_origin() raises:
    var none = Dict[String, String]()
    assert_true(mcp_origin_ok(none))
    var loop = Dict[String, String]()
    loop["origin"] = "http://127.0.0.1:3000"
    assert_true(mcp_origin_ok(loop))
    loop["origin"] = "http://localhost:5173/app"
    assert_true(mcp_origin_ok(loop))
    var evil = Dict[String, String]()
    evil["origin"] = "https://evil.test"
    evil["host"] = "127.0.0.1:8000"
    assert_true(not mcp_origin_ok(evil))
    var nul = Dict[String, String]()
    nul["origin"] = "null"
    assert_true(not mcp_origin_ok(nul))
    var same = Dict[String, String]()
    same["origin"] = "https://box.lan:8000"
    same["host"] = "box.lan:8000"
    assert_true(mcp_origin_ok(same))
    print("origin ok")


def test_envelope() raises:
    var d = parse_json('{"jsonrpc":"2.0","id":7,"method":"ping"}')
    var r = doc_root(d)
    assert_true(mcp_is_object(d, r))
    assert_true(mcp_has_id(d, r))
    assert_equal(mcp_id_json(d, r), "7")
    var ds = parse_json('{"jsonrpc":"2.0","id":"a-b","method":"ping"}')
    assert_equal(mcp_id_json(ds, doc_root(ds)), '"a-b"')
    var dn = parse_json('{"jsonrpc":"2.0","method":"ping"}')
    assert_true(not mcp_has_id(dn, doc_root(dn)))
    assert_equal(mcp_id_json(dn, doc_root(dn)), "null")
    var ok = parse_json(mcp_ok("3", '{"a":1}'))
    assert_equal(doc_ostr(ok, doc_root(ok), "jsonrpc"), "2.0")
    var er = parse_json(mcp_err("3", -32601, "nope"))
    var ern = doc_find(er, doc_root(er), "error")
    assert_true(ern >= 0 and doc_kind(er, ern) == J_OBJ)
    var t = parse_json(mcp_tool_text("hi", False))
    var carr = doc_find(t, doc_root(t), "content")
    assert_true(carr >= 0 and doc_len(t, carr) == 1)
    var te = parse_json(mcp_tool_text("bad", True))
    assert_true(doc_find(te, doc_root(te), "isError") >= 0)
    # Arg-copy depends on verbatim node rendering (strings stay quoted).
    var ar = parse_json('{"concept":"a b","steps":4}')
    var rr = doc_root(ar)
    assert_equal(j_render_at(ar, doc_find(ar, rr, "concept")), '"a b"')
    assert_equal(j_render_at(ar, doc_find(ar, rr, "steps")), "4")
    print("envelope ok")


def test_catalog() raises:
    var d = parse_json(mcp_tools_json())
    var r = doc_root(d)
    var tools = doc_find(d, r, "tools")
    assert_true(tools >= 0)
    assert_equal(doc_len(d, tools), 11)
    var names = String(",")
    for i in range(doc_len(d, tools)):
        var t = doc_at(d, tools, i)
        var nm = doc_ostr(d, t, "name")
        assert_true(nm != "")
        assert_true(doc_ostr(d, t, "description") != "")
        var sch = doc_find(d, t, "inputSchema")
        assert_true(sch >= 0 and doc_kind(d, sch) == J_OBJ)
        names += nm + ","
    assert_true(names.find(",start_expedition,") >= 0)
    assert_true(names.find(",expedition_status,") >= 0)
    assert_true(names.find(",get_findings,") >= 0)
    assert_true(names.find(",search_claims,") >= 0)
    assert_true(names.find(",stop_expedition,") >= 0)
    assert_true(names.find(",list_journals,") >= 0)
    assert_true(names.find(",get_journal,") >= 0)
    assert_true(names.find(",save_journal,") >= 0)
    assert_true(names.find(",load_journal,") >= 0)
    assert_true(names.find(",get_topology,") >= 0)
    assert_true(names.find(",list_models,") >= 0)
    print("catalog ok")


def main() raises:
    test_negotiate()
    test_origin()
    test_envelope()
    test_catalog()
    print("ALL MCP TESTS PASSED")
