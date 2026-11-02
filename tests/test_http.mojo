"""Tests for metamining.http: parse, framing, client over a stub."""

from std.testing import assert_equal, assert_true

from metamining.http import (
    dechunk,
    hget,
    http_get,
    http_post_json,
    parse_endpoint_url,
    parse_http_request,
    parse_http_response,
    parse_query,
    pct_decode,
    read_web_file,
    resp_bytes,
    sse_event,
    status_text,
)
from metamining.libc import (
    accept_conn,
    bind_listen,
    child_exit,
    close_fd,
    fork_child,
    poll_one,
    set_timeout,
    socket_port,
    tcp_recv_some,
    tcp_send_all,
    wait_child,
)


def test_parse_get() raises:
    var raw = String(
        "GET /api/state?concept=a%20b&seed=7 HTTP/1.1\r\n"
        "Host: x\r\nX-Custom: v\r\n\r\n"
    )
    var r = parse_http_request(raw)
    assert_true(r.complete)
    assert_equal(r.method, "GET")
    assert_equal(r.path, "/api/state")
    assert_equal(hget(r.query, "concept"), "a b")
    assert_equal(hget(r.query, "seed"), "7")
    assert_equal(hget(r.headers, "x-custom"), "v")
    assert_equal(r.consumed, raw.byte_length())
    print("parse_get ok")


def test_parse_post() raises:
    var raw = String(
        "POST /api/control HTTP/1.1\r\nContent-Length: 15\r\n\r\n"
        + '{"a":123456789}'
    )
    var r = parse_http_request(raw)
    assert_true(r.complete)
    assert_equal(r.method, "POST")
    assert_equal(r.body, '{"a":123456789}')
    var short = String("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")
    var r2 = parse_http_request(short)
    assert_true(not r2.complete)
    assert_equal(r2.consumed, 0)
    var noclen = String("GET /h HTTP/1.1\r\n\r\nEXTRA")
    var r3 = parse_http_request(noclen)
    assert_true(r3.complete)
    assert_equal(r3.body, "")
    print("parse_post ok")


def test_parse_response() raises:
    var raw = String(
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{}"
    )
    var r = parse_http_response(raw)
    assert_equal(r.status, 401)
    assert_equal(hget(r.headers, "content-type"), "application/json")
    assert_equal(r.body, "{}")
    print("parse_response ok")


def test_framing_helpers() raises:
    assert_equal(pct_decode("a+b%20c%21"), "a b c!")
    assert_equal(dechunk("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), "hello world")
    assert_equal(sse_event("a\nb"), "data: a\ndata: b\n\n")
    assert_equal(status_text(404), "Not Found")
    var resp = resp_bytes(200, "text/plain", "hi")
    assert_true(resp.startswith("HTTP/1.1 200 OK\r\n"))
    assert_true(resp.find("Content-Length: 2\r\n") >= 0)
    assert_true(resp.endswith("hi"))
    var q = parse_query("a=1&b=&c")
    assert_equal(hget(q, "a"), "1")
    assert_equal(hget(q, "b"), "")
    assert_equal(hget(q, "c"), "")
    var nf = read_web_file("/nonexistent-dir-xyz", "index.html")
    assert_true(not nf.found)
    var trav = read_web_file("web", "../secret")
    assert_true(not trav.found)
    print("framing ok")


def stub_once(srv: Int, expect_sub: String, resp_body: String, chunked: Bool):
    if poll_one(srv, 15000) != 1:
        child_exit(3)
    var conn = accept_conn(srv)
    _ = set_timeout(conn, 10)
    var req = String()
    for _ in range(8):
        req += tcp_recv_some(conn, 4096)
        if expect_sub == "" or req.find(expect_sub) >= 0:
            break
    var code = 0
    if expect_sub != "" and req.find(expect_sub) < 0:
        code = 2
    var resp: String
    if chunked:
        resp = String(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        )
    else:
        resp = (
            String(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                "Content-Length: "
            )
            + String(resp_body.byte_length())
            + "\r\nConnection: close\r\n\r\n"
            + resp_body
        )
    _ = tcp_send_all(conn, resp)
    _ = close_fd(conn)
    _ = close_fd(srv)
    child_exit(code)


def run_stub_case(
    path: String, post_body: String, expect_sub: String, chunked: Bool
) raises -> String:
    var srv = bind_listen("127.0.0.1", 0)
    assert_true(srv >= 0)
    var port = socket_port(srv)
    var pid = fork_child()
    assert_true(pid >= 0)
    if pid == 0:
        stub_once(srv, expect_sub, '{"id":"m1"}', chunked)
        child_exit(0)
    _ = close_fd(srv)
    var url = parse_endpoint_url("http://127.0.0.1:" + String(port))
    assert_true(url.ok)
    var body: String
    if post_body == "":
        var r = http_get(url, path, "")
        assert_true(r.ok)
        assert_equal(r.status, 200)
        body = r.body
    else:
        var r = http_post_json(url, path, post_body, "")
        assert_true(r.ok)
        assert_equal(r.status, 200)
        body = r.body
    var w = wait_child(pid, False)
    assert_equal(w.pid, pid)
    assert_equal(w.status, 0)
    return body


def test_client() raises:
    var g = run_stub_case("/v1/models", "", "GET /v1/models", False)
    assert_equal(g, '{"id":"m1"}')
    var p = run_stub_case("/v1/responses", '{"model":"m"}', '"model":"m"', False)
    assert_equal(p, '{"id":"m1"}')
    var c = run_stub_case("/chunk", "", "", True)
    assert_equal(c, "hello world")
    print("client ok")


def test_endpoint_url() raises:
    var u = parse_endpoint_url("https://api.meta.ai/v1/responses")
    assert_true(u.ok)
    assert_equal(u.scheme, "https")
    assert_equal(u.host, "api.meta.ai")
    assert_equal(u.port, 443)
    assert_equal(u.base, "/v1/responses")
    var h = parse_endpoint_url("http://10.1.2.3:11434")
    assert_true(h.ok)
    assert_equal(h.port, 11434)
    assert_equal(h.base, "")
    var b = parse_endpoint_url("api.meta.ai")
    assert_true(b.ok)
    assert_equal(b.scheme, "https")
    assert_true(not parse_endpoint_url("").ok)
    assert_true(not parse_endpoint_url("ftp://x").ok)
    assert_true(not parse_endpoint_url("http://:80").ok)
    print("endpoint_url ok")


def main() raises:
    test_parse_get()
    test_parse_post()
    test_parse_response()
    test_framing_helpers()
    test_client()
    test_endpoint_url()
    print("ALL HTTP TESTS PASSED")
