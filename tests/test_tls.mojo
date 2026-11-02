"""Tests for metamining.tls: resolve, proxy parse, live Meta handshake.

The live test hits https://api.meta.ai (no key; expects 401) and is
skipped with META_OFFLINE=1.
"""

from std.os.env import getenv
from std.testing import assert_equal, assert_true

from metamining.tls import (
    errno_now,
    getaddrinfo_ipv4,
    parse_proxy_url,
    tls_close,
    tls_connect,
    tls_read_some,
    tls_write_all,
)


def test_resolve_localhost() raises:
    var ip = getaddrinfo_ipv4("localhost", "443")
    assert_true(ip.ok)
    assert_equal(Int(ip.b0), 127)
    assert_equal(Int(ip.b3), 1)
    assert_true(errno_now() >= 0)
    print("resolve ok")


def test_proxy_parse() raises:
    var p = parse_proxy_url("http://127.0.0.1:36623")
    assert_true(p.ok)
    assert_equal(p.host, "127.0.0.1")
    assert_equal(p.port, 36623)
    assert_equal(p.user, "")
    var q = parse_proxy_url("http://u:pw@10.0.0.2:8080/")
    assert_true(q.ok)
    assert_equal(q.user, "u")
    assert_equal(q.pw, "pw")
    assert_equal(q.port, 8080)
    assert_true(not parse_proxy_url("").ok)
    assert_true(not parse_proxy_url("notaurl").ok)
    print("proxy_parse ok")


def test_live_meta() raises:
    if getenv("META_OFFLINE", "") == "1":
        print("live_meta SKIPPED (META_OFFLINE=1)")
        return
    var c = tls_connect("api.meta.ai", 443, "")
    if not c.ok:
        print("live connect failed: " + c.err + " verify=" + String(c.verify))
    assert_true(c.ok)
    assert_equal(c.verify, 0)
    var req = String(
        "GET /v1/models HTTP/1.1\r\nHost: api.meta.ai\r\n"
        "Connection: close\r\nUser-Agent: metamining-tls-test\r\n\r\n"
    )
    assert_true(tls_write_all(c, req) > 0)
    var resp = String()
    while resp.byte_length() < 131072:
        var chunk = tls_read_some(c, 16384)
        if chunk == "":
            break
        resp += chunk
    tls_close(c)
    print("live bytes: " + String(resp.byte_length()))
    var head = resp
    var cut = resp.find("\r\n")
    if cut > 0:
        head = String(resp[byte=0:cut])
    print("live status: " + head)
    assert_true(resp.find("401") >= 0)
    var bad = tls_connect("api.meta.ai", 443, "wrong.invalid")
    var enforced = (not bad.ok) or bad.verify != 0
    tls_close(bad)
    assert_true(enforced)
    print("live_meta ok (verify enforced)")


def main() raises:
    test_resolve_localhost()
    test_proxy_parse()
    test_live_meta()
    print("ALL TLS TESTS PASSED")
